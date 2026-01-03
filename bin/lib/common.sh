#!/usr/bin/env bash

# Logging Functions
log_info() {
    echo "[INFO] $(date +'%Y-%m-%d %H:%M:%S') - $1"
}

log_warn() {
    echo "[WARN] $(date +'%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_error() {
    echo "[ERROR] $(date +'%Y-%m-%d %H:%M:%S') - $1" >&2
}

# Vault Functions
KEYS_FILE="${ROOT_DIR}/vault_keys.txt"

check_vault() {
    if [ ! -f "$KEYS_FILE" ]; then
        log_error "Vault keys file not found at $KEYS_FILE"
        exit 1
    fi

    if [ -z "$(docker ps -q -f name=vault-local)" ]; then
        log_error "Vault container 'vault-local' is not running."
        exit 1
    fi
    
    # Export Vault Token for subsequent commands
    export VAULT_TOKEN=$(jq -r ".root_token" "$KEYS_FILE")
}

check_vault_mount() {
    local mount=$1
    if ! docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault-local vault secrets list | grep -q "${mount}/"; then
        log_info "Vault mount '$mount/' seems missing. Attempting to enable..."
        docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault-local vault secrets enable -path="$mount" kv >/dev/null 2>&1 || true
    fi
}

fetch_secret() {
    local path=$1
    local field=$2
    # Determine mount from path or assume 'secret' if not specified?
    # Actually 'vault kv get' handles the mount if it's in the path (e.g. apps/foo) BUT
    # vault kv syntax is 'vault kv get -mount=secret foo' OR 'vault kv get secret/foo' depending on version/v2.
    # The current code uses '-mount=secret'. We need to make it dynamic.
    
    # Simple heuristic: If path starts with 'apps/', use mount='apps'. Else 'secret'.
    local mount="secret"
    local secret_path="$path"
    
    if [[ "$path" == apps/* ]]; then
        mount="apps"
        secret_path="${path#apps/}"
    elif [[ "$path" == infras/* ]]; then
        mount="infras"
        secret_path="${path#infras/}"
    elif [[ "$path" == secret/* ]]; then
        mount="secret"
        secret_path="${path#secret/}"
    fi

    docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault-local vault kv get -mount="$mount" -field="$field" "$secret_path"
}

store_secret() {
    local path=$1
    local key=$2
    local value=$3
    
    local mount="secret"
    local secret_path="$path"
    
    if [[ "$path" == apps/* ]]; then
        mount="apps"
        secret_path="${path#apps/}"
    elif [[ "$path" == infras/* ]]; then
        mount="infras"
        secret_path="${path#infras/}"
    elif [[ "$path" == secret/* ]]; then
        mount="secret"
        secret_path="${path#secret/}"
    fi
    
    # Check if mount exists (lazy check for apps and infras)
    if [ "$mount" == "apps" ] || [ "$mount" == "infras" ]; then
        check_vault_mount "$mount"
    fi

    docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault-local vault kv put -mount="$mount" "$secret_path" "$key"="$value" > /dev/null
}

store_credential() {
    local path=$1
    local username=$2
    local password=$3
    
    local mount="secret"
    local secret_path="$path"
    
    if [[ "$path" == apps/* ]]; then
        mount="apps"
        secret_path="${path#apps/}"
    elif [[ "$path" == infras/* ]]; then
        mount="infras"
        secret_path="${path#infras/}"
    elif [[ "$path" == secret/* ]]; then
        mount="secret"
        secret_path="${path#secret/}"
    fi
    
    # Check if mount exists (lazy check for apps and infras)
    if [ "$mount" == "apps" ] || [ "$mount" == "infras" ]; then
        check_vault_mount "$mount"
    fi

    docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault-local vault kv put -mount="$mount" "$secret_path" username="$username" password="$password" > /dev/null
}

ensure_credential() {
    local path=$1
    local username=$2
    
    log_info "Ensuring credential exists at $path..."
    
    # Try to fetch existing password
    local existing_pass=$(fetch_secret "$path" password 2>/dev/null || true)
    
    if [ -n "$existing_pass" ]; then
        log_info "Credential already exists at $path. Skipping generation."
    else
        log_info "Credential missing at $path. Generating new..."
        local new_pass=$(generate_password)
        store_credential "$path" "$username" "$new_pass"
        log_info "Generated and stored new credential for $username at $path."
    fi
}

create_policy() {
    local app_name=$1
    local policy_name="app-${app_name}"
    
    # Create policy file content
    # Support both KV v1 and v2 paths to be robust
    local policy_content="
# Apps (v1 + v2)
path \"apps/data/${app_name}\" { capabilities = [\"read\", \"list\"] }
path \"apps/metadata/${app_name}\" { capabilities = [\"read\", \"list\"] }
path \"apps/data/${app_name}/*\" { capabilities = [\"read\", \"list\"] }

# Infras (v1 + v2)
path \"infras/+/${app_name}\" { capabilities = [\"read\", \"list\"] }
path \"infras/+/${app_name}/*\" { capabilities = [\"read\", \"list\"] }
path \"infras/data/+/${app_name}\" { capabilities = [\"read\", \"list\"] }
path \"infras/data/+/${app_name}/*\" { capabilities = [\"read\", \"list\"] }
"
    
    log_info "Creating/Updating Vault policy '$policy_name'..."
    docker exec -i -e VAULT_TOKEN="$VAULT_TOKEN" vault-local vault policy write "$policy_name" - <<< "$policy_content" > /dev/null
}

create_token() {
    local app_name=$1
    local policy_name="app-${app_name}"
    
    log_info "Generating Vault Token for '$app_name'..." >&2
    
    # Create token with policy
    # -format=json to parse token
    local token_json=$(docker exec -e VAULT_TOKEN="$VAULT_TOKEN" vault-local vault token create -policy="$policy_name" -format=json)
    local token=$(echo "$token_json" | jq -r ".auth.client_token")
    
    echo "$token"
}

# General Utilities
generate_password() {
    # Generate a random alphanumeric string
    openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16
}
