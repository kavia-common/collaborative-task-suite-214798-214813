#!/bin/bash

# CollabSphere PostgreSQL startup & provisioning script
# - Starts PostgreSQL (if not already running)
# - Ensures a ready-to-use database + role for Django
# - Enables common extensions used by Django apps/migrations
#
# Notes:
# - This script is designed to be idempotent (safe to run multiple times).
# - Credentials are currently defined here to match existing repo conventions
#   (see db_connection.txt and db_visualizer/postgres.env generation below).

set -euo pipefail

DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

DATA_DIR="/var/lib/postgresql/data"

echo "Starting PostgreSQL setup..."

# Find PostgreSQL version and set paths
PG_VERSION="$(ls /usr/lib/postgresql/ | head -1)"
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"
echo "Using PG_BIN: ${PG_BIN}"

# Check if PostgreSQL is already running on the specified port
if sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" > /dev/null 2>&1; then
    echo "PostgreSQL is already running on port ${DB_PORT}!"
else
    # Also check if there's a PostgreSQL process running (in case pg_isready fails)
    if pgrep -f "postgres.*-p ${DB_PORT}" > /dev/null 2>&1; then
        echo "Found existing PostgreSQL process on port ${DB_PORT}"
        echo "Attempting to verify readiness..."
    else
        # Initialize PostgreSQL data directory if it doesn't exist
        if [ ! -f "${DATA_DIR}/PG_VERSION" ]; then
            echo "Initializing PostgreSQL data directory at ${DATA_DIR}..."
            sudo -u postgres "${PG_BIN}/initdb" -D "${DATA_DIR}"
        fi

        # Start PostgreSQL server in background
        echo "Starting PostgreSQL server..."
        sudo -u postgres "${PG_BIN}/postgres" -D "${DATA_DIR}" -p "${DB_PORT}" &
    fi

    # Wait for PostgreSQL to start
    echo "Waiting for PostgreSQL to become ready..."
    for i in {1..20}; do
        if sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" > /dev/null 2>&1; then
            echo "PostgreSQL is ready!"
            break
        fi
        echo "Waiting... (${i}/20)"
        sleep 1
    done

    if ! sudo -u postgres "${PG_BIN}/pg_isready" -p "${DB_PORT}" > /dev/null 2>&1; then
        echo "ERROR: PostgreSQL did not become ready on port ${DB_PORT}."
        exit 1
    fi
fi

echo "Provisioning database/role for Django..."

# Ensure role exists (create if missing) and always reset password to desired value.
# Also ensure the app role has CREATEDB so Django can create test databases (e.g., test_<dbname>)
# when running manage.py test.
sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d postgres -v ON_ERROR_STOP=1 << EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;

    -- Keep password in sync with this script so the container is "ready-to-use"
    ALTER ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';

    -- Django test runner creates databases; grant CREATEDB idempotently.
    -- This is safe to run repeatedly and does not require SUPERUSER.
    ALTER ROLE ${DB_USER} CREATEDB;

    -- Optional but useful for Django migrations that may create schemas/extensions
    -- (Extensions are still created by postgres below; this is future-proofing.)
    ALTER ROLE ${DB_USER} SET client_encoding TO 'utf8';
    ALTER ROLE ${DB_USER} SET default_transaction_isolation TO 'read committed';
    ALTER ROLE ${DB_USER} SET timezone TO 'UTC';
END
\$\$;
EOF

# Ensure database exists and is owned by the app role (ownership helps avoid permission issues).
sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d postgres -v ON_ERROR_STOP=1 << EOF
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}') THEN
        CREATE DATABASE ${DB_NAME} OWNER ${DB_USER};
    END IF;
END
\$\$;

-- Ensure ownership even if DB already existed
ALTER DATABASE ${DB_NAME} OWNER TO ${DB_USER};
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF

# Ensure schema privileges are correct for Django migrations.
sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 << EOF
-- Ensure the public schema exists (it should), and make app user owner for simplest Django operation.
CREATE SCHEMA IF NOT EXISTS public;
ALTER SCHEMA public OWNER TO ${DB_USER};

GRANT USAGE, CREATE ON SCHEMA public TO ${DB_USER};
GRANT ALL ON SCHEMA public TO ${DB_USER};

-- Ensure default privileges so objects created by migrations are accessible.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};
EOF

# Enable commonly used extensions for Django apps.
# We do it as postgres to avoid needing SUPERUSER on app role.
# These are safe even if unused; and are IF NOT EXISTS for idempotency.
sudo -u postgres "${PG_BIN}/psql" -p "${DB_PORT}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 << 'EOF'
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "citext";
EOF

# Save connection command to a file (used by other tooling / conventions).
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > db_connection.txt
echo "Connection string saved to db_connection.txt"

# Save environment variables to a file for the Node.js DB viewer.
cat > db_visualizer/postgres.env << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo ""
echo "PostgreSQL provisioning complete."
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo ""
echo "Environment variables saved to db_visualizer/postgres.env"
echo "To use with Node.js viewer, run: source db_visualizer/postgres.env"
echo "To connect: $(cat db_connection.txt)"
