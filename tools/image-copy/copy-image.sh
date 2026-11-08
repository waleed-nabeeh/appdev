#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: $0 SOURCE_IMAGE TARGET_IMAGE AUTHFILE [--src-tls-verify=false] [--dest-tls-verify=false] [--debug] [--command-timeout=60s]" >&2
  exit 2
fi

source_image="$1"
target_image="$2"
authfile="$3"
shift 3

skopeo_args=(skopeo)
copy_args=(copy --retry-times 3 --authfile "$authfile")
for option in "$@"; do
  case "$option" in
    --src-tls-verify=false|--dest-tls-verify=false)
      copy_args+=("$option")
      ;;
    --debug)
      skopeo_args+=("$option")
      ;;
    --command-timeout=*)
      if [[ ! "$option" =~ ^--command-timeout=[1-9][0-9]*(s|m|h)$ ]]; then
        echo "Use a positive timeout such as --command-timeout=60s or --command-timeout=10m" >&2
        exit 2
      fi
      skopeo_args+=("$option")
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

echo "Starting Skopeo copy..."
"${skopeo_args[@]}" "${copy_args[@]}" \
  "docker://${source_image}" \
  "docker://${target_image}"

echo "Image copied. Inspect the destination to confirm its digest before use."
