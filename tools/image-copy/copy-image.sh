#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 SOURCE_IMAGE TARGET_IMAGE AUTHFILE [--src-tls-verify=false] [--dest-tls-verify=false]" >&2
  exit 2
fi

source_image="$1"
target_image="$2"
authfile="$3"
shift 3

copy_args=(copy --retry-times 3 --authfile "$authfile")
for option in "$@"; do
  case "$option" in
    --src-tls-verify=false|--dest-tls-verify=false)
      copy_args+=("$option")
      ;;
    *)
      echo "Unknown option: $option" >&2
      exit 2
      ;;
  esac
done

test -r "$authfile" || {
  echo "Auth file is not readable: $authfile" >&2
  exit 1
}

skopeo "${copy_args[@]}" \
  "docker://${source_image}" \
  "docker://${target_image}"

echo "Image copied. Inspect the destination to confirm its digest before use."
