#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KEYS_FILE="${ROOT_DIR}/vault_keys.txt"
COMPOSE_FILE="${ROOT_DIR}/kafka-local/docker-compose.yml"
JAAS_FILE="${ROOT_DIR}/kafka-local/kafka_server_jaas.conf"

# Source Common Library
source "${ROOT_DIR}/bin/lib/common.sh"

echo "[INFO] Starting kafka-local..."

# Check Vault Availability
check_vault

if [ -n "${VAULT_TOKEN:-}" ]; then
    echo "[INFO] Vault detected. Ensuring/Fetching secrets..."
    
    # Ensure credential exists
    ensure_credential "infras/kafka/sasl" "admin"
    
    # Fetch Secrets
    export KAFKA_SASL_USERNAME=$(fetch_secret infras/kafka/sasl username)
    export KAFKA_SASL_PASSWORD=$(fetch_secret infras/kafka/sasl password)
    
    echo "[INFO] Secrets fetched successfully."
    
    # Generate Broker Credentials
    JAAS_CONTENT="KafkaServer {
    org.apache.kafka.common.security.plain.PlainLoginModule required
    username=\"$KAFKA_SASL_USERNAME\"
    password=\"$KAFKA_SASL_PASSWORD\"
    user_$KAFKA_SASL_USERNAME=\"$KAFKA_SASL_PASSWORD\""

    for i in 1 2 3; do
        broker="kafka-$i"
        ensure_credential "infras/kafka/$broker" "$broker"
        pass=$(fetch_secret "infras/kafka/$broker" password)
        
        # Export for docker-compose
        export KAFKA_${i}_PASSWORD="$pass"
        
        # Append to JAAS
        JAAS_CONTENT="${JAAS_CONTENT}
    user_${broker//-/_}=\"$pass\""
    done

    # Close JAAS
    JAAS_CONTENT="${JAAS_CONTENT}
    ;
};"

    echo "[INFO] Generating Kafka JAAS configuration..."
    echo "$JAAS_CONTENT" > "$JAAS_FILE"
    echo "[INFO] Secrets fetched and JAAS config generated."
else
    echo "[WARN] Vault not detected or keys missing. Using existing configuration."
fi

echo "[INFO] Starting kafka-local using ${COMPOSE_FILE}..."
docker compose -f "${COMPOSE_FILE}" up -d
echo "[OK] kafka-local is starting. Use 'docker ps' to verify the container."
