#!/bin/bash
# Deploy Kafka to MiniKube with Vault integration

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KAFKA_DIR="$(dirname "$SCRIPT_DIR")"

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Deploy Kafka to MiniKube                                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

# Check Vault
echo "→ Checking Vault..."
if ! kubectl get pod -n infras-vault -l app=vault &>/dev/null; then
    echo "  ❌ Vault not found in infras-vault namespace"
    echo "     Deploy Vault first"
    exit 1
fi

VAULT_POD=$(kubectl get pod -n infras-vault -l app=vault -o jsonpath='{.items[0].metadata.name}')
echo "  ✓ Vault pod: $VAULT_POD"

# Check Vault status
if ! kubectl exec -n infras-vault "$VAULT_POD" -- vault status -format=json 2>/dev/null | jq -e '.sealed == false' &>/dev/null; then
    echo "  ⚠️  Vault is sealed. Unseal first"
    exit 1
fi
echo "  ✓ Vault is unsealed"

# Get Vault root token
echo ""
echo "→ Fetching Vault credentials..."
ROOT_TOKEN=$(kubectl get secret vault-root-token -n infras-vault -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || echo "")

if [ -z "$ROOT_TOKEN" ]; then
    echo "  ❌ vault-root-token secret not found"
    echo "     Create it first:"
    echo "     kubectl create secret generic vault-root-token -n infras-vault --from-literal=token=\$(cat ~/.vault-init/root-token.txt)"
    exit 1
fi

# Login to Vault
kubectl exec -n infras-vault "$VAULT_POD" -- vault login -method=token token="$ROOT_TOKEN" > /dev/null 2>&1

# Fetch/Create Kafka admin credentials
echo "  → Getting Kafka admin credentials from Vault..."

# Check if credentials exist
CREDS_JSON=$(kubectl exec -n infras-vault "$VAULT_POD" -- vault kv get -format=json infras/kafka/sasl 2>/dev/null || echo "")

if [ -n "$CREDS_JSON" ]; then
    # Parse username and password from existing secret
    USERNAME=$(echo "$CREDS_JSON" | jq -r '.data.data.username // "admin"')
    PASSWORD=$(echo "$CREDS_JSON" | jq -r '.data.data.password // ""')

    if [ -z "$PASSWORD" ] || [ "$(echo "$CREDS_JSON" | jq -r '.data.data.username // ""')" = "" ]; then
        echo "  → Updating secret structure..."
        PASSWORD=$(echo "$CREDS_JSON" | jq -r '.data.data.password // ""')
        if [ -z "$PASSWORD" ]; then
            PASSWORD=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)
        fi
        kubectl exec -n infras-vault "$VAULT_POD" -- vault kv put infras/kafka/sasl username="admin" password="$PASSWORD" > /dev/null 2>&1
        echo "  ✓ Secret updated with username and password"
    else
        echo "  ✓ Credentials found in Vault"
    fi
else
    # Create new secret with both username and password
    echo "  → Credentials not found, generating..."
    USERNAME="admin"
    PASSWORD=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)
    kubectl exec -n infras-vault "$VAULT_POD" -- vault kv put infras/kafka/sasl username="$USERNAME" password="$PASSWORD" > /dev/null 2>&1
    echo "  ✓ Credentials stored in Vault at infras/kafka/sasl"
fi

# Generate broker password
BROKER_PASSWORD=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 20)

# Create JAAS Secret with Vault credentials
echo ""
echo "→ Creating JAAS Secret..."
kubectl create secret generic kafka-jaas-config \
    --from-literal=kafka_server_jaas.conf="KafkaServer {
  org.apache.kafka.common.security.plain.PlainLoginModule required
  username=\"kafka-1\"
  password=\"${BROKER_PASSWORD}\"
  user_admin=\"${PASSWORD}\"
  user_kafka-1=\"${BROKER_PASSWORD}\"
;
};" \
    -n infras-kafka --dry-run=client -o yaml | kubectl apply -f -
echo "  ✓ JAAS Secret created"

# Store broker password in Vault for reference
echo ""
echo "→ Storing broker credentials in Vault..."
kubectl exec -n infras-vault "$VAULT_POD" -- vault kv put infras/kafka/broker username="kafka-1" password="$BROKER_PASSWORD" > /dev/null 2>&1
echo "  ✓ Broker credentials stored in Vault at infras/kafka/broker"

# Deploy resources
echo ""
echo "→ Deploying Kafka resources..."
kubectl apply -f "$KAFKA_DIR/configmap.yaml"
kubectl apply -f "$KAFKA_DIR/service.yaml"

# Delete existing StatefulSet if exists (to restart with new config)
if kubectl get statefulset kafka -n infras-kafka &>/dev/null; then
    echo "  → Deleting existing StatefulSet..."
    kubectl delete statefulset kafka -n infras-kafka
    echo "  ✓ StatefulSet deleted"
fi

kubectl apply -f "$KAFKA_DIR/statefulset.yaml"
echo "  ✓ Resources deployed"

# Wait for ready
echo ""
echo "→ Waiting for Kafka to be ready..."
kubectl wait --for=condition=ready pod -l app=kafka -n infras-kafka --timeout=120s

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Kafka Deployed Successfully!                               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Connection Details:"
echo "  PLAINTEXT (9092): kafka.infras-kafka.svc.cluster.local:9092"
echo "  SASL (9095):      kafka.infras-kafka.svc.cluster.local:9095"
echo "  Port-forward:     kubectl port-forward -n infras-kafka svc/kafka 9095:9095"
echo ""
echo "  Internal ports (290xx):"
echo "    Broker:    29091"
echo "    Internal:  29092 (for CLI kafka-acls.sh)"
echo "    Controller: 29093"
echo ""
echo "Admin Credentials:"
echo "  Username:         admin"
echo "  Password:         (stored in Vault)"
echo "  Vault path:       infras/kafka/sasl"
echo ""
echo "Broker Credentials:"
echo "  Username:         kafka-1"
echo "  Vault path:       infras/kafka/broker"
echo ""
echo "Commands:"
echo "  Logs:      kubectl logs -n infras-kafka -f kafka-0"
echo "  Port-forward: kubectl port-forward -n infras-kafka kafka-0 9094:9094"
echo "  CLI ACL:   infras-cli kafka create-acl <service-name>"
echo ""
