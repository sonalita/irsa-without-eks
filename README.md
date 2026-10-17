# IRSA with a kind cluster

This repository demonstrates using IAM Roles for Service Accounts (OIDC federation) from a local `Kind` cluster to read encrypted strings from AWS Parameter Store for free.

> [!TIP]
> There's a full walkthrough of the idea and each step in the accompanying article: [EKS-Style IAM Roles on Any Kubernetes Cluster — Without EKS](https://medium.com/@steve.atkinson_15525/eks-style-iam-roles-on-any-kubernetes-cluster-without-eks-33bc39c3a3c6).

## Motivation

In my homelab, `cert-manager` issues TLS certificates for `Traefik` from Let's Encrypt using `DNS-01` challenges. That requires a Cloudflare API token to be available in the cluster as a Kubernetes secret.

I originally managed that secret with `sealed-secrets`, but it is awkward in a fully declarative, GitOps-driven setup: the encrypted values live in git, are tied to the cluster's sealing key, and have to be re-sealed whenever the cluster is rebuilt.

A better fit is to keep the secret in AWS Parameter Store and have `external-secrets` sync it into the cluster, so git only holds references. That raises a bootstrap problem: the cluster needs AWS credentials to read the parameter, and those credentials would themselves be a long-lived secret to store somewhere.

IAM Roles for Service Accounts (IRSA) solves this. Kubernetes signs service account tokens (JWTs) with the cluster's own key. If the cluster's OIDC discovery document and public keys are published at a public HTTPS URL, AWS IAM can be configured to trust that URL as an OIDC identity provider and exchange those tokens for short-lived credentials. No AWS access keys are stored in the cluster, and this works on a local or self-hosted cluster, not just EKS. Parameter Store's standard tier is free, so the whole setup costs nothing.

> [!NOTE]
> This repository uses a throwaway `kind` cluster to demonstrate the technique end to end, rather than my actual homelab.

## This is a demonstration

> [!WARNING]
> The shell scripts here exist to make each step visible and easy to follow while learning. They are not how you would run this in practice.

In a real environment you would:

- Define the AWS resources (IAM OIDC provider, roles, policies, SSM parameters) as infrastructure as code, for example with Terraform or OpenTofu.
- Deploy external-secrets and its `SecretStore`/`ExternalSecret` resources through GitOps, for example with Flux or Argo CD, so the cluster state is declared in git and reconciled continuously.
- Never put real secrets in the repository. External-secrets exists so that secret values stay in Parameter Store and only references are in git.

## Prerequisites

- An AWS account and an AWS CLI profile (SSO or otherwise) with permission to create IAM and SSM resources. Everything here is free tier or no-cost. The AWS resources created are:
  - an IAM OIDC provider
  - an IAM role with a policy to read Parameter Store keys, and a trust relationship for the cluster's `aws-parameter-store` service account via the OIDC provider
  - one test `SecureString` parameter in Parameter Store, `/${CLUSTER_NAME}/test-secret`
- The following installed on your machine:
  - `docker` or `podman` to host the kind Kubernetes cluster (for podman, set `KIND_EXPERIMENTAL_PROVIDER=podman`)
  - `kind`, `kubectl` and `helm` for creating and managing a test Kubernetes cluster
  - `aws` (AWS CLI v2), `curl` and `jq`
  - Optional, to publish with Cloudflare Pages: `nodejs` and `wrangler` (`npm i -g wrangler`)
- A publicly reachable HTTPS domain that will host two OIDC files, for example a Cloudflare Pages project with a custom domain.
  - For Cloudflare Pages: create the project (`wrangler pages project create <name> --production-branch main`) and attach your `OIDC_HOST` to it as a custom domain in the Cloudflare dashboard (Pages project → Custom domains).

## Setup

```bash
cp .env.example .env
# edit .env with your own values
```

`.env` is gitignored; only non-secret configuration belongs in it.

## Scripts

All scripts read their configuration from `.env` via `scripts/common.sh`.

1. `scripts/createcluster.sh` – create the kind cluster and export its OIDC documents.
2. `scripts/cloudflarepublish.sh` – optional: publish the OIDC discovery document and keys to Cloudflare Pages. Use `--build-only` to generate the files without deploying.
3. `scripts/createiam.sh` – create the IAM OIDC provider, role, policy and a test parameter.
4. `scripts/external-secrets.sh` – deploy external-secrets, create its service account, and configure it to read the test parameter.

## Steps to build the example

1. Populate your `.env` file.
2. Run `scripts/createcluster.sh`. This writes `oidc-discovery-document.json` and `oidc-jwks.json` to the repo root.
3. Publish the OIDC documents so they are publicly reachable at:
   - `https://${OIDC_HOST}/.well-known/openid-configuration`
   - `https://${OIDC_HOST}/openid/v1/jwks`

   Either upload the two files yourself, or run `scripts/cloudflarepublish.sh`.
4. Log in to AWS (for example `aws sso login --profile <your profile>`) and run `scripts/createiam.sh`.
5. Run `scripts/external-secrets.sh`.

## Cleanup

```bash
set -a; source .env; set +a

export AWS_DEFAULT_REGION="$AWS_REGION"

aws ssm delete-parameter --name "/${CLUSTER_NAME}/test-secret"
aws iam delete-role-policy --role-name parameter-store-read-role --policy-name parameter-store-read-policy
aws iam delete-role --role-name parameter-store-read-role
aws iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:aws:iam::${AWS_ACCOUNT_NUMBER}:oidc-provider/${OIDC_HOST}"
kind delete cluster --name "$CLUSTER_NAME"
```

Remove the Cloudflare Pages project in the dashboard if you no longer need it.

## References

Installation and background links for the tools used here.

### Tooling

- Container runtime: [Docker](https://docs.docker.com/engine/install/) or [Podman](https://podman.io/docs/installation)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [Helm](https://helm.sh/docs/intro/install/)
- [AWS CLI v2](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html), and [configuring SSO](https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-sso.html) for `aws sso login`
- [curl](https://curl.se/download.html) and [jq](https://jqlang.github.io/jq/download/)
- Optional, for Cloudflare Pages: [Node.js](https://nodejs.org/en/download), [Wrangler](https://developers.cloudflare.com/workers/wrangler/install-and-update/), [Pages](https://developers.cloudflare.com/pages/) and [custom domains](https://developers.cloudflare.com/pages/configuration/custom-domains/)

### How it works

- Kubernetes: [Service account issuer discovery](https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/#service-account-issuer-discovery)
- AWS: [Creating an OIDC identity provider in IAM](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc.html) and [Parameter Store](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html)
- [external-secrets](https://external-secrets.io/) and its [AWS Parameter Store provider](https://external-secrets.io/latest/provider/aws-parameter-store/)

### Motivation and production setups

- [cert-manager DNS-01 challenges](https://cert-manager.io/docs/configuration/acme/dns01/), [Traefik](https://traefik.io/traefik) and [sealed-secrets](https://github.com/bitnami-labs/sealed-secrets)
- Infrastructure as code: [Terraform](https://developer.hashicorp.com/terraform) or [OpenTofu](https://opentofu.org/)
- GitOps: [Flux](https://fluxcd.io/) or [Argo CD](https://argo-cd.readthedocs.io/)

## Development

Scripts are linted with [ShellCheck](https://www.shellcheck.net/): `shellcheck -x scripts/*.sh` (configured by `.shellcheckrc`).
