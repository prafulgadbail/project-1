#!/bin/bash
set -Eeuo pipefail

# ============================================================
# CHANGE ONLY THESE VALUES
# ============================================================

CLUSTER_NAME="prod-cluster"
AWS_REGION="us-east-1"

MONITORING_NAMESPACE="monitoring"
PROMETHEUS_RELEASE="kube-prometheus-stack"

# Prometheus data retention
PROMETHEUS_RETENTION="15d"

# Persistent storage for Prometheus
PROMETHEUS_STORAGE_SIZE="50Gi"

# Persistent storage for Grafana
GRAFANA_STORAGE_SIZE="10Gi"

# ============================================================
# DO NOT CHANGE BELOW THIS LINE
# ============================================================

echo "============================================================"
echo " Prometheus + Grafana Monitoring Setup"
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
# Check AWS and Kubernetes access
# ------------------------------------------------------------

echo ""
echo "[1/7] Checking Kubernetes cluster connection..."

aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --no-cli-pager

kubectl get nodes >/dev/null

echo "Kubernetes connection OK."

# ------------------------------------------------------------
# Create monitoring namespace
# ------------------------------------------------------------

echo ""
echo "[2/7] Creating monitoring namespace..."

kubectl create namespace "$MONITORING_NAMESPACE" \
    --dry-run=client \
    -o yaml |
kubectl apply -f -

echo "Monitoring namespace ready."

# ------------------------------------------------------------
# Add Prometheus Community Helm repository
# ------------------------------------------------------------

echo ""
echo "[3/7] Adding Prometheus Community Helm repository..."

helm repo add prometheus-community \
    https://prometheus-community.github.io/helm-charts \
    >/dev/null 2>&1 || true

helm repo update >/dev/null 2>&1

echo "Helm repository ready."

# ------------------------------------------------------------
# Install Prometheus + Grafana monitoring stack
# ------------------------------------------------------------

echo ""
echo "[4/7] Installing Prometheus + Grafana..."

helm upgrade --install "$PROMETHEUS_RELEASE" \
    prometheus-community/kube-prometheus-stack \
    --namespace "$MONITORING_NAMESPACE" \
    --create-namespace \
    --set prometheus.prometheusSpec.retention="$PROMETHEUS_RETENTION" \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=gp3 \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]=ReadWriteOnce \
    --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage="$PROMETHEUS_STORAGE_SIZE" \
    --set grafana.persistence.enabled=true \
    --set grafana.persistence.storageClassName=gp3 \
    --set grafana.persistence.size="$GRAFANA_STORAGE_SIZE" \
    --set grafana.persistence.accessModes[0]=ReadWriteOnce \
    --set grafana.service.type=ClusterIP \
    --wait \
    --timeout 10m

echo "Prometheus + Grafana installed."

# ------------------------------------------------------------
# Verify Prometheus
# ------------------------------------------------------------

echo ""
echo "[5/7] Verifying Prometheus..."

kubectl rollout status statefulset/prometheus-"$PROMETHEUS_RELEASE"-prometheus \
    -n "$MONITORING_NAMESPACE" \
    --timeout=300s

# ------------------------------------------------------------
# Verify Grafana
# ------------------------------------------------------------

echo ""
echo "[6/7] Verifying Grafana..."

kubectl rollout status deployment/"$PROMETHEUS_RELEASE"-grafana \
    -n "$MONITORING_NAMESPACE" \
    --timeout=300s

# ------------------------------------------------------------
# Display monitoring resources
# ------------------------------------------------------------

echo ""
echo "[7/7] Checking monitoring resources..."

echo ""
echo "Deployments:"
kubectl get deployments -n "$MONITORING_NAMESPACE"

echo ""
echo "StatefulSets:"
kubectl get statefulsets -n "$MONITORING_NAMESPACE"

echo ""
echo "Pods:"
kubectl get pods -n "$MONITORING_NAMESPACE"

echo ""
echo "Services:"
kubectl get svc -n "$MONITORING_NAMESPACE"

echo ""
echo "PersistentVolumeClaims:"
kubectl get pvc -n "$MONITORING_NAMESPACE"

echo ""
echo "============================================================"
echo " MONITORING SETUP COMPLETED"
echo "============================================================"

echo ""
echo "Prometheus Namespace : $MONITORING_NAMESPACE"
echo "Prometheus Retention : $PROMETHEUS_RETENTION"
echo "Prometheus Storage   : $PROMETHEUS_STORAGE_SIZE"
echo "Grafana Storage      : $GRAFANA_STORAGE_SIZE"
echo ""
echo "SUCCESS: Prometheus + Grafana monitoring is ready."