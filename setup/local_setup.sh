#!/bin/bash
set -e

# Run migrations using default PostgreSQL connection
psql -d llm_logs -f setup/migrations/01_create_tables.sql

# Test connection
cat > test_db.py << EOF
from sqlalchemy import create_engine, text

try:
    # Note: Using localhost for local PostgreSQL
    engine = create_engine('postgresql://localhost/llm_logs')
    with engine.connect() as conn:
        result = conn.execute(text('SELECT version();')).scalar()
        print('Successfully connected to PostgreSQL!')
        print(f'PostgreSQL version: {result}')
except Exception as e:
    print(f'Error: {e}')
    exit(1)
EOF

uv run test_db.py
rm test_db.py

echo "Local database setup complete!"
