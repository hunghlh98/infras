# AI Guidelines for Adding New Services

This document outlines the standard procedure for an AI agent (or developer) to add a new third-party service to this infrastructure repository.

## 1. Directory Structure

Create a new directory for the service following the naming convention: `<service-name>-local`.

**Example:** `postgres-local/`

Inside this directory, you must create:
*   `docker-compose.yml`: The service definition.
*   `up.sh`: Script to start the service.
*   `down.sh`: Script to stop the service.
*   `reset.sh`: Script to stop the service and clean up data.

## 2. Docker Compose Configuration (`docker-compose.yml`)

*   **Version**: Use `version: "3.8"`.
*   **Platform**: Explicitly set `platform: linux/amd64` for all services to ensure compatibility (especially on Apple Silicon).
*   **Network**: Use the default bridge network unless clustering requires a specific network.
*   **Volumes**:
    *   Map data volumes to `../volumes/<service-name>-data`.
    *   Define named volumes at the bottom of the file.
*   **Environment Variables**:
    *   Use `${VARIABLE_NAME}` syntax for secrets.
    *   Do **not** hardcode passwords.

**Template:**

```yaml
version: "3.8"

services:
  my-service:
    image: my-service:latest
    platform: linux/amd64
    container_name: my-service-local
    ports:
      - "PORT:PORT"
    environment:
      PASSWORD: ${SERVICE_PASSWORD}
    volumes:
      - ../volumes/my-service-data:/data

volumes:
  my-service-data:
    name: my-service-data
```

## 3. Secret Management (Vault Integration)

All sensitive data (passwords, API keys) must be stored in Vault.

### 3.1. Update `.env` Template
Add the new service's required credentials to the root `.env` file.

```properties
# My Service Credentials
SERVICE_PASSWORD=
```

### 3.2. Update `vault-local/init_vault.sh`
Add a command to write the new secret to Vault.

```bash
run_vault kv put -mount=secret myservice/auth password="$SERVICE_PASSWORD"
```

### 3.3. Implement `up.sh` with Vault Fetching
The `up.sh` script must:
1.  Check if Vault is running.
2.  Fetch secrets using the `vault` CLI (via `docker exec`).
3.  Export secrets as environment variables.
4.  Run `docker compose up -d`.

**Standard `up.sh` Pattern:**

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_FILE="${ROOT_DIR}/vault_keys.txt"
COMPOSE_FILE="${ROOT_DIR}/<service-name>-local/docker-compose.yml"

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
    export SERVICE_PASSWORD=$(fetch_secret myservice/auth password)
else
    echo "[WARN] Vault not detected. Using local environment."
fi

echo "[INFO] Starting <service-name>..."
docker compose -f "${COMPOSE_FILE}" up -d
```

## 4. Standard Scripts

### `down.sh`
Standard script to stop containers.

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/<service-name>-local/docker-compose.yml"
docker compose -f "${COMPOSE_FILE}" down
```

### `reset.sh`
Standard script to stop containers and remove data volumes.

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/<service-name>-local/docker-compose.yml"
DATA_DIR="${ROOT_DIR}/volumes/<service-name>-data"

docker compose -f "${COMPOSE_FILE}" down
rm -rf "$DATA_DIR"
docker compose -f "${COMPOSE_FILE}" up -d
```

## 5. Checklist for AI

1.  [ ] Created directory `<service>-local`.
2.  [ ] Created `docker-compose.yml` with `platform: linux/amd64`.
3.  [ ] Added credentials to `.env`.
4.  [ ] Updated `vault-local/init_vault.sh` to store credentials.
5.  [ ] Created `up.sh` that fetches secrets from Vault.
6.  [ ] Created `down.sh` and `reset.sh`.
7.  [ ] Verified volume mapping to `../volumes/`.
