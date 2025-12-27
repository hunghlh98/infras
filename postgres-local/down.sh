#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="${ROOT_DIR}/postgres-local/docker-compose.yml"
docker compose -f "${COMPOSE_FILE}" down
