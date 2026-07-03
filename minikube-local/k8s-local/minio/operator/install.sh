#!/bin/bash
# Install the MinIO Operator (pinned v7.1.1) into the infras-minio namespace.
# The namespace override lives in the kustomization.yaml next to this script,
# which uses the upstream operator as a remote base.
# NOTE: minio/operator was archived 2026-03-20; v7.1.1 is the final community
# release. Requires Kubernetes >= 1.30.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "→ Installing MinIO Operator v7.1.1 into namespace infras-minio..."
kubectl apply -k "$SCRIPT_DIR"

echo "→ Waiting for Operator deployment to become available..."
kubectl -n infras-minio rollout status deployment/minio-operator --timeout=180s

echo "✅ MinIO Operator v7.1.1 installed in infras-minio."
