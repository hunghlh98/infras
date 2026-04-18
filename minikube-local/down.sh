#!/bin/bash

# Get the absolute project root (one level up from minikube-local/)
PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

# 1. Use the state directory inside volumes/minikube/
export MINIKUBE_HOME="$PROJECT_ROOT/volumes/minikube/state"

echo "Stopping minikube in $MINIKUBE_HOME..."

# Stop minikube
echo "🛑 Stopping minikube..."
minikube stop

# Stop ingress forwarder if running
echo "🔧 Checking ingress forwarder..."
if docker ps | grep -q "minikube-ingress-forwarder"; then
  echo "🛑 Stopping ingress forwarder (keeping container for fast restart)..."
  docker stop minikube-ingress-forwarder >/dev/null 2>&1 || true
  echo "✅ Ingress forwarder stopped"
else
  echo "✅ No ingress forwarder running"
fi

echo "--------------------------------------------------------"
echo "✅ Minikube stopped safely."
echo "💡 State preserved in: $MINIKUBE_HOME"
echo "--------------------------------------------------------"
