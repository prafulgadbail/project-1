#!/bin/bash

set -Eeuo pipefail

# ============================================================
# CHANGE ONLY THESE VALUES
# ============================================================

CLUSTER_NAME="prod-cluster"
AWS_REGION="us-east-1"
SECRET_NAME="prod/mariadb"

# Cluster-specific IAM resources prevent projects/clusters
# from overwriting each other's Secrets Manager permissions.
IAM_POLICY_NAME="EKSExternalSecretsManagerPolicy-${CLUSTER_NAME}"
IAM_ROLE_NAME="EKSExternalSecretsManagerRole-${CLUSTER_NAME}"

ESO_NAMESPACE="external-secrets"
ESO_SERVICE_ACCOUNT="external-secrets"

# ============================================================
# DO NOT CHANGE BELOW THIS LINE
# ============================================================

echo "============================================================"
echo " External Secrets Operator Setup"
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
# Get AWS account ID dynamically
# ------------------------------------------------------------

ACCOUNT_ID=$(aws sts get-caller-identity \
    --query 'Account' \
    --output text \
    --no-cli-pager)

if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
    echo "ERROR: Unable to detect AWS Account ID."
    exit 1
fi

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

echo "AWS Account : $ACCOUNT_ID"
echo "Cluster     : $CLUSTER_NAME"
echo "Region      : $AWS_REGION"
echo "Secret      : $SECRET_NAME"
echo "IAM Policy  : $IAM_POLICY_NAME"
echo "IAM Role    : $IAM_ROLE_NAME"

# ------------------------------------------------------------
# Configure kubectl for the selected EKS cluster
# ------------------------------------------------------------

echo ""
echo "[1/8] Updating kubeconfig..."

aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --no-cli-pager

kubectl get nodes >/dev/null

echo "EKS connection OK."

# ------------------------------------------------------------
# Get Secrets Manager secret ARN dynamically
# ------------------------------------------------------------

echo ""
echo "[2/8] Checking Secrets Manager secret..."

SECRET_ARN=$(aws secretsmanager describe-secret \
    --region "$AWS_REGION" \
    --secret-id "$SECRET_NAME" \
    --query 'ARN' \
    --output text \
    --no-cli-pager)

if [[ -z "$SECRET_ARN" || "$SECRET_ARN" == "None" ]]; then
    echo "ERROR: Secrets Manager secret not found: $SECRET_NAME"
    exit 1
fi

echo "Secret ARN: $SECRET_ARN"

# ------------------------------------------------------------
# Create or update IAM policy
# Access is restricted to the required secret only.
# ------------------------------------------------------------

echo ""
echo "[3/8] Creating or updating IAM Policy..."

POLICY_DOCUMENT=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadRequiredSecret",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "${SECRET_ARN}"
    }
  ]
}
EOF
)

if aws iam get-policy \
    --policy-arn "$POLICY_ARN" \
    --no-cli-pager >/dev/null 2>&1; then

    echo "IAM Policy exists."

    # AWS IAM allows a maximum of 5 policy versions.
    # Remove the oldest non-default version when required.
    NON_DEFAULT_COUNT=$(aws iam list-policy-versions \
        --policy-arn "$POLICY_ARN" \
        --query 'length(Versions[?IsDefaultVersion==`false`])' \
        --output text \
        --no-cli-pager)

    if [[ "$NON_DEFAULT_COUNT" -ge 4 ]]; then

        OLDEST_VERSION=$(aws iam list-policy-versions \
            --policy-arn "$POLICY_ARN" \
            --query 'sort_by(Versions[?IsDefaultVersion==`false`], &CreateDate)[0].VersionId' \
            --output text \
            --no-cli-pager)

        echo "Deleting oldest policy version: $OLDEST_VERSION"

        aws iam delete-policy-version \
            --policy-arn "$POLICY_ARN" \
            --version-id "$OLDEST_VERSION" \
            --no-cli-pager
    fi

    aws iam create-policy-version \
        --policy-arn "$POLICY_ARN" \
        --policy-document "$POLICY_DOCUMENT" \
        --set-as-default \
        --no-cli-pager >/dev/null

    echo "IAM Policy updated."

else

    echo "IAM Policy not found. Creating..."

    aws iam create-policy \
        --policy-name "$IAM_POLICY_NAME" \
        --policy-document "$POLICY_DOCUMENT" \
        --no-cli-pager >/dev/null

    echo "IAM Policy created."
fi

# ------------------------------------------------------------
# Install EKS Pod Identity Agent if required
# ------------------------------------------------------------

echo ""
echo "[4/8] Checking EKS Pod Identity Agent..."

if aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name eks-pod-identity-agent \
    --region "$AWS_REGION" \
    --no-cli-pager >/dev/null 2>&1; then

    echo "Pod Identity Agent already exists."

else

    echo "Installing Pod Identity Agent..."

    aws eks create-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name eks-pod-identity-agent \
        --region "$AWS_REGION" \
        --no-cli-pager >/dev/null
fi

aws eks wait addon-active \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name eks-pod-identity-agent \
    --region "$AWS_REGION"

echo "Pod Identity Agent is ACTIVE."

# ------------------------------------------------------------
# Create IAM Role for External Secrets Operator
# ------------------------------------------------------------

echo ""
echo "[5/8] Checking IAM Role..."

if aws iam get-role \
    --role-name "$IAM_ROLE_NAME" \
    --no-cli-pager >/dev/null 2>&1; then

    echo "IAM Role already exists."

else

    echo "Creating IAM Role..."

    TRUST_POLICY='{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Sid": "AllowEKSPodIdentity",
          "Effect": "Allow",
          "Principal": {
            "Service": "pods.eks.amazonaws.com"
          },
          "Action": [
            "sts:AssumeRole",
            "sts:TagSession"
          ]
        }
      ]
    }'

    aws iam create-role \
        --role-name "$IAM_ROLE_NAME" \
        --assume-role-policy-document "$TRUST_POLICY" \
        --no-cli-pager >/dev/null

    echo "IAM Role created."
fi

# ------------------------------------------------------------
# Attach IAM Policy to the role
# ------------------------------------------------------------

echo ""
echo "[6/8] Ensuring IAM Policy is attached..."

if aws iam list-attached-role-policies \
    --role-name "$IAM_ROLE_NAME" \
    --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN'].PolicyArn" \
    --output text \
    --no-cli-pager | grep -Fq "$POLICY_ARN"; then

    echo "IAM Policy already attached."

else

    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn "$POLICY_ARN" \
        --no-cli-pager

    echo "IAM Policy attached."
fi

# ------------------------------------------------------------
# Create Pod Identity association BEFORE ESO installation
# ------------------------------------------------------------

echo ""
echo "[7/8] Checking Pod Identity association..."

ASSOCIATION_ID=$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query "associations[?namespace=='${ESO_NAMESPACE}' && serviceAccount=='${ESO_SERVICE_ACCOUNT}'].associationId | [0]" \
    --output text \
    --no-cli-pager)

if [[ -n "$ASSOCIATION_ID" && "$ASSOCIATION_ID" != "None" ]]; then

    echo "Pod Identity association already exists."
    echo "Association ID: $ASSOCIATION_ID"

else

    echo "Creating Pod Identity association..."

    aws eks create-pod-identity-association \
        --cluster-name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --role-arn "$ROLE_ARN" \
        --namespace "$ESO_NAMESPACE" \
        --service-account "$ESO_SERVICE_ACCOUNT" \
        --no-cli-pager >/dev/null

    echo "Pod Identity association created."
fi

# ------------------------------------------------------------
# Install or upgrade External Secrets Operator
# ------------------------------------------------------------

echo ""
echo "[8/8] Installing or upgrading External Secrets Operator..."

helm repo add external-secrets \
    https://charts.external-secrets.io \
    >/dev/null 2>&1 || true

helm repo update >/dev/null 2>&1

helm upgrade --install external-secrets \
    external-secrets/external-secrets \
    --namespace "$ESO_NAMESPACE" \
    --create-namespace \
    --wait \
    --timeout 5m

echo "External Secrets Operator installed/upgraded."

# ------------------------------------------------------------
# Verify ESO controller
# ------------------------------------------------------------

kubectl rollout status deployment/external-secrets \
    -n "$ESO_NAMESPACE" \
    --timeout=180s

echo ""
echo "ESO resources:"
kubectl get deployment -n "$ESO_NAMESPACE"

echo ""
echo "============================================================"
echo " EXTERNAL SECRETS OPERATOR SETUP COMPLETED"
echo "============================================================"

echo ""
echo "Cluster : $CLUSTER_NAME"
echo "Region  : $AWS_REGION"
echo "Secret  : $SECRET_NAME"
echo "Role    : $IAM_ROLE_NAME"
echo "Policy  : $IAM_POLICY_NAME"
echo ""
echo "SUCCESS: External Secrets Operator is ready."