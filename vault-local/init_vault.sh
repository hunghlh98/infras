#!/usr/bin/env bash
set -euo pipefail

# This script initializes and unseals Vault, then writes secrets.
# It's designed to be run once.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_FILE="${ROOT_DIR}/vault_keys.txt"
ENV_FILE="${ROOT_DIR}/local.env"

# Load environment variables
if [ -f "$ENV_FILE" ]; then
    set -a
    source "$ENV_FILE"
    set +a
else
    echo "[ERROR] .env file not found at $ENV_FILE"
    exit 1
fi

# Give Vault time to start
sleep 2

export VAULT_ADDR='http://127.0.0.1:8200'

# Define a helper function to run vault commands inside the container
# We will pass VAULT_TOKEN if it is set
run_vault() {
  if [ -n "${VAULT_TOKEN:-}" ]; then
    docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault-local vault "$@"
  else
    docker exec vault-local vault "$@"
  fi
}

# Check if Vault is already initialized
if run_vault status -format=json | jq -e '.initialized' > /dev/null; then
  echo "[INFO] Vault is already initialized. Unsealing..."
else
  echo "[INFO] Vault not initialized. Initializing..."
  # Initialize Vault and capture the output
  run_vault operator init -key-shares=1 -key-threshold=1 -format=json > "$KEYS_FILE"
  echo "[OK] Vault initialized. Unseal keys and root token saved to $KEYS_FILE"
fi

# Unseal Vault
UNSEAL_KEY=$(jq -r ".unseal_keys_b64[0]" "$KEYS_FILE")
run_vault operator unseal "$UNSEAL_KEY"
echo "[OK] Vault is unsealed."

# Log in with the root token
export VAULT_TOKEN=$(jq -r ".root_token" "$KEYS_FILE")
echo "[INFO] Logged in with root token."

# --- Write Secrets ---
echo "[INFO] Writing secrets to Vault..."
# Enable kv-v2 secrets engine at 'secret/' if not enabled (default in dev mode, but good to ensure)
# In standard server mode, we might need to enable it.
if ! run_vault secrets list -format=json | jq -e '."secret/"' > /dev/null; then
    echo "[INFO] Enabling kv-v2 secrets engine at secret/..."
    run_vault secrets enable -path=secret kv-v2
fi

# Set the token for the following commands within the container
run_vault kv put -mount=secret mysql/root password="$MYSQL_ROOT_PASSWORD"
run_vault kv put -mount=secret mysql/admin password="$MYSQL_ADMIN_PASSWORD"
run_vault kv put -mount=secret mysql/my_user password="$MYSQL_USER_PASSWORD"
run_vault kv put -mount=secret kafka/sasl username="$KAFKA_SASL_USERNAME" password="$KAFKA_SASL_PASSWORD"
run_vault kv put -mount=secret redis/auth password="$REDIS_PASSWORD"
echo "[OK] All secrets have been written to Vault."

echo "[INFO] Verifying secrets..."
run_vault kv get -mount=secret mysql/root
