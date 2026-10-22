#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 AUTHFILE [FRONTEND_CHART_DIRECTORY]" >&2
  exit 2
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
authfile=$1
chart_dir=${2:-"$script_dir/../../apps/frontend/helm"}
registry=quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa
test -r "$authfile"
command -v helm >/dev/null
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Dummy values exercise rendering only; no workload uses this image.
helm lint "$chart_dir" \
  --set-string image.repository=example.invalid/frontend \
  --set-string image.digest=sha256:0000000000000000000000000000000000000000000000000000000000000000
helm package "$chart_dir" --destination "$work"
packages=("$work"/*.tgz)
[[ ${#packages[@]} -eq 1 && -f ${packages[0]} ]]
helm push "${packages[0]}" "oci://$registry/devops" --registry-config "$authfile"
echo 'Chart published. Keep chart.version in the GitOps values aligned with Chart.yaml.'
