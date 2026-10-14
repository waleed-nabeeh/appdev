#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 SOURCE_IMAGE TARGET_IMAGE AUTHFILE" >&2
  exit 2
fi

source_image="$1"
target_image="$2"
authfile="$3"

test -r "$authfile" || {
  echo "Auth file is not readable: $authfile" >&2
  exit 1
}

skopeo copy \
  --retry-times 3 \
  --authfile "$authfile" \
  "docker://${source_image}" \
  "docker://${target_image}"

echo "Image copied. Resolve and sign the immutable target digest before testing."
