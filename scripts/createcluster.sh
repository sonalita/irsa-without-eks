#!/bin/bash

# Creates the kind cluster with its service-account issuer set to https://${OIDC_HOST},
# then exports the cluster's OIDC discovery document and JWKS for publishing.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_vars CLUSTER_NAME OIDC_HOST

KUBE_CONTEXT="kind-$CLUSTER_NAME"

if kind get clusters 2> /dev/null | grep -qx "$CLUSTER_NAME"; then
    echo "Cluster '$CLUSTER_NAME' already exists, skipping creation."
else
    # Create the kind cluster with oidc token issuer
    kind create cluster --name "$CLUSTER_NAME" --config - <<KIND_CONFIG
---
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
kubeadmConfigPatches:
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        service-account-issuer: https://${OIDC_HOST}
        service-account-jwks-uri: https://${OIDC_HOST}/openid/v1/jwks
KIND_CONFIG
fi

# Extract the OIDC discovery document from the cluster and save it to a file
kubectl --context "$KUBE_CONTEXT" get --raw /.well-known/openid-configuration > "$REPO_ROOT/oidc-discovery-document.json"

# Extract the JWT public keys from the cluster and save them to a file
kubectl --context "$KUBE_CONTEXT" get --raw /openid/v1/jwks > "$REPO_ROOT/oidc-jwks.json"

echo "Publish $REPO_ROOT/oidc-discovery-document.json and $REPO_ROOT/oidc-jwks.json to your OIDC_HOST domain so that they are accessible at:"
echo "https://${OIDC_HOST}/.well-known/openid-configuration"
echo "https://${OIDC_HOST}/openid/v1/jwks"
echo "(or run scripts/cloudflarepublish.sh to publish them to Cloudflare Pages)"
