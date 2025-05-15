#!/bin/bash

# Exit on error and debug output
set -e
set -x

# Get the directory where the script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

# Load environment variables
if [ -f "$PROJECT_ROOT/.env" ]; then
    echo "Loading .env file from $PROJECT_ROOT/.env"
    set -a
    source "$PROJECT_ROOT/.env"
    set +a
fi

# Verify DATABASE_URL is set
if [ -z "${DATABASE_URL}" ]; then
    echo "Error: DATABASE_URL is not set"
    exit 1
fi

# Install dbmate if not present
if ! command -v dbmate &> /dev/null; then
    echo "Installing dbmate..."
    brew install dbmate
fi

# Store original DATABASE_URL
ORIGINAL_URL="${DATABASE_URL}"

# Create llm_logs database within the DO cluster using defaultdb connection
echo "Creating llm_logs database..."
psql "${ORIGINAL_URL}" -c 'CREATE DATABASE llm_logs WITH OWNER = doadmin;' || echo "Database might already exist, continuing..."

# Set up URL for llm_logs database
LLM_LOGS_URL=$(echo "${ORIGINAL_URL}" | sed 's/defaultdb/llm_logs/')

# Run migrations on llm_logs database
echo "Running migrations on llm_logs database..."
cd "$PROJECT_ROOT"
export DBMATE_MIGRATIONS_DIR="$PROJECT_ROOT/setup/migrations"
DATABASE_URL="${LLM_LOGS_URL}" dbmate up

# Update .env file to use llm_logs database
echo "Updating .env file to use llm_logs database..."
sed -i.bak "s|${ORIGINAL_URL}|${LLM_LOGS_URL}|g" "$PROJECT_ROOT/.env"

echo ""
echo "✓ Setup complete!"
echo "✓ Created llm_logs database"
echo "✓ Ran migrations"
echo "✓ Updated .env to use llm_logs database"
echo ""
echo "You can now run: source .env && uv run example.py"
