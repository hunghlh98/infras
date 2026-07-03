# MinIO (Object Storage) — k8s-local

S3-compatible object storage deployed via the **MinIO Operator** as a
single-node, erasure-coded Tenant. Chosen to rehearse a production
Kubernetes deployment; data safety is provided by host backups.

> **Heads-up:** the community `minio/operator` was archived 2026-03-20.
> This uses the final release **v7.1.1** (pinned). Fine for local rehearsal;
> not receiving updates.

## Topology
- Namespace: `infras-minio` (both the Operator and the Tenant live here)
- Operator pinned to **1 replica** (single-node: its default 2 replicas require
  anti-affinity across 2 nodes). See `operator/kustomization.yaml`.
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

## Data safety — real-time host mirror
Instead of dated snapshots (which duplicate all objects and grow unbounded),
a **continuous mirror** keeps a single host copy in sync with MinIO using
`mc mirror --watch --overwrite --remove`. The mirror lives in this module at
`minio/volumes/` (user-owned; created automatically) and stays flat in size.

```bash
./scripts/sync.sh start     # start the real-time mirror daemon (background)
./scripts/sync.sh status    # is it running?
./scripts/sync.sh stop      # stop it
./scripts/sync.sh sync      # one-shot mirror now, then exit
./scripts/sync.sh watch     # run in foreground (for a systemd user unit)
./scripts/sync.sh restore   # push the host mirror BACK into MinIO (recovery)
```

- Needs `s3.minio.local` reachable — run `./scripts/setup-dns.sh` first, or set
  `S3_ENDPOINT` (e.g. a `kubectl port-forward` URL).
- The daemon uses `nohup`; it does **not** survive reboot. Re-run `start` after
  boot, or wrap `watch` in a systemd user unit for persistence.
- **Trade-off:** `--remove` makes the mirror a live replica, not a point-in-time
  archive — an accidental delete in MinIO is also removed from the mirror. This
  is the deliberate size-vs-snapshot choice for local dev.

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
