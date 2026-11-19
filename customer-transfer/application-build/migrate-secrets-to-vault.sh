#!/usr/bin/env bash
# One-time bootstrap: existing OpenShift Secret data -> new Vault KV v2 entries.
{ set +x; } 2>/dev/null
set -euo pipefail
umask 077
shopt -s dotglob nullglob

namespace=${PIPELINE_NAMESPACE:-devops}
mount=${VAULT_KV_MOUNT:-secret}
prefix=${VAULT_PIPELINE_PREFIX:-devops/pipelines}
expected_server=${EXPECTED_OCP_SERVER:-https://api.hub-visa-ocp.mofa.gov.sa:6443}
[[ -n ${VAULT_ADDR:-} ]] || { echo 'Set VAULT_ADDR explicitly to the approved existing Vault endpoint.' >&2; exit 1; }
for tool in oc vault mktemp; do command -v "$tool" >/dev/null || { echo "Required command missing: $tool" >&2; exit 1; }; done
[[ $namespace =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] || { echo 'Invalid pipeline namespace.' >&2; exit 1; }
[[ $mount =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*$ ]] || { echo 'Invalid Vault mount.' >&2; exit 1; }
[[ $prefix =~ ^[A-Za-z0-9_][A-Za-z0-9_-]*(/[A-Za-z0-9_][A-Za-z0-9_-]*)*$ ]] || { echo 'Invalid Vault relative prefix.' >&2; exit 1; }
server=$(oc whoami --show-server)
[[ ${server%/} == "${expected_server%/}" ]] || { echo 'OpenShift server differs from EXPECTED_OCP_SERVER; nothing migrated.' >&2; exit 1; }

# CAS=0 must not silently become an unguarded write to a KV v1 mount.
mount_type=$(vault read -field=type "sys/internal/ui/mounts/$mount" 2>/dev/null) || {
  echo 'Cannot inspect Vault mount. Check VAULT_ADDR, login and migration permissions.' >&2; exit 1;
}
options=$(vault read -field=options "sys/internal/ui/mounts/$mount" 2>/dev/null)
[[ $mount_type == kv && ( $options == *'version:2]'* || $options == *'version:2 '* ) ]] || {
  echo 'Migration requires a verified Vault KV v2 mount; nothing migrated.' >&2; exit 1;
}

allowed=(git-credentials registry-auth npm-auth rhacs-auth pipeline-proxy dmz-build-ssh)
if (( $# == 0 )); then set -- "${allowed[@]}"; fi
# Validate the complete selection before reading or writing credential values.
for name in "$@"; do
  found=false
  for candidate in "${allowed[@]}"; do if [[ $name == "$candidate" ]]; then found=true; break; fi; done
  [[ $found == true ]] || { echo "Unsupported pipeline Secret: $name" >&2; exit 1; }
done

work=$(mktemp -d "${TMPDIR:-/tmp}/mofa-vault-migration.XXXXXXXX")
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for name in "$@"; do
  directory="$work/$name"
  mkdir -m 700 "$directory"
  oc -n "$namespace" extract "secret/$name" --to="$directory" >/dev/null
  arguments=()
  for file in "$directory"/*; do
    [[ -f $file && ! -L $file ]] || { echo 'Unexpected extracted Secret entry.' >&2; exit 1; }
    field=${file##*/}
    [[ $field =~ ^[A-Za-z0-9._][A-Za-z0-9._-]*$ ]] || { echo 'Unsupported Secret key name.' >&2; exit 1; }
    chmod 600 "$file"
    arguments+=("$field=@$file")
  done
  (( ${#arguments[@]} > 0 )) || { echo "Secret $name contains no data." >&2; exit 1; }
  # Only filenames appear in process arguments; values are never echoed.
  if ! vault kv put -mount="$mount" -cas=0 "$prefix/$name" "${arguments[@]}" >/dev/null; then
    echo "Migration stopped at $name. Existing Vault entries are never overwritten. Check access/CAS errors and migrate remaining names explicitly." >&2
    exit 1
  fi
  rm -rf -- "$directory"
  printf 'CREATED %s/%s/%s from Secret %s/%s\n' "$mount" "$prefix" "$name" "$namespace" "$name"
done
echo 'Selected entries migrated. Verify ESO Ready conditions and test a fresh pipeline run.'
