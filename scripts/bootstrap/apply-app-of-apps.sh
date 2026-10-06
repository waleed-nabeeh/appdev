#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 bootstrap/app-of-apps/values-replica.yaml bootstrap/root-application.yaml" >&2
  exit 2
fi

OC_BIN="${OC_BIN:-oc}"
HELM_BIN="${HELM_BIN:-helm}"
VALUES_FILE="$1"
ROOT_APPLICATION="$2"

if grep -Eq 'CUSTOMER_|APPROVED_|INTERNAL_|REPLACE' "$VALUES_FILE" "$ROOT_APPLICATION"; then
  echo "Unresolved placeholder found in bootstrap configuration" >&2
  exit 1
fi

"$OC_BIN" apply -f bootstrap/namespaces/vault.yaml
"$OC_BIN" apply -f bootstrap/namespaces/trusted-artifact-signer.yaml
"$OC_BIN" apply -f bootstrap/namespaces/customer-cicd.yaml
"$OC_BIN" apply -f bootstrap/namespaces/customer-demo.yaml

"$HELM_BIN" lint bootstrap/app-of-apps -f "$VALUES_FILE"
"$OC_BIN" apply -f "$ROOT_APPLICATION"

"$OC_BIN" get applications -n openshift-gitops
