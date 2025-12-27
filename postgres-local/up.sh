#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_FILE="${ROOT_DIR}/vault_keys.txt"
COMPOSE_FILE="${ROOT_DIR}/postgres-local/docker-compose.yml"

# Helper function to fetch secrets
fetch_secret() {
    local path=$1
    local field=$2
    if [ -n "${VAULT_TOKEN:-}" ]; then
        docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault-local vault kv get -mount=secret -field="$field" "$path"
    else
        docker exec vault-local vault kv get -mount=secret -field="$field" "$path"
    fi
}

if [ -f "$KEYS_FILE" ] && [ "$(docker ps -q -f name=vault-local)" ]; then
    echo "[INFO] Vault detected. Fetching secrets..."
    export VAULT_TOKEN=$(jq -r ".root_token" "$KEYS_FILE")
    
    # FETCH SECRETS HERE
    export POSTGRES_PASSWORD=$(fetch_secret postgres/auth password)
else
    echo "[WARN] Vault not detected. Using local environment."
fi

echo "[INFO] Starting postgres-local..."
docker compose -f "${COMPOSE_FILE}" up -d
