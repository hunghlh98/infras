#!/bin/bash

# Exit on pipe failures - important for checking minikube start status through tee
set -o pipefail

# Get the absolute project root (one level up from minikube-local/)
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# 1. Use the state directory inside volumes/minikube/
export MINIKUBE_HOME="$PROJECT_ROOT/volumes/minikube/state"

echo "Starting minikube in $MINIKUBE_HOME..."

# Check if minikube is already running
if minikube status --profile=minikube 2>/dev/null | grep -q "Running"; then
  echo "✅ Minikube is already running!"
else
  # Try to start normally first
  if ! minikube start \
    --cpus=8 \
    --memory=16384mb \
    --disk-size=50g \
    --driver=docker 2>&1 | tee /tmp/minikube-start.log; then

    # Check if it's the "Address already in use" error
    if grep -qi "address already in use" /tmp/minikube-start.log; then
      echo "⚠️  Network address conflict detected, attempting recovery..."

      # Check if minikube-ingress-forwarder is the culprit
      if docker ps | grep -q "minikube-ingress-forwarder"; then
        echo "🔧 Stopping minikube-ingress-forwarder temporarily..."
        docker stop minikube-ingress-forwarder
        INGRESS_FORWARDER_STOPPED=true
      fi

      # Force cleanup of any stuck containers (PRESERVES DATA)
      echo "🔧 Cleaning up stuck containers..."
      docker rm -f minikube 2>/dev/null || true

      # Clean up Docker networks that might be causing conflicts
      echo "🔧 Cleaning up Docker networks..."
      docker network rm minikube 2>/dev/null || true

      # Retry start WITHOUT deleting the cluster
      echo "🔄 Retrying minikube start..."
      if ! minikube start --cpus=8 --memory=16384mb --disk-size=50g --driver=docker; then
        # If minikube start still fails, try to restore ingress forwarder
        if [ "$INGRESS_FORWARDER_STOPPED" = true ]; then
          echo "🔄 Attempting to restore minikube-ingress-forwarder..."
          docker start minikube-ingress-forwarder 2>/dev/null || true
        fi

        echo "❌ Failed to start minikube after recovery attempts."
        echo "💡 Manual recovery options:"
        echo "   1. Check logs: cat /tmp/minikube-start.log"
        echo "   2. Diagnose: minikube status --profile=minikube"
        echo "   3. ⚠️  Full reset (DELETES ALL DATA): minikube delete --profile=minikube && ./up.sh"
        exit 1
      fi

      # Note: We don't automatically restore the ingress-forwarder since it
      # may be from a previous setup. Users can recreate it if needed.
    else
      echo "❌ Failed to start minikube. Check logs above."
      echo "💡 For diagnostics: cat /tmp/minikube-start.log"
      exit 1
    fi
  fi
fi

# 2. Enable ingress addon for local access
echo "🌐 Configuring ingress access..."

# Enable ingress addon
if ! minikube addons enable ingress 2>/dev/null; then
  echo "⚠️  Failed to enable ingress addon, may already be enabled"
fi

# Start ingress forwarder if not running
if ! docker ps | grep -q "minikube-ingress-forwarder"; then
  echo "🔧 Starting ingress forwarder for port 8080 access..."

  # Wait for ingress controller to be ready and get NodePort
  echo "⏳ Waiting for ingress controller..."
  timeout 30 bash -c 'until kubectl get svc -n ingress-nginx ingress-nginx-controller &>/dev/null; do sleep 1; done'

  INGRESS_PORT=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.ports[?(@.name=="http")].nodePort}')

  if [ -n "$INGRESS_PORT" ]; then
    docker run -d --name minikube-ingress-forwarder \
      --network minikube \
      -p 8080:80 \
      alpine/socat \
      TCP-LISTEN:80,fork,reuseaddr TCP:$(minikube ip):${INGRESS_PORT} || \
      echo "⚠️  Failed to start ingress forwarder (may already exist)"
  else
    echo "⚠️  Could not determine ingress NodePort"
  fi
else
  echo "✅ Ingress forwarder already running"
fi

# Verify everything is running
echo "🔍 Verifying services..."

if ! minikube status --profile=minikube 2>/dev/null | grep -q "Running"; then
  echo "❌ Minikube failed to start properly. Check status with: minikube status"
  exit 1
fi

echo "--------------------------------------------------------"
echo "✅ Minikube is up! Resources: 8 CPUs, 16GiB RAM"
echo "📍 State location: $MINIKUBE_HOME"
echo "🌐 Ingress access: http://localhost:8080 (vault.local, etc.)"
echo "💡 Data-safe: No destructive operations performed"
echo "--------------------------------------------------------"
