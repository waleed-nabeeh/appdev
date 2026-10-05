#!/usr/bin/env bash
set -euo pipefail

OC_BIN="${OC_BIN:-oc}"
NAMESPACE="${VAULT_NAMESPACE:-vault}"
KEY_FILE="${1:-}"

if [[ -z "${KEY_FILE}" ]]; then
  echo "Usage: $0 /secure/path/vault-init.json" >&2
  exit 2
fi

umask 077
mkdir -p "$(dirname "${KEY_FILE}")"

initialized="$(${OC_BIN} exec -n "${NAMESPACE}" vault-0 -- \
  vault status -format=json 2>/dev/null | jq -r '.initialized')"

if [[ "${initialized}" == "false" ]]; then
  if [[ -e "${KEY_FILE}" ]]; then
    echo "Refusing to overwrite existing key file: ${KEY_FILE}" >&2
    exit 1
  fi
  ${OC_BIN} exec -n "${NAMESPACE}" vault-0 -- \
    vault operator init -key-shares=5 -key-threshold=3 -format=json >"${KEY_FILE}"
  chmod 600 "${KEY_FILE}"
fi

if [[ ! -s "${KEY_FILE}" ]]; then
  echo "Vault is initialized but the key file is unavailable: ${KEY_FILE}" >&2
  exit 1
fi

for pod in vault-0 vault-1 vault-2; do
  for _ in $(seq 1 60); do
    status="$(${OC_BIN} exec -n "${NAMESPACE}" "${pod}" -- \
      vault status -format=json 2>/dev/null || true)"
    [[ "$(jq -r '.initialized // false' <<<"${status}")" == "true" ]] && break
    sleep 5
  done

  if [[ "$(jq -r '.initialized // false' <<<"${status}")" != "true" ]]; then
    echo "Timed out waiting for ${pod} to join the initialized Raft cluster" >&2
    exit 1
  fi

  if [[ "$(jq -r '.sealed' <<<"${status}")" == "true" ]]; then
    for index in 0 1 2; do
      key="$(jq -r ".unseal_keys_b64[${index}]" "${KEY_FILE}")"
      ${OC_BIN} exec -n "${NAMESPACE}" "${pod}" -- \
        vault operator unseal "${key}" >/dev/null
    done
  fi
done

${OC_BIN} exec -n "${NAMESPACE}" vault-0 -- vault status
