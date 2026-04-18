# Getting Started

Quick start guides for local infrastructure setup.

## Prerequisites

### For MiniKube (Recommended)
- Minikube v1.30+ installed
- kubectl configured
- 8 CPUs, 16GB RAM available
- Docker daemon running

### For Docker Compose (Legacy)
- Docker & Docker Compose installed
- `jq` (JSON processor)

## Option 1: MiniKube (Recommended)

Production-like Kubernetes environment with monitoring and service mesh.

### Start Cluster

```bash
cd minikube-local
./up.sh                          # Start cluster (preserves data)
```

**What happens**:
- Starts Minikube with 8CPU/16GB RAM
- Creates 8 namespaces for isolation
- Deploys Ingress controller
- Starts Vault, PostgreSQL, Infras-CLI

### Verify Services

```bash
kubectl get pods -A | grep infras
minikube status
```

**Expected output**:
```
infras-vault/vault-0              1/1 Running
infras-postgres/postgres-*        2/2 Running
infras-cli/infras-cli-*           1/1 Running
```

### Access Services

See [SERVICE_ACCESS.md](SERVICE_ACCESS.md) for complete access guide.

**Quick access**:
```bash
# PostgreSQL port-forward
kubectl port-forward svc/postgres 5433:5432 -n infras-postgres

# Vault port-forward
kubectl port-forward svc/vault 8200:8200 -n infras-vault

# Infras-CLI API
kubectl port-forward svc/infras-cli 8080:80 -n infras-cli
```

### Stop Cluster

```bash
./down.sh                        # Stop (preserves state)
```

## Option 2: Docker Compose (Legacy)

Simple setup for single-service development.

### Start Vault (Required First)

```bash
./vault-local/up.sh              # Start Vault
./vault-local/init_vault.sh      # Initialize & generate secrets
```

**What happens**:
- Starts Vault container
- Initializes and unseals Vault
- Saves keys to `vault_keys.txt`
- Creates admin user credentials in `vault_chown.txt`
- Enables secret engines for services

### Start Other Services

```bash
./postgres-local/up.sh           # PostgreSQL
./mysql-local/up.sh              # MySQL
./kafka-local/up.sh              # Kafka (3-node cluster)
./redis-local/up.sh              # Redis (3-node cluster)
./keycloak-local/up.sh           # Keycloak with PostgreSQL
```

### Verify Services

```bash
docker ps | grep local
```

### Stop Services

```bash
./<service>-local/down.sh        # Stop individual service
```

## Which to Use?

### Choose MiniKube if you need:
- ✅ Production-like development environment
- ✅ Service monitoring and observability
- ✅ Team collaboration with namespace isolation
- ✅ Testing Kubernetes deployments
- ✅ Advanced networking (Ingress, service mesh)

### Choose Docker if you need:
- ✅ Quick single-service development
- ✅ Simple debugging with direct logs
- ✅ Minimal resource usage
- ✅ Familiar Docker Compose workflow

## Quick Reference Commands

### Cluster Management (MiniKube)
```bash
./minikube-local/up.sh                    # Start cluster
./minikube-local/down.sh                  # Stop cluster
minikube status                           # Cluster health
kubectl cluster-info                      # API server status
```

### Service Deployment (MiniKube)
```bash
infras-cli deploy postgres                # Deploy service
infras-cli status all                     # Check all services
cd k8s-local/postgres && ./scripts/deploy.sh  # Manual deploy
```

### Service Status (MiniKube)
```bash
kubectl get pods -A | grep infras         # All pods
kubectl get svc -A | grep infras         # All services
kubectl get ingress -A                    # Access URLs
```

### Service Access (MiniKube)
```bash
kubectl port-forward svc/postgres 5433:5432 -n infras-postgres
kubectl exec -it postgres-0 -n infras-postgres -- psql -U postgres
kubectl logs -f deployment/postgres -n infras-postgres
```

### Docker Compose Management
```bash
./vault-local/up.sh && ./vault-local/init_vault.sh
./postgres-local/up.sh
docker ps | grep local
docker logs -f postgres-local
```

## Common Workflows

### Setup Application Credentials

```bash
./bin/setup_acl.sh <app_name> <infra_type> [owner_username]
```

**Example**: `./bin/setup_acl.sh payment-service mysql`

Creates:
- Vault token with restricted access
- Infrastructure credentials in Vault
- Application-specific secrets path

### Access PostgreSQL Database

**MiniKube**:
```bash
kubectl port-forward svc/postgres 5433:5432 -n infras-postgres
psql -h localhost -p 5433 -U postgres
```

**Docker**:
```bash
psql -h localhost -p 5433 -U postgres
```

### View Service Logs

**MiniKube**:
```bash
kubectl logs -f deployment/postgres -n infras-postgres
kubectl logs -f statefulset/vault -n infras-vault
```

**Docker**:
```bash
docker logs -f postgres-local
docker logs -f vault-local
```

### Troubleshooting

**MiniKube not starting**:
```bash
minikube delete          # Clean slate
./up.sh                  # Fresh start
```

**Services not accessible**:
```bash
kubectl get pods -A      # Check pod status
kubectl describe pod <pod-name> -n <namespace>
```

**Vault initialization issues**:
```bash
./vault-local/down.sh    # Docker
rm -rf volumes/vault-data/*  # Clean data
./vault-local/up.sh && ./vault-local/init_vault.sh
```

## Next Steps

1. **Choose your environment**: MiniKube (recommended) or Docker
2. **Start services**: Follow option 1 or 2 above
3. **Access services**: See [SERVICE_ACCESS.md](SERVICE_ACCESS.md)
4. **Setup application**: Use `./bin/setup_acl.sh` for credentials
5. **Check status**: See [STATUS.md](STATUS.md) for current deployment

## Documentation

- **[STATUS.md](STATUS.md)** - Current deployment status
- **[SERVICE_ACCESS.md](SERVICE_ACCESS.md)** - Service URLs & credentials
- **[minikube-local/k8s-local/README.md](minikube-local/k8s-local/README.md)** - MiniKube full docs
- **[MIGRATION_PLAN.md](MIGRATION_PLAN.md)** - Docker → MiniKube migration
- **[TASKS.md](TASKS.md)** - Implementation task tracking
