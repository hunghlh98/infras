#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR_PREFIX="${ROOT_DIR}/volumes/kafka-"

echo "[INFO] Stopping kafka-local cluster..."
${ROOT_DIR}/kafka-local/down.sh

echo "[INFO] Removing data directories..."
rm -rf "${DATA_DIR_PREFIX}"*-data

echo "[INFO] Starting kafka-local cluster..."
${ROOT_DIR}/kafka-local/up.sh

echo "[OK] Reset complete. Waiting for Kafka cluster to be ready..."
sleep 10
docker ps | grep kafka
