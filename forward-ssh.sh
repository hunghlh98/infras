#!/usr/bin/env bash

# Logic for SSH port forwarding
# This script is called by forward-ports.sh

set -euo pipefail

SSH_OPTS=(
  -N
  -o ExitOnForwardFailure=yes
  -o ServerAliveInterval=60
  -o ServerAliveCountMax=3
)

# Usage: ./forward-ssh.sh "mapping1 mapping2" "user@host"
MAPPINGS=$1
TARGET=$2

FORWARDS=()
for mapping in $MAPPINGS; do
  FORWARDS+=("-L" "$mapping")
done

echo "Starting SSH forward: ssh ${SSH_OPTS[*]} ${FORWARDS[*]} $TARGET"
exec ssh "${SSH_OPTS[@]}" "${FORWARDS[@]}" "$TARGET"
