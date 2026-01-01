#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_FILE="${ROOT_DIR}/vault_keys.txt"
COMPOSE_FILE="${ROOT_DIR}/postgres-local/docker-compose.yml"

# Source Common Library
source "${ROOT_DIR}/bin/lib/common.sh"

echo "[INFO] Starting postgres-local..."

# Check Vault Availability
check_vault

if [ -n "${VAULT_TOKEN:-}" ]; then
    echo "[INFO] Vault detected. Ensuring/Fetching secrets..."
    
    # Ensure credential exists
    ensure_credential "infras/postgres/auth" "postgres"
    
    # Fetch Secrets
    export POSTGRES_PASSWORD=$(fetch_secret infras/postgres/auth password)
    
    echo "[INFO] Secrets fetched successfully."
else
    echo "[WARN] Vault not detected. Using local environment."
fi

echo "[INFO] Starting postgres-local..."
docker compose -f "${COMPOSE_FILE}" up -d
