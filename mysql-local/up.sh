#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_FILE="${ROOT_DIR}/vault_keys.txt"
COMPOSE_FILE="${ROOT_DIR}/mysql-local/docker-compose.yml"

# Source Common Library
source "${ROOT_DIR}/bin/lib/common.sh"

echo "[INFO] Starting mysql-local..."

# Check Vault Availability
check_vault

if [ -n "${VAULT_TOKEN:-}" ]; then
    echo "[INFO] Vault detected. Ensuring/Fetching secrets..."
    
    # Ensure credential exists (self-initialization)
    ensure_credential "infras/mysql/root" "root"
    
    # Fetch Secrets
    export MYSQL_ROOT_PASSWORD=$(fetch_secret infras/mysql/root password)
    
    echo "[INFO] Secrets fetched successfully."
    
    echo "[INFO] Secrets fetched successfully."
else
    echo "[WARN] Vault not detected or keys missing. Falling back to .env file or existing environment variables."
fi

echo "[INFO] Starting mysql-local using ${COMPOSE_FILE}..."
docker compose -f "${COMPOSE_FILE}" up -d
echo "[OK] mysql-local is starting. Use 'docker ps' to verify the container."
