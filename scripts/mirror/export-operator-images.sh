#!/usr/bin/env bash
set -euo pipefail

OC_BIN="${OC_BIN:-oc}"
OUTPUT="${1:-mirror/operator-related-images.txt}"
csv_prefixes=(
  openshift-gitops-operator
  openshift-pipelines-operator-rh
  rhtas-operator
  rhacs-operator
  quay-operator
  cert-manager-operator
  cloudnative-pg
)

csv_json="$("$OC_BIN" get csv -A -o json)"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

for prefix in "${csv_prefixes[@]}"; do
  jq -r --arg prefix "$prefix" '
    .items
    | map(select(.metadata.name | startswith($prefix + ".v")))
    | sort_by(.metadata.creationTimestamp)
    | last
    | .spec.relatedImages[]?.image
  ' <<<"$csv_json" >>"$tmp"
done

sort -u "$tmp" >"$OUTPUT"
echo "Wrote $(wc -l <"$OUTPUT" | tr -d ' ') images to $OUTPUT"
