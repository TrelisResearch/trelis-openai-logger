"""
LLM PostgreSQL Logger - A drop-in replacement for OpenAI client with PostgreSQL logging
"""

from .db import ENGINE, SessionLocal
from .models import Base, LLMTrace
from .patch import wrap_client

import openai

class OpenAI(openai.OpenAI):
    """Drop-in replacement for openai.OpenAI that logs to PostgreSQL."""
    
    def __init__(self, *args, pg_dsn: str | None = None, **kwargs):
        super().__init__(*args, **kwargs)
        wrap_client(self, pg_dsn)
