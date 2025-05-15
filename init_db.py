"""Initialize the database tables."""
from trelis_openai_logger.models import Base
from trelis_openai_logger.db import ENGINE

def init_db():
    Base.metadata.create_all(bind=ENGINE)

if __name__ == "__main__":
    init_db()
    print("Database tables created successfully!")
