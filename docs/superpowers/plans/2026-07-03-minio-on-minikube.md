# MinIO on Minikube Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy MinIO into the local minikube cluster via the MinIO Operator as a single-node erasure-coded Tenant, exposed through nginx ingress, with host backups for data safety, and provisionable through `infras-cli` (CLI + API) as a first-class infra type.

**Architecture:** Install the MinIO Operator (controller) into `minio-operator`. Declare a `Tenant` in `infras-minio` running one pool of 1 server × 4 drives with `EC:2` erasure coding on native `standard` PVCs. Serve HTTP (no auto-TLS) behind the existing nginx ingress on the `:8080` forwarder. Achieve "data safe on host" via a local `mc mirror` backup script — not a live host mount (MinIO does not support 9p/NFS backends).

**Tech Stack:** Kubernetes 1.35 (minikube, docker driver), MinIO Operator v7.1.1, MinIO `RELEASE.2025-04-08T15-41-24Z`, nginx ingress, `mc` client, bash.

## Global Constraints

- **Operator version:** `v7.1.1` (final community release; repo archived 2026-03-20, unmaintained). Requires Kubernetes ≥ 1.30.0 — cluster is 1.35.1 ✓.
- **Tenant API:** `apiVersion: minio.min.io/v2`, `kind: Tenant`.
- **MinIO image:** `quay.io/minio/minio:RELEASE.2025-04-08T15-41-24Z`.
- **Topology:** exactly **1 server × 4 `volumesPerServer`**, `MINIO_STORAGE_CLASS_STANDARD="EC:2"`. (Single-node minikube: multiple servers would fail scheduling under the Operator's node anti-affinity; 1 server × 4 drives gives erasure coding on one node.)
- **Storage:** `storageClassName: standard`, `2Gi` per drive (4 drives = 8Gi).
- **TLS:** `requestAutoCert: false` (HTTP served, proxied by nginx; matches vault/grafana `ssl-redirect: "false"`).
- **Namespaces:** Operator → `minio-operator` (Operator-created); Tenant → `infras-minio` (we create).
- **Ingress:** `ingressClassName: nginx`; hosts `minio.local` (console) and `s3.minio.local` (S3 API); reached via the existing `minikube-ingress-forwarder` on `http://<host>.local:8080`.
- **Dev credentials (change for anything real):** root `minio` / `minio123`; console user `console` / `console123`. These are local-dev placeholders.
- **Backups:** local `mc` binary → `volumes/minio-backup/<timestamp>/` on the host.
- **File layout:** all new manifests under `minikube-local/k8s-local/minio/`, matching existing service directories.
- **infras-cli integration:** MinIO is a first-class infra type. Provisioning model is **bucket-per-app** (each app gets an own bucket named after the service, full RW on that bucket). Admin creds live in Vault at `infras/minio/root`. Client is the `minio` Python SDK (`MinioAdmin` + `Minio`). Endpoint default `minio.infras-minio.svc.cluster.local:80` (`minio_secure=false`); local CLI overrides via `MINIO_ENDPOINT`.
- **infras-cli dependency:** `minio==7.2.15`. Adding it requires rebuilding the image into minikube's docker-env (`eval $(minikube -p minikube docker-env) && docker build ...`) and `kubectl rollout restart` — `minikube image load` will NOT overwrite `:latest`.
- **Out of scope (documented, not built here):** Vault-sourced credentials, real TLS, multi-node topology, and the global `/tmp/hostpath-provisioner` fix (separate task — touches all services).

---

## File Structure

| File | Responsibility |
|------|----------------|
| `minikube-local/k8s-local/namespaces/00-namespaces.yaml` (modify) | Add `infras-minio` namespace |
| `minikube-local/k8s-local/namespaces/resource-quotas.yaml` (modify) | Add generous quota for `infras-minio` |
| `minikube-local/k8s-local/minio/operator/install.sh` (create) | Pinned Operator install |
| `minikube-local/k8s-local/minio/secrets.yaml` (create) | `storage-configuration` + `storage-user` Secrets |
| `minikube-local/k8s-local/minio/tenant.yaml` (create) | `Tenant` CR (1×4, EC:2, HTTP) |
| `minikube-local/k8s-local/minio/ingress.yaml` (create) | Console + S3 API ingresses |
| `minikube-local/k8s-local/minio/scripts/setup-dns.sh` (create) | Add `minio.local`/`s3.minio.local` to `/etc/hosts` |
| `minikube-local/k8s-local/minio/scripts/backup.sh` (create) | `mc mirror` backup/restore/list/verify/cleanup/schedule |
| `minikube-local/k8s-local/minio/README.md` (create) | Deploy, access, backup, scale-to-prod notes |
| `minikube-local/k8s-local/minio/scripts/store-admin-creds.sh` (create) | Seed `infras/minio/root` into Vault for infras-cli |
| `.../infras-cli/app/config.py` (modify) | Add `minio_endpoint` / `minio_secure` |
| `.../infras-cli/requirements.txt` (modify) | Add `minio==7.2.15` |
| `.../infras-cli/app/services/minio_service.py` (create) | `MinIOService` ACL provisioning |
| `.../infras-cli/app/services/factory.py` (modify) | Register `"minio"` |
| `.../infras-cli/app/api/routes/acl.py` (modify) | Add `"minio"` to `SUPPORTED_INFRA_TYPES` |
| `.../infras-cli/app/cli/__main__.py` (modify) | Mention `minio` in help text |
| `.../infras-cli/tests/unit/test_minio_service.py` (create) | MinIOService unit tests |
| `.../infras-cli/tests/unit/test_factory_minio.py` (create) | Factory registration test |

---

## Task 1: Namespace & Resource Quota

**Files:**
- Modify: `minikube-local/k8s-local/namespaces/00-namespaces.yaml`
- Modify: `minikube-local/k8s-local/namespaces/resource-quotas.yaml`

**Interfaces:**
- Produces: namespace `infras-minio` (used by all later tasks); ResourceQuota `minio-resource-quota`.

- [ ] **Step 1: Add the namespace**

Append to `minikube-local/k8s-local/namespaces/00-namespaces.yaml`:

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: infras-minio
  labels:
    name: infras-minio
    project: k8s-local
```

- [ ] **Step 2: Add a generous resource quota**

Append to `minikube-local/k8s-local/namespaces/resource-quotas.yaml`. The quota must be generous — the Operator injects init/sidecar containers and tight quotas block Tenant pods:

```yaml
---
# Resource Quota for infras-minio namespace
# Generous on purpose: the MinIO Operator injects init/sidecar containers.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: minio-resource-quota
  namespace: infras-minio
spec:
  hard:
    requests.cpu: "1"
    requests.memory: "1Gi"
    limits.cpu: "2"
    limits.memory: "3Gi"
    persistentvolumeclaims: "6"
```

- [ ] **Step 3: Apply**

Run:
```bash
kubectl apply -f minikube-local/k8s-local/namespaces/00-namespaces.yaml
kubectl apply -f minikube-local/k8s-local/namespaces/resource-quotas.yaml
```
Expected: `namespace/infras-minio created` and `resourcequota/minio-resource-quota created` (other resources `unchanged`).

- [ ] **Step 4: Verify**

Run:
```bash
kubectl get ns infras-minio
kubectl get resourcequota -n infras-minio
```
Expected: namespace `Active`; quota `minio-resource-quota` listed with the limits above.

- [ ] **Step 5: Commit**

```bash
git add minikube-local/k8s-local/namespaces/00-namespaces.yaml minikube-local/k8s-local/namespaces/resource-quotas.yaml
git commit -m "feat(minio): add infras-minio namespace and resource quota"
```

---

## Task 2: Install the MinIO Operator

**Files:**
- Create: `minikube-local/k8s-local/minio/operator/install.sh`

**Interfaces:**
- Produces: the `minio-operator` namespace, the `minio.min.io/v2` CRDs (`tenants.minio.min.io`), and a running Operator controller. Task 4 depends on the CRD existing.

- [ ] **Step 1: Write the pinned install script**

Create `minikube-local/k8s-local/minio/operator/install.sh`:

```bash
#!/bin/bash
# Install the MinIO Operator (pinned) into the minio-operator namespace.
# NOTE: minio/operator was archived 2026-03-20; v7.1.1 is the final community
# release. Requires Kubernetes >= 1.30.
set -euo pipefail

OPERATOR_VERSION="v7.1.1"

echo "→ Installing MinIO Operator ${OPERATOR_VERSION}..."
kubectl kustomize "github.com/minio/operator?ref=${OPERATOR_VERSION}" | kubectl apply -f -

echo "→ Waiting for Operator deployment to become available..."
kubectl -n minio-operator rollout status deployment/minio-operator --timeout=180s

echo "✅ MinIO Operator ${OPERATOR_VERSION} installed."
```

- [ ] **Step 2: Make it executable and run it**

Run:
```bash
chmod +x minikube-local/k8s-local/minio/operator/install.sh
./minikube-local/k8s-local/minio/operator/install.sh
```
Expected: many `created` lines, then `deployment "minio-operator" successfully rolled out` and `✅ MinIO Operator v7.1.1 installed.`

- [ ] **Step 3: Verify the CRD and controller**

Run:
```bash
kubectl get crd tenants.minio.min.io
kubectl get pods -n minio-operator
```
Expected: CRD `tenants.minio.min.io` exists; Operator pod(s) in `minio-operator` are `Running`.

- [ ] **Step 4: Commit**

```bash
git add minikube-local/k8s-local/minio/operator/install.sh
git commit -m "feat(minio): pinned MinIO Operator v7.1.1 install script"
```

---

## Task 3: Credential Secrets

**Files:**
- Create: `minikube-local/k8s-local/minio/secrets.yaml`

**Interfaces:**
- Consumes: namespace `infras-minio` (Task 1).
- Produces: Secret `storage-configuration` (key `config.env`, referenced by `Tenant.spec.configuration.name`) and Secret `storage-user` (keys `CONSOLE_ACCESS_KEY`/`CONSOLE_SECRET_KEY`, referenced by `Tenant.spec.users[0].name`).

- [ ] **Step 1: Write the secrets manifest**

Create `minikube-local/k8s-local/minio/secrets.yaml`. `config.env` sets root creds AND the erasure-coding storage class (`EC:2`):

```yaml
---
# Root configuration consumed by Tenant.spec.configuration.name
apiVersion: v1
kind: Secret
metadata:
  name: storage-configuration
  namespace: infras-minio
type: Opaque
stringData:
  config.env: |-
    export MINIO_ROOT_USER="minio"
    export MINIO_ROOT_PASSWORD="minio123"
    export MINIO_STORAGE_CLASS_STANDARD="EC:2"
    export MINIO_BROWSER="on"
---
# Console user consumed by Tenant.spec.users[0].name
# CONSOLE_ACCESS_KEY=console  CONSOLE_SECRET_KEY=console123 (base64)
apiVersion: v1
kind: Secret
metadata:
  name: storage-user
  namespace: infras-minio
type: Opaque
data:
  CONSOLE_ACCESS_KEY: Y29uc29sZQ==
  CONSOLE_SECRET_KEY: Y29uc29sZTEyMw==
```

- [ ] **Step 2: Apply**

Run:
```bash
kubectl apply -f minikube-local/k8s-local/minio/secrets.yaml
```
Expected: `secret/storage-configuration created` and `secret/storage-user created`.

- [ ] **Step 3: Verify the keys and decoded values**

Run:
```bash
kubectl get secret storage-configuration -n infras-minio -o jsonpath='{.data.config\.env}' | base64 -d
kubectl get secret storage-user -n infras-minio -o jsonpath='{.data.CONSOLE_ACCESS_KEY}' | base64 -d; echo
```
Expected: the four `export ...` lines (including `MINIO_ROOT_USER="minio"` and `MINIO_STORAGE_CLASS_STANDARD="EC:2"`), then `console`.

- [ ] **Step 4: Commit**

```bash
git add minikube-local/k8s-local/minio/secrets.yaml
git commit -m "feat(minio): storage-configuration and console-user secrets"
```

---

## Task 4: MinIO Tenant

**Files:**
- Create: `minikube-local/k8s-local/minio/tenant.yaml`

**Interfaces:**
- Consumes: CRD `tenants.minio.min.io` (Task 2); Secrets `storage-configuration`, `storage-user` (Task 3); namespace/quota (Task 1).
- Produces: Tenant `infras`; the Operator-created Services `minio` (S3 API) and `infras-console` (console) in `infras-minio`; PVCs `data0-3-infras-pool-0-0`. Task 5 (ingress) and Task 6 (backup) depend on these service names.

- [ ] **Step 1: Write the Tenant manifest**

Create `minikube-local/k8s-local/minio/tenant.yaml`. Single server, 4 drives, HTTP:

```yaml
apiVersion: minio.min.io/v2
kind: Tenant
metadata:
  name: infras
  namespace: infras-minio
  labels:
    app: minio
  annotations:
    prometheus.io/path: /minio/v2/metrics/cluster
    prometheus.io/port: "9000"
    prometheus.io/scrape: "true"
spec:
  image: quay.io/minio/minio:RELEASE.2025-04-08T15-41-24Z
  mountPath: /export
  configuration:
    name: storage-configuration
  users:
    - name: storage-user
  requestAutoCert: false
  podManagementPolicy: Parallel
  pools:
    - name: pool-0
      servers: 1
      volumesPerServer: 4
      volumeClaimTemplate:
        metadata:
          name: data
        spec:
          accessModes:
            - ReadWriteOnce
          storageClassName: standard
          resources:
            requests:
              storage: 2Gi
      securityContext:
        runAsUser: 1000
        runAsGroup: 1000
        runAsNonRoot: true
        fsGroup: 1000
        fsGroupChangePolicy: "OnRootMismatch"
      containerSecurityContext:
        runAsUser: 1000
        runAsGroup: 1000
        runAsNonRoot: true
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
        seccompProfile:
          type: RuntimeDefault
      resources:
        requests:
          cpu: 250m
          memory: 512Mi
        limits:
          cpu: "1"
          memory: 2Gi
```

- [ ] **Step 2: Apply**

Run:
```bash
kubectl apply -f minikube-local/k8s-local/minio/tenant.yaml
```
Expected: `tenant.minio.min.io/infras created`.

- [ ] **Step 3: Wait for the pod and PVCs**

Run:
```bash
kubectl -n infras-minio wait --for=condition=ready pod -l v1.min.io/tenant=infras --timeout=240s
kubectl get pvc -n infras-minio
```
Expected: pod `infras-pool-0-0` becomes ready; four Bound PVCs `data0-infras-pool-0-0` … `data3-infras-pool-0-0`, each 2Gi, storageclass `standard`.

- [ ] **Step 4: Verify erasure coding and services**

Run:
```bash
kubectl logs -n infras-minio infras-pool-0-0 -c minio | grep -iE "Status:|drives|EC" | head
kubectl get svc -n infras-minio
```
Expected: startup log reports 4 online drives; Services include `minio` (S3 API) and `infras-console`. **Note the actual service names/ports — Task 5 must match them.**

- [ ] **Step 5: Commit**

```bash
git add minikube-local/k8s-local/minio/tenant.yaml
git commit -m "feat(minio): single-node erasure-coded Tenant (1x4, EC:2)"
```

---

## Task 5: Ingress & Local DNS

**Files:**
- Create: `minikube-local/k8s-local/minio/ingress.yaml`
- Create: `minikube-local/k8s-local/minio/scripts/setup-dns.sh`

**Interfaces:**
- Consumes: Services `minio` and `infras-console` in `infras-minio` (Task 4).
- Produces: host access at `http://minio.local:8080` (console) and `http://s3.minio.local:8080` (S3 API).

- [ ] **Step 1: Confirm the real service ports**

Run:
```bash
kubectl get svc -n infras-minio -o custom-columns=NAME:.metadata.name,PORTS:.spec.ports[*].port
```
Expected: `minio` on `80` and `infras-console` on `9090` (HTTP, because `requestAutoCert: false`). If your Operator build differs, use the observed names/ports in Step 2.

- [ ] **Step 2: Write the ingress manifest**

Create `minikube-local/k8s-local/minio/ingress.yaml`. Large `proxy-body-size` so big object uploads pass through nginx:

```yaml
---
# MinIO S3 API — http://s3.minio.local:8080
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-api-ingress
  namespace: infras-minio
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-body-size: "1000m"
spec:
  ingressClassName: nginx
  rules:
    - host: s3.minio.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: minio
                port:
                  number: 80
---
# MinIO Console — http://minio.local:8080
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-console-ingress
  namespace: infras-minio
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/proxy-body-size: "1000m"
spec:
  ingressClassName: nginx
  rules:
    - host: minio.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: infras-console
                port:
                  number: 9090
```

- [ ] **Step 3: Write the DNS helper**

Create `minikube-local/k8s-local/minio/scripts/setup-dns.sh` (mirrors `ingress/setup-local-dns.sh`):

```bash
#!/bin/bash
# Add minio.local and s3.minio.local to /etc/hosts pointing at the minikube IP.
set -e
MINIKUBE_IP=$(minikube ip)
HOSTS_FILE="/etc/hosts"

echo "→ MiniKube IP: $MINIKUBE_IP"
if grep -q "minio.local" "$HOSTS_FILE"; then
  echo "⚠ minio.local already present in $HOSTS_FILE — skipping."
  exit 0
fi

sudo -- bash -c "cat >> '$HOSTS_FILE' << EOF

# MinIO Ingress - Local DNS (managed by k8s-local)
$MINIKUBE_IP minio.local
$MINIKUBE_IP s3.minio.local
EOF"

echo "✅ Added minio.local and s3.minio.local"
echo "   Console: http://minio.local:8080"
echo "   S3 API:  http://s3.minio.local:8080"
```

- [ ] **Step 4: Apply ingress and configure DNS**

Run:
```bash
kubectl apply -f minikube-local/k8s-local/minio/ingress.yaml
chmod +x minikube-local/k8s-local/minio/scripts/setup-dns.sh
./minikube-local/k8s-local/minio/scripts/setup-dns.sh
```
Expected: two ingresses created; `/etc/hosts` gains the two entries.

- [ ] **Step 5: Verify host access**

Run:
```bash
curl -s -o /dev/null -w "console:%{http_code}\n" http://minio.local:8080/
curl -s http://s3.minio.local:8080/minio/health/live -o /dev/null -w "s3-health:%{http_code}\n"
```
Expected: `console:200` (console UI) and `s3-health:200` (MinIO liveness).

- [ ] **Step 6: Commit**

```bash
git add minikube-local/k8s-local/minio/ingress.yaml minikube-local/k8s-local/minio/scripts/setup-dns.sh
git commit -m "feat(minio): nginx ingress + local DNS for console and S3 API"
```

---

## Task 6: Backup & Restore Script

**Files:**
- Create: `minikube-local/k8s-local/minio/scripts/backup.sh`

**Interfaces:**
- Consumes: S3 API at `http://s3.minio.local:8080` (Task 5); root creds from Secret `storage-configuration` (Task 3).
- Produces: host snapshots under `volumes/minio-backup/<timestamp>/` and a restore path from them.

- [ ] **Step 1: Write the backup script**

Create `minikube-local/k8s-local/minio/scripts/backup.sh`. It auto-fetches a local `mc` binary, reads root creds from the k8s Secret, and mirrors all buckets to the host:

```bash
#!/bin/bash
# MinIO backup/restore for minikube — mirrors all buckets to the host.
# Commands: create | list | restore <snapshot> | verify <snapshot> | cleanup | schedule [hour]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MINIO_DIR="$(dirname "$SCRIPT_DIR")"
PROJECT_ROOT="$(cd "$MINIO_DIR/../../.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-$PROJECT_ROOT/volumes/minio-backup}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
NAMESPACE="infras-minio"
S3_ENDPOINT="${S3_ENDPOINT:-http://s3.minio.local:8080}"
ALIAS="infras"
MC_BIN="$SCRIPT_DIR/bin/mc"

log()  { echo -e "\033[0;34mℹ\033[0m $1"; }
ok()   { echo -e "\033[0;32m✓\033[0m $1"; }
warn() { echo -e "\033[1;33m⚠\033[0m $1"; }
err()  { echo -e "\033[0;31m✗\033[0m $1"; }

ensure_mc() {
  if [ ! -x "$MC_BIN" ]; then
    log "Downloading mc client..."
    mkdir -p "$(dirname "$MC_BIN")"
    curl -fsSL https://dl.min.io/client/mc/release/linux-amd64/mc -o "$MC_BIN"
    chmod +x "$MC_BIN"
  fi
}

configure_alias() {
  local user pass env
  env=$(kubectl get secret storage-configuration -n "$NAMESPACE" -o jsonpath='{.data.config\.env}' | base64 -d)
  user=$(echo "$env" | sed -n 's/^export MINIO_ROOT_USER="\(.*\)"$/\1/p')
  pass=$(echo "$env" | sed -n 's/^export MINIO_ROOT_PASSWORD="\(.*\)"$/\1/p')
  "$MC_BIN" alias set "$ALIAS" "$S3_ENDPOINT" "$user" "$pass" >/dev/null
}

create_backup() {
  ensure_mc; configure_alias
  local ts snap
  ts=$(date +"%Y%m%d-%H%M%S")
  snap="$BACKUP_DIR/$ts"
  mkdir -p "$snap"
  log "Mirroring all buckets to $snap ..."
  "$MC_BIN" mirror --overwrite "$ALIAS" "$snap"
  ok "Snapshot created: $snap"
}

list_backups() {
  if [ ! -d "$BACKUP_DIR" ]; then warn "No backups in $BACKUP_DIR"; return; fi
  log "Snapshots in $BACKUP_DIR:"
  ls -1 "$BACKUP_DIR"
}

restore_backup() {
  local snap="$1"
  [ -z "$snap" ] && { err "Usage: $0 restore <snapshot>"; list_backups; exit 1; }
  [[ "$snap" != /* ]] && snap="$BACKUP_DIR/$snap"
  [ -d "$snap" ] || { err "Snapshot not found: $snap"; exit 1; }
  ensure_mc; configure_alias
  warn "This mirrors $snap back INTO MinIO (may overwrite objects)."
  read -p "Continue? (yes/no): " c; [ "$c" = "yes" ] || { log "Cancelled"; exit 0; }
  "$MC_BIN" mirror --overwrite "$snap" "$ALIAS"
  ok "Restored from $snap"
}

verify_backup() {
  local snap="$1"
  [ -z "$snap" ] && { err "Usage: $0 verify <snapshot>"; exit 1; }
  [[ "$snap" != /* ]] && snap="$BACKUP_DIR/$snap"
  [ -d "$snap" ] || { err "Snapshot not found: $snap"; exit 1; }
  local files size
  files=$(find "$snap" -type f | wc -l)
  size=$(du -sh "$snap" | cut -f1)
  log "Snapshot: $snap"; echo "  Files: $files"; echo "  Size:  $size"
  [ "$files" -gt 0 ] && ok "Verification passed" || { err "Snapshot is empty"; exit 1; }
}

cleanup_backups() {
  [ -d "$BACKUP_DIR" ] || { warn "Nothing to clean"; return; }
  log "Removing snapshots older than $RETENTION_DAYS days..."
  find "$BACKUP_DIR" -maxdepth 1 -mindepth 1 -type d -mtime +"$RETENTION_DAYS" -print -exec rm -rf {} \;
  ok "Cleanup done"
}

schedule_backup() {
  local hour="${1:-02}"
  local cmd="cd $MINIO_DIR && ./scripts/backup.sh create >> $BACKUP_DIR/backup.log 2>&1"
  (crontab -l 2>/dev/null | grep -v "minio/scripts/backup.sh"; echo "0 $hour * * * $cmd") | crontab -
  ok "Scheduled daily backup at ${hour}:00"
}

case "${1:-}" in
  create)   create_backup ;;
  list)     list_backups ;;
  restore)  restore_backup "${2:-}" ;;
  verify)   verify_backup "${2:-}" ;;
  cleanup)  cleanup_backups ;;
  schedule) schedule_backup "${2:-}" ;;
  *) echo "Usage: $0 {create|list|restore <snap>|verify <snap>|cleanup|schedule [hour]}"; exit 1 ;;
esac
```

- [ ] **Step 2: Make executable and seed test data**

Run (creates a bucket + object so the backup has content):
```bash
chmod +x minikube-local/k8s-local/minio/scripts/backup.sh
BIN=minikube-local/k8s-local/minio/scripts/bin/mc
minikube-local/k8s-local/minio/scripts/backup.sh list >/dev/null 2>&1 || true   # triggers mc download
$BIN mb --ignore-existing infras/testbucket
echo "hello-minio" | $BIN pipe infras/testbucket/hello.txt
```
Expected: `Bucket created successfully` and no error on `pipe`.

- [ ] **Step 3: Create and verify a snapshot**

Run:
```bash
minikube-local/k8s-local/minio/scripts/backup.sh create
SNAP=$(ls -1t volumes/minio-backup | head -1)
minikube-local/k8s-local/minio/scripts/backup.sh verify "$SNAP"
cat "volumes/minio-backup/$SNAP/testbucket/hello.txt"
```
Expected: snapshot created; verify reports Files ≥ 1, "Verification passed"; the file prints `hello-minio` — **proving the object now lives on your host disk**.

- [ ] **Step 4: Restore drill**

Run (delete the bucket, then restore from host):
```bash
BIN=minikube-local/k8s-local/minio/scripts/bin/mc
$BIN rb --force infras/testbucket
$BIN mb infras/testbucket
SNAP=$(ls -1t volumes/minio-backup | head -1)
echo yes | minikube-local/k8s-local/minio/scripts/backup.sh restore "$SNAP"
$BIN cat infras/testbucket/hello.txt
```
Expected: `hello-minio` — data recovered from the host snapshot.

- [ ] **Step 5: Ignore the mc binary and backups in git**

Append to `.gitignore` (repo root):
```
minikube-local/k8s-local/minio/scripts/bin/
volumes/minio-backup/
```

- [ ] **Step 6: Commit**

```bash
git add minikube-local/k8s-local/minio/scripts/backup.sh .gitignore
git commit -m "feat(minio): mc-mirror backup/restore script with host snapshots"
```

---

## Task 7: Documentation

**Files:**
- Create: `minikube-local/k8s-local/minio/README.md`

**Interfaces:**
- Consumes: everything above.
- Produces: operator/user-facing docs.

- [ ] **Step 1: Write the README**

Create `minikube-local/k8s-local/minio/README.md`:

```markdown
# MinIO (Object Storage) — k8s-local

S3-compatible object storage deployed via the **MinIO Operator** as a
single-node, erasure-coded Tenant. Chosen to rehearse a production
Kubernetes deployment; data safety is provided by host backups.

> **Heads-up:** the community `minio/operator` was archived 2026-03-20.
> This uses the final release **v7.1.1** (pinned). Fine for local rehearsal;
> not receiving updates.

## Topology
- Namespace: `infras-minio` (Operator in `minio-operator`)
- 1 server × 4 drives, `EC:2` erasure coding, `standard` PVCs (2Gi each)
- HTTP (`requestAutoCert: false`), proxied by nginx ingress

## Deploy (in order)
```bash
kubectl apply -f ../namespaces/00-namespaces.yaml
kubectl apply -f ../namespaces/resource-quotas.yaml
./operator/install.sh
kubectl apply -f secrets.yaml
kubectl apply -f tenant.yaml
kubectl apply -f ingress.yaml
./scripts/setup-dns.sh
./scripts/store-admin-creds.sh   # seed infras/minio/root in Vault for infras-cli
```

## Provisioning app access (infras-cli)
MinIO is a first-class infra type. Each app gets its own bucket + scoped user:
```bash
infras-cli setup-acl <app> minio     # creates bucket <app>, user <app>, stores creds in Vault
infras-cli verify-acl <app> minio    # confirms the user exists
```

## Access
| Interface | URL | Credentials |
|-----------|-----|-------------|
| Console | http://minio.local:8080 | `minio` / `minio123` |
| S3 API (host) | http://s3.minio.local:8080 | root or `console` / `console123` |
| S3 API (in-cluster) | `minio.infras-minio.svc.cluster.local` | same |

`mc` alias: `mc alias set infras http://s3.minio.local:8080 minio minio123`

## Backups (data safety)
```bash
./scripts/backup.sh create            # snapshot all buckets → volumes/minio-backup/
./scripts/backup.sh list
./scripts/backup.sh verify <snapshot>
./scripts/backup.sh restore <snapshot>
./scripts/backup.sh schedule 2        # daily at 02:00
```

## Scaling to real production
- Increase the pool to `servers: 4+` across multiple nodes and remove the
  single-node assumption; the Operator's pod anti-affinity then spreads
  servers across nodes.
- Enable `requestAutoCert: true` for TLS.
- Source credentials from Vault (External Secrets Operator / Vault Agent)
  instead of the plain `storage-configuration` Secret.

## Known limitation
Data lives on native PVCs at the minikube provisioner path
(`/tmp/hostpath-provisioner`), which is not persisted across container
recreation. Rely on `backup.sh` for durability, or apply the repo-wide
provisioner fix (separate task).
```

- [ ] **Step 2: Commit**

```bash
git add minikube-local/k8s-local/minio/README.md
git commit -m "docs(minio): deploy, access, backup, and scale-to-prod guide"
```

---

## Task 8: infras-cli — Config, Dependency & MinIOService

**Files:**
- Modify: `minikube-local/k8s-local/infras-cli/app/config.py`
- Modify: `minikube-local/k8s-local/infras-cli/requirements.txt`
- Create: `minikube-local/k8s-local/infras-cli/app/services/minio_service.py`
- Create: `minikube-local/k8s-local/infras-cli/tests/unit/test_minio_service.py`

**Interfaces:**
- Consumes: `InfrastructureService` base (`app/services/base.py`), `settings` (`app/config.py`), Vault path `infras/minio/root` (seeded in Task 10).
- Produces: class `MinIOService` with `create_acl(service_name, password, **kwargs) -> dict`, `verify_acl(service_name, **kwargs) -> bool`, `get_vault_path(service_name) -> str`. Task 9 registers it.

> All commands below run from `minikube-local/k8s-local/infras-cli/` with the venv active: `cd minikube-local/k8s-local/infras-cli && source venv/bin/activate`.

- [ ] **Step 1: Add endpoint settings to config**

In `app/config.py`, after the `keycloak_port` line (~line 33), add:

```python
    minio_endpoint: str = "minio.infras-minio.svc.cluster.local:80"
    minio_secure: bool = False
```

- [ ] **Step 2: Add the dependency**

In `requirements.txt`, after the `requests==2.31.0` block, add:

```
# MinIO Admin/S3 Client
minio==7.2.15
```

Then install it into the venv:

Run: `pip install minio==7.2.15`
Expected: `Successfully installed minio-7.2.15 ...`

- [ ] **Step 3: Write the failing unit test**

Create `tests/unit/test_minio_service.py`:

```python
"""Unit tests for MinIOService (mocked Vault / MinIO clients)."""

import json
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from app.services.minio_service import MinIOService


def _service():
    vault = MagicMock()
    vault.fetch_secret = AsyncMock(side_effect=["minio", "minio123"])
    vault._detect_mount = MagicMock(return_value=("secret", "infras/minio/app1"))
    vault.client = MagicMock()
    svc = MinIOService(vault, MagicMock())
    # Neutralize the inherited Vault write so we test only MinIO behavior.
    svc._store_credential = AsyncMock(return_value="infras/minio/app1")
    return svc, vault


@pytest.mark.asyncio
async def test_create_acl_provisions_bucket_user_and_policy():
    svc, vault = _service()
    admin, s3 = MagicMock(), MagicMock()
    s3.bucket_exists.return_value = False
    with patch.object(MinIOService, "_clients", return_value=(admin, s3)):
        result = await svc.create_acl("app1", "secretpw")

    s3.make_bucket.assert_called_once_with("app1")
    admin.add_user.assert_called_once_with(access_key="app1", secret_key="secretpw")
    admin.set_user_or_group_policy.assert_called_once_with(
        policy_name="app-app1", user_or_group="app1"
    )
    # Policy JSON scopes to just this bucket
    _, kw = admin.add_canned_policy.call_args
    policy = json.loads(kw["policy"])
    assert policy["Statement"][0]["Resource"] == [
        "arn:aws:s3:::app1",
        "arn:aws:s3:::app1/*",
    ]
    assert result["bucket"] == "app1"
    assert result["access_key"] == "app1"
    assert result["vault_path"] == "infras/minio/app1"


@pytest.mark.asyncio
async def test_verify_acl_true_when_user_listed():
    svc, _ = _service()
    admin = MagicMock()
    admin.list_users.return_value = {"app1": {}, "other": {}}
    with patch.object(MinIOService, "_clients", return_value=(admin, MagicMock())):
        assert await svc.verify_acl("app1") is True


@pytest.mark.asyncio
async def test_verify_acl_false_when_user_absent():
    svc, _ = _service()
    admin = MagicMock()
    admin.list_users.return_value = {"other": {}}
    with patch.object(MinIOService, "_clients", return_value=(admin, MagicMock())):
        assert await svc.verify_acl("app1") is False


def test_get_vault_path():
    svc, _ = _service()
    assert svc.get_vault_path("app1") == "infras/minio/app1"
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `pytest tests/unit/test_minio_service.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.services.minio_service'`.

- [ ] **Step 5: Implement MinIOService**

Create `app/services/minio_service.py`:

```python
"""MinIO ACL provisioning service (bucket-per-app + scoped IAM policy)."""

import json
import structlog
from typing import Dict, Any

from minio import Minio, MinioAdmin
from minio.credentials import StaticProvider

from .base import InfrastructureService
from ..config import settings

logger = structlog.get_logger(__name__)


class MinIOService(InfrastructureService):
    """Provision MinIO access: a dedicated bucket + scoped policy + user per app."""

    def _clients(self, admin_user: str, admin_pass: str):
        """Build (MinioAdmin, Minio) clients from admin credentials."""
        creds = StaticProvider(admin_user, admin_pass)
        admin = MinioAdmin(
            endpoint=settings.minio_endpoint,
            credentials=creds,
            secure=settings.minio_secure,
        )
        s3 = Minio(
            settings.minio_endpoint,
            access_key=admin_user,
            secret_key=admin_pass,
            secure=settings.minio_secure,
        )
        return admin, s3

    @staticmethod
    def _policy_json(bucket: str) -> str:
        """Full read/write scoped to exactly one bucket."""
        return json.dumps({
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": ["s3:*"],
                    "Resource": [
                        f"arn:aws:s3:::{bucket}",
                        f"arn:aws:s3:::{bucket}/*",
                    ],
                }
            ],
        })

    async def create_acl(self, service_name: str, password: str, **kwargs) -> Dict[str, Any]:
        logger.info("Creating MinIO ACL", service_name=service_name)

        admin_user = await self.vault.fetch_secret("infras/minio/root", "username")
        admin_pass = await self.vault.fetch_secret("infras/minio/root", "password")

        admin, s3 = self._clients(admin_user, admin_pass)
        bucket = service_name
        policy_name = f"app-{service_name}"

        # 1. Bucket (idempotent)
        if not s3.bucket_exists(bucket):
            s3.make_bucket(bucket)
            logger.info("Created MinIO bucket", bucket=bucket)

        # 2. Scoped canned policy (upsert)
        admin.add_canned_policy(policy_name=policy_name, policy=self._policy_json(bucket))

        # 3. User whose access key IS the service name (upsert)
        admin.add_user(access_key=service_name, secret_key=password)

        # 4. Attach the policy to the user
        admin.set_user_or_group_policy(policy_name=policy_name, user_or_group=service_name)

        # 5. Store credential in Vault (+ app secret) via the inherited helper
        vault_path = await self._store_credential(service_name, password)

        logger.info("MinIO ACL created", service_name=service_name, vault_path=vault_path)
        return {
            "endpoint": settings.minio_endpoint,
            "bucket": bucket,
            "access_key": service_name,
            "policy": policy_name,
            "vault_path": vault_path,
        }

    async def verify_acl(self, service_name: str, **kwargs) -> bool:
        logger.info("Verifying MinIO ACL", service_name=service_name)
        admin_user = await self.vault.fetch_secret("infras/minio/root", "username")
        admin_pass = await self.vault.fetch_secret("infras/minio/root", "password")
        admin, _ = self._clients(admin_user, admin_pass)
        # Errors (endpoint/Vault unreachable) propagate -> reported as "could not verify".
        users = admin.list_users()
        exists = service_name in users
        if exists:
            logger.info("MinIO ACL verified", service_name=service_name)
        else:
            logger.warning("MinIO ACL not found", service_name=service_name)
        return exists

    def get_vault_path(self, service_name: str) -> str:
        return f"infras/minio/{service_name}"
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `pytest tests/unit/test_minio_service.py -v`
Expected: PASS — all four tests green.

- [ ] **Step 7: Commit**

```bash
git add minikube-local/k8s-local/infras-cli/app/config.py \
        minikube-local/k8s-local/infras-cli/requirements.txt \
        minikube-local/k8s-local/infras-cli/app/services/minio_service.py \
        minikube-local/k8s-local/infras-cli/tests/unit/test_minio_service.py
git commit -m "feat(infras-cli): MinIOService for bucket-per-app ACL provisioning"
```

---

## Task 9: infras-cli — Register MinIO in Factory, API & CLI

**Files:**
- Modify: `minikube-local/k8s-local/infras-cli/app/services/factory.py`
- Modify: `minikube-local/k8s-local/infras-cli/app/api/routes/acl.py`
- Modify: `minikube-local/k8s-local/infras-cli/app/cli/__main__.py`
- Create: `minikube-local/k8s-local/infras-cli/tests/unit/test_factory_minio.py`

**Interfaces:**
- Consumes: `MinIOService` (Task 8).
- Produces: `ServiceFactory.create_service("minio", ...)` returns a `MinIOService`; `"minio"` appears in `SUPPORTED_INFRA_TYPES` so `list_infras`/`list_apps` cover it.

- [ ] **Step 1: Write the failing factory test**

Create `tests/unit/test_factory_minio.py`:

```python
"""Factory must know about the minio infra type."""

from unittest.mock import MagicMock

from app.services.factory import ServiceFactory
from app.services.minio_service import MinIOService


def test_factory_creates_minio_service():
    svc = ServiceFactory.create_service("minio", MagicMock(), MagicMock())
    assert isinstance(svc, MinIOService)


def test_minio_in_supported_services():
    assert "minio" in ServiceFactory.get_supported_services()
```

- [ ] **Step 2: Run it to verify it fails**

Run: `pytest tests/unit/test_factory_minio.py -v`
Expected: FAIL — `ValueError: Unsupported infrastructure type: 'minio'`.

- [ ] **Step 3: Register in the factory**

In `app/services/factory.py`, add the import after the other service imports:

```python
from .minio_service import MinIOService
```

and add to the `SUPPORTED_SERVICES` dict (after the `"kafka"` entry):

```python
        "minio": MinIOService,
```

- [ ] **Step 4: Add `minio` to the API's supported types**

In `app/api/routes/acl.py`, change:

```python
SUPPORTED_INFRA_TYPES = ["postgres", "redis", "kafka", "mysql", "keycloak"]
```

to:

```python
SUPPORTED_INFRA_TYPES = ["postgres", "redis", "kafka", "mysql", "keycloak", "minio"]
```

- [ ] **Step 5: Mention minio in the CLI help**

In `app/cli/__main__.py`, update the `infra_type` argument help strings for both the `setup_acl` and (if present) verify commands, changing `(mysql, postgres, redis, kafka, keycloak)` to `(mysql, postgres, redis, kafka, keycloak, minio)`.

Run to find every occurrence:
```bash
grep -n "kafka, keycloak" app/cli/__main__.py
```
Replace each `mysql, postgres, redis, kafka, keycloak` with `mysql, postgres, redis, kafka, keycloak, minio`.

- [ ] **Step 6: Run the factory test to verify it passes**

Run: `pytest tests/unit/test_factory_minio.py tests/unit/test_minio_service.py -v`
Expected: PASS — all tests green.

- [ ] **Step 7: Commit**

```bash
git add minikube-local/k8s-local/infras-cli/app/services/factory.py \
        minikube-local/k8s-local/infras-cli/app/api/routes/acl.py \
        minikube-local/k8s-local/infras-cli/app/cli/__main__.py \
        minikube-local/k8s-local/infras-cli/tests/unit/test_factory_minio.py
git commit -m "feat(infras-cli): register minio infra type in factory, API and CLI"
```

---

## Task 10: Seed Vault, Rebuild Image & End-to-End Provision

**Files:**
- Create: `minikube-local/k8s-local/minio/scripts/store-admin-creds.sh`

**Interfaces:**
- Consumes: running MinIO Tenant (Task 4); `MinIOService` registered (Task 9); Secret `storage-configuration` (Task 3).
- Produces: Vault secret `infras/minio/root`; a redeployed infras-cli image; a verified end-to-end `setup-acl <app> minio`.

- [ ] **Step 1: Write the Vault-seed script**

Create `minikube-local/k8s-local/minio/scripts/store-admin-creds.sh`. It reads the root creds from the k8s Secret and writes them to `infras/minio/root` in Vault by exec-ing the Vault pod (no local vault CLI needed):

```bash
#!/bin/bash
# Seed MinIO root credentials into Vault at infras/minio/root for infras-cli.
set -euo pipefail

NS_MINIO="infras-minio"
NS_VAULT="infras-vault"
ROOT_TOKEN_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/.vault-init/root-token.txt"

env=$(kubectl get secret storage-configuration -n "$NS_MINIO" -o jsonpath='{.data.config\.env}' | base64 -d)
USER=$(echo "$env" | sed -n 's/^export MINIO_ROOT_USER="\(.*\)"$/\1/p')
PASS=$(echo "$env" | sed -n 's/^export MINIO_ROOT_PASSWORD="\(.*\)"$/\1/p')
TOKEN=$(cat "$ROOT_TOKEN_FILE")

echo "→ Writing infras/minio/root to Vault..."
kubectl exec -n "$NS_VAULT" statefulset/vault -- sh -c \
  "VAULT_TOKEN='$TOKEN' vault kv put secret/infras/minio/root username='$USER' password='$PASS'"

echo "✅ Seeded infras/minio/root"
```

> If your Vault KV mount path is not `secret/`, adjust the `vault kv put` path to match the mount used by the other `infras/*` secrets (check `kubectl exec -n infras-vault statefulset/vault -- vault secrets list`).

- [ ] **Step 2: Seed the credential and verify**

Run:
```bash
chmod +x minikube-local/k8s-local/minio/scripts/store-admin-creds.sh
./minikube-local/k8s-local/minio/scripts/store-admin-creds.sh
kubectl exec -n infras-vault statefulset/vault -- sh -c \
  "VAULT_TOKEN=$(cat minikube-local/k8s-local/.vault-init/root-token.txt) vault kv get secret/infras/minio/root"
```
Expected: `✅ Seeded infras/minio/root`, then a table showing `username` and `password`.

- [ ] **Step 3: Rebuild the infras-cli image into minikube and roll out**

Per the repo's deploy gotchas (`minikube image load` will NOT overwrite `:latest`):

```bash
cd minikube-local/k8s-local/infras-cli
eval $(minikube -p minikube docker-env)
docker build --network=host -t infras-cli:latest .
eval $(minikube -p minikube docker-env -u)
kubectl rollout restart deployment/infras-cli -n infras-cli
kubectl rollout status deployment/infras-cli -n infras-cli --timeout=120s
```
Expected: build succeeds; `deployment "infras-cli" successfully rolled out`.

- [ ] **Step 4: End-to-end provision via the CLI (in-cluster exec)**

Run (uses the in-cluster API path, which resolves `minio.infras-minio.svc.cluster.local`):
```bash
POD=$(kubectl get pod -n infras-cli -l app=infras-cli -o jsonpath='{.items[0].metadata.name}')
kubectl exec -n infras-cli "$POD" -- python3 -m app.cli setup-acl demoapp minio
kubectl exec -n infras-cli "$POD" -- python3 -m app.cli verify-acl demoapp minio 2>/dev/null || true
```
Expected: setup reports success with `bucket=demoapp`, `access_key=demoapp`, a `vault_path` of `infras/minio/demoapp`, and an issued token.

- [ ] **Step 5: Confirm the provisioned resources**

Run:
```bash
# Vault holds the app credential
kubectl exec -n infras-vault statefulset/vault -- sh -c \
  "VAULT_TOKEN=$(cat minikube-local/k8s-local/.vault-init/root-token.txt) vault kv get secret/infras/minio/demoapp"
# Bucket + user exist in MinIO
BIN=minikube-local/k8s-local/minio/scripts/bin/mc
$BIN ls infras/ | grep demoapp
$BIN admin user list infras | grep demoapp
```
Expected: Vault shows `minio.username=demoapp` / `minio.password=...`; `mc` lists the `demoapp` bucket and the `demoapp` user. This proves both API and CLI paths provision a real, isolated bucket-per-app ACL.

- [ ] **Step 6: Commit**

```bash
git add minikube-local/k8s-local/minio/scripts/store-admin-creds.sh
git commit -m "feat(minio): seed Vault admin creds + end-to-end infras-cli provisioning"
```

---

## Self-Review Notes

- **Spec coverage:** Operator install (T2), Tenant 1×4 EC:2 on standard PVCs (T4), HTTP + ingress `minio.local`/`s3.minio.local` (T5), k8s Secret creds with Vault noted phase-2 (T3/T7), `mc mirror` backups to `volumes/minio-backup/` (T6), single-node anti-affinity adaptation (T4/global constraints), resource-quota caveat (T1), provisioner-fragility documented as out-of-scope follow-up (T7/global constraints), **infras-cli integration: config+dep+MinIOService (T8), factory/API/CLI registration (T9), Vault seeding + image rebuild + end-to-end provision (T10)** covering spec §8. All spec §2–§10 items map to a task.
- **Type consistency (infras-cli):** `MinIOService.create_acl/verify_acl/get_vault_path` signatures match the `InfrastructureService` base and how `acl.py` calls them; `_clients` and `_policy_json` are patched/asserted identically in `test_minio_service.py`; factory key `"minio"` matches `SUPPORTED_INFRA_TYPES` and the `infras-minio` namespace probed by `list_infras`.
- **Endpoint assumption:** `MinIOService` defaults to in-cluster `minio.infras-minio.svc.cluster.local:80`. The end-to-end verify (T10 Step 4) runs *inside* the cluster (via `kubectl exec` into the infras-cli pod) so DNS resolves; local host runs would need `MINIO_ENDPOINT=s3.minio.local:8080`.
- **Service-name assumption:** the ingress/backup steps assume Operator service names `minio` and `infras-console` and ports `80`/`9090`. T4 Step 4 and T5 Step 1 explicitly print the actual values so the implementer corrects them if the pinned Operator build differs.
- **Verification adapted for infra:** each task's "test" is an apply-then-verify with concrete expected output; T6 includes a real create→verify→restore data-safety drill.
