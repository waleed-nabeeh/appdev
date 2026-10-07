#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
umask 077
AUTH_DIR=$(mktemp -d /tmp/registry-auth.XXXXXX)
export REGISTRY_AUTH_FILE="${AUTH_DIR}/auth.json"

# Both helpers inherit the same temporary credentials file.
trap 'rm -f -- "${REGISTRY_AUTH_FILE}"; rmdir -- "${AUTH_DIR}"' EXIT
export no_proxy="${no_proxy:-${NO_PROXY:-}}"
export no_proxy="${no_proxy:+${no_proxy},}quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa"
export NO_PROXY="${no_proxy}"

bash "${SCRIPT_DIR}/prepare-registry-auth.sh"
bash "${SCRIPT_DIR}/pull-push-customer-images.sh" "$@"
