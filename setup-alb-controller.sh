#!/bin/bash

set -Eeuo pipefail

# ============================================================
# CHANGE ONLY THESE 2 VALUES
# ============================================================
CLUSTER_NAME="prod-cluster"
REGION="us-east-1"

# ============================================================
# DO NOT CHANGE BELOW
# ============================================================

POLICY_NAME="AWSLoadBalancerControllerIAMPolicy"
ROLE_NAME="AmazonEKSLoadBalancerControllerRole"
SERVICE_ACCOUNT="aws-load-balancer-controller"
NAMESPACE="kube-system"

LBC_VERSION="v2.14.1"
HELM_VERSION="1.14.0"

IAM_TIMEOUT=90

POLICY_FILE="/tmp/aws-lbc-iam-policy.json"
TRUST_FILE="/tmp/aws-lbc-trust-policy.json"
EXISTING_TRUST_FILE="/tmp/aws-lbc-existing-trust.json"
UPDATED_TRUST_FILE="/tmp/aws-lbc-updated-trust.json"

trap 'echo; echo "ERROR: Script failed at line $LINENO"; exit 1' ERR

echo "=========================================="
echo " AWS Load Balancer Controller Setup"
echo "=========================================="
echo "Cluster : $CLUSTER_NAME"
echo "Region  : $REGION"
echo

# ------------------------------------------------------------
# CHECK REQUIRED COMMANDS
# ------------------------------------------------------------
for cmd in aws eksctl kubectl helm curl jq timeout; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: $cmd is not installed."
        exit 1
    fi
done

# ------------------------------------------------------------
# AWS ACCOUNT
# ------------------------------------------------------------
ACCOUNT_ID=$(aws sts get-caller-identity \
    --query Account \
    --output text \
    --no-cli-pager)

if [[ -z "$ACCOUNT_ID" || "$ACCOUNT_ID" == "None" ]]; then
    echo "ERROR: Unable to detect AWS Account ID."
    exit 1
fi

echo "Account : $ACCOUNT_ID"

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/${POLICY_NAME}"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"

# ------------------------------------------------------------
# CHECK EKS CLUSTER
# ------------------------------------------------------------
echo
echo "==> Checking EKS cluster..."

CLUSTER_STATUS=$(aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.status' \
    --output text \
    --no-cli-pager)

if [[ "$CLUSTER_STATUS" != "ACTIVE" ]]; then
    echo "ERROR: EKS cluster status is $CLUSTER_STATUS"
    echo "Cluster must be ACTIVE."
    exit 1
fi

echo "EKS cluster is ACTIVE."

# ------------------------------------------------------------
# GET VPC ID FROM EKS CLUSTER
# This avoids depending on EC2 Instance Metadata (IMDS).
# VPC ID is detected dynamically - nothing is hardcoded.
# ------------------------------------------------------------
echo
echo "==> Detecting VPC ID from EKS cluster..."

VPC_ID=$(aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.resourcesVpcConfig.vpcId' \
    --output text \
    --no-cli-pager)

if [[ -z "$VPC_ID" || "$VPC_ID" == "None" ]]; then
    echo "ERROR: Unable to detect VPC ID from EKS cluster."
    exit 1
fi

echo "VPC ID   : $VPC_ID"

# ------------------------------------------------------------
# KUBECONFIG
# ------------------------------------------------------------
echo
echo "==> Updating kubeconfig..."

aws eks update-kubeconfig \
    --region "$REGION" \
    --name "$CLUSTER_NAME"

# ------------------------------------------------------------
# OIDC
# ------------------------------------------------------------
echo
echo "==> Checking OIDC provider..."

OIDC_ISSUER=$(aws eks describe-cluster \
    --region "$REGION" \
    --name "$CLUSTER_NAME" \
    --query 'cluster.identity.oidc.issuer' \
    --output text \
    --no-cli-pager)

if [[ -z "$OIDC_ISSUER" || "$OIDC_ISSUER" == "None" ]]; then
    echo "ERROR: EKS cluster does not have an OIDC issuer."
    exit 1
fi

OIDC_PROVIDER="${OIDC_ISSUER#https://}"
OIDC_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"

if aws iam get-open-id-connect-provider \
    --open-id-connect-provider-arn "$OIDC_ARN" \
    --no-cli-pager >/dev/null 2>&1
then
    echo "OIDC provider already exists - reusing."
else
    echo "OIDC provider not found - creating..."

    eksctl utils associate-iam-oidc-provider \
        --region "$REGION" \
        --cluster "$CLUSTER_NAME" \
        --approve

    echo "OIDC provider created."
fi

# ------------------------------------------------------------
# IAM POLICY
# ------------------------------------------------------------
echo
echo "==> Checking IAM Policy..."

if aws iam get-policy \
    --policy-arn "$POLICY_ARN" \
    --no-cli-pager >/dev/null 2>&1
then
    echo "IAM Policy already exists - reusing."
else
    echo "IAM Policy not found - creating..."

    curl -fsSL \
        "https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/${LBC_VERSION}/docs/install/iam_policy.json" \
        -o "$POLICY_FILE"

    aws iam create-policy \
        --policy-name "$POLICY_NAME" \
        --policy-document "file://$POLICY_FILE" \
        --no-cli-pager

    echo "IAM Policy created."
fi

# ------------------------------------------------------------
# IAM ROLE
# ------------------------------------------------------------
echo
echo "==> Checking IAM Role..."

if aws iam get-role \
    --role-name "$ROLE_NAME" \
    --no-cli-pager >/dev/null 2>&1
then
    echo "IAM Role already exists - reusing."
else
    echo "IAM Role not found - creating..."

    cat > "$TRUST_FILE" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:${NAMESPACE}:${SERVICE_ACCOUNT}"
        }
      }
    }
  ]
}
JSON

    set +e

    timeout "$IAM_TIMEOUT" aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "file://$TRUST_FILE" \
        --no-cli-pager

    CREATE_ROLE_RC=$?

    set -e

    # If AWS created the role but CLI response timed out,
    # verify the role before deciding that creation failed.
    if aws iam get-role \
        --role-name "$ROLE_NAME" \
        --no-cli-pager >/dev/null 2>&1
    then
        echo "IAM Role exists - creation confirmed."
    else
        if [[ "$CREATE_ROLE_RC" -ne 0 ]]; then
            echo "ERROR: IAM Role creation failed."
            exit 1
        fi

        echo "ERROR: IAM Role was not found after creation."
        exit 1
    fi
fi

# ------------------------------------------------------------
# UPDATE TRUST POLICY
# Ensures the current EKS cluster can assume the IAM role.
# ------------------------------------------------------------
echo
echo "==> Ensuring current cluster is trusted by IAM Role..."

aws iam get-role \
    --role-name "$ROLE_NAME" \
    --query 'Role.AssumeRolePolicyDocument' \
    --output json \
    --no-cli-pager > "$EXISTING_TRUST_FILE"

jq \
    --arg oidc "$OIDC_ARN" \
    --arg provider "$OIDC_PROVIDER" \
    --arg namespace "$NAMESPACE" \
    --arg serviceaccount "$SERVICE_ACCOUNT" '
    .Version = "2012-10-17"
    |
    .Statement = (
        [
            .Statement[]
            |
            select(
                .Principal.Federated? != $oidc
            )
        ]
        +
        [
            {
                "Effect": "Allow",
                "Principal": {
                    "Federated": $oidc
                },
                "Action": "sts:AssumeRoleWithWebIdentity",
                "Condition": {
                    "StringEquals": {
                        ($provider + ":aud"): "sts.amazonaws.com",
                        ($provider + ":sub"):
                            ("system:serviceaccount:" + $namespace + ":" + $serviceaccount)
                    }
                }
            }
        ]
    )
' "$EXISTING_TRUST_FILE" > "$UPDATED_TRUST_FILE"

aws iam update-assume-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-document "file://$UPDATED_TRUST_FILE" \
    --no-cli-pager

echo "Trust policy ready for current cluster."

# ------------------------------------------------------------
# ATTACH POLICY
# ------------------------------------------------------------
echo
echo "==> Ensuring IAM Policy is attached..."

aws iam attach-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-arn "$POLICY_ARN" \
    --no-cli-pager

echo "IAM Policy attached."

# ------------------------------------------------------------
# SERVICE ACCOUNT
# ------------------------------------------------------------
echo
echo "==> Creating/updating Kubernetes ServiceAccount..."

kubectl create serviceaccount "$SERVICE_ACCOUNT" \
    --namespace "$NAMESPACE" \
    --dry-run=client \
    -o yaml |
kubectl apply -f -

kubectl annotate serviceaccount \
    "$SERVICE_ACCOUNT" \
    --namespace "$NAMESPACE" \
    "eks.amazonaws.com/role-arn=${ROLE_ARN}" \
    --overwrite

echo "ServiceAccount ready."

# ------------------------------------------------------------
# HELM REPOSITORY
# ------------------------------------------------------------
echo
echo "==> Updating Helm repository..."

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks

# ------------------------------------------------------------
# HELM INSTALL / UPGRADE
# Explicit VPC ID prevents controller from depending on EC2 IMDS.
# ------------------------------------------------------------
echo
echo "==> Installing/upgrading AWS Load Balancer Controller..."

helm upgrade --install aws-load-balancer-controller \
    eks/aws-load-balancer-controller \
    --namespace "$NAMESPACE" \
    --set clusterName="$CLUSTER_NAME" \
    --set serviceAccount.create=false \
    --set serviceAccount.name="$SERVICE_ACCOUNT" \
    --set region="$REGION" \
    --set vpcId="$VPC_ID" \
    --version "$HELM_VERSION" \
    --wait \
    --timeout 5m

# ------------------------------------------------------------
# VERIFY
# ------------------------------------------------------------
echo
echo "==> Verifying deployment..."

kubectl rollout status \
    deployment/aws-load-balancer-controller \
    --namespace "$NAMESPACE" \
    --timeout=180s

echo
echo "=========================================="
echo " ALB CONTROLLER SETUP COMPLETED"
echo "=========================================="
echo

kubectl get deployment \
    aws-load-balancer-controller \
    --namespace "$NAMESPACE"

echo

kubectl get pods \
    --namespace "$NAMESPACE" \
    -l app.kubernetes.io/name=aws-load-balancer-controller

echo

kubectl get serviceaccount \
    "$SERVICE_ACCOUNT" \
    --namespace "$NAMESPACE"

echo
echo "Cluster : $CLUSTER_NAME"
echo "Region  : $REGION"
echo "Account : $ACCOUNT_ID"
echo "VPC     : $VPC_ID"
echo
echo "SUCCESS: AWS Load Balancer Controller is ready."