#!/bin/bash

# Exit on error
set -e

# Load environment variables
if [ -f ../.env ]; then
    export $(cat ../.env | grep -v '^#' | xargs)
fi

# Default values
DROPLET_NAME="llm-logger"
SSH_KEY_NAME="do_llm_logger"
DB_PASSWORD=${DB_PASSWORD:-"your_secure_password"}  # Use from .env or default

# Validate required environment variables
if [ "$DB_PASSWORD" = "your_secure_password" ]; then
    echo "Warning: Using default database password. Set DB_PASSWORD in .env for security."
fi

# Create SSH key if it doesn't exist
if [ ! -f ~/.ssh/${SSH_KEY_NAME} ]; then
    echo "Creating SSH key..."
    ssh-keygen -t ed25519 -f ~/.ssh/${SSH_KEY_NAME} -N ""
fi

# Check if SSH key already exists in Digital Ocean
echo "Checking for existing SSH key in Digital Ocean..."
EXISTING_KEY_ID=$(doctl compute ssh-key list --format ID,Name,FingerPrint --no-header | grep "${DROPLET_NAME}" | awk '{print $1}')

if [ -n "$EXISTING_KEY_ID" ]; then
    echo "SSH key '${DROPLET_NAME}' already exists in Digital Ocean"
    SSH_KEY_ID=$EXISTING_KEY_ID
else
    echo "Importing SSH key to Digital Ocean..."
    doctl compute ssh-key import ${DROPLET_NAME} --public-key-file ~/.ssh/${SSH_KEY_NAME}.pub
    SSH_KEY_ID=$(doctl compute ssh-key list --format ID,Name --no-header | grep "${DROPLET_NAME}" | awk '{print $1}')
fi

if [ -z "$SSH_KEY_ID" ]; then
    echo "Error: Failed to get SSH key ID"
    exit 1
fi

echo "Using SSH key ID: ${SSH_KEY_ID}"

# -------------------------------------------------------------------
# Delete any existing droplet that has the exact name and wait for it
# -------------------------------------------------------------------
existing_droplet_ids=$(doctl compute droplet list --format ID,Name --no-header \
                      | awk -v name="$DROPLET_NAME" '$2==name {print $1}')

if [ -n "$existing_droplet_ids" ]; then
    echo "Deleting existing droplet(s)..."
    doctl compute droplet delete -f $existing_droplet_ids

    echo "Waiting for droplet(s) to be fully destroyed..."
    for id in $existing_droplet_ids; do
        # keep polling until the droplet is really gone
        while doctl compute droplet get "$id" >/dev/null 2>&1; do
            sleep 5
        done
    done
fi

# Create cloud-init configuration
cat > cloud-init.yml << EOF
#cloud-config
package_update: true
packages: [postgresql, postgresql-contrib]

write_files:
  - path: /tmp/01_create_tables.sql
    content: |
      -- migrate:up
      CREATE TABLE IF NOT EXISTS llm_traces (
          id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
          created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
          model VARCHAR(255),
          endpoint VARCHAR(255),
          input_messages JSONB DEFAULT '[]'::jsonb,
          raw_response JSONB,
          latency_ms FLOAT,
          status_code INTEGER,
          prompt_tokens INTEGER,
          completion_tokens INTEGER,
          total_tokens INTEGER,
          meta_data JSONB,
          error TEXT
      );
      
      -- migrate:down
      DROP TABLE IF EXISTS llm_traces;
    permissions: '0644'
  - path: /tmp/setup_db.sh
    content: |
      #!/bin/bash
      set -e
      
      # Install dbmate
      curl -fsSL -o /usr/local/bin/dbmate https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64
      chmod +x /usr/local/bin/dbmate
      
      # Set up migrations directory
      mkdir -p /var/lib/postgresql/db/migrations
      cp /tmp/01_create_tables.sql /var/lib/postgresql/db/migrations/01_create_tables.sql
      chown -R postgres:postgres /var/lib/postgresql/db
      
      # Create symlink for dbmate's expected structure
      mkdir -p /var/lib/postgresql/db/db
      ln -s /var/lib/postgresql/db/migrations /var/lib/postgresql/db/db/migrations
      
      # Run migrations as postgres user
      sudo -u postgres bash -c 'cd /var/lib/postgresql/db && DATABASE_URL="postgresql:///llm_logs?sslmode=disable" dbmate up'
    permissions: '0755'

runcmd:
  # Configure PostgreSQL
  - systemctl start postgresql
  - sudo -u postgres createdb llm_logs
  - sudo -u postgres psql -c "ALTER USER postgres PASSWORD '${DB_PASSWORD}';"
  - sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses TO '*';"
  - sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
  - echo "host all all 0.0.0.0/0 md5" >> /etc/postgresql/14/main/pg_hba.conf
  - systemctl restart postgresql
  # Run database setup
  - chmod +x /tmp/setup_db.sh
  - /tmp/setup_db.sh
EOF

# Create droplet
echo "Creating droplet..."
doctl compute droplet create \
    --user-data-file cloud-init.yml \
    --image ubuntu-22-04-x64 \
    --size s-1vcpu-2gb \
    --region lon1 \
    --ssh-keys "$SSH_KEY_ID" \
    --wait \
    "$DROPLET_NAME"

# Wait for droplet to be ready
echo "Waiting for droplet to be ready..."
while true; do
    STATUS=$(doctl compute droplet list --format Status --no-header ${DROPLET_NAME})
    if [ "$STATUS" = "active" ]; then
        break
    fi
    echo "Waiting... (status: $STATUS)"
    sleep 5
done

# Get droplet IP
DROPLET_IP=$(doctl compute droplet list --format PublicIPv4 --no-header ${DROPLET_NAME})
# Generate connection string
CONNECTION_STRING="postgresql://postgres:${DB_PASSWORD}@${DROPLET_IP}/llm_logs"

echo "\nDroplet is being created!\n"
echo "IP: ${DROPLET_IP}"

echo "\nNext steps:\n"
echo "1. Wait about 2-3 minutes for the droplet to fully setup"
echo "2. Update your .env file with:"
echo "DATABASE_URL='${CONNECTION_STRING}'"
echo "3. Run: source .env && uv run example.py"
