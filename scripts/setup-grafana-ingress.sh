#!/bin/bash
set -Eeuo pipefail

# ============================================================
# CHANGE ONLY THESE VALUES
# ============================================================

CLUSTER_NAME="prod-cluster"
AWS_REGION="us-east-1"

GRAFANA_NAMESPACE="monitoring"
GRAFANA_HOST="grafana.prafulgadbail.online"

# ACM certificate used for HTTPS
ACM_CERTIFICATE_ARN="arn:aws:acm:us-east-1:261945560801:certificate/cc2a6bb8-049f-49c6-97d5-367af3c5d9eb"

# Shared ALB group used by application and monitoring Ingresses
ALB_GROUP_NAME="shared-alb"

# ============================================================
# DO NOT CHANGE BELOW THIS LINE
# ============================================================

echo "============================================================"
echo " Grafana Ingress Setup"
echo "============================================================"

# Check required commands
for CMD in aws kubectl; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: $CMD is not installed."
        exit 1
    fi
done

echo ""
echo "[1/5] Configuring kubectl..."

aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME"

echo "Kubernetes connection configured."

echo ""
echo "[2/5] Checking Grafana..."

kubectl get deployment \
    kube-prometheus-stack-grafana \
    -n "$GRAFANA_NAMESPACE"

kubectl get service \
    kube-prometheus-stack-grafana \
    -n "$GRAFANA_NAMESPACE"

echo "Grafana service found."

echo ""
echo "[3/5] Creating Grafana Ingress..."

cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress

metadata:
  name: grafana-ingress
  namespace: $GRAFANA_NAMESPACE

  # Share the existing ALB with other Ingress resources
  annotations:
    alb.ingress.kubernetes.io/group.name: $ALB_GROUP_NAME

    # Use an internet-facing Application Load Balancer
    alb.ingress.kubernetes.io/scheme: internet-facing

    # Route traffic directly to pod IPs
    alb.ingress.kubernetes.io/target-type: ip

    # ACM certificate for HTTPS
    alb.ingress.kubernetes.io/certificate-arn: $ACM_CERTIFICATE_ARN

    # Listen on HTTP and HTTPS
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'

    # Redirect HTTP traffic to HTTPS
    alb.ingress.kubernetes.io/ssl-redirect: '443'

spec:
  ingressClassName: alb

  rules:
    - host: $GRAFANA_HOST
      http:
        paths:

          # Route Grafana traffic to the Grafana service
          - path: /
            pathType: Prefix
            backend:
              service:
                name: kube-prometheus-stack-grafana
                port:
                  number: 80
EOF

echo "Grafana Ingress created."

echo ""
echo "[4/5] Waiting for ALB..."

ALB_HOSTNAME=""

for i in {1..30}; do

    ALB_HOSTNAME=$(kubectl get ingress grafana-ingress \
        -n "$GRAFANA_NAMESPACE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' \
        2>/dev/null || true)

    if [ -n "$ALB_HOSTNAME" ]; then
        break
    fi

    sleep 10
done

echo ""
echo "[5/5] Verifying Grafana Ingress..."

kubectl get ingress \
    grafana-ingress \
    -n "$GRAFANA_NAMESPACE"

echo ""
echo "============================================================"
echo " GRAFANA INGRESS SETUP COMPLETED"
echo "============================================================"

echo ""
echo "Grafana Host : https://$GRAFANA_HOST"
echo "ALB Hostname : ${ALB_HOSTNAME:-Not available yet}"
echo ""
echo "IMPORTANT:"
echo "Create the Route 53 record manually:"
echo "$GRAFANA_HOST -> Existing Shared ALB"
echo ""