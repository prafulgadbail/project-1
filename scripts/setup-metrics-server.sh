#!/bin/bash
set -Eeuo pipefail

# ============================================================
# CHANGE ONLY THESE VALUES
# ============================================================

CLUSTER_NAME="prod-cluster"
AWS_REGION="us-east-1"

METRICS_NAMESPACE="kube-system"

# ============================================================
# DO NOT CHANGE BELOW THIS LINE
# ============================================================

echo "============================================================"
echo " Kubernetes Metrics Server Setup"
echo "============================================================"

# ------------------------------------------------------------
# Check required commands
# ------------------------------------------------------------

for CMD in aws kubectl helm; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: $CMD is not installed."
        exit 1
    fi
done

# ------------------------------------------------------------
# Connect kubectl to EKS
# ------------------------------------------------------------

echo ""
echo "[1/5] Checking EKS cluster connection..."

aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --no-cli-pager

kubectl get nodes >/dev/null

echo "Kubernetes connection OK."

# ------------------------------------------------------------
# Add Metrics Server Helm repository
# ------------------------------------------------------------

echo ""
echo "[2/5] Adding Metrics Server Helm repository..."

helm repo add metrics-server \
    https://kubernetes-sigs.github.io/metrics-server/ \
    >/dev/null 2>&1 || true

helm repo update >/dev/null 2>&1

echo "Helm repository ready."

# ------------------------------------------------------------
# Install or upgrade Metrics Server
# ------------------------------------------------------------

echo ""
echo "[3/5] Installing Metrics Server..."

helm upgrade --install metrics-server \
    metrics-server/metrics-server \
    --namespace "$METRICS_NAMESPACE" \
    --set "args[0]=--kubelet-preferred-address-types=InternalIP,Hostname,ExternalIP" \
    --set "args[1]=--kubelet-use-node-status-port" \
    --wait \
    --timeout 5m

echo "Metrics Server installed."

# ------------------------------------------------------------
# Verify Metrics Server deployment
# ------------------------------------------------------------

echo ""
echo "[4/5] Verifying Metrics Server..."

kubectl rollout status deployment/metrics-server \
    -n "$METRICS_NAMESPACE" \
    --timeout=180s

kubectl get deployment metrics-server \
    -n "$METRICS_NAMESPACE"

# ------------------------------------------------------------
# Verify metrics API
# ------------------------------------------------------------

echo ""
echo "[5/5] Checking Kubernetes metrics API..."

sleep 15

kubectl top nodes || true

echo ""
echo "============================================================"
echo " METRICS SERVER SETUP COMPLETED"
echo "============================================================"

echo ""
echo "Cluster : $CLUSTER_NAME"
echo ""
echo "Metrics Server is ready for HPA."
echo ""
echo "Test commands:"
echo "kubectl top nodes"
echo "kubectl top pods -n student-app"
echo ""

