#!/bin/bash
# Unseal Vault
# Can be run multiple times (checks if already unsealed)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
K8S_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"
OUTPUT_DIR="$K8S_DIR/.vault-init"
OUTPUT_FILE="$OUTPUT_DIR/cluster-keys.json"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Unseal Vault                                              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if keys file exists
if [ ! -f "$OUTPUT_FILE" ]; then
    echo "❌ Initialization keys not found!"
    echo "   Initialize Vault first:"
    echo "   $SCRIPT_DIR/init.sh"
    exit 1
fi

# Check if Vault pod is running
POD_NAME=$(kubectl get pods -n infras-vault -l app=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$POD_NAME" ]; then
    echo "❌ Vault pod not found!"
    exit 1
fi

echo "→ Found Vault pod: $POD_NAME"
echo ""

# Check seal status
echo "→ Checking seal status..."
SEALED=$(kubectl exec -n infras-vault "$POD_NAME" -- vault status -format=json 2>/dev/null | jq -r '.sealed' 2>/dev/null || echo "true")

if [ "$SEALED" = "false" ]; then
    echo "✅ Vault is already unsealed!"
    echo ""
    kubectl exec -n infras-vault "$POD_NAME" -- vault status
    exit 0
fi

echo "→ Vault is sealed. Unsealing..."
echo ""

# Get unseal keys
UNSEAL_KEYS=$(jq -r '.unseal_keys_b64[]' "$OUTPUT_FILE")
KEY_COUNT=0
THRESHOLD=3

for KEY in $UNSEAL_KEYS; do
    KEY_COUNT=$((KEY_COUNT + 1))

    if [ $KEY_COUNT -gt $THRESHOLD ]; then
        echo "✅ Vault is unsealed! (used $KEY_COUNT keys)"
        echo ""
        kubectl exec -n infras-vault "$POD_NAME" -- vault status
        echo ""
        echo "════════════════════════════════════════════════════════════"
        echo "  Next Step:"
        echo "════════════════════════════════════════════════════════════"
        echo ""
        echo "Configure Vault (secrets engines, auth):"
        echo "  $SCRIPT_DIR/configure.sh"
        echo ""
        echo "════════════════════════════════════════════════════════════"
        exit 0
    fi

    echo "→ Using unseal key $KEY_COUNT of $THRESHOLD..."
    OUTPUT=$(kubectl exec -n infras-vault "$POD_NAME" -- vault operator unseal "$KEY" 2>&1)

    # Check if unseal was successful (either progress or already unsealed)
    if echo "$OUTPUT" | grep -q "Unseal Progress\|Sealed.*false"; then
        echo "  ✅ Key accepted (Progress: $KEY_COUNT/$THRESHOLD)"
    else
        echo "  ❌ Error: $OUTPUT"
        exit 1
    fi

    # Small delay between keys
    sleep 1
done
