#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Source Common Library
source "${ROOT_DIR}/bin/lib/common.sh"

if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <app_name>"
    exit 1
fi

APP_NAME=$1

# Check Vault Availability
check_vault

echo "[INFO] Generating token for app: $APP_NAME"

# Create/Update Policy
create_policy "$APP_NAME"

# Generate Token
TOKEN=$(create_token "$APP_NAME")

echo ""
echo "==================================================================="
echo "APP:     $APP_NAME"
echo "TOKEN:   $TOKEN"
echo "==================================================================="
echo "This token allows access to:"
echo " - infras/+/${APP_NAME}/*"
echo " - apps/${APP_NAME}/*"
