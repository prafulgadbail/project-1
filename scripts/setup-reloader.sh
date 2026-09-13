#!/bin/bash

set -Eeuo pipefail

# ============================================================
# CHANGE ONLY THESE VALUES
# ============================================================

RELOADER_NAMESPACE="reloader"

# ============================================================
# DO NOT CHANGE BELOW THIS LINE
# ============================================================

echo "============================================================"
echo " Kubernetes Reloader Setup"
echo "============================================================"

# Check required commands
for CMD in kubectl helm; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: $CMD is not installed."
        exit 1
    fi
done

echo ""
echo "[1/4] Checking Kubernetes cluster connection..."

kubectl get nodes >/dev/null

echo "Kubernetes connection OK."

echo ""
echo "[2/4] Adding Reloader Helm repository..."

helm repo add stakater https://stakater.github.io/stakater-charts \
    >/dev/null 2>&1 || true

helm repo update >/dev/null 2>&1

echo "Helm repository ready."

echo ""
echo "[3/4] Installing or upgrading Reloader..."

helm upgrade --install reloader \
    stakater/reloader \
    --namespace "$RELOADER_NAMESPACE" \
    --create-namespace \
    --wait \
    --timeout 5m

echo "Reloader installed successfully."

echo ""
echo "[4/4] Verifying Reloader..."

kubectl rollout status deployment/reloader-reloader \
    -n "$RELOADER_NAMESPACE" \
    --timeout=180s

kubectl get deployment \
    -n "$RELOADER_NAMESPACE"

echo ""
echo "============================================================"
echo " RELOADER SETUP COMPLETED"
echo "============================================================"

echo ""
echo "Reloader Namespace : $RELOADER_NAMESPACE"
echo ""
echo "SUCCESS: Kubernetes Reloader is ready."