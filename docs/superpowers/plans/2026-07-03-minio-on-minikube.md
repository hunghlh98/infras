# MinIO on Minikube Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy MinIO into the local minikube cluster via the MinIO Operator as a single-node erasure-coded Tenant, exposed through nginx ingress, with host backups for data safety.

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

## Self-Review Notes

- **Spec coverage:** Operator install (T2), Tenant 1×4 EC:2 on standard PVCs (T4), HTTP + ingress `minio.local`/`s3.minio.local` (T5), k8s Secret creds with Vault noted phase-2 (T3/T7), `mc mirror` backups to `volumes/minio-backup/` (T6), single-node anti-affinity adaptation (T4/global constraints), resource-quota caveat (T1), provisioner-fragility documented as out-of-scope follow-up (T7/global constraints). All spec §2–§8 items map to a task.
- **Service-name assumption:** the ingress/backup steps assume Operator service names `minio` and `infras-console` and ports `80`/`9090`. T4 Step 4 and T5 Step 1 explicitly print the actual values so the implementer corrects them if the pinned Operator build differs.
- **Verification adapted for infra:** each task's "test" is an apply-then-verify with concrete expected output; T6 includes a real create→verify→restore data-safety drill.
