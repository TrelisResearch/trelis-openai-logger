"""Database connection and session management."""
import os
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, scoped_session
from sqlalchemy.ext.asyncio import create_async_engine, async_sessionmaker

# Support both sync and async database connections
PG_DSN = os.getenv("OPENAI_PG_DSN", "postgresql:///llm_logs")
ASYNC_PG_DSN = os.getenv("LLM_ASYNC_PG_DSN", PG_DSN.replace("postgresql://", "postgresql+asyncpg://"))

# Sync engine
ENGINE = create_engine(
    PG_DSN,
    pool_pre_ping=True,
    pool_size=10,
    max_overflow=20
)

# Async engine
ASYNC_ENGINE = create_async_engine(
    ASYNC_PG_DSN,
    pool_pre_ping=True,
    pool_size=10,
    max_overflow=20
)

# Session factories
_session_factory = sessionmaker(autocommit=False, autoflush=False)
SessionLocal = scoped_session(_session_factory)
SessionLocal.configure(bind=ENGINE)

AsyncSessionLocal = async_sessionmaker(
    bind=ASYNC_ENGINE,
    autocommit=False,
    autoflush=False,
    expire_on_commit=False
)

def set_engine(new_engine):
    """Update the engine and reconfigure the session factory."""
    global ENGINE
    ENGINE = new_engine
    SessionLocal.remove()
    SessionLocal.configure(bind=new_engine)

def get_db():
    """Get a database session."""
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()

async def get_async_db():
    """Get an async database session."""
    async with AsyncSessionLocal() as session:
        yield session
