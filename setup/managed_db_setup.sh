#!/bin/bash

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

[ -f "$PROJECT_ROOT/.env" ] && source "$PROJECT_ROOT/.env"

[ -z "${DATABASE_URL}" ] && echo "Error: DATABASE_URL is not set" && exit 1

# Install dbmate if needed
[ ! -x "$(command -v dbmate)" ] && brew install dbmate

# Setup llm_logs database
ORIGINAL_URL="${DATABASE_URL}"
psql "${ORIGINAL_URL}" -c 'CREATE DATABASE llm_logs WITH OWNER = doadmin;' >/dev/null 2>&1 || true

LLM_LOGS_URL=$(echo "${ORIGINAL_URL}" | sed 's/defaultdb/llm_logs/')
cd "$PROJECT_ROOT"
export DBMATE_MIGRATIONS_DIR="$PROJECT_ROOT/db/migrations"
DATABASE_URL="${LLM_LOGS_URL}" dbmate up >/dev/null 2>&1

sed -i.bak "s|${ORIGINAL_URL}|${LLM_LOGS_URL}|g" "$PROJECT_ROOT/.env" && rm "$PROJECT_ROOT/.env.bak"

echo "Run: source .env && uv run example.py"
