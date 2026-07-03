#!/bin/bash
# Deploy MinIO to MiniKube — single entrypoint (house style, cf. postgres/scripts/deploy.sh).
#
# Does everything cluster-side, in order:
#   1. Install the MinIO Operator (pinned v7.1.1) into infras-minio
#   2. Provision credentials: Vault is the source of truth (infras/minio/root),
#      20-char random password, NOTHING hardcoded on disk; create the k8s
#      Secrets the Tenant consumes
#   3. Apply the Tenant (minio-pool, 1x4 EC:2) and wait for it to be ready
#   4. Apply the ingress routes
#
# NOT included (separate utilities, like postgres keeps backup.sh apart):
#   - ./setup-dns.sh   (adds /etc/hosts entries; needs sudo)
#   - ./sync.sh start  (real-time host mirror daemon for data safety)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINIO_DIR="$(dirname "$SCRIPT_DIR")"
NS_MINIO="infras-minio"
NS_VAULT="infras-vault"

# 20-char alphanumeric (house style). `|| true` swallows the SIGPIPE that
# `head` closing the pipe raises in `tr` — which pipefail would otherwise
# turn into a script-aborting non-zero exit.
gen_pw() { tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 20 || true; }

echo "╔════════════════════════════════════════════════════════════╗"
echo "║  Deploy MinIO to MiniKube                                  ║"
echo "╚════════════════════════════════════════════════════════════╝"

# Preconditions: namespace + quota + limitrange come from the shared
# namespaces/ manifests (applied once for all services).
if ! kubectl get ns "$NS_MINIO" >/dev/null 2>&1 \
   || ! kubectl get limitrange minio-defaults -n "$NS_MINIO" >/dev/null 2>&1; then
  echo "❌ $NS_MINIO namespace or its minio-defaults LimitRange is missing."
  echo "   The LimitRange is required — the operator injects sidecar/init containers"
  echo "   with no resource requests, which the namespace quota would otherwise reject."
  echo "   Apply first:"
  echo "   kubectl apply -f ../namespaces/00-namespaces.yaml -f ../namespaces/resource-quotas.yaml"
  exit 1
fi

# 1. MinIO Operator ----------------------------------------------------------
echo ""
echo "→ Installing MinIO Operator (v7.1.1, pinned) into $NS_MINIO..."
kubectl apply -k "$MINIO_DIR/operator" >/dev/null
kubectl -n "$NS_MINIO" rollout status deployment/minio-operator --timeout=180s

# 2. Credentials — Vault is the source of truth -----------------------------
echo ""
echo "→ Provisioning credentials (Vault: infras/minio/root)..."
VAULT_POD=$(kubectl get pod -n "$NS_VAULT" -l app=vault -o jsonpath='{.items[0].metadata.name}')
[ -n "$VAULT_POD" ] || { echo "  ❌ Vault pod not found in $NS_VAULT"; exit 1; }
ROOT_TOKEN=$(kubectl get secret vault-root-token -n "$NS_VAULT" -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || echo "")
[ -n "$ROOT_TOKEN" ] || ROOT_TOKEN=$(cat "$MINIO_DIR/../.vault-init/root-token.txt" 2>/dev/null || echo "")
[ -n "$ROOT_TOKEN" ] || { echo "  ❌ No Vault root token (secret vault-root-token / .vault-init/root-token.txt)"; exit 1; }
kubectl exec -n "$NS_VAULT" "$VAULT_POD" -- vault login -method=token token="$ROOT_TOKEN" >/dev/null 2>&1

ROOT_USER="minio"
EXISTING=$(kubectl exec -n "$NS_VAULT" "$VAULT_POD" -- vault kv get -format=json infras/minio/root 2>/dev/null || echo "")
if [ -n "$EXISTING" ]; then
  ROOT_USER=$(echo "$EXISTING" | jq -r '.data.data.username // "minio"')
  ROOT_PASS=$(echo "$EXISTING" | jq -r '.data.data.password // ""')
  echo "  ✓ Reusing existing infras/minio/root (no rotation)"
fi
if [ -z "${ROOT_PASS:-}" ]; then
  ROOT_PASS=$(gen_pw)
  kubectl exec -n "$NS_VAULT" "$VAULT_POD" -- \
    vault kv put infras/minio/root username="$ROOT_USER" password="$ROOT_PASS" >/dev/null
  echo "  ✓ Generated 20-char root credential -> infras/minio/root"
fi

CONSOLE_KEY="console"
CONSOLE_SECRET=$(kubectl get secret storage-user -n "$NS_MINIO" -o jsonpath='{.data.CONSOLE_SECRET_KEY}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
[ -n "$CONSOLE_SECRET" ] || CONSOLE_SECRET=$(gen_pw)

kubectl create secret generic storage-configuration -n "$NS_MINIO" \
  --from-literal=config.env="$(printf 'export MINIO_ROOT_USER="%s"\nexport MINIO_ROOT_PASSWORD="%s"\nexport MINIO_STORAGE_CLASS_STANDARD="EC:2"\nexport MINIO_BROWSER="on"' "$ROOT_USER" "$ROOT_PASS")" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl create secret generic storage-user -n "$NS_MINIO" \
  --from-literal=CONSOLE_ACCESS_KEY="$CONSOLE_KEY" \
  --from-literal=CONSOLE_SECRET_KEY="$CONSOLE_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "  ✓ storage-configuration + storage-user secrets applied"

# 3. Tenant ------------------------------------------------------------------
echo ""
echo "→ Applying Tenant and waiting for it to be ready..."
kubectl apply -f "$MINIO_DIR/tenant.yaml" >/dev/null
for _ in $(seq 1 30); do
  kubectl get pod -n "$NS_MINIO" -l v1.min.io/tenant=infras >/dev/null 2>&1 \
    && [ -n "$(kubectl get pod -n "$NS_MINIO" -l v1.min.io/tenant=infras -o name 2>/dev/null)" ] && break
  sleep 5
done
kubectl -n "$NS_MINIO" wait --for=condition=ready pod -l v1.min.io/tenant=infras --timeout=300s

# 4. Ingress -----------------------------------------------------------------
echo ""
echo "→ Applying ingress routes..."
kubectl apply -f "$MINIO_DIR/ingress.yaml" >/dev/null

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  MinIO deployed.                                           ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo "  Console:  http://minio.local:8080   (user: $ROOT_USER; pass in Vault infras/minio/root)"
echo "  S3 API:   http://s3.minio.local:8080"
echo "  Next:     ./scripts/setup-dns.sh     # /etc/hosts (sudo, one-time)"
echo "            ./scripts/sync.sh start    # real-time host mirror"
