"""Monkey-patch helpers for OpenAI primitives."""
import functools
import time
import traceback
from typing import Any, Dict, Optional

from openai import OpenAI
from openai.types.chat import ChatCompletion
from openai.types.completion import Completion

from .db import SessionLocal
from .models import LLMTrace


def wrap_client(client: OpenAI, pg_dsn: Optional[str] = None) -> None:
    """Wrap an OpenAI client instance to log all API calls to PostgreSQL."""
    if pg_dsn:
        from sqlalchemy import create_engine
        from .db import ENGINE, set_engine
        ENGINE.dispose()
        new_engine = create_engine(pg_dsn)
        set_engine(new_engine)

    # Wrap the chat completions endpoint
    original_chat = client.chat.completions.create
    client.chat.completions.create = _log_and_return(
        original_chat, "chat.completions"
    )

    # Wrap the completions endpoint
    original_completion = client.completions.create
    client.completions.create = _log_and_return(
        original_completion, "completions"
    )


def _log_and_return(func: Any, endpoint: str):
    """Decorator that logs API calls and their responses to PostgreSQL."""
    @functools.wraps(func)
    def wrapper(*args, **kwargs):
        t0 = time.time()
        session = SessionLocal()
        
        try:
            # Make the API call
            response = func(*args, **kwargs)
            latency = (time.time() - t0) * 1000
            
            # Extract usage statistics
            usage = {}
            if isinstance(response, (ChatCompletion, Completion)):
                usage = response.usage.model_dump() if response.usage else {}
            
            # Create trace entry
            trace = LLMTrace(
                model=kwargs.get("model", "unknown"),
                endpoint=endpoint,
                prompt=kwargs.get("messages", kwargs.get("prompt", [])),
                response=response.model_dump(),
                latency_ms=latency,
                status_code=200,
                prompt_tokens=usage.get("prompt_tokens"),
                completion_tokens=usage.get("completion_tokens"),
                total_tokens=usage.get("total_tokens"),
                metadata={
                    "temperature": kwargs.get("temperature", 1.0),
                    "max_tokens": kwargs.get("max_tokens"),
                    "top_p": kwargs.get("top_p", 1.0),
                }
            )
            
            session.add(trace)
            session.commit()
            
            return response
            
        except Exception as e:
            # Log the error
            trace = LLMTrace(
                model=kwargs.get("model", "unknown"),
                endpoint=endpoint,
                prompt=kwargs.get("messages", kwargs.get("prompt", [])),
                error=str(e),
                status_code=500,
                meta_data={"traceback": traceback.format_exc()}
            )
            
            session.add(trace)
            session.commit()
            raise
            
        finally:
            session.close()
    
    return wrapper
