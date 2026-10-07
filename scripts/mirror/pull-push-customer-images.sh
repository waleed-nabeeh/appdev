#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
LIST_FILE=${1:-"${SCRIPT_DIR}/../../mirror/customer-scope-images.csv"}
TARGET_REGISTRY=${TARGET_REGISTRY:-quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa}

command -v podman >/dev/null || {
  echo "ERROR: podman is required." >&2
  exit 1
}

[[ -f "${LIST_FILE}" ]] || {
  echo "ERROR: image list not found: ${LIST_FILE}" >&2
  exit 1
}

echo "Log in to the source registries before starting when credentials are required:"
echo "  podman login registry.redhat.io"
echo "  podman login registry.connect.redhat.com"
echo
echo "Logging in to ${TARGET_REGISTRY}"
podman login "${TARGET_REGISTRY}"

total=$(awk 'NR > 1 && NF {count++} END {print count+0}' "${LIST_FILE}")
current=0

while IFS=, read -r source target; do
  [[ "${source}" == "source_image" || -z "${source}" ]] && continue
  current=$((current + 1))
  echo "[${current}/${total}] ${source}"
  podman pull "${source}"
  podman tag "${source}" "${target}"
  podman push "${target}"
done < "${LIST_FILE}"

echo "Completed: ${total} images pushed to ${TARGET_REGISTRY}/devops"
