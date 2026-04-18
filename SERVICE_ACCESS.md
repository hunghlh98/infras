# Service Access

Access methods and credentials for infrastructure services.

## MiniKube Services

| Service | Method | Access Command/URL | Credentials |
|---------|--------|-------------------|-------------|
| **Vault UI** | Ingress | http://vault.local:8080 | See vault/README.md |
| **PostgreSQL** | Port-forward | `kubectl port-forward svc/postgres 5433:5432 -n infras-postgres` | In Vault |
| **Infras-CLI API** | Ingress | http://infras-cli.local:8080 | Public API |
| **Grafana** | Ingress | http://grafana.local:8080 | `admin`/`admin` |
| **Prometheus** | Ingress | http://prometheus.local:8080 | None |
| **MySQL** | Port-forward | `kubectl port-forward svc/mysql 3306:3306 -n infras-mysql` | In Vault |
| **Redis** | Port-forward | `kubectl port-forward svc/redis 6379:6379 -n infras-redis` | In Vault |
| **Kafka** | Port-forward | `kubectl port-forward svc/kafka 9092:9092 -n infras-kafka` | SASL auth |
| **Keycloak** | Ingress | http://keycloak.local:8080 | Admin/`admin` |

### Services

#### Vault
**Purpose**: Secrets management and credential distribution

**Access Methods**:
- **Ingress** (recommended): `http://vault.local:8080`
- **Port-forward**: `kubectl port-forward svc/vault 8200:8200 -n infras-vault`
- **NodePort**: `http://localhost:30200` (via Minikube)

**Credentials**:
- Initial root token: See `minikube-local/k8s-local/vault/README.md`
- App tokens: Generated via `./bin/setup_acl.sh`
- Admin UI: See `vault_chown.txt` (Docker setup)

**Documentation**: [minikube-local/k8s-local/vault/README.md](minikube-local/k8s-local/vault/README.md)

#### PostgreSQL
**Purpose**: Relational database with metrics exporter

**Access Methods**:
- **Port-forward**: `kubectl port-forward svc/postgres 5433:5432 -n infras-postgres`
- **Internal**: `postgres://postgres:5432` (cluster DNS)

**Connection String**:
```bash
postgresql://postgres:<password-from-vault>@localhost:5433/postgres
```

**Shell Access**:
```bash
kubectl exec -it postgres-0 -n infras-postgres -- psql -U postgres
```

**Credentials**: Stored in Vault at `infras/postgres/*`

**Documentation**: [minikube-local/k8s-local/postgres/CONNECTION_GUIDE.md](minikube-local/k8s-local/postgres/CONNECTION_GUIDE.md)

#### Infras-CLI
**Purpose**: Infrastructure automation API and CLI tool

**Access Methods**:
- **Ingress** (recommended): `http://infras-cli.local:8080`
- **Port-forward**: `kubectl port-forward svc/infras-cli 8080:80 -n infras-cli`
- **Internal**: `http://infras-cli.infras-cli.svc.cluster.local:8000` (cluster DNS)

**API Endpoints**:
- `GET /` - API health check
- `GET /api/status` - Service status overview
- `POST /api/deploy` - Deploy services
- See [USAGE.md](minikube-local/k8s-local/infras-cli/USAGE.md) for complete API reference

**Documentation**: [minikube-local/k8s-local/infras-cli/USAGE.md](minikube-local/k8s-local/infras-cli/USAGE.md)

### NOT DeployED (Planned)

| Service | Status | Planned Access |
|---------|--------|----------------|
## Access Methods

### 1. Port-Forwarding (Recommended for Local)

Direct access to services from localhost.

**Pros**: Simple, works everywhere, no DNS setup
**Cons**: One service per port, manual setup

```bash
# PostgreSQL example
kubectl port-forward svc/postgres 5433:5432 -n infras-postgres

# Connect from local machine
psql -h localhost -p 5433 -U postgres
```

### 2. Ingress (Production-like)

Access services via domain names through Ingress controller.

**Pros**: Production-like, domain names, one port for all services
**Cons**: Requires SSH tunnel or Cloudflare Tunnel

**Setup**:
```bash
# Ingress is forwarded to port 8080
# Access via http://service.local:8080

# Requires SSH tunnel (see k8s-local/README.md)
ssh -L 8080:localhost:8080 user@server
```

**Current Ingress Rules**:
```
vault.local → Vault UI
infras-cli.local → Infras-CLI API
```

### 3. NodePort (Direct Minikube)

Access services via Minikube's exposed ports.

**Pros**: Direct access, no tunneling
**Cons**: Different ports per service, not production-like

```bash
# Vault example
minikube service vault-nodeport -n infras-vault --url
# Returns: http://192.168.49.2:30200
```

## Docker Compose Services (Legacy)

### Service Access

| Service | Port | Access URL | Credentials |
|---------|------|-----------|-------------|
| **PostgreSQL** | 5433 | `localhost:5433` | In Vault |
| **MySQL** | 3306 | `localhost:3306` | In Vault |
| **Redis** | 6379 | `localhost:6379` | In Vault |
| **Kafka** | 9092 | `localhost:9092` | SASL auth, see `kafka-local/` |
| **Vault** | 8200 | `http://localhost:8200` | See `vault_chown.txt` |
| **Keycloak** | 8080 | `http://localhost:8080` | Admin/`admin` |

**Check running services**:
```bash
docker ps | grep local
```

**Access example**:
```bash
# PostgreSQL
psql -h localhost -p 5433 -U postgres

# Redis CLI
redis-cli -h localhost -p 6379 -a <password>
```

## Connection Examples

### PostgreSQL

**MiniKube**:
```bash
# Port-forward
kubectl port-forward svc/postgres 5433:5432 -n infras-postgres

# Connect
psql -h localhost -p 5433 -U postgres -d postgres
```

**Docker**:
```bash
psql -h localhost -p 5433 -U postgres -d postgres
```

### Vault

**MiniKube** (Ingress):
```bash
# Access UI
curl http://vault.local:8080

# API access
export VAULT_ADDR="http://vault.local:8080"
vault status
```

**MiniKube** (Port-forward):
```bash
kubectl port-forward svc/vault 8200:8200 -n infras-vault
export VAULT_ADDR="http://localhost:8200"
vault status
```

**Docker**:
```bash
export VAULT_ADDR="http://localhost:8200"
vault login $(cat vault_chown.txt)
```

### Infras-CLI

**MiniKube** (Ingress):
```bash
# Health check
curl http://infras-cli.local:8080/

# Get service status
curl http://infras-cli.local:8080/api/status
```

**MiniKube** (Port-forward):
```bash
kubectl port-forward svc/infras-cli 8080:80 -n infras-cli
curl http://localhost:8080/api/status
```

## Credential Management

### Vault Integration

All credentials stored in Vault:
- **Infrastructure creds**: `infras/<service>/<app-name>`
- **Application secrets**: `apps/<app-name>`

### Generate App Credentials

```bash
./bin/setup_acl.sh <app_name> <infra_type>
```

**Example**: `./bin/setup_acl.sh payment-service mysql`

**Output**:
```
SERVICE: payment-service
INFRA:   mysql
SECRET:  infras/mysql/payment-service
TOKEN:   hvs.EXAMPLETOKEN...
```

### Access Vault Secrets

**From within cluster**:
```bash
kubectl exec -it vault-0 -n infras-vault -- sh
vault kv get infras/postgres/postgres
```

**From local machine** (after port-forward):
```bash
kubectl port-forward svc/vault 8200:8200 -n infras-vault
export VAULT_ADDR="http://localhost:8200"
vault login <token>
vault kv get infras/postgres/postgres
```

## Troubleshooting

### Port-Forward Not Working

```bash
# Check pod is running
kubectl get pods -n <namespace>

# Check service exists
kubectl get svc -n <namespace>

# Describe service for endpoints
kubectl describe svc <service-name> -n <namespace>
```

### Ingress Not Accessible

```bash
# Check ingress controller
kubectl get pods -n ingress-nginx

# Check ingress rules
kubectl get ingress -A

# Verify DNS resolution
curl -v http://vault.local:8080
```

### Service Connection Refused

```bash
# Check service endpoints
kubectl get endpoints <service-name> -n <namespace>

# Check pod logs
kubectl logs -f <pod-name> -n <namespace>

# Verify service is ready
kubectl get pods -n <namespace> -w
```

## Quick Access Commands

```bash
# Start port-forward in background
kubectl port-forward svc/postgres 5433:5432 -n infras-postgres &

# Access PostgreSQL
psql -h localhost -p 5433 -U postgres

# Vault port-forward
kubectl port-forward svc/vault 8200:8200 -n infras-vault &
export VAULT_ADDR="http://localhost:8200"

# Infras-CLI port-forward
kubectl port-forward svc/infras-cli 8080:80 -n infras-cli &
curl http://localhost:8080/api/status

# View all services
kubectl get svc -A | grep infras
kubectl get ingress -A
```

## Documentation Links

- **[STATUS.md](STATUS.md)** - Current deployment status
- **[GETTING_STARTED.md](GETTING_STARTED.md)** - Setup guides
- **[minikube-local/k8s-local/README.md](minikube-local/k8s-local/README.md)** - MiniKube full documentation
- **[minikube-local/k8s-local/postgres/CONNECTION_GUIDE.md](minikube-local/k8s-local/postgres/CONNECTION_GUIDE.md)** - PostgreSQL detailed connection guide
- **[minikube-local/k8s-local/vault/README.md](minikube-local/k8s-local/vault/README.md)** - Vault configuration and usage
