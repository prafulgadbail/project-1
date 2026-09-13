#!/bin/bash

set -euo pipefail

# ============================================================
# CHANGE ONLY THESE VALUES
# ============================================================

CLUSTER_NAME="prod-cluster"
AWS_REGION="us-east-1"
SECRET_NAME="prod/mariadb"

IAM_POLICY_NAME="EKSExternalSecretsManagerPolicy"
IAM_ROLE_NAME="EKSExternalSecretsManagerRole"

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
    --output text)

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${IAM_POLICY_NAME}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${IAM_ROLE_NAME}"

echo "AWS Account : $ACCOUNT_ID"
echo "Cluster     : $CLUSTER_NAME"
echo "Region      : $AWS_REGION"
echo "Secret      : $SECRET_NAME"

# ------------------------------------------------------------
# Configure kubectl for the selected EKS cluster
# ------------------------------------------------------------

echo ""
echo "[1/7] Updating kubeconfig..."

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
echo "[2/7] Checking Secrets Manager secret..."

SECRET_ARN=$(aws secretsmanager describe-secret \
    --region "$AWS_REGION" \
    --secret-id "$SECRET_NAME" \
    --query 'ARN' \
    --output text \
    --no-cli-pager)

echo "Secret ARN: $SECRET_ARN"

# ------------------------------------------------------------
# Create IAM policy only if it does not exist
# ------------------------------------------------------------

echo ""
echo "[3/7] Checking IAM Policy..."

if aws iam get-policy \
    --policy-arn "$POLICY_ARN" \
    --no-cli-pager >/dev/null 2>&1; then

    echo "IAM Policy already exists. Skipping."

else

    echo "Creating IAM Policy..."

    POLICY_DOCUMENT=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ReadSecretsManagerSecret",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "$SECRET_ARN"
    }
  ]
}
EOF
)

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
echo "[4/7] Checking EKS Pod Identity Agent..."

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

    echo "Pod Identity Agent installation started."

fi

# ------------------------------------------------------------
# Wait for Pod Identity Agent
# ------------------------------------------------------------

aws eks wait addon-active \
    --cluster-name "$CLUSTER_NAME" \
    --addon-name eks-pod-identity-agent \
    --region "$AWS_REGION"

echo "Pod Identity Agent is ACTIVE."

# ------------------------------------------------------------
# Create IAM Role only if it does not exist
# ------------------------------------------------------------

echo ""
echo "[5/7] Checking IAM Role..."

if aws iam get-role \
    --role-name "$IAM_ROLE_NAME" \
    --no-cli-pager >/dev/null 2>&1; then

    echo "IAM Role already exists. Skipping."

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
# Attach policy only if it is not already attached
# ------------------------------------------------------------

if aws iam list-attached-role-policies \
    --role-name "$IAM_ROLE_NAME" \
    --query "AttachedPolicies[?PolicyArn=='$POLICY_ARN'].PolicyArn" \
    --output text \
    --no-cli-pager | grep -q "$POLICY_ARN"; then

    echo "IAM Policy already attached."

else

    echo "Attaching IAM Policy..."

    aws iam attach-role-policy \
        --role-name "$IAM_ROLE_NAME" \
        --policy-arn "$POLICY_ARN"

    echo "IAM Policy attached."

fi

# ------------------------------------------------------------
# Install or verify External Secrets Operator
# ------------------------------------------------------------

echo ""
echo "[6/7] Checking External Secrets Operator..."

helm repo add external-secrets \
    https://charts.external-secrets.io >/dev/null 2>&1 || true

helm repo update >/dev/null 2>&1

helm upgrade --install external-secrets \
    external-secrets/external-secrets \
    --namespace external-secrets \
    --create-namespace \
    --wait \
    --timeout 5m

echo "External Secrets Operator is READY."

# ------------------------------------------------------------
# Create Pod Identity association only if it does not exist
# ------------------------------------------------------------

echo ""
echo "[7/7] Checking Pod Identity association..."

ASSOCIATION_ID=$(aws eks list-pod-identity-associations \
    --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --query "associations[?namespace=='external-secrets' && serviceAccount=='external-secrets'].associationId | [0]" \
    --output text \
    --no-cli-pager)

if [ -n "$ASSOCIATION_ID" ] && [ "$ASSOCIATION_ID" != "None" ]; then

    echo "Pod Identity association already exists."
    echo "Association ID: $ASSOCIATION_ID"

else

    echo "Creating Pod Identity association..."

    aws eks create-pod-identity-association \
        --cluster-name "$CLUSTER_NAME" \
        --region "$AWS_REGION" \
        --role-arn "$ROLE_ARN" \
        --namespace external-secrets \
        --service-account external-secrets \
        --no-cli-pager

    echo "Pod Identity association created."

fi

# ------------------------------------------------------------
# Final verification
# ------------------------------------------------------------

echo ""
echo "============================================================"
echo " SETUP COMPLETED SUCCESSFULLY"
echo "============================================================"

kubectl get pods -n external-secrets

echo ""
echo "IAM Policy : $POLICY_ARN"
echo "IAM Role   : $ROLE_ARN"
echo "Secret     : $SECRET_NAME"

echo ""
echo "Next: SecretStore + ExternalSecret manifests."