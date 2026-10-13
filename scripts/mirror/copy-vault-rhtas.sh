#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
AUTH_FILE=${1:?Usage: bash copy-vault-rhtas.sh AUTH_FILE}
LIST=${2:-"${SCRIPT_DIR}/../../mirror/vault-rhtas-images.csv"}
while IFS=, read -r source target || [[ -n "${source}" ]]; do
  [[ -z "${source}" || "${source}" == source_image ]] && continue
  target=${target%$'\r'}
  bash "${SCRIPT_DIR}/copy-image.sh" "$source" "$target" "$AUTH_FILE"
done < "$LIST"
