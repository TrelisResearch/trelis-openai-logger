Below is a practical blueprint for building a drop-in replacement for openai.OpenAI that logs every request/response to a PostgreSQL database. It borrows the “import-swap” idea used by OpenPipe’s SDK (which simply tells you to write from openpipe import OpenAI and everything else just works)
docs.openpipe.ai
 and the monkey-patching pattern shown in wrappers_delight 
GitHub
, but swaps file/HTTP logging for a robust relational store.

1. Project layout

openai_pg_logger/
├── openai_pg_logger/
│   ├── __init__.py     # exposes `OpenAI` & helper APIs
│   ├── db.py           # DB engine / session handling
│   ├── models.py       # SQLAlchemy ORM models
│   ├── patch.py        # monkey-patch helpers for OpenAI primitives
│   └── utils.py        # JSON-safe helpers, async helpers
├── tests/
│   └── …
├── pyproject.toml
└── README.md
Key runtime deps
[project]
dependencies = [
  "openai>=1.25",          # official SDK
  "SQLAlchemy>=2.0",
  "psycopg2-binary>=2.9",  # or asyncpg for async support
  "pydantic",              # strong typing / validation
]
2. PostgreSQL schema

# models.py
from sqlalchemy import (
    BigInteger, Boolean, Column, DateTime, Float, ForeignKey, JSON, String, Text
)
from sqlalchemy.dialects.postgresql import UUID, JSONB
from sqlalchemy.orm import declarative_base, relationship
import uuid, datetime

Base = declarative_base()

class Trace(Base):
    __tablename__ = "openai_traces"

    id            = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    created_at    = Column(DateTime, default=datetime.datetime.utcnow, index=True)
    model         = Column(String, index=True)
    endpoint      = Column(String, index=True)            # e.g. chat.completions
    prompt        = Column(JSONB)                         # messages or prompt string
    response      = Column(JSONB)
    latency_ms    = Column(Float)
    status_code   = Column(Integer)
    prompt_tokens = Column(Integer)
    completion_tokens = Column(Integer)
    total_tokens  = Column(Integer)
    metadata      = Column(JSONB, nullable=True)          # user tags, cost, etc.
    error         = Column(Text, nullable=True)
Why JSONB instead of text? It lets you filter on arbitrary keys, index selectively with GIN, and avoid custom migrations every time OpenAI adds a new field.

Migration choices:

Alembic (already bundled with SQLAlchemy) for versioned migrations.
Or just issue CREATE TABLE IF NOT EXISTS … at startup for smaller projects.
3. Database engine & session management

# db.py
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, scoped_session

PG_DSN = os.getenv("OPENAI_PG_DSN", "postgresql://user:pass@localhost:5432/openai_logs")
ENGINE = create_engine(PG_DSN, pool_pre_ping=True, pool_size=10, max_overflow=20)
SessionLocal = scoped_session(sessionmaker(bind=ENGINE, autocommit=False, autoflush=False))
Add async_sessionmaker + create_async_engine if you want fully async.

4. Wrapper strategy

4.1 Option A — subclass openai.OpenAI
# __init__.py  (public API)

from openai import OpenAI as _OpenAI  # the real SDK
from .patch import wrap_client

class OpenAI(_OpenAI):
    """Drop-in replacement that logs to Postgres."""
    def __init__(self, *a, pg_dsn: str | None = None, **kw):
        super().__init__(*a, **kw)
        wrap_client(self, pg_dsn or os.getenv("OPENAI_PG_DSN"))
4.2 Option B — monkey-patch module-wide functions
For projects that directly import openai.ChatCompletion.create, you can do:

# patch.py
import functools, time, traceback, openai
from .db import SessionLocal, Trace

def _log_and_return(func, endpoint):
    @functools.wraps(func)
    def _wrapper(*args, **kwargs):
        t0 = time.time()
        session = SessionLocal()
        try:
            resp = func(*args, **kwargs)
            latency = (time.time() - t0) * 1000
            usage   = getattr(resp, "usage", {})
            trace = Trace(
                model=kwargs.get("model"),
                endpoint=endpoint,
                prompt=kwargs.get("messages") or kwargs,
                response=resp.to_dict_recursive(),
                latency_ms=latency,
                status_code=200,
                prompt_tokens=usage.get("prompt_tokens"),
                completion_tokens=usage.get("completion_tokens"),
                total_tokens=usage.get("total_tokens"),
                metadata=kwargs.get("metadata"),
            )
            session.add(trace)
            session.commit()
            return resp
        except Exception as exc:
            session.rollback()
            session.add(Trace(
                model=kwargs.get("model"),
                endpoint=endpoint,
                prompt=kwargs,
                response=None,
                latency_ms=(time.time() - t0) * 1000,
                status_code=getattr(exc, "status_code", None),
                error="".join(traceback.format_exception(exc)),
            ))
            session.commit()
            raise
        finally:
            session.close()
    return _wrapper

def wrap_client(client, _pg_dsn: str | None = None):
    # patch only once
    if getattr(client, "__pg_wrapped__", False):
        return client
    client.__pg_wrapped__ = True
    cc = client.chat.completions
    cc.create = _log_and_return(cc.create, "chat.completions")
    # patch other endpoints the same way if needed
    return client
The pattern mirrors wrappers_delight but persists into SQL instead of NDJSON.

5. Performance notes

Off-thread / async logging.
In production, push the log body onto a queue.Queue() and have a background thread or asyncio.Task flush to Postgres every N traces or T seconds. That keeps latency overhead < 1 ms.
Batched INSERTs.
Use session.bulk_save_objects() or COPY (via psycopg2.extras.execute_values) if volume is high.
Streaming responses.
When stream=True, the OpenAI SDK returns an iterator/generator.
Wrap it with a lightweight proxy that accumulates the chunks, yields them downstream, and finally writes a single completed row once the stream ends (or an error row on exception).
6. Indexing & retention

CREATE INDEX idx_traces_created_at ON openai_traces (created_at);
CREATE INDEX idx_traces_model ON openai_traces (model);
CREATE INDEX idx_traces_gin_prompt ON openai_traces USING gin (prompt jsonb_path_ops);
Add a partition-by-range on created_at or a nightly DELETE FROM openai_traces WHERE created_at < NOW() - INTERVAL '180 days' if GDPR / cost is a concern.

7. Example usage

from openai_pg_logger import OpenAI   # ← this is *your* package

client = OpenAI(
    api_key=os.getenv("OPENAI_API_KEY"),
    # everything else is standard OpenAI kwargs
)

completion = client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role":"user","content":"Why do hummingbirds hover?"}],
    metadata={"prompt_id": "biology-demo"}
)
print(completion.choices[0].message.content)
# trace is now safely persisted in Postgres
Existing codebases only need to change the import line.

8. Packaging & distribution

pyproject.toml already shown; build with PEP 517 (python -m build) and publish to PyPI.
Add entry_points.console_scripts for a tiny CLI, e.g. openai-pg-migrate to run alembic upgrade head.
Provide a Dockerfile with Postgres init + your package for one-command local testing.
9. Bonus features to consider

Feature	Implementation idea
Cost tracking	usage.total_tokens * PRICING[model][mode], store in metadata.
Tag-based grouping (like OpenPipe)	Accept a tags: dict[str,str] kwarg and merge into metadata.
Grafana dashboard	Use pg_stat_statements + a Prometheus exporter to surface latency / cost.
Replay tool for regression tests	Read traces, feed prompts back into new model versions, diff outputs.
GDPR redaction	Post-processing job that hashes user PII columns or truncates prompt after N days.
TL;DR
Intercept calls (wrap_client).
Persist the kwargs + response into a well-indexed JSONB-heavy table.
Return the original OpenAI response untouched so existing code keeps working.
Ship as a package called e.g. openai-pg-logger.
With ~250 lines of code you’ll have feature-parity with OpenPipe’s request-logging SDK, but backed by your own Postgres instance so you can query, JOIN, and dashboard to your heart’s content.




Sources
You said:
BTW, can you explore whether and how this will handle a) system messages, b) tool calls, c) tool responses.

Also, investigate to what degree the open pipe tool tries to support anthropic and gemini or not. And what's involved in doing that.
ChatGPT said:

Thought for 2m 50s
1 — Will the Postgres logger capture system messages, tool calls and tool responses?
Feature	Where it shows up in the Python SDK	What your wrapper must do	Schema tweak you’ll want
System messages ({"role":"system", …})	They live in the same messages array that you already copy out of kwargs["messages"].	Nothing extra—just be sure you store the entire list unchanged. Add an optional redact_system=True flag if you ever need to strip or hash sensitive system prompts before shipping them to the DB.	No change, but you may choose to add a system_prompt TEXT materialised column for easier filtering.
Tool calls (model says “I want to call get_weather”)	For non-streaming calls you’ll see choices[0].message.tool_calls and finish_reason == "tool". In a streaming response you’ll get a sequence of deltas that gradually build the tool_calls array.	• When stream=False, your existing resp.to_dict_recursive() already contains the whole structure, so you’re done.
• For stream=True, wrap the generator, accrete every delta, and serialise the final assembled message once the iterator is exhausted.
Tip: expose a callback hook (on_chunk) if callers still want incremental chunks.	Add three nullable columns:
tool_name TEXT, tool_arguments JSONB, tool_finish_reason TEXT.
Populate them from the first tool call in the array (store the full array in response as today).
Tool responses ({"role":"tool", "tool_call_id":"...","content":"…"})	They arrive in the next user-initiated request as another message in messages.	Log them exactly like any other message. If you want tighter grouping, create a conversation_id (UUID) and ask callers to pass it so you can link successive traces.	Consider a small linking table:
tool_results(trace_id UUID, tool_call_id TEXT, content JSONB).
Good news: nothing about OpenAI’s tool system requires special error-handling—if the model never finishes with "tool" just log what you got.
2 — How far does OpenPipe go with Anthropic & Gemini?
Capability	Anthropic (Claude 3 family)	Gemini (Vertex AI)	How OpenPipe exposes it	Caveats you inherit
Simple chat completions	✅	✅	Prefix the model string with anthropic: or gemini: and keep using client.chat.completions.create(...)	Your OpenAI-shaped request is translated under the hood; latency is a bit higher because OpenPipe has to map schemas.
System messages	✅ (OpenPipe copies your first system message into Anthropic’s system param)	✅ (prepends it to Gemini’s text prompt)	Same as above	Anthropic only allows one system prompt, so if you supply several they’ll be concatenated—be aware when debugging.
Function / tool calling	✅ Claude 3 supports the tool_use & tool_result protocol	✅ Gemini exposes “function calling” in Vertex AI and lists it as supported for Gemini 2.0/2.5 Flash/Pro 
cloud.google.com
Partially. OpenPipe forwards the tools array but today it drops OpenAI-specific output-format options (e.g. response_format={"type":"json_object"}). Tool calls work, but you don’t yet get streaming delta.tool_calls.	• Missing streaming tool deltas means you must wait for the full response.
• Token-counts in usage come back in the provider’s units and can differ from OpenAI’s—budgeting logic should look at the provider column, not the numbers alone.
• Anthropic’s system+tools combo is still in beta and occasionally refuses parallel calls.
Provider-native extras (images, citations, web-search)	Available via raw Anthropic API but not surfaced through OpenPipe yet.	Gemini multimodal & parallel function calling aren’t surfaced either.	N/A	Call the provider SDK directly if you need these, then post logs with OpenPipe’s reporting API.
3 — What it would take to add multi-provider logging to your Postgres wrapper
Introduce a provider discriminator
class Trace(Base):
    ...
    provider = Column(String, default="openai")  # openai | anthropic | gemini
Wrap the other SDKs the same way you wrapped openai:
from anthropic import Anthropic
from vertexai.generative_models import GenerativeModel

class AnthropicLogged(Anthropic):   # sync + async variants
    def __init__(self, *a, **kw):
        super().__init__(*a, **kw)
        patch_endpoints(self, provider="anthropic")

class GeminiLogged(GenerativeModel):
    def __init__(self, model_name, *a, **kw):
        super().__init__(model_name, *a, **kw)
        patch_endpoints(self, provider="gemini")
patch_endpoints is the same decorator factory you already wrote—just pass the provider so you can record it.
Normalise the shape of the data before insert
Wrap each provider response into a minimal common contract:
def to_trace_dict(resp, provider):
    if provider == "openai":
        return resp.to_dict_recursive()
    elif provider == "anthropic":
        return resp.model_dump()  # the SDK uses pydantic
    elif provider == "gemini":
        return resp.to_json()     # Vertex AI returns a ProtoMessage
Handle token usage differences
Add input_tokens/output_tokens columns and fill them with whatever each SDK calls them (usage.input_tokens for Claude, usage.prompt_tokens for GPT-4o, usage.chars_in for Gemini, etc.).
Streaming support
• Anthropics’ stream=True returns an httpx.AsyncByteStream; accumulate chunks exactly like you already do for OpenAI.<br>
• Gemini streaming uses server-sent events; the Vertex AI Python SDK exposes an iterator of GenerationResponse. Wrap it the same way.
Test matrix
Provider	Plain chat	Tools	Streaming	Errors
OpenAI	✅	✅	✅	✅
Anthropic	✅	✅* (no delta stream)	✅	✅
Gemini	✅	✅	✅	✅
4 — Checklist of code & schema edits
models.py
provider       = Column(String, index=True)
system_prompt  = Column(Text, nullable=True)      # optional materialised helper
tool_name      = Column(String, nullable=True)
tool_arguments = Column(JSONB, nullable=True)
tool_finish_reason = Column(String, nullable=True)
Add GIN indexes on tool_arguments if you plan to filter on them.
patch.py
When finish_reason == "tool" pull the first tool_calls[0] to fill the helper columns.
When streaming, buffer until finish_reason shows up.
tests/
Golden tests for:
– OpenAI with tools & stream
– Anthropic Claude 3 tool_use (non-stream)
– Gemini 2.5 Pro function calling (stream)
5 — Bottom line
System messages need no special handling beyond possibly redaction.
Tool calls just require you to recognise finish_reason=="tool" and, if streaming, re-assemble the chunks before you commit.
Tool responses arrive as ordinary messages in the next request—log them like any other prompt.
OpenPipe already shows that OpenAI-shaped requests can be auto-translated to Anthropic and Gemini. If you want the same “one import” developer experience and first-party Postgres logging, just patch the two extra SDKs, store the provider tag, and keep your schema JSON-heavy so you don’t have to chase every field those providers add next month.