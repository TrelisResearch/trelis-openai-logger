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
  - path: /tmp/setup_db.sh
    content: |
      #!/bin/bash
      set -e
      
      # Install dbmate
      curl -fsSL -o /usr/local/bin/dbmate https://github.com/amacneil/dbmate/releases/latest/download/dbmate-linux-amd64
      chmod +x /usr/local/bin/dbmate
      
      # Create db directory structure
      mkdir -p /var/lib/postgresql/db/migrations
      chown -R postgres:postgres /var/lib/postgresql/db
      
      # Copy migrations
      cp -r /tmp/db/* /var/lib/postgresql/db/
      chown -R postgres:postgres /var/lib/postgresql/db
      
      # Run migrations as postgres user
      sudo -u postgres bash -c 'cd /var/lib/postgresql/db && DATABASE_URL="postgresql:///llm_logs?sslmode=disable" dbmate up'
    owner: root:root
    permissions: '0755'
  - path: /tmp/db/
    owner: postgres:postgres
    permissions: '0755'

runcmd:
  # Configure PostgreSQL
  - systemctl start postgresql
  - sudo -u postgres createdb llm_logs
  - sudo -u postgres psql -c "ALTER USER postgres PASSWORD '${DB_PASSWORD}';"
  - sudo -u postgres psql -c "ALTER SYSTEM SET listen_addresses TO '*';"
  - sudo -u postgres psql -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
  - echo "host all all 0.0.0.0/0 md5" >> /etc/postgresql/14/main/pg_hba.conf
  # Run database setup
  - bash /tmp/setup_db.sh
  - systemctl restart postgresql
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

echo "\nDroplet setup complete!\n"
echo "IP: ${DROPLET_IP}"
echo "Connection string: ${CONNECTION_STRING}"
echo "\nTo use this connection string:\n"
echo "1. Add to .env file:"
echo "DATABASE_URL='${CONNECTION_STRING}'"
echo "\n2. Or export directly:\nexport DATABASE_URL='${CONNECTION_STRING}'"


# Add to known hosts
echo "Adding to known hosts..."
ssh-keyscan -H ${DROPLET_IP} >> ~/.ssh/known_hosts

# Copy db directory to droplet
echo "Copying database migrations..."
scp -i ~/.ssh/${SSH_KEY_NAME} -r db root@${DROPLET_IP}:/tmp/

# Wait for PostgreSQL to be ready
echo "Waiting for PostgreSQL to be ready..."
while true; do
    if ssh -i ~/.ssh/${SSH_KEY_NAME} root@${DROPLET_IP} 'systemctl is-active postgresql'; then
        break
    fi
    echo "Waiting for PostgreSQL..."
    sleep 5
done



# Test connection
echo "Testing PostgreSQL connection..."
cat > test_db.py << EOF
from sqlalchemy import create_engine, text

DATABASE_URL = f"postgresql://postgres:${DB_PASSWORD}@${DROPLET_IP}/llm_logs"

def test_connection():
    try:
        engine = create_engine(DATABASE_URL)
        with engine.connect() as conn:
            result = conn.execute(text("SELECT version();")).scalar()
            print("Successfully connected to PostgreSQL!")
            print(f"PostgreSQL version: {result}")
            
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS test_connection (
                    id SERIAL PRIMARY KEY,
                    test_column VARCHAR(50)
                );
            """))
            conn.commit()
            print("Successfully created test table!")
            
            conn.execute(text(
                "INSERT INTO test_connection (test_column) VALUES ('test successful')"
            ))
            conn.commit()
            print("Successfully inserted test data!")
            
            result = conn.execute(text("SELECT * FROM test_connection")).fetchone()
            print(f"Retrieved test data: {result}")
            
    except Exception as e:
        print(f"Error: {e}")
        exit(1)

if __name__ == "__main__":
    test_connection()
EOF

uv run test_db.py

echo "Setup complete! Your PostgreSQL connection string is:"
echo "postgresql://postgres:${DB_PASSWORD}@${DROPLET_IP}/llm_logs"
