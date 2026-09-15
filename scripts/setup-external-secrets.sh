# Connect Kubernetes to AWS Secrets Manager
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: aws-secrets-manager
  namespace: student-app

spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1

---

# Sync database credentials from AWS Secrets Manager
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: mariadb-external-secret
  namespace: student-app

spec:
  # Check AWS Secrets Manager for changes every hour
  refreshInterval: 1h

  # Use the AWS Secrets Manager SecretStore
  secretStoreRef:
    name: aws-secrets-manager
    kind: SecretStore

  # Create the Kubernetes Secret used by the backend Deployment
  target:
    name: mariadb-secret
    creationPolicy: Owner

  # Copy all key-value pairs from the AWS secret
  dataFrom:
    - extract:
        key: prod/mariadb