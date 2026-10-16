#!/bin/bash

# Deploys `external-secrets` via Helm and configures a test secret from AWS Parameter Store

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_vars AWS_ACCOUNT_NUMBER AWS_REGION CLUSTER_NAME OIDC_HOST

# Default to the kind context for this cluster; override with KUBE_CONTEXT in .env
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-$CLUSTER_NAME}"

helm repo add external-secrets https://charts.external-secrets.io
helm repo update

echo "Deploying external-secrets to cluster ${CLUSTER_NAME}..."
helm upgrade --install external-secrets external-secrets/external-secrets \
  --kube-context "$KUBE_CONTEXT" \
  --namespace external-secrets \
  --create-namespace

echo "Waiting for pods to go ready..."
kubectl --context "$KUBE_CONTEXT" wait --for=condition=ready pod -l app.kubernetes.io/instance=external-secrets -n external-secrets --timeout=120s

echo "Creating service account for AWS access..."
kubectl --context "$KUBE_CONTEXT" apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: aws-parameter-store
  namespace: external-secrets
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${AWS_ACCOUNT_NUMBER}:role/parameter-store-read-role
EOF

echo "Creating secret store for AWS Parameter Store..."
kubectl --context "$KUBE_CONTEXT" apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: aws-parameter-store
  namespace: external-secrets
spec:
  provider:
    aws:
      service: ParameterStore
      region: ${AWS_REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: aws-parameter-store
EOF

echo "Creating secret from AWS Parameter Store..."
kubectl --context "$KUBE_CONTEXT" apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: demo-api-key
  namespace: external-secrets
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-parameter-store
    kind: SecretStore
  target:
    name: demo-api-key
    creationPolicy: Owner
  data:
    - secretKey: api-key
      remoteRef:
        key: /$CLUSTER_NAME/test-secret
EOF
