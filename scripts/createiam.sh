#!/bin/bash

# Creates the IAM OIDC provider, the parameter-store-read-role (trusted by the
# aws-parameter-store service account via the provider) and a test parameter.
# Requires the cluster's OIDC documents to already be published at https://${OIDC_HOST}.

set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
require_vars AWS_ACCOUNT_NUMBER AWS_PROFILE AWS_REGION CLUSTER_NAME OIDC_HOST
export AWS_DEFAULT_REGION=$AWS_REGION

ROLE_NAME=parameter-store-read-role
PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_NUMBER}:oidc-provider/${OIDC_HOST}"
PARAMETER_PREFIX="/${CLUSTER_NAME}"

if ! CALLER_ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2> /dev/null); then
    echo "Error: AWS credentials are not configured or invalid. Please use 'aws sso login --profile $AWS_PROFILE' or provide credentials." >&2
    exit 1
fi

if [[ "$CALLER_ACCOUNT" != "$AWS_ACCOUNT_NUMBER" ]]; then
    echo "Error: profile '$AWS_PROFILE' is in account $CALLER_ACCOUNT but AWS_ACCOUNT_NUMBER is $AWS_ACCOUNT_NUMBER." >&2
    exit 1
fi

# Validate that discovery and public key files can be retrieved from the OIDC_HOST domain
for path in .well-known/openid-configuration openid/v1/jwks; do
    if ! curl -sf "https://${OIDC_HOST}/${path}" > /dev/null; then
        echo "Error: Unable to retrieve https://${OIDC_HOST}/${path}. Please ensure the file is published and the OIDC_HOST variable is set correctly." >&2
        exit 1
    fi
done

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Trust policy: only the aws-parameter-store service account, with the STS audience, may assume the role
cat > "$WORK_DIR/trust-policy.json" <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Federated": "${PROVIDER_ARN}"
            },
            "Action": "sts:AssumeRoleWithWebIdentity",
            "Condition": {
                "StringEquals": {
                    "${OIDC_HOST}:aud": "sts.amazonaws.com",
                    "${OIDC_HOST}:sub": "system:serviceaccount:external-secrets:aws-parameter-store"
                }
            }
        }
    ]
}
POLICY

# Parameter store read policy for the role, including kms permissions for the default SSM key
cat > "$WORK_DIR/parameter-store-read-policy.json" <<POLICY
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ssm:GetParameter",
                "ssm:GetParameters",
                "ssm:GetParametersByPath"
            ],
            "Resource": "arn:aws:ssm:${AWS_REGION}:${AWS_ACCOUNT_NUMBER}:parameter${PARAMETER_PREFIX}/*"
        },
        {
            "Effect": "Allow",
            "Action": "kms:Decrypt",
            "Resource": "arn:aws:kms:${AWS_REGION}:${AWS_ACCOUNT_NUMBER}:key/*",
            "Condition": {
                "ForAnyValue:StringEquals": {
                    "kms:ResourceAliases": "alias/aws/ssm"
                },
                "StringLike": {
                    "kms:ViaService": "ssm.${AWS_REGION}.amazonaws.com"
                }
            }
        }
    ]
}
POLICY

# Create the IAM OIDC provider for the cluster
# (no thumbprint: AWS validates publicly trusted CAs, such as Cloudflare's, itself)
echo "Creating IAM OIDC provider for https://${OIDC_HOST}..."
if aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$PROVIDER_ARN" &> /dev/null; then
    echo "IAM OIDC provider $PROVIDER_ARN already exists, skipping."
else
    aws iam create-open-id-connect-provider \
        --url "https://${OIDC_HOST}" \
        --client-id-list sts.amazonaws.com
    echo "IAM OIDC provider created for https://${OIDC_HOST}"
fi

echo "Creating IAM role '$ROLE_NAME' with trust policy for aws-parameter-store service account. This may take a couple of minutes..."
# Create (or update) the IAM role, and attach the parameter-store-read policy
if aws iam get-role --role-name "$ROLE_NAME" &> /dev/null; then
    aws iam update-assume-role-policy \
        --role-name "$ROLE_NAME" \
        --policy-document "file://$WORK_DIR/trust-policy.json"
    echo "IAM role '$ROLE_NAME' already exists, trust policy updated."
else
    aws iam create-role \
        --role-name "$ROLE_NAME" \
        --assume-role-policy-document "file://$WORK_DIR/trust-policy.json" > /dev/null
    echo "IAM role '$ROLE_NAME' created."
fi
aws iam put-role-policy \
    --role-name "$ROLE_NAME" \
    --policy-name parameter-store-read-policy \
    --policy-document "file://$WORK_DIR/parameter-store-read-policy.json"
echo "Policy 'parameter-store-read-policy' attached to '$ROLE_NAME'."

# Create a test secret in parameter store for testing only
aws ssm put-parameter \
    --name "${PARAMETER_PREFIX}/test-secret" \
    --value "This is a test secret value" \
    --type SecureString \
    --key-id alias/aws/ssm \
    --overwrite > /dev/null
echo "Test secret created in Parameter Store at ${PARAMETER_PREFIX}/test-secret"

echo "Role ARN: arn:aws:iam::${AWS_ACCOUNT_NUMBER}:role/${ROLE_NAME}"
