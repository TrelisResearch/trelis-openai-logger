"""
Example usage of trelis_openai_logger with local, droplet, or managed PostgreSQL databases.
Test with:
    - Local:    uv run example.py
    - Droplet:  DATABASE_URL="postgresql://postgres:your_password@your_ip/llm_logs" uv run example.py
    - Managed:  DATABASE_URL="your_managed_db_url" uv run example.py
"""
import os
from trelis_openai_logger import OpenAI
from dotenv import load_dotenv
from sqlalchemy import create_engine, text

def get_connection_info(db_url):
    """Extract and return sanitized connection information."""
    from urllib.parse import urlparse
    parsed = urlparse(db_url)
    if parsed.hostname in ['localhost', '127.0.0.1']:
        return 'local database'
    elif parsed.hostname:
        return f'remote database at {parsed.hostname}'
    return 'unknown database'

def test_db_connection(db_url):
    """Test the database connection before proceeding."""
    try:
        print(f'\nConnecting to {get_connection_info(db_url)}...')
        engine = create_engine(db_url)
        with engine.connect() as conn:
            result = conn.execute(text('SELECT version();')).scalar()
            print('✓ Successfully connected to PostgreSQL!')
            print(f'✓ PostgreSQL version: {result}')
            
            # Verify llm_traces table exists
            result = conn.execute(text("""
                SELECT EXISTS (
                    SELECT FROM information_schema.tables 
                    WHERE table_name = 'llm_traces'
                );
            """)).scalar()
            if not result:
                print('✗ llm_traces table does not exist! Did you run the migrations?')
                return False
            print('✓ llm_traces table exists!')
            return True
            
    except Exception as e:
        print(f'✗ Database connection error: {e}')
        return False

def main():
    # Load environment variables
    load_dotenv()

    # Get database URL from environment
    db_url = os.getenv('DATABASE_URL')
    if not db_url:
        print('Error: DATABASE_URL not set in environment')
        return

    # Test database connection
    if not test_db_connection(db_url):
        return

    # Initialize OpenAI client with logging
    client = OpenAI(
        api_key=os.getenv('OPENAI_API_KEY'),
        pg_dsn=db_url
    )

    # Test OpenAI API
    try:
        response = client.chat.completions.create(
            model="gpt-4.1-mini",
            messages=[{"role": "user", "content": "Hello!"}]
        )
        print('\n✓ OpenAI API test successful!')
        print(f'Response: {response.choices[0].message.content}')

        # Query the logged data
        engine = create_engine(db_url)
        with engine.connect() as conn:
            result = conn.execute(text("""
                SELECT 
                    to_char(created_at, 'YYYY-MM-DD HH24:MI:SS') as time,
                    model,
                    prompt,
                    response->>'content' as response,
                    latency_ms,
                    total_tokens
                FROM llm_traces
                ORDER BY created_at DESC
                LIMIT 1;
            """)).fetchone()
            if result:
                print('\n✓ Successfully logged to llm_traces:')
                print(f'Time: {result.time}')
                print(f'Model: {result.model}')
                print(f'Latency: {result.latency_ms:.2f}ms')
                print(f'Total tokens: {result.total_tokens}')
            else:
                print('\n✗ No logs found in llm_traces')

    except Exception as e:
        print(f'\n✗ OpenAI API test failed: {e}')

if __name__ == "__main__":
    main()
