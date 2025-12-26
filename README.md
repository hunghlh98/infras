# Local Infrastructure Setup

This repository contains scripts and Docker Compose configurations to set up a local development infrastructure including Vault, Kafka, MySQL, and Redis.

## Prerequisites

*   Docker & Docker Compose
*   `jq` (JSON processor)

## Getting Started

### 1. Environment Setup

Create a `local.env` file from the example `.env` file and configure your credentials.

```bash
cp .env local.env
# Edit local.env with your desired credentials
```

### 2. Start Vault & Initialize Secrets

Vault is used to manage secrets for other services. It must be started and initialized first.

```bash
# Start Vault service
./vault-local/up.sh

# Initialize Vault and populate secrets from local.env
./vault-local/init_vault.sh
```

This process will:
*   Start a Vault container.
*   Initialize and unseal Vault.
*   Save unseal keys and root token to `vault_keys.txt`.
*   Write secrets from `local.env` into Vault.

### 3. Start Other Services

Once Vault is running and populated, you can start the other services. The startup scripts will automatically fetch credentials from Vault.

#### Kafka

```bash
./kafka-local/up.sh
```
*   Generates JAAS configuration using secrets from Vault.
*   Starts a 3-node Kafka cluster with SASL authentication.

#### MySQL

```bash
./mysql-local/up.sh
```
*   Fetches root, admin, and user passwords from Vault.
*   Starts a MySQL 8.0 instance.

#### Redis

```bash
./redis-local/up.sh
```
*   Fetches the Redis password from Vault.
*   Starts a 3-node Redis Cluster.

## Service Management

Each service directory (`kafka-local`, `mysql-local`, `redis-local`, `vault-local`) contains helper scripts:

*   `up.sh`: Start the service.
*   `down.sh`: Stop and remove the service containers.
*   `reset.sh`: Stop the service and remove data volumes (use with caution).

## Directory Structure

*   `vault-local/`: Vault configuration and initialization scripts.
*   `kafka-local/`: Kafka cluster configuration.
*   `mysql-local/`: MySQL configuration and initialization.
*   `redis-local/`: Redis Cluster configuration.
*   `volumes/`: Persistent data storage for containers (created automatically).
*   `vault_keys.txt`: Generated file containing Vault keys (do not commit this).
*   `local.env`: Local environment variables (do not commit this).
