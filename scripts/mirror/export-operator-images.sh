#!/usr/bin/env bash
set -euo pipefail

OC_BIN="${OC_BIN:-oc}"
OUTPUT="${1:-mirror/operator-related-images.txt}"
packages=(
  openshift-gitops-operator
  openshift-pipelines-operator-rh
  rhtas-operator
  rhacs-operator
  quay-operator
)

csv_json="$("$OC_BIN" get csv -A -o json)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for package in "${packages[@]}"; do
  jq -r --arg package "$package" '
    .items
    | map(select(.metadata.name | startswith($package + ".v")))
    | sort_by(.metadata.creationTimestamp)
    | last
    | .spec.relatedImages[]?.image
  ' <<<"$csv_json" >>"$tmp"
done

sort -u "$tmp" >"$OUTPUT"
echo "Wrote $(wc -l <"$OUTPUT" | tr -d ' ') images to $OUTPUT"
