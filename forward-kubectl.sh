#!/usr/bin/env bash

# Logic for kubectl port forwarding
# This script is called by forward-ports.sh

set -euo pipefail

# Usage: ./forward-kubectl.sh "namespace" "resource" "port_mapping"
NAMESPACE=$1
RESOURCE=$2
MAPPING=$3

echo "Starting kubectl forward: kubectl port-forward -n $NAMESPACE $RESOURCE $MAPPING"
exec kubectl port-forward -n "$NAMESPACE" "$RESOURCE" "$MAPPING"
