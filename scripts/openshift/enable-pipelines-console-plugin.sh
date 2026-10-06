#!/usr/bin/env bash
set -euo pipefail

OC_BIN="${OC_BIN:-oc}"
PLUGIN="pipelines-console-plugin"

if ! ${OC_BIN} get consoleplugin.console.openshift.io "${PLUGIN}" >/dev/null 2>&1; then
  echo "ConsolePlugin ${PLUGIN} is not installed" >&2
  exit 1
fi

if ${OC_BIN} get console.operator.openshift.io cluster \
  -o jsonpath='{.spec.plugins}' | tr ' ' '\n' | grep -q "${PLUGIN}"; then
  echo "${PLUGIN} is already enabled."
  exit 0
fi

${OC_BIN} patch console.operator.openshift.io cluster --type=json \
  -p="[{\"op\":\"add\",\"path\":\"/spec/plugins/-\",\"value\":\"${PLUGIN}\"}]"

echo "Enabled ${PLUGIN}. Refresh the OpenShift web console after reconciliation."
