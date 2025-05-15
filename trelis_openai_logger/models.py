"""SQLAlchemy models for LLM logging."""
from sqlalchemy import Column, DateTime, Float, Integer, String, Text
from sqlalchemy.dialects.postgresql import UUID, JSONB
from sqlalchemy.orm import declarative_base
import datetime
import uuid

Base = declarative_base()

class LLMTrace(Base):
    """Trace model for logging LLM interactions."""
    __tablename__ = "llm_traces"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    created_at = Column(DateTime, default=datetime.datetime.utcnow, index=True)
    model = Column(String, index=True)
    endpoint = Column(String, index=True)
    input_messages = Column(JSONB, default=list)
    raw_response = Column(JSONB)
    latency_ms = Column(Float)
    status_code = Column(Integer)
    prompt_tokens = Column(Integer)
    completion_tokens = Column(Integer)
    total_tokens = Column(Integer)
    meta_data = Column(JSONB, nullable=True)
    error = Column(Text, nullable=True)
