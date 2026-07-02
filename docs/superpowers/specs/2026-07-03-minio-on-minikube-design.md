# MinIO on Minikube — Design Spec

**Date:** 2026-07-03
**Status:** Draft for review
**Goal:** Deploy MinIO (S3-compatible object storage) into the local minikube cluster in a way that (a) keeps data safe, (b) rehearses a realistic production Kubernetes deployment, and (c) is provisionable through `infras-cli` (both CLI and API) as a first-class infra type alongside postgres/kafka.

---

## 1. Context & Decision

The user is standing up MinIO and asked whether to run it on Docker or Kubernetes, prioritizing **data safety** and **production-parity scaling**.

Key findings from investigation:

- Minikube uses `--driver=docker`, so the cluster runs inside a Docker container. Getting PVC data onto the host requires a 3-hop chain (`pod → hostPath PV → 9p mount → host`).
- The host↔container hop is **9p**, which minikube's docker driver falls back to (no native bind mount).
- **MinIO does not support network/remote filesystems (NFS/9p-style) for its backend** — it requires a native local filesystem. This rules out host-mounting MinIO's data directory over 9p.
- Current PVCs live at the fragile `/tmp/hostpath-provisioner` path inside the container (not the persisted `/var`), so a container recreate or `minikube delete` would wipe them.

**Decision:** Deploy MinIO **on Kubernetes via the MinIO Operator** (production-authentic). MinIO data stays on **native `standard` PVCs** (respecting its filesystem requirement). "Data always safe" is achieved the production way — via **logical backups** (`mc mirror`) to the host — not via a live host mount.

**Rejected alternatives:**
- *Docker + host bind mount* — simplest and safest for data, but does not rehearse production k8s (the user's stated goal).
- *Hand-written distributed StatefulSet* — transparent and repo-consistent, but the Operator is the real production model.
- *Standalone single-instance* — too far from production (no erasure coding).

---

## 2. Architecture

```
minio-operator (ns)            infras-minio (ns)
┌────────────────┐             ┌───────────────────────────────────────┐
│ MinIO Operator │──manages──► │ Tenant: infras                          │
│  (controller)  │             │  Pool 0: 1 server × 4 drives (EC:2)     │
└────────────────┘             │   ├─ pod infras-pool-0-0                │
                               │   │   ├─ PVC data0 (2Gi, standard)      │
                               │   │   ├─ PVC data1 (2Gi, standard)      │
                               │   │   ├─ PVC data2 (2Gi, standard)      │
                               │   │   └─ PVC data3 (2Gi, standard)      │
                               │   ├─ Service: minio (S3 API :80)        │
                               │   └─ Service: infras-console (:9090)    │
                               └───────────────────────────────────────┘
     Ingress (nginx):  s3.minio.local  → minio:80
                       minio.local     → infras-console:9090
     In-cluster DNS:   minio.infras-minio.svc.cluster.local
     Backups:          mc mirror  →  volumes/minio-backup/  (host)
```

### Single-node adaptation (important)

The MinIO Operator defaults to **hard pod anti-affinity** (one server per node), which fails to schedule on single-node minikube. This design uses **one pool with 4 `volumesPerServer`** (1 pod, 4 drives, erasure coding EC:2) instead of 4 separate server pods. This preserves erasure-coding/data-protection behavior on a single node.

**Scaling to real production:** replace the single pool with N servers × M drives across multiple nodes and remove/relax the single-node affinity override. Documented in the tenant README.

---

## 3. Components

All manifests live under `minikube-local/k8s-local/minio/`, consistent with existing service layout.

| File | Purpose |
|------|---------|
| `namespaces` (edit `namespaces/00-namespaces.yaml`) | Add `infras-minio` namespace |
| `namespaces/resource-quotas.yaml` (edit) | Add a **generous** quota for `infras-minio` (see §6) |
| `minio/operator/` | MinIO Operator install (via official manifest/kustomize, pinned version) |
| `minio/tenant.yaml` | `Tenant` CR: 1 pool × 4 drives, EC:2, `requestAutoCert: false` |
| `minio/tenant-config-secret.yaml` | Secret with `config.env` (`MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`) |
| `minio/ingress.yaml` | Two ingresses: `s3.minio.local` → API, `minio.local` → console |
| `minio/scripts/backup.sh` | `mc mirror` backup/restore/list/verify/cleanup/schedule (modeled on postgres/scripts/backup.sh) |
| `minio/scripts/setup-dns.sh` | Append `minio.local` + `s3.minio.local` to `/etc/hosts` |
| `minio/README.md` | Deploy steps, access, backup usage, scale-to-prod notes |

### Credentials
- **Phase 1 (this spec):** root credentials in a k8s Secret consumed by the Tenant's `config.env`. This is the standard way the Operator's Tenant consumes credentials.
- **Phase 2 (follow-up, not in this spec):** source credentials from Vault (via Vault Agent injector or External Secrets Operator) to match the repo's Vault pattern. Explicitly out of scope here to keep the first pass working.

### TLS
- `requestAutoCert: false` → MinIO serves HTTP, terminated/proxied by nginx ingress (matches vault/grafana pattern of `ssl-redirect: "false"`). Production would enable TLS; noted in README.

---

## 4. Access

| Interface | URL / endpoint | Backing service |
|-----------|----------------|-----------------|
| S3 API (host) | `http://s3.minio.local:8080` | `minio:80` |
| Console (host) | `http://minio.local:8080` | `infras-console:9090` |
| S3 API (in-cluster) | `minio.infras-minio.svc.cluster.local` | — |

Ingress uses `ingressClassName: nginx`, `ssl-redirect: "false"`, and a large `proxy-body-size` (e.g. `1000m`) so large object uploads pass through. The `:8080` suffix matches the existing `minikube-ingress-forwarder` in `up.sh`.

`mc` alias for local use: `mc alias set local http://s3.minio.local:8080 <root-user> <root-pass>`.

---

## 5. Data Safety

### Primary: native PVCs + logical backup
- MinIO data on `standard` PVCs (native container fs — MinIO-supported, no 9p).
- Erasure coding EC:2 across 4 drives → tolerates loss of up to 2 of the 4 drives *within the cluster* (rehearses production data protection; not real HA on one physical disk).
- **`minio/scripts/backup.sh`** mirrors all buckets to `volumes/minio-backup/<timestamp>/` on the host via `mc mirror`, following the conventions of `postgres/scripts/backup.sh`:
  - subcommands: `create`, `list`, `restore <snapshot>`, `verify <snapshot>`, `cleanup`, `schedule [hour]`
  - retention via `RETENTION_DAYS` (default 7)
  - runs `mc` from a throwaway pod or local `mc` binary against `s3.minio.local`
- This is the supported "data on my laptop" path for MinIO, and satisfies "data always safe" across cluster deletion.

### Secondary hardening: fix the fragile provisioner path
- Document (and optionally apply) moving the minikube hostpath provisioner off `/tmp/hostpath-provisioner` onto a `/var`-persisted path so a container recreate does not wipe PVCs. This benefits **all** services (postgres/vault/kafka too), so it is documented as a repo-wide note, not MinIO-specific.
- **Decision needed at review:** include the provisioner fix in this work, or split into a separate task? (Recommendation: document here, apply as a separate small PR since it touches all services.)

---

## 6. Resource Sizing

Single MinIO pod with 4 drives.

| Resource | Value |
|----------|-------|
| Pod requests | cpu `250m`, memory `512Mi` |
| Pod limits | cpu `1`, memory `2Gi` |
| PVCs | 4 × 2Gi = 8Gi total |

**Resource quota caveat:** tight ResourceQuotas can block Operator-managed pods (the Operator injects sidecars/init containers). The `infras-minio` quota must be **generous** (e.g. `requests.cpu: "1"`, `requests.memory: "1Gi"`, `limits.cpu: "2"`, `limits.memory: "3Gi"`, `persistentvolumeclaims: "6"`) or omitted initially. The Operator's own namespace (`minio-operator`) gets no quota.

---

## 7. Testing / Verification

1. `kubectl get tenant -n infras-minio` → Tenant reaches `Initialized`.
2. Pod `infras-pool-0-0` Running with 4 mounted PVCs.
3. From an `mc` client: create a bucket, `cp` an object, `ls` it back.
4. Console reachable at `http://minio.local:8080`, login with root creds.
5. In-cluster reachability: a throwaway pod resolves and PUTs to `minio.infras-minio.svc.cluster.local`.
6. `backup.sh create` produces a snapshot under `volumes/minio-backup/`; `backup.sh verify` passes; delete a bucket and `restore` brings it back.
7. Data-safety drill: `minikube stop && minikube start` (data survives on PVC); documented `restore` recovers from host backup after a simulated PVC loss.

---

## 8. infras-cli Integration (ACL provisioning)

MinIO becomes a first-class infra type in `infras-cli` (in `minikube-local/k8s-local/infras-cli/`). Both the CLI and the API share `ServiceFactory` + the `InfrastructureService` abstraction, so a single new service class lights up both entrypoints.

### Provisioning model — bucket-per-app
`setup-acl <app> minio` grants each app **its own bucket** named after the service, with full read/write on just that bucket (clean isolation, mirroring postgres' "a database per app"). The generated user's access key = the service name; the secret = a generated password stored in Vault.

### Components
| Change | File |
|--------|------|
| New service class `MinIOService` | `app/services/minio_service.py` (create) |
| Register `"minio": MinIOService` | `app/services/factory.py` (modify) |
| Add `"minio"` to `SUPPORTED_INFRA_TYPES` + CLI help | `app/api/routes/acl.py`, `app/cli/__main__.py` (modify) |
| Endpoint settings `minio_endpoint`, `minio_secure` | `app/config.py` (modify) |
| Dependency `minio==7.2.x` | `requirements.txt` (modify) |
| Unit tests | `tests/unit/test_minio_service.py`, `tests/unit/test_factory_minio.py` (create) |

### How it works
- **Admin creds:** fetched from Vault at `infras/minio/root` (keys `username`/`password`), seeded at deploy time from the `storage-configuration` secret. `"root"` is already a `RESERVED_INFRA_KEYS` entry, so it is correctly excluded from app listings.
- **Client:** the `minio` Python SDK's `MinioAdmin` (admin API over HTTP) + `Minio` (bucket ops) — consistent with how Keycloak uses `requests` (no `kubectl exec`; MinIO has a real admin API). Verified methods: `add_user(access_key, secret_key)`, `add_canned_policy(policy_name, policy)`, `set_user_or_group_policy(policy_name, user_or_group)`, `list_users()`, `Minio.make_bucket/bucket_exists`.
- **Endpoint:** `settings.minio_endpoint` defaults to in-cluster `minio.infras-minio.svc.cluster.local:80` (`minio_secure=false`). Local CLI use overrides via `MINIO_ENDPOINT=s3.minio.local:8080`.
- **`create_acl`:** ensure bucket → `add_canned_policy(app-<name>, <scoped JSON>)` → `add_user(<name>, <password>)` → `set_user_or_group_policy` → inherited `_store_credential` writes `minio.username`/`minio.password` to `infras/minio/<name>` and the app secret. Idempotent (bucket/user/policy upserts).
- **`verify_acl`:** `service_name in admin.list_users()`. Infra errors (endpoint/Vault unreachable) propagate → API returns 502 "could not verify", never a misleading "not found" (matches the codebase's corrected behavior).
- **Deploy:** adding the dependency requires rebuilding the infras-cli image into minikube's docker-env and `kubectl rollout restart` (per the repo's known deploy gotchas — `minikube image load` will not overwrite `:latest`).

## 9. Out of Scope (this spec)

- Vault as the *source of truth* for the Tenant's own root secret (phase 2). Note: infras-cli *reading* a copy of the root creds from `infras/minio/root` **is** in scope (§8) — this exclusion is only about the Tenant's `storage-configuration` secret still being a plain k8s Secret rather than injected from Vault.
- Real TLS/auto-cert.
- Multi-node distributed topology (documented as scale path only).
- The global hostpath-provisioner fix as an *applied* change (documented; separate task recommended).

---

## 10. Open Questions for Review

1. **Provisioner fix:** apply now or separate task? (Recommendation: separate.)
2. **PVC size:** 2Gi × 4 enough for your rehearsal, or larger?
3. **Ingress hostnames:** `minio.local` + `s3.minio.local` acceptable?
4. **Backup driver:** run `mc` from a local binary on the host, or from an in-cluster job pod? (Recommendation: local `mc` binary against the ingress, matching how `postgres/scripts/backup.sh` uses local tooling.)
