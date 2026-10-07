#!/usr/bin/env bash
set -Eeuo pipefail

AUTH_FILE=${REGISTRY_AUTH_FILE:-"${HOME}/.config/containers/customer-auth.json"}
SOURCE_REGISTRIES=(registry.redhat.io registry.connect.redhat.com)
TARGET_REGISTRY=quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa

command -v podman >/dev/null || {
  echo "ERROR: podman is required." >&2
  exit 1
}

mkdir -p "$(dirname "${AUTH_FILE}")"
touch "${AUTH_FILE}"
chmod 600 "${AUTH_FILE}"

read -r -p "Red Hat registry username: " REDHAT_USERNAME
read -r -s -p "Red Hat registry token/password: " REDHAT_PASSWORD
echo

for registry in "${SOURCE_REGISTRIES[@]}"; do
  printf '%s' "${REDHAT_PASSWORD}" | podman login \
    --authfile "${AUTH_FILE}" \
    --username "${REDHAT_USERNAME}" \
    --password-stdin \
    "${registry}"
done
unset REDHAT_PASSWORD

read -r -p "Internal Quay username: " QUAY_USERNAME
read -r -s -p "Internal Quay password/token: " QUAY_PASSWORD
echo

printf '%s' "${QUAY_PASSWORD}" | podman login \
  --authfile "${AUTH_FILE}" \
  --username "${QUAY_USERNAME}" \
  --password-stdin \
  "${TARGET_REGISTRY}"
unset QUAY_PASSWORD

chmod 600 "${AUTH_FILE}"
echo "Registry authentication saved to ${AUTH_FILE} with mode 0600."
echo "Do not copy this file into Git."
