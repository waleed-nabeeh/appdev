#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIST_FILE=${1:-"${SCRIPT_DIR}/../../mirror/customer-scope-images.csv"}
TARGET_REGISTRY=${TARGET_REGISTRY:-quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa}
AUTH_FILE=${REGISTRY_AUTH_FILE:-"${HOME}/.config/containers/customer-auth.json"}

command -v podman >/dev/null || {
  echo "ERROR: podman is required." >&2
  exit 1
}

[[ -f "${LIST_FILE}" ]] || {
  echo "ERROR: image list not found: ${LIST_FILE}" >&2
  exit 1
}

[[ -f "${AUTH_FILE}" ]] || {
  echo "ERROR: registry auth file not found: ${AUTH_FILE}" >&2
  echo "Run scripts/mirror/prepare-registry-auth.sh first." >&2
  exit 1
}

total=$(awk 'NR > 1 && NF {count++} END {print count+0}' "${LIST_FILE}")
current=0

while IFS=, read -r source target; do
  [[ "${source}" == "source_image" || -z "${source}" ]] && continue
  current=$((current + 1))
  echo "[${current}/${total}] ${source}"
  podman pull --authfile "${AUTH_FILE}" "${source}"
  podman tag "${source}" "${target}"
  podman push --authfile "${AUTH_FILE}" "${target}"
done < "${LIST_FILE}"

echo "Completed: ${total} images pushed to ${TARGET_REGISTRY}/devops"
