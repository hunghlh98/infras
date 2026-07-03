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

## Backups (data safety)
One-time: ensure the backup dir is writable by your user (the repo `volumes/`
is often root-owned):
```bash
sudo mkdir -p ../../../volumes/minio-backup && sudo chown "$USER" ../../../volumes/minio-backup
```
Then:
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
