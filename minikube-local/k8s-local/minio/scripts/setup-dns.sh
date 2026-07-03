#!/bin/bash
# Add minio.local and s3.minio.local to /etc/hosts pointing at the minikube IP.
set -e
MINIKUBE_IP=$(minikube ip)
HOSTS_FILE="/etc/hosts"

echo "→ MiniKube IP: $MINIKUBE_IP"
if grep -q "minio.local" "$HOSTS_FILE"; then
  echo "⚠ minio.local already present in $HOSTS_FILE — skipping."
  exit 0
fi

sudo -- bash -c "cat >> '$HOSTS_FILE' << EOF

# MinIO Ingress - Local DNS (managed by k8s-local)
$MINIKUBE_IP minio.local
$MINIKUBE_IP s3.minio.local
EOF"

echo "✅ Added minio.local and s3.minio.local"
echo "   Console: http://minio.local:8080"
echo "   S3 API:  http://s3.minio.local:8080"
