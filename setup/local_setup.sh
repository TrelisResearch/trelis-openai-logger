#!/bin/bash
set -e

# Install dbmate if not present
if ! command -v dbmate &> /dev/null; then
    brew install dbmate
fi

# Set database URL for dbmate
export DATABASE_URL="postgresql://localhost/llm_logs?sslmode=disable"

# Run migrations
dbmate up

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
