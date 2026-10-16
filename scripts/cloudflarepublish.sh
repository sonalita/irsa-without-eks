#!/bin/bash

# OPTIONAL: publishes the cluster's OIDC discovery document and JWKS to an existing Cloudflare
# Pages project so AWS STS can validate service-account tokens (AssumeRoleWithWebIdentity).
# Public keys only. This is an alternative to publishing the oidc-*.json files by hand.
#
# Re-run only if the service-account signing key (/etc/kubernetes/pki/sa.*) rotates.
# Needs: kubectl, jq, curl, wrangler (npm i -g wrangler), and an existing Cloudflare Pages
# project with OIDC_HOST attached as a custom domain and its production branch set to "main".
#
# Usage: cloudflarepublish.sh [--build-only] [--debug]
#   --build-only  generate the files without deploying
#   --debug       trace the script (set -x)

set -o pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

OUT_DIR="${OUT_DIR:-$(mktemp -d)}"
DEBUG=false
BUILD_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            DEBUG=true
            shift
            ;;
        --build-only)
            BUILD_ONLY=true
            shift
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

require_vars OIDC_HOST CLUSTER_NAME
if ! "$BUILD_ONLY"; then
    require_vars CLOUDFLARE_PAGES_PROJECT
fi

# check required tooling
for tool in kubectl jq curl wrangler; do
    if ! command -v "$tool" &> /dev/null; then
        echo "Error: $tool is not installed." >&2
        exit 1
    fi
done

if "$DEBUG"; then
    set -x
fi

mkdir -p "$OUT_DIR/.well-known" "$OUT_DIR/openid/v1"

cat > "$OUT_DIR/index.html" <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OIDC issuer</title>
</head>
<body>
  <h1>OIDC issuer</h1>
  <p>This site publishes the public OIDC metadata and signing keys used by AWS.</p>
  <ul>
    <li><a href="/.well-known/openid-configuration">OIDC discovery document</a></li>
    <li><a href="/openid/v1/jwks">Public signing keys (JWKS)</a></li>
  </ul>
</body>
</html>
HTML

echo "Fetching JWKS from apiserver..."

# Default to the kind context for this cluster; override with KUBE_CONTEXT in .env
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-$CLUSTER_NAME}"

if ! kubectl --context "$KUBE_CONTEXT" get --raw /openid/v1/jwks | jq . > "$OUT_DIR/openid/v1/jwks"; then
    echo "Error: failed to fetch JWKS from context '$KUBE_CONTEXT'." >&2
    exit 1
fi

echo "Building discovery document for https://${OIDC_HOST}..."
if ! kubectl --context "$KUBE_CONTEXT" get --raw /.well-known/openid-configuration \
    | jq --arg iss "https://${OIDC_HOST}" \
        '.issuer = $iss | .jwks_uri = ($iss + "/openid/v1/jwks")' \
    > "$OUT_DIR/.well-known/openid-configuration"; then
    echo "Error: failed to build the discovery document from context '$KUBE_CONTEXT'." >&2
    exit 1
fi

for f in openid/v1/jwks .well-known/openid-configuration; do
    if [[ ! -s "$OUT_DIR/$f" ]]; then
        echo "Error: $OUT_DIR/$f is empty." >&2
        exit 1
    fi
done

cat > "$OUT_DIR/_headers" <<HEADERS
/.well-known/openid-configuration
  Content-Type: application/json
/openid/v1/jwks
  Content-Type: application/json
HEADERS

echo "Generated files in $OUT_DIR:"
(cd "$OUT_DIR" && find . -type f | sort)

if "$BUILD_ONLY"; then
    echo "--build-only: not deploying."
    exit 0
fi

# wrangler whoami exits 0 even when logged out, so check its output.
# Only log out on exit if this script did the login.
if wrangler whoami 2>&1 | grep -qi "not authenticated"; then
    wrangler login || exit 1
    trap 'wrangler logout' EXIT
fi

read -r -p "Deploy to Cloudflare Pages project '$CLOUDFLARE_PAGES_PROJECT'? [y/N] " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Aborted."
    exit 1
fi

wrangler pages deploy "$OUT_DIR" --project-name "$CLOUDFLARE_PAGES_PROJECT" --branch main

echo "Verifying..."
curl -sf "https://${OIDC_HOST}/" > /dev/null || { echo "Error: https://${OIDC_HOST}/ unreachable. Is it attached to the Pages project as a custom domain?" >&2; exit 1; }
curl -sf "https://${OIDC_HOST}/.well-known/openid-configuration" | jq .
curl -sf "https://${OIDC_HOST}/openid/v1/jwks" | jq .

echo "Done."
