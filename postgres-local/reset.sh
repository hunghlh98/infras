#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/postgres-local/docker-compose.yml"
DATA_DIR="${ROOT_DIR}/volumes/postgres-data"

docker compose -f "${COMPOSE_FILE}" down
rm -rf "$DATA_DIR"
docker compose -f "${COMPOSE_FILE}" up -d
