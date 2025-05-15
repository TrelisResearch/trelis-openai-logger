from sqlalchemy import create_engine, text

def test_connection():
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

if __name__ == '__main__':
    test_connection()
