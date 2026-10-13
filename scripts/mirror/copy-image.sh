#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: bash $0 SOURCE_IMAGE TARGET_IMAGE AUTH_FILE" >&2
  exit 2
fi
command -v skopeo >/dev/null
[[ -s "$3" ]] || { echo "Auth file missing or empty" >&2; exit 1; }
skopeo copy --all --preserve-digests --authfile "$3" \
  "docker://${1#docker://}" "docker://${2#docker://}"
