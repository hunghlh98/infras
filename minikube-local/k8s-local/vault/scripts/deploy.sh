#!/bin/bash
# Deploy Vault to MiniKube cluster
# Can be re-run to update Vault deployment

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VAULT_DIR="$(dirname "$SCRIPT_DIR")"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Deploy Vault to MiniKube                                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check if namespace exists
if ! kubectl get namespace infras-vault &>/dev/null; then
    echo "❌ Namespace infras-vault not found!"
    echo "   Please create it first:"
    echo "   kubectl apply -f minikube-local/k8s-local/namespaces/00-namespaces.yaml"
    exit 1
fi

echo "→ Deploying Vault resources..."

# Apply ServiceAccount and RBAC
echo "  • Applying ServiceAccount and RBAC..."
kubectl apply -f "$VAULT_DIR/serviceaccount.yaml"

# Apply ConfigMap
echo "  • Applying ConfigMap..."
kubectl apply -f "$VAULT_DIR/configmap.yaml"

# Apply Services
echo "  • Applying Services..."
kubectl apply -f "$VAULT_DIR/service.yaml"

# Apply Ingress
echo "  • Applying Ingress..."
kubectl apply -f "$VAULT_DIR/ingress.yaml"

# Apply StatefulSet
echo "  • Applying StatefulSet..."
kubectl apply -f "$VAULT_DIR/statefulset.yaml"

echo ""
echo "✅ Vault deployed successfully!"
echo ""
echo "Waiting for Vault pod to be running..."
kubectl wait --for=jsonpath='.status.phase'=Running pod -l app=vault -n infras-vault --timeout=120s
echo "✅ Vault is running (not yet initialized)"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Next Steps:"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "1. Initialize Vault:"
echo "   $SCRIPT_DIR/init.sh"
echo ""
echo "2. Unseal Vault (after initialization):"
echo "   $SCRIPT_DIR/unseal.sh"
echo ""
echo "3. Configure Vault (secrets engines, auth):"
echo "   $SCRIPT_DIR/configure.sh"
echo ""
echo "════════════════════════════════════════════════════════════"
echo ""
