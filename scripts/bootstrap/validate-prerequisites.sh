#!/usr/bin/env bash
set -euo pipefail

OC_BIN="${OC_BIN:-oc}"

required_packages=(
  openshift-gitops-operator
  openshift-pipelines-operator-rh
  rhtas-operator
  rhacs-operator
  quay-operator
)

installed_csvs="$("$OC_BIN" get csv -A -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')"

for package in "${required_packages[@]}"; do
  if ! grep -q "^${package}" <<<"$installed_csvs"; then
    echo "Missing or unready operator CSV: ${package}" >&2
    exit 1
  fi
done

for crd in \
  applications.argoproj.io \
  pipelines.tekton.dev \
  securesigns.rhtas.redhat.com \
  centrals.platform.stackrox.io \
  quayregistries.quay.redhat.com; do
  "$OC_BIN" get crd "$crd" >/dev/null
done

if ! "$OC_BIN" get central -A -o name | grep -q .; then
  echo "RHACS Central is not deployed" >&2
  exit 1
fi

if ! "$OC_BIN" get quayregistry -A -o name | grep -q .; then
  echo "Quay is not deployed" >&2
  exit 1
fi

echo "Operator, RHACS Central, and Quay prerequisites are present."
