# MiniKube Local Infrastructure

Complete Kubernetes infrastructure running on MiniKube for local development and testing.

## 🚀 Quick Start

### Prerequisites

- MiniKube running with Docker driver
- kubectl configured
- Docker daemon running

### Check Status

```bash
# Check MiniKube status
minikube status

# Check all namespaces
kubectl get namespaces

# Check all pods
kubectl get pods --all-namespaces
```

---

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    MiniKube Cluster                          │
│  ┌──────────────────────────────────────────────────────┐   │
│  │           Namespaces                                 │   │
│  │  • infras-monitoring  (Prometheus, Grafana)         │   │
│  │  • infras-vault      (HashiCorp Vault)              │   │
│  │  • infras-postgres   (PostgreSQL Database)          │   │
│  │  • infras-cli        (Infras CLI App)               │   │
│  │  • infras-mysql      (MySQL Database)               │   │
│  │  • infras-redis      (Redis Cluster)                │   │
│  │  • infras-kafka      (Kafka Cluster)                │   │
│  │  • infras-keycloak   (Keycloak Identity)            │   │
│  └──────────────────────────────────────────────────────┘   │
│                            │                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │           NGINX Ingress Controller                    │   │
│  │  Routes: grafana.local, prometheus.local, etc.       │   │
│  │  NodePort: 30559 (HTTP) → Port 80                    │   │
│  └──────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              Docker Port Forwarder                           │
│  Container: minikube-ingress-forwarder                      │
│  Host:8080 → MiniKube:30559                                 │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              Cloudflare Tunnel / SSH Tunnel                  │
│  Access: https://grafana.yourdomain.com                     │
└─────────────────────────────────────────────────────────────┘
```

---

## 📊 Access Services

### Option 1: Cloudflare Tunnel (Recommended - Public Access)

**Best for:** Access from anywhere without SSH tunneling

#### Setup Cloudflare Tunnel

1. **Go to Cloudflare Dashboard**
   - Zero Trust → Access → Tunnels → Your Tunnel → Public Hostname

2. **Add services** with these settings:

| Subdomain | Service | Host Header |
|-----------|---------|-------------|
| `grafana` | `http://localhost:8080` | `grafana.local` |
| `prometheus` | `http://localhost:8080` | `prometheus.local` |

3. **Access URLs:**
   - https://grafana.yourdomain.com
   - https://prometheus.yourdomain.com

**Default Credentials:**
- Grafana: `admin` / `admin` (change on first login)
- Prometheus: (no authentication)

---

### Option 2: SSH Tunnel (Local Access)

**Best for:** Development and local access

#### On SERVER

Start the port forwarder:
```bash
/home/hunghlh/app/infras/minikube-local/bin/start-ingress-forwarder.sh
```

#### On LOCAL Machine

Setup SSH tunnel:
```bash
# Add to /etc/hosts
sudo bash -c 'echo "127.0.0.1 grafana.local prometheus.local" >> /etc/hosts'

# Create SSH tunnel
ssh -L 8080:localhost:8080 user@server-ip -N
```

#### Access URLs

- http://grafana.local:8080
- http://prometheus.local:8080

---

### Option 3: Direct Port Forward

**Best for:** Quick development access

```bash
# Grafana
kubectl port-forward -n infras-monitoring deployment/grafana 3000:3000
# Open: http://localhost:3000

# Prometheus
kubectl port-forward -n infras-monitoring statefulset/prometheus 9090:9090
# Open: http://localhost:9090
```

---

## 🔧 Port Forwarder Management

The **Docker port forwarder** forwards host port 8080 to the Ingress Controller inside MiniKube (NodePort 30559).

### Start/Stop

```bash
# Start
/home/hunghlh/app/infras/minikube-local/bin/start-ingress-forwarder.sh

# Stop
/home/hunghlh/app/infras/minikube-local/bin/stop-ingress-forwarder.sh
```

### Status & Logs

```bash
# Check if running
docker ps | grep minikube-ingress-forwarder

# View logs
docker logs minikube-ingress-forwarder

# Test connection
curl -H "Host: grafana.local" http://localhost:8080
```

### Auto-start

The container is configured with `--restart unless-stopped`, so it automatically starts when Docker daemon starts.

---

## 📁 Directory Structure

```
k8s-local/
├── README.md                          # This file
├── namespaces/                        # Namespace definitions
│   └── 00-namespaces.yaml             # All 8 namespaces
├── ingress/                           # Ingress configuration
│   ├── nginx-ingress-controller.yaml  # NGINX Ingress Controller
│   └── monitoring-ingress.yaml        # Ingress routes for monitoring
├── monitoring/                        # Monitoring stack
│   ├── prometheus/                    # Prometheus StatefulSet
│   ├── grafana/                       # Grafana Deployment
│   │   └── dashboards/                # Dashboard JSON files
│   ├── node-exporter.yaml             # Node metrics exporter
│   ├── kube-state-metrics.yaml        # K8s resource metrics
│   ├── docker-stats-exporter.yaml     # Docker container stats
│   ├── loki/                          # Log aggregation
│   ├── promtail/                      # Log collector
│   ├── exporters/                     # Service exporters
│   │   ├── mysql-exporter.yaml        # MySQL metrics
│   │   ├── postgres-exporter.yaml     # PostgreSQL metrics
│   │   ├── redis-exporter.yaml        # Redis metrics
│   │   └── kafka-jmx-exporter.yaml    # Kafka metrics
│   ├── host-stats/                    # Host metrics collection
│   │   ├── setup-host-metrics.sh      # One-click setup
│   │   ├── expose-metrics.sh          # Manual expose script
│   │   └── README.md                  # Host metrics documentation
│   └── README.md                      # Detailed monitoring docs
└── bin/                               # Management scripts
    ├── start-ingress-forwarder.sh     # Start port forwarder
    └── stop-ingress-forwarder.sh      # Stop port forwarder
```

---

## 🎯 Deployed Services

### Monitoring (infras-monitoring)

| Service | Type | Purpose | Access |
|---------|------|---------|--------|
| Prometheus | StatefulSet | Metrics collection | http://prometheus.local:8080 |
| Grafana | Deployment | Visualization | http://grafana.local:8080 |
| Node Exporter | DaemonSet | Node metrics | :9100/metrics |
| kube-state-metrics | Deployment | K8s metrics | :8080/metrics |
| Loki | StatefulSet | Log aggregation | :3100/loki/api/v1/push |
| Promtail | DaemonSet | Log collector | :9080 |

### Key Dashboards

**MiniKube Cluster Overview**
- URL: http://grafana.local:8080/d/minikube-cluster/minikube-cluster-overview
- Panels:
  1. Cluster Overview (pods, namespaces, nodes)
  2. Node/Infrastructure Metrics (CPU, memory, disk, network)
  3. Host Resources (Docker stats from host machine)

---

## 🖥️ Host Resources Monitoring

The monitoring stack includes **host machine metrics** collected from the MiniKube Docker container.

### What's Monitored

| Metric | Description |
|--------|-------------|
| `docker_cpu_percent` | CPU usage of minikube container |
| `docker_memory_bytes` | Memory usage in bytes |
| `docker_memory_limit_bytes` | Total memory limit |
| `docker_memory_percent` | Memory usage percentage |
| `docker_net_rx_bytes` | Network received bytes |
| `docker_net_tx_bytes` | Network transmitted bytes |
| `docker_block_read_bytes` | Block read bytes |
| `docker_block_write_bytes` | Block write bytes |

### Setup Host Metrics (One-time)

```bash
/home/hunghlh/app/infras/minikube-local/k8s-local/monitoring/host-stats/setup-host-metrics.sh
```

This starts:
- Docker stats collector (runs every 15 seconds)
- Auto-expose to minikube (runs every 20 seconds)

### Verify

```bash
# Check current metrics
cat /tmp/node_exporter_textfile/docker_stats.prom

# View collector logs
tail -f /tmp/node_exporter_textfile/docker-stats.log

# Check processes
ps aux | grep docker-stats
```

For detailed documentation, see [monitoring/host-stats/README.md](monitoring/host-stats/README.md)

---

## 🛠️ Troubleshooting

### Port Forwarder Issues

**Container not running:**
```bash
# Check status
docker ps -a | grep minikube-ingress-forwarder

# Restart
/home/hunghlh/app/infras/minikube-local/bin/start-ingress-forwarder.sh
```

**Port 8080 not accessible:**
```bash
# Check if port is listening
sudo ss -tlnp | grep 8080

# Check Docker logs
docker logs minikube-ingress-forwarder

# Test connection
curl -v http://localhost:8080
```

### Grafana/Prometheus Not Accessible

**Check pods:**
```bash
kubectl get pods -n infras-monitoring
```

**Check services:**
```bash
kubectl get svc -n infras-monitoring
```

**Check Ingress:**
```bash
kubectl get ingress -n infras-monitoring
```

**Test with Host header:**
```bash
curl -H "Host: grafana.local" http://localhost:8080
# Should return 200 OK
```

### Host Metrics Not Appearing

**Check if collector is running:**
```bash
ps aux | grep docker-stats
```

**Check metrics file:**
```bash
cat /tmp/node_exporter_textfile/docker_stats.prom
```

**Restart collector:**
```bash
/home/hunghlh/app/infras/minikube-local/k8s-local/monitoring/host-stats/setup-host-metrics.sh
```

### MiniKube Issues

**Check MiniKube status:**
```bash
minikube status
```

**Restart MiniKube:**
```bash
minikube stop
minikube start
```

**Get MiniKube IP:**
```bash
minikube ip
```

---

## 🔄 Maintenance

### Start All Services

```bash
# Start port forwarder
/home/hunghlh/app/infras/minikube-local/bin/start-ingress-forwarder.sh

# Start host metrics collector
/home/hunghlh/app/infras/minikube-local/k8s-local/monitoring/host-stats/setup-host-metrics.sh
```

### Stop All Services

```bash
# Stop port forwarder
/home/hunghlh/app/infras/minikube-local/bin/stop-ingress-forwarder.sh

# Stop host metrics collector
kill $(cat /tmp/node_exporter_textfile/docker-stats.pid) 2>/dev/null || true
kill $(cat /tmp/node_exporter_textfile/auto-expose.pid) 2>/dev/null || true
```

### Update Services

```bash
# Apply new configuration
kubectl apply -f k8s-local/

# Restart deployment
kubectl rollout restart deployment/grafana -n infras-monitoring

# Restart statefulset
kubectl rollout restart statefulset/prometheus -n infras-monitoring
```

---

## 📚 Additional Documentation

- [Monitoring Stack Details](monitoring/README.md)
- [Host Metrics Collection](monitoring/host-stats/README.md)
- [Grafana Dashboards](monitoring/grafana/dashboards/)

---

## 🚧 Next Steps

### Planned Services

The following services are planned for deployment:

1. **Vault** - Secret management
2. **MySQL** - Relational database
3. **PostgreSQL** - Relational database
4. **Redis Cluster** - Cache and session store
5. **Kafka Cluster** - Event streaming
6. **Keycloak** - Identity and access management
7. **Infras CLI** - Infrastructure automation tool

See [TASKS.md](../../TASKS.md) for detailed implementation plan and progress tracking.

---

## 🤝 Contributing

When adding new services:

1. Create namespace in `namespaces/00-namespaces.yaml`
2. Add deployment manifests in service-specific directory
3. Create Ingress route in `ingress/`
4. Add service exporter in `monitoring/exporters/`
5. Update this README with access details
6. Create Grafana dashboard in `monitoring/grafana/dashboards/`

---

## 📝 Notes

- **MiniKube Driver**: Docker
- **MiniKube IP**: 192.168.49.2
- **Ingress NodePort**: 30559 (HTTP), 32368 (HTTPS)
- **Host Forward Port**: 8080
- **Restart Policy**: unless-stopped (auto-start on boot)

---

## ⚡ Quick Commands Reference

```bash
# Status checks
minikube status                          # MiniKube status
kubectl get pods -A                      # All pods
docker ps | grep ingress                 # Port forwarder status

# Access
/home/hunghlh/app/infras/minikube-local/bin/start-ingress-forwarder.sh   # Start forwarder
ssh -L 8080:localhost:8080 user@server  # SSH tunnel

# Logs
kubectl logs -n infras-monitoring deployment/grafana     # Grafana logs
docker logs minikube-ingress-forwarder                   # Forwarder logs
tail -f /tmp/node_exporter_textfile/docker-stats.log     # Host metrics logs

# Troubleshooting
kubectl describe pod <pod-name>           # Pod details
kubectl get events -A                     # Cluster events
kubectl get ingress -A                    # All ingress routes
```
