#!/bin/bash
set -Eeuo pipefail

# ============================================================
# CHANGE ONLY THESE VALUES
# ============================================================

CLUSTER_NAME="prod-cluster"
AWS_REGION="us-east-1"

# ============================================================
# DO NOT CHANGE BELOW THIS LINE
# ============================================================

echo "============================================================"
echo " EBS CSI Driver Setup"
echo "============================================================"

# ------------------------------------------------------------
# Check required commands
# ------------------------------------------------------------

for CMD in aws kubectl eksctl; do
    if ! command -v "$CMD" >/dev/null 2>&1; then
        echo "ERROR: $CMD is not installed."
        exit 1
    fi
done

# ------------------------------------------------------------
# Check AWS account access
# ------------------------------------------------------------

echo ""
echo "[1/6] Checking AWS access..."

aws sts get-caller-identity \
    --no-cli-pager >/dev/null

echo "AWS access OK."

# ------------------------------------------------------------
# Verify EKS cluster
# ------------------------------------------------------------

echo ""
echo "[2/6] Checking EKS cluster..."

aws eks describe-cluster \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --no-cli-pager >/dev/null

aws eks update-kubeconfig \
    --region "$AWS_REGION" \
    --name "$CLUSTER_NAME" \
    --no-cli-pager

kubectl get nodes >/dev/null

echo "EKS cluster connection OK."

# ------------------------------------------------------------
# Associate IAM OIDC provider
# ------------------------------------------------------------

echo ""
echo "[3/6] Configuring IAM OIDC provider..."

eksctl utils associate-iam-oidc-provider \
    --cluster "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --approve

echo "OIDC provider ready."

# ------------------------------------------------------------
# Install or upgrade AWS EBS CSI Driver
#
# The EBS CSI Driver is installed as an AWS managed EKS add-on.
# IAM permissions are attached using the recommended
# AmazonEBSCSIDriverPolicy.
# ------------------------------------------------------------

echo ""
echo "[4/6] Installing EBS CSI Driver..."

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

EBS_ROLE_NAME="EKS-EBS-CSI-DriverRole-${CLUSTER_NAME}"

# ------------------------------------------------------------
# Create IAM trust policy for EBS CSI Driver
# ------------------------------------------------------------

cat > /tmp/ebs-csi-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:aud": "sts.amazonaws.com",
          "${OIDC_PROVIDER}:sub": "system:serviceaccount:kube-system:ebs-csi-controller-sa"
        }
      }
    }
  ]
}
EOF

# ------------------------------------------------------------
# Create IAM role if it does not already exist
# ------------------------------------------------------------

if aws iam get-role \
    --role-name "$EBS_ROLE_NAME" \
    --no-cli-pager >/dev/null 2>&1; then

    echo "EBS CSI IAM role already exists."

else

    aws iam create-role \
        --role-name "$EBS_ROLE_NAME" \
        --assume-role-policy-document file:///tmp/ebs-csi-trust-policy.json \
        --description "IAM role for EKS EBS CSI Driver - ${CLUSTER_NAME}" \
        --no-cli-pager >/dev/null

    echo "EBS CSI IAM role created."
fi

# ------------------------------------------------------------
# Attach AWS managed EBS CSI policy
# ------------------------------------------------------------

aws iam attach-role-policy \
    --role-name "$EBS_ROLE_NAME" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy

EBS_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${EBS_ROLE_NAME}"

echo "EBS CSI IAM role ready."

# ------------------------------------------------------------
# Install or upgrade EBS CSI Driver add-on
# ------------------------------------------------------------

aws eks create-addon \
    --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --addon-name aws-ebs-csi-driver \
    --service-account-role-arn "$EBS_ROLE_ARN" \
    --resolve-conflicts OVERWRITE \
    --no-cli-pager \
    >/dev/null 2>&1 || \
aws eks update-addon \
    --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --addon-name aws-ebs-csi-driver \
    --service-account-role-arn "$EBS_ROLE_ARN" \
    --resolve-conflicts OVERWRITE \
    --no-cli-pager \
    >/dev/null

echo "EBS CSI Driver installed."

# ------------------------------------------------------------
# Wait for EBS CSI Driver
# ------------------------------------------------------------

echo ""
echo "[5/6] Waiting for EBS CSI Driver..."

aws eks wait addon-active \
    --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --addon-name aws-ebs-csi-driver

echo "EBS CSI Driver is ACTIVE."

# ------------------------------------------------------------
# Verify gp3 StorageClass
# ------------------------------------------------------------

echo ""
echo "[6/6] Checking gp3 StorageClass..."

if kubectl get storageclass gp3 >/dev/null 2>&1; then

    echo "gp3 StorageClass already exists."

else

    echo "Creating gp3 StorageClass..."

    cat <<EOF | kubectl apply -f -
# Default EBS gp3 StorageClass for persistent application data
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3

  # Make gp3 the default StorageClass
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"

# Use the AWS EBS CSI Driver
provisioner: ebs.csi.aws.com

# Create gp3 EBS volumes
parameters:
  type: gp3
  fsType: ext4

# Automatically create EBS volume when PVC is created
volumeBindingMode: WaitForFirstConsumer

# Delete the EBS volume when its PVC is deleted
reclaimPolicy: Delete
EOF

    echo "gp3 StorageClass created."
fi

# ------------------------------------------------------------
# Verify installation
# ------------------------------------------------------------

echo ""
echo "EBS CSI Add-on:"
aws eks describe-addon \
    --cluster-name "$CLUSTER_NAME" \
    --region "$AWS_REGION" \
    --addon-name aws-ebs-csi-driver \
    --query 'addon.status' \
    --output text \
    --no-cli-pager

echo ""
echo "Storage Classes:"
kubectl get storageclass

# ------------------------------------------------------------
# Cleanup
# ------------------------------------------------------------

rm -f /tmp/ebs-csi-trust-policy.json

echo ""
echo "============================================================"
echo " EBS CSI SETUP COMPLETED"
echo "============================================================"

echo ""
echo "Cluster       : $CLUSTER_NAME"
echo "Region        : $AWS_REGION"
echo "StorageClass  : gp3"
echo ""
echo "SUCCESS: EBS CSI Driver and gp3 StorageClass are ready."