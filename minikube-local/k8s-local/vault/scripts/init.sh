#!/bin/bash
# Initialize Vault and save unseal keys and root token
# Can be re-run safely (checks if already initialized)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$VAULT_DIR/../.vault-init"
OUTPUT_FILE="$OUTPUT_DIR/cluster-keys.json"
ROOT_TOKEN_FILE="$OUTPUT_DIR/root-token.txt"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Initialize Vault                                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if Vault pod is running
POD_NAME=$(kubectl get pods -n infras-vault -l app=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$POD_NAME" ]; then
    echo "❌ Vault pod not found!"
    echo "   Deploy Vault first:"
    echo "   $SCRIPT_DIR/deploy.sh"
    exit 1
fi

echo "→ Found Vault pod: $POD_NAME"
echo ""

# Wait for Vault pod to be running (not Ready, since Vault isn't initialized yet)
echo "→ Waiting for Vault pod to be running..."
kubectl wait --for=jsonpath='.status.phase'=Running pod "$POD_NAME" -n infras-vault --timeout=120s
echo "✅ Vault is running (ready for initialization)"
echo ""

# Check if already initialized
echo "→ Checking if Vault is already initialized..."
INIT_STATUS=$(kubectl exec -n infras-vault "$POD_NAME" -- vault status -format=json 2>/dev/null | jq -r '.initialized' 2>/dev/null || echo "false")

if [ "$INIT_STATUS" = "true" ]; then
    echo "⚠️  Vault is already initialized!"
    echo ""
    echo "To re-initialize, you must:"
    echo "  1. Backup your data: kubectl exec -n infras-vault $POD_NAME -- mv /vault/file /vault/file.backup"
    echo "  2. Wipe Vault data: kubectl exec -n infras-vault $POD_NAME -- rm -rf /vault/file/*"
    echo "  3. Restart Vault: kubectl delete pod $POD_NAME -n infras-vault"
    echo "  4. Run this script again"
    echo ""
    echo "Your existing keys are in: $OUTPUT_FILE"
    exit 0
fi

# Initialize Vault
echo "→ Initializing Vault (this may take a moment)..."
INIT_OUTPUT=$(kubectl exec -n infras-vault "$POD_NAME" -- vault operator init -format=json -key-shares=5 -key-threshold=3)

# Save output
mkdir -p "$OUTPUT_DIR"
echo "$INIT_OUTPUT" | jq '.' > "$OUTPUT_FILE"

# Extract root token
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | jq -r '.root_token')
echo "$ROOT_TOKEN" > "$ROOT_TOKEN_FILE"
chmod 600 "$ROOT_TOKEN_FILE"

echo "✅ Vault initialized successfully!"
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  IMPORTANT: Save your keys securely!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Keys saved to: $OUTPUT_FILE"
echo "Root token saved to: $ROOT_TOKEN_FILE"
echo ""
echo "⚠️  BACKUP THESE FILES AND STORE THEM SECURELY!"
echo "   Without them, you cannot access your Vault data!"
echo ""
echo "Unseal keys (5 keys, need 3 to unseal):"
echo "$INIT_OUTPUT" | jq -r '.unseal_keys_b64[]' | nl -w2 -s'. '
echo ""
echo "Root token:"
echo "  $ROOT_TOKEN"
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Next Steps:"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "1. Unseal Vault (run 3 times with different keys):"
echo "   $SCRIPT_DIR/unseal.sh"
echo ""
echo "2. Configure Vault (secrets engines, auth):"
echo "   $SCRIPT_DIR/configure.sh"
echo ""
echo "════════════════════════════════════════════════════════════"
echo ""
