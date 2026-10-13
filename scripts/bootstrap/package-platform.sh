#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
OUTPUT=${1:?Usage: bash package-platform.sh OUTPUT_DIRECTORY}
mkdir -p "$OUTPUT"
for chart in platform/vault/chart platform/rhtas/chart bootstrap/app-of-apps; do
  helm lint "$ROOT/$chart"
  helm package "$ROOT/$chart" --destination "$OUTPUT"
done
cp "$ROOT/mirror/vault-rhtas-images.csv" "$OUTPUT/"
cp "$ROOT/mirror/rhtas-idms.example.yaml" "$OUTPUT/"
cp "$ROOT/docs/vault-rhtas-first-deployment.md" "$OUTPUT/"
echo "Charts and inventory packaged. Transfer appdev too for scripts and GitOps paths."
