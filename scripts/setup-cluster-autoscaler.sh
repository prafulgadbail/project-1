#!/bin/bash
set -Eeuo pipefail

# ============================================================
# CHANGE ONLY THESE VALUES
# ============================================================

CLUSTER_NAME="prod-cluster"
AWS_REGION="us-east-1"

AUTOSCALER_NAMESPACE="kube-system"

IAM_POLICY_NAME="EKSClusterAutoscalerPolicy-${CLUSTER_NAME}"
IAM_ROLE_NAME="EKSClusterAutoscalerRole-${CLUSTER_NAME}"

# ============================================================
# DO NOT CHANGE BELOW THIS LINE
# ============================================================

echo "============================================================"
echo " EKS Cluster Autoscaler Setup"
echo "============================================================"

# ------------------------------------------------------------
# Check required commands
# ------------------------------------------------------------

for CMD in aws kubectl helm jq eksctl; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: $CMD is not installed."
        exit 1
    fi
done

# ------------------------------------------------------------
# Verify AWS and Kubernetes access
# ------------------------------------------------------------

echo ""
echo "[1/9] Checking AWS and Kubernetes access..."

aws sts get-caller-identity --no-cli-pager >/dev/null

aws eks describe-cluster \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --no-cli-pager >/dev/null

aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --no-cli-pager

kubectl get nodes >/dev/null

echo "AWS and Kubernetes access OK."

# ------------------------------------------------------------
# Automatically detect Kubernetes version from EKS
# ------------------------------------------------------------

echo ""
echo "[2/9] Detecting Kubernetes version..."

K8S_VERSION=$(aws eks describe-cluster \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.version' \
    --output text \
    --no-cli-pager)

echo "Kubernetes Version: $K8S_VERSION"

# ------------------------------------------------------------
# Add Cluster Autoscaler Helm repository
# ------------------------------------------------------------

echo ""
echo "[3/9] Adding Cluster Autoscaler Helm repository..."

helm repo add autoscaler \
    https://kubernetes.github.io/autoscaler \
    >/dev/null 2>&1 || true

helm repo update >/dev/null 2>&1

echo "Helm repository ready."

# ------------------------------------------------------------
# Automatically find a Helm chart matching Kubernetes version
# ------------------------------------------------------------

echo ""
echo "[4/9] Finding compatible Cluster Autoscaler version..."

AUTOSCALER_CHART_VERSION=$(helm search repo \
    autoscaler/cluster-autoscaler \
    --versions \
    -o json |
    jq -r --arg version "$K8S_VERSION" '
        .[]
        | select(.app_version | startswith($version + "."))
        | .version
    ' |
    head -n 1)

if [ -z "$AUTOSCALER_CHART_VERSION" ]; then
    echo "ERROR: No compatible Cluster Autoscaler Helm chart found for Kubernetes $K8S_VERSION."
    exit 1
fi

echo "Kubernetes Version       : $K8S_VERSION"
echo "Autoscaler Chart Version : $AUTOSCALER_CHART_VERSION"

# ------------------------------------------------------------
# Associate IAM OIDC provider with the EKS cluster
# ------------------------------------------------------------

echo ""
echo "[5/9] Configuring IAM OIDC provider..."

eksctl utils associate-iam-oidc-provider \
    --cluster "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --approve

echo "OIDC provider ready."

# ------------------------------------------------------------
# Get AWS account and OIDC information
# ------------------------------------------------------------

ACCOUNT_ID=$(aws sts get-caller-identity \
    --query 'Account' \
    --output text \
    --no-cli-pager)

OIDC_ISSUER=$(aws eks describe-cluster \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.identity.oidc.issuer' \
    --output text \
    --no-cli-pager)

OIDC_PROVIDER="${OIDC_ISSUER#https://}"

OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"

# ------------------------------------------------------------
# Create IAM trust policy for Cluster Autoscaler ServiceAccount
# ------------------------------------------------------------

cat > /tmp/cluster-autoscaler-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${AUTOSCALER_NAMESPACE}:cluster-autoscaler",
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com"
        }
      }
    }
  ]
}
EOF

# ------------------------------------------------------------
# Create least-privilege IAM policy for Cluster Autoscaler
# ------------------------------------------------------------

cat > /tmp/cluster-autoscaler-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/k8s.io/cluster-autoscaler/enabled": "true",
          "aws:ResourceTag/k8s.io/cluster-autoscaler/${CLUSTER_NAME}": "owned"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup"
      ],
      "Resource": "*"
    }
  ]
}
EOF

# ------------------------------------------------------------
# Create or update IAM policy
# ------------------------------------------------------------

echo ""
echo "[6/9] Creating IAM policy and role..."

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"

if aws iam get-policy \
    --policy-arn "$POLICY_ARN" \
    --no-cli-pager >/dev/null 2>&1; then

    echo "IAM policy already exists."

else

    aws iam create-policy \
        --policy-name "$IAM_POLICY_NAME" \
        --policy-document file:///tmp/cluster-autoscaler-policy.json \
        --no-cli-pager >/dev/null

    echo "IAM policy created."
fi

if aws iam get-role \
    --role-name "$IAM_ROLE_NAME" \
    --no-cli-pager >/dev/null 2>&1; then

    echo "IAM role already exists."

    aws iam update-assume-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-document file:///tmp/cluster-autoscaler-trust-policy.json \
        --no-cli-pager

else

    aws iam create-role \
        --role-name "$IAM_ROLE_NAME" \
        --assume-role-policy-document file:///tmp/cluster-autoscaler-trust-policy.json \
        --description "IAM role for EKS Cluster Autoscaler - ${CLUSTER_NAME}" \
        --no-cli-pager >/dev/null

    echo "IAM role created."
fi

# ------------------------------------------------------------
# Attach IAM policy to role
# ------------------------------------------------------------

aws iam attach-role-policy \
    --role-name "$IAM_ROLE_NAME" \
    --policy-arn "$POLICY_ARN"

IAM_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

echo "IAM role ready."

# ------------------------------------------------------------
# Discover all EKS Managed Node Groups
# ------------------------------------------------------------

echo ""
echo "[7/9] Discovering EKS Managed Node Groups..."

NODEGROUPS=$(aws eks list-nodegroups \
    --region "$AWS_REGION" \
    --cluster-name "$CLUSTER_NAME" \
    --query 'nodegroups[]' \
    --output text \
    --no-cli-pager)

if [ -z "$NODEGROUPS" ]; then
    echo "ERROR: No EKS Managed Node Groups found."
    exit 1
fi

echo "Node Groups:"
echo "$NODEGROUPS"

# ------------------------------------------------------------
# Add Cluster Autoscaler discovery tags to every ASG
# ------------------------------------------------------------

echo ""
echo "Configuring Cluster Autoscaler tags..."

for NODEGROUP in $NODEGROUPS; do

    echo ""
    echo "Node Group: $NODEGROUP"

    ASGS=$(aws eks describe-nodegroup \
        --region "$AWS_REGION" \
        --cluster-name "$CLUSTER_NAME" \
        --nodegroup-name "$NODEGROUP" \
        --query 'nodegroup.resources.autoScalingGroups[].name' \
        --output text \
        --no-cli-pager)

    for ASG in $ASGS; do

        echo "ASG: $ASG"

        aws autoscaling create-or-update-tags \
            --tags \
                "ResourceId=${ASG},ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/enabled,Value=true,PropagateAtLaunch=false" \
                "ResourceId=${ASG},ResourceType=auto-scaling-group,Key=k8s.io/cluster-autoscaler/${CLUSTER_NAME},Value=owned,PropagateAtLaunch=false"

    done
done

echo "Cluster Autoscaler tags configured."

# ------------------------------------------------------------
# Install or upgrade Cluster Autoscaler
# ------------------------------------------------------------

echo ""
echo "[8/9] Installing or upgrading Cluster Autoscaler..."

helm upgrade --install cluster-autoscaler \
    autoscaler/cluster-autoscaler \
    --namespace "$AUTOSCALER_NAMESPACE" \
    --version "$AUTOSCALER_CHART_VERSION" \
    --set "autoDiscovery.clusterName=$CLUSTER_NAME" \
    --set "awsRegion=$AWS_REGION" \
    --set "rbac.serviceAccount.create=true" \
    --set "rbac.serviceAccount.name=cluster-autoscaler" \
    --set "rbac.serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$IAM_ROLE_ARN" \
    --set "replicaCount=1" \
    --set "extraArgs.balance-similar-node-groups=true" \
    --set "extraArgs.expander=least-waste" \
    --set "extraArgs.skip-nodes-with-local-storage=false" \
    --set "extraArgs.skip-nodes-with-system-pods=false" \
    --wait \
    --timeout 5m

echo "Cluster Autoscaler installed."

# ------------------------------------------------------------
# Verify Cluster Autoscaler
# ------------------------------------------------------------

echo ""
echo "[9/9] Verifying Cluster Autoscaler..."

kubectl rollout status deployment/cluster-autoscaler \
    -n "$AUTOSCALER_NAMESPACE" \
    --timeout=180s

kubectl get deployment cluster-autoscaler \
    -n "$AUTOSCALER_NAMESPACE"

kubectl get pods \
    -n "$AUTOSCALER_NAMESPACE" \
    -l app.kubernetes.io/name=cluster-autoscaler

# ------------------------------------------------------------
# Cleanup temporary IAM files
# ------------------------------------------------------------

rm -f /tmp/cluster-autoscaler-trust-policy.json
rm -f /tmp/cluster-autoscaler-policy.json

echo ""
echo "============================================================"
echo " CLUSTER AUTOSCALER SETUP COMPLETED"
echo "============================================================"

echo ""
echo "Cluster              : $CLUSTER_NAME"
echo "AWS Region            : $AWS_REGION"
echo "Kubernetes Version    : $K8S_VERSION"
echo "Autoscaler Chart      : $AUTOSCALER_CHART_VERSION"
echo "IAM Role              : $IAM_ROLE_NAME"
echo ""
echo "SUCCESS: Cluster Autoscaler is ready."