# Infrastructure Repository

Local development infrastructure with **2 deployment models**:
- **MiniKube** (recommended): Kubernetes-based, production-like
- **Docker Compose** (legacy): Simple, single-service development

## Quick Start

### MiniKube (Recommended)
```bash
cd minikube-local && ./up.sh          # Start cluster
kubectl get pods -A | grep infras     # Verify services
```

### Docker Compose (Legacy)
```bash
./vault-local/up.sh && ./vault-local/init_vault.sh
./postgres-local/up.sh                # Start other services
```

## Deployment Models

| Model | Status | Use Case | Services |
|-------|--------|----------|----------|
| **MiniKube** | Active (32%) | Production-like, team workflows | 3 of 8 deployed |
| **Docker** | Stable | Simple local dev | 6 services |

## Current Status

### MiniKube Deployment
| Service | Status | Pods | Access |
|---------|--------|------|--------|
| Vault | ✅ Running | 1/1 | `kubectl port-forward svc/vault 8200:8200 -n infras-vault` |
| PostgreSQL | ✅ Running | 2/2 | `kubectl port-forward svc/postgres 5433:5432 -n infras-postgres` |
| Infras-CLI | ✅ Running | 1/1 | `kubectl port-forward svc/infras-cli 8080:80 -n infras-cli` |
| Monitoring | ❌ Not deployed | - | Planned |
| MySQL | 🚧 Planned | - | - |
| Redis | 🚧 Planned | - | - |
| Kafka | 🚧 Planned | - | - |
| Keycloak | 🚧 Planned | - | - |

### Docker Compose Services
All 6 services stable: `vault-local`, `postgres-local`, `mysql-local`, `kafka-local`, `redis-local`, `keycloak-local`

## Documentation

| Document | Purpose |
|----------|---------|
| **[STATUS.md](STATUS.md)** | Current deployment status |
| **[GETTING_STARTED.md](GETTING_STARTED.md)** | Detailed setup guides |
| **[SERVICE_ACCESS.md](SERVICE_ACCESS.md)** | Service URLs & credentials |
| **[minikube-local/k8s-local/README.md](minikube-local/k8s-local/README.md)** | MiniKube full docs |
| **[MIGRATION_PLAN.md](MIGRATION_PLAN.md)** | Docker → MiniKube migration |
| **[TASKS.md](TASKS.md)** | Implementation tasks (34/105 done) |

## Quick Reference

### Cluster Management (Kubernetes)
```bash
./minikube-local/up.sh                  # Start cluster
./minikube-local/down.sh                # Stop (preserves state)
minikube status                         # Check cluster health
```

### Service Deployment (Infras)
```bash
infras-cli deploy postgres              # Deploy service
infras-cli status all                   # Check all services
cd k8s-local/postgres && ./scripts/deploy.sh  # Manual deploy
```

### Service Status (Kubernetes)
```bash
kubectl get pods -A | grep infras       # All infras pods
kubectl get svc -A | grep infras       # All infras services
kubectl get ingress -A                  # Access URLs
```

### Service Access (Kubernetes)
```bash
# Port-forward to local
kubectl port-forward svc/postgres 5433:5432 -n infras-postgres

# Shell into pod
kubectl exec -it postgres-0 -n infras-postgres -- psql -U postgres

# View logs
kubectl logs -f deployment/postgres -n infras-postgres
```

### Legacy Docker Compose
```bash
./vault-local/up.sh && ./vault-local/init_vault.sh
./postgres-local/up.sh
docker ps | grep local                 # Check status
```

## Architecture

MiniKube deployment uses **8 namespaces** with resource quotas (8CPU/16GB RAM):
- `infras-vault`: HashiCorp Vault for secrets
- `infras-postgres`: PostgreSQL with metrics exporter
- `infras-cli`: Infrastructure automation CLI
- `infras-monitoring`: Prometheus, Grafana, Loki (planned)
- `infras-mysql`, `infras-redis`, `infras-kafka`, `infras-keycloak`: Planned

See [minikube-local/k8s-local/README.md](minikube-local/k8s-local/README.md) for details.

## User & ACL Management

Provision users and credentials for applications:

```bash
./bin/setup_acl.sh <app_name> <infra_type> [owner_username]
```

**Example**: `./bin/setup_acl.sh payment-service mysql`

Creates:
- Vault token with restricted access
- Credentials in `infras/<infra_type>/<app_name>`
- App secrets path at `apps/<app_name>`

**Supported**: `mysql`, `postgres`, `redis`, `kafka`, `keycloak`

## Project Status

- **MiniKube Migration**: 32% complete (34 of 105 tasks)
- **Active Development**: Monitoring stack, MySQL, Redis, Kafka, Keycloak
- **Production**: Vault, PostgreSQL, Infras-CLI stable

See [TASKS.md](TASKS.md) for detailed task tracking.

## Directory Structure

```
├── minikube-local/          # Kubernetes deployment (primary)
│   ├── up.sh               # Start cluster
│   ├── down.sh             # Stop cluster
│   └── k8s-local/          # Service manifests & docs
├── bin/                    # ACL setup scripts
├── *-local/                # Docker Compose services (legacy)
├── volumes/                # Persistent data
└── *.md                    # Documentation
```

## Which to Use?

**Choose MiniKube if you need**:
- Production-like environment
- Service mesh & monitoring
- Team collaboration
- Kubernetes deployment testing

**Choose Docker if you need**:
- Simple single-service development
- Quick prototyping
- Minimal resource usage
- Familiar Docker Compose workflow
