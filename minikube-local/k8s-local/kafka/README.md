# Kafka on Kubernetes (MiniKube Local)

Single-node Kafka deployment using KRaft mode (no Zookeeper) with SASL authentication.

## Architecture

- **Image**: confluentinc/cp-kafka:7.6.1
- **Mode**: KRaft (broker + controller combined)
- **Authentication**: SASL_PLAINTEXT via Vault
- **Storage**: 5Gi Persistent Volume
- **Replicas**: 1

## Prerequisites

1. **Vault must be running** with Kafka credentials stored:
   ```bash
   # Store Kafka credentials in Vault
   vault kv put secret/infras/kafka/credentials \
     admin-password=<your_admin_password> \
     broker-password=<your_broker_password>
   ```

2. **Vault token secret** must exist in `infras-vault` namespace

## Quick Start

### 1. Deploy Kafka

```bash
# From the k8s-local directory
kubectl apply -f kafka/
```

### 2. Verify Deployment

```bash
# Check pod status
kubectl get pods -n infras-kafka

# View logs
kubectl logs -n infras-kafka kafka-0

# Check services
kubectl get svc -n infras-kafka
```

### 3. Access Kafka

#### From within the cluster

Connect to `kafka.infras-kafka.svc.cluster.local:9094` using SASL authentication.

#### From outside the cluster (port-forward)

```bash
# Forward SASL port
kubectl port-forward -n infras-kafka kafka-0 9094:9094

# Test with kafka-client tools
kafka-topics.sh --bootstrap-server localhost:9094 \
  --command-config client_sasl.properties --list
```

## Configuration

### Environment Variables

| Variable | Value | Description |
|----------|-------|-------------|
| `KAFKA_NODE_ID` | 1 | Broker node ID |
| `KAFKA_BROKER_ID` | 1 | Legacy broker ID |
| `KAFKA_OPTS` | JAAS config path | Points to Vault-fetched JAAS config |
| `KAFKA_HEAP_OPTS` | -Xmx512M -Xms512M | JVM heap settings |

### Ports

| Port | Name | Protocol | Description |
|------|------|----------|-------------|
| 9091 | broker | SASL_PLAINTEXT | Inter-broker communication |
| 9093 | controller | SASL_PLAINTEXT | Controller quorum |
| 9094 | sasl | SASL_PLAINTEXT | Client connections (SASL) |

### SASL Authentication

The Kafka broker uses SASL_PLAINTEXT authentication with PLAIN mechanism. Credentials are fetched from Vault at startup.

**Default users:**
- `admin` - Super user with full permissions
- `kafka-1` - Broker service account

**Client configuration example** (`client_sasl.properties`):
```properties
security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username="admin" password="<admin-password>";
```

## Topics and Data

### Create a topic

```bash
kafka-topics.sh --bootstrap-server kafka.infras-kafka.svc.cluster.local:9094 \
  --command-config client_sasl.properties \
  --create --topic test-topic --partitions 3 --replication-factor 1
```

### List topics

```bash
kafka-topics.sh --bootstrap-server kafka.infras-kafka.svc.cluster.local:9094 \
  --command-config client_sasl.properties --list
```

### Produce messages

```bash
kafka-console-producer.sh --bootstrap-server kafka.infras-kafka.svc.cluster.local:9094 \
  --producer.config client_sasl.properties --topic test-topic
```

### Consume messages

```bash
kafka-console-consumer.sh --bootstrap-server kafka.infras-kafka.svc.cluster.local:9094 \
  --consumer.config client_sasl.properties --topic test-topic --from-beginning
```

## Persistence

Kafka data is stored in a PersistentVolumeClaim (5Gi) mounted at `/var/lib/kafka/data`. Data persists across pod restarts.

## Troubleshooting

### Pod not starting

1. Check if Vault is accessible:
   ```bash
   kubectl exec -n infras-kafka kafka-0 -- wget -O- http://vault.infras-vault.svc.cluster.local:8200/v1/sys/health
   ```

2. Check if Vault credentials exist:
   ```bash
   vault kv get secret/infras/kafka/credentials
   ```

3. Check init container logs:
   ```bash
   kubectl logs -n infras-kafka kafka-0 -c vault-init
   ```

### Connection issues

1. Verify SASL authentication:
   ```bash
   # Use correct credentials from Vault
   vault kv get -field=admin-password secret/infras/kafka/credentials
   ```

2. Check service endpoints:
   ```bash
   kubectl get endpoints -n infras-kafka kafka
   ```

## Monitoring

Prometheus metrics are exposed on port 9302 (annotations configured).

## Future Enhancements

- [ ] Add Kafka Exporter for detailed metrics
- [ ] Add KafkaUI or Kowl for web-based management
- [ ] Multi-broker setup for high availability
- [ ] TLS/SSL encryption for production
- [ ] Schema Registry integration

## Cleanup

```bash
# Delete Kafka deployment
kubectl delete -f kafka/

# Delete persistent volume (careful - this deletes all data!)
kubectl delete pvc -n infras-kafka kafka-data-kafka-0
```
