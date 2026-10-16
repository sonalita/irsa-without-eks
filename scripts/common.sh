# shellcheck shell=bash
# Shared configuration, sourced by the other scripts. Not meant to be run directly.
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$REPO_ROOT/.env" ]]; then
    echo "Error: $REPO_ROOT/.env not found. Copy .env.example to .env and edit it." >&2
    exit 1
fi

# Export everything in .env so child processes (aws, kubectl, kind) see it
set -a
source "$REPO_ROOT/.env"
set +a

# Exit with a helpful message if any of the named variables is unset or empty
require_vars() {
    local missing=0 name
    for name in "$@"; do
        if [[ -z "${!name:-}" ]]; then
            echo "Error: $name is not set. Add it to $REPO_ROOT/.env" >&2
            missing=1
        fi
    done
    (( missing == 0 )) || exit 1
}
