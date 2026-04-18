# PostgreSQL - MiniKube Deployment

Simple PostgreSQL 17 deployment for MiniKube with secure authentication.

---

## 🚀 Quick Start

```bash
cd postgres
./scripts/deploy.sh
```

---

## 🔒 Security

**Password required for ALL connections** (scram-sha-256 encryption)

- ✅ Localhost connections require password
- ✅ Cross-namespace connections require password
- ✅ External connections require password
- ❌ Trust authentication disabled (no more "no password" access)

---

## ⚙️ Configuration

- **Image**: postgres:17-alpine
- **max_connections**: 200
- **max_prepared_transactions**: 100
- **Storage**: 5Gi PVC
- **Credentials**: Stored in Vault (`infras/postgres/auth`)
- **Authentication**: scram-sha-256 (required for ALL connections)

---

## 📁 Files

```
postgres/
├── scripts/
│   ├── deploy.sh              # Deploy script with Vault integration
│   └── connect-examples.sh    # Connection examples
├── deployment.yaml              # PostgreSQL deployment with exporter
├── pvc.yaml                     # Persistent volume claim (5Gi)
├── service.yaml                 # Services (PostgreSQL + metrics)
├── CONNECTION_GUIDE.md         # Complete connection guide
└── README.md                    # This file
```

---

## 🔐 Connection Details

```
Host: postgres.infras-postgres.svc.cluster.local
Port: 5432
Database: postgres
User: postgres
Password: (from Vault: infras/postgres/auth)
Authentication: scram-sha-256 (password required for ALL connections)
```

**Get password from Vault:**
```bash
kubectl exec -n infras-vault vault-0 -- vault kv get -field=password infras/postgres/auth
```

---

## 📡 How to Connect

**⚠️ IMPORTANT: Password is ALWAYS required for all connections!**

### From Kubernetes Pods (Cross-Namespace)

```bash
# Using psql in another pod (password required)
kubectl exec -n <namespace> <pod-name> -- sh -c \
  'PGPASSWORD=<from-vault> psql -h postgres.infras-postgres.svc.cluster.local -U postgres -d postgres'

# Example from vault namespace
kubectl exec -n infras-vault vault-0 -- sh -c \
  'PGPASSWORD=$(vault kv get -field=password infras/postgres/auth) \
   psql -h postgres.infras-postgres.svc.cluster.local -U postgres'
```

### From Local Machine (via Port-Forward)

```bash
# Step 1: Port-forward (in one terminal)
kubectl port-forward -n infras-postgres svc/postgres 5433:5432

# Step 2: Get password (in another terminal)
kubectl exec -n infras-vault vault-0 -- vault kv get -field=password infras/postgres/auth

# Step 3: Connect using password
PGPASSWORD=<from-step-2> psql -h localhost -p 5433 -U postgres -d postgres
```

### Application Connection String

```
postgresql://postgres:<password>@postgres.infras-postgres.svc.cluster.local:5432/postgres
```

Replace `<password>` with the password from Vault.

---

## 📊 Configuration Verification

```bash
# Check max_connections
kubectl exec -n infras-postgres deployment/postgres -- psql -U postgres -c "SHOW max_connections;"
# Expected: 200

# Check max_prepared_transactions
kubectl exec -n infras-postgres deployment/postgres -- psql -U postgres -c "SHOW max_prepared_transactions;"
# Expected: 100

# Check authentication
kubectl exec -n infras-postgres deployment/postgres -- cat /var/lib/postgresql/data/pg_hba.conf
# Expected: All lines show "scram-sha-256"
```

---

## 🔧 Management

### Test Password Authentication

```bash
# Test 1: Should FAIL - connection without password
kubectl exec -n infras-postgres deployment/postgres -- \
  psql -U postgres -h localhost -c "SELECT 1;" 2>&1 | grep "fe_sendauth"

# Test 2: Should SUCCEED - connection with correct password
PASSWORD=$(kubectl exec -n infras-vault vault-0 -- vault kv get -field=password infras/postgres/auth 2>/dev/null | tr -d '\n')
kubectl exec -n infras-postgres deployment/postgres -- sh -c "PGPASSWORD=$PASSWORD psql -U postgres -h localhost -c 'SELECT 1 AS success;'"
```

### View Logs

```bash
# PostgreSQL logs
kubectl logs -n infras-postgres -f -l app=postgres -c postgres

# Exporter logs
kubectl logs -n infras-postgres -f -l app=postgres -c exporter
```

### Restart PostgreSQL

```bash
kubectl rollout restart deployment/postgres -n infras-postgres
```

---

## 🗄️ Backup & Recovery

**🎉 NEW:** Automated backup script with compression, scheduling, and retention!

### Quick Start (Recommended)

```bash
# Create a compressed backup
./scripts/backup.sh create

# List all backups
./scripts/backup.sh list

# Setup automated daily backups
./scripts/backup.sh schedule

# See full guide
cat BACKUP_GUIDE.md
```

### Manual Backup (Simple)

```bash
kubectl exec -n infras-postgres deployment/postgres -- \
  pg_dump -U postgres postgres > postgres-backup.sql
```

### Manual Restore (Simple)

```bash
cat postgres-backup.sql | kubectl exec -i -n infras-postgres deployment/postgres -- \
  psql -U postgres -d postgres
```

### Reset (Delete All Data)

```bash
kubectl delete pvc postgres-data -n infras-postgres
./scripts/deploy.sh
```

### Advanced Backup Options

The new backup script supports:
- ✅ Compressed backups (~80% space savings)
- ✅ Automated daily backups via cron
- ✅ Backup verification and integrity checking
- ✅ Automatic cleanup (keeps last 7 days)
- ✅ Restore from any backup
- ✅ Detailed logging

**Full documentation:** [BACKUP_GUIDE.md](./BACKUP_GUIDE.md)

---

## 📝 Vault Integration

Credentials stored at: `infras/postgres/auth`

**Structure:**
```json
{
  "username": "postgres",
  "password": "<random-generated>"
}
```

**View Credentials:**
```bash
kubectl exec -n infras-vault vault-0 -- vault kv get infras/postgres/auth
```

**Rotate Password:**
```bash
# Generate new password and update Vault
kubectl exec -n infras-vault vault-0 -- \
  vault kv put infras/postgres/auth username="postgres" password="$(openssl rand -base64 20 | tr -dc 'A-Za-z0-9' | head -c 20)"

# Update Kubernetes secret
kubectl exec -n infras-vault vault-0 -- vault kv get -field=password infras/postgres/auth | \
  xargs kubectl create secret generic postgres-password --from-literal=password=0 -n infras-postgres --dry-run=client -o yaml | \
  kubectl apply -f -

# Restart PostgreSQL to apply new password
kubectl rollout restart deployment/postgres -n infras-postgres
```

---

## 🔒 Security Best Practices

1. ✅ **Password required for ALL connections** (scram-sha-256)
2. ✅ **Credentials stored in Vault** (not in deployment manifests)
3. ✅ **Random password generation** (20 chars, alphanumeric)
4. ✅ **No file footprint** (secrets as Kubernetes Secrets)
5. ⚠️ **Use SSL for external connections** (not configured by default)
6. ⚠️ **Regular password rotation** recommended

---

## 📈 Metrics

Access via port-forward:
```bash
kubectl port-forward -n infras-postgres svc/postgres-exporter 9187:9187
curl http://localhost:9187/metrics
```

---

## 🛠️ Troubleshooting

**Connection refused:**
```bash
kubectl get pods -n infras-postgres
kubectl describe pod -n infras-postgres -l app=postgres
```

**Authentication failed:**
```bash
# Check password
kubectl exec -n infras-vault vault-0 -- vault kv get infras/postgres/auth

# Check Kubernetes secret
kubectl get secret postgres-password -n infras-postgres -o yaml
```

**Wrong configuration:**
```bash
# Check pg_hba.conf
kubectl exec -n infras-postgres deployment/postgres -- \
  cat /var/lib/postgresql/data/pg_hba.conf | grep -E "^local|^host"

# Check config
kubectl exec -n infras-postgres deployment/postgres -- psql -U postgres -c "SHOW all;"
```

---

## 📚 Additional Resources

- [CONNECTION_GUIDE.md](CONNECTION_GUIDE.md) - Detailed connection examples
- [PostgreSQL 17 Docs](https://www.postgresql.org/docs/17/)
- [Vault Integration](../vault/README.md)
- `/home/hunghlh/app/infras/postgres-local` - Docker-compose reference

---

## ⚡ Quick Commands

```bash
# Deploy
./scripts/deploy.sh

# Connect (from within pod - uses env var for password)
kubectl exec -n infras-postgres deployment/postgres -- psql -U postgres

# Connect (from other namespaces - password required)
kubectl exec -n <namespace> <pod> -- sh -c \
  'PGPASSWORD=$(kubectl exec -n infras-vault vault-0 -- vault kv get -field=password infras/postgres/auth 2>/dev/null) \
   psql -h postgres.infras-postgres.svc.cluster.local -U postgres'

# Logs
kubectl logs -n infras-postgres -f -l app=postgres -c postgres

# Metrics
kubectl port-forward -n infras-postgres svc/postgres-exporter 9187:9187
curl http://localhost:9187/metrics

# Verify config
kubectl exec -n infras-postgres deployment/postgres -- sh -c \
  'PGPASSWORD=$POSTGRES_PASSWORD psql -U postgres -h localhost -c "SHOW max_connections;"'

# Verify security (pg_hba.conf)
kubectl exec -n infras-postgres deployment/postgres -- cat /var/lib/postgresql/data/pg_hba.conf
```
