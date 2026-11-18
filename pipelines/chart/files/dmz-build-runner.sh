#!/usr/bin/env bash
set -euo pipefail
umask 077
unset HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY FTP_PROXY http_proxy https_proxy no_proxy all_proxy ftp_proxy
base=$1
job_id=$2
max_builds=$3
wait_seconds=$4
cd "$base"
root=$(pwd -P)
job="$root/jobs/$job_id"
local_image="localhost/tekton-build:$job_id"
build_started=false
cleanup() {
  if [ "$build_started" = true ]; then
    podman image rm "$local_image" >/dev/null 2>&1 || true
  fi
  rm -rf -- "$job"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
for tool in podman flock tar realpath; do command -v "$tool" >/dev/null; done
# All runs for this account/root share these same lock files; never delete them.
mkdir -p "$root/slots"
exec 8>"$root/slots/config.lock"
flock -x 8
if [ -f "$root/slots/max-builds" ]; then
  test "$(cat "$root/slots/max-builds")" = "$max_builds" || {
    echo 'Shared VM concurrency configuration differs. Drain active builds before changing it.' >&2; exit 1;
  }
else
  printf '%s' "$max_builds" > "$root/slots/max-builds"
fi
flock -u 8
start=$SECONDS
acquired=false
while [ "$acquired" = false ]; do
  for ((slot=1; slot<=max_builds; slot++)); do
    exec 9>"$root/slots/$slot.lock"
    if flock -n 9; then acquired=true; break; fi
    exec 9>&-
  done
  if [ "$acquired" = false ]; then
    if ((SECONDS-start >= wait_seconds)); then echo 'Timed out waiting for a VM build slot.' >&2; exit 1; fi
    sleep 5
  fi
done
printf 'Acquired shared DMZ build slot %s/%s for %s\n' "$slot" "$max_builds" "$job_id"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
test "$(podman info --format '{{.Host.Security.Rootless}}')" = true || {
  echo 'The dedicated account must use rootless Podman.' >&2; exit 1;
}
tls_verify=true
if [ -f "$job/metadata/tls-verify" ]; then tls_verify=$(cat "$job/metadata/tls-verify"); fi
case "$tls_verify" in true|false) ;; *) echo 'Invalid registry TLS verification setting.' >&2; exit 1 ;; esac
if [ "$tls_verify" = false ]; then echo 'Temporary test mode: Podman registry TLS certificate verification is disabled.'; fi
proxy_enabled=false
if [ -f "$job/metadata/proxy-enabled" ]; then proxy_enabled=$(cat "$job/metadata/proxy-enabled"); fi
case "$proxy_enabled" in true|false) ;; *) echo 'Invalid DMZ proxy setting.' >&2; exit 1 ;; esac
if [ "$proxy_enabled" = true ]; then
  # Read data only: never source/eval files received from a Secret.
  HTTP_PROXY=$(cat "$job/credentials/proxy/HTTP_PROXY")
  HTTPS_PROXY=$(cat "$job/credentials/proxy/HTTPS_PROXY")
  NO_PROXY=$(cat "$job/credentials/proxy/NO_PROXY")
  for endpoint in "$HTTP_PROXY" "$HTTPS_PROXY"; do
    case "$endpoint" in http://?*|https://?*) ;; *) echo 'Proxy URLs must use http:// or https://.' >&2; exit 1 ;; esac
  done
  export HTTP_PROXY HTTPS_PROXY NO_PROXY
  export http_proxy="$HTTP_PROXY" https_proxy="$HTTPS_PROXY" no_proxy="$NO_PROXY"
  echo 'Approved DMZ proxy enabled for Podman registry operations and build containers; runner does not print its values.'
fi
image=$(cat "$job/metadata/image")
context=$(cat "$job/metadata/context")
containerfile=$(cat "$job/metadata/containerfile")
cd "$job/source"
test -f "$containerfile"
test -d "$context"
for path in "$(realpath -e "$containerfile")" "$(realpath -e "$context")"; do
  case "$path/" in "$job/source/"*) ;; *) echo 'Build path escapes its source directory.' >&2; exit 1 ;; esac
done
set --
while IFS= read -r -d '' argument; do set -- "$@" --build-arg "$argument"; done < "$job/metadata/build-args0"
if [ -s "$job/credentials/npm_token" ]; then set -- "$@" --secret "id=npm_token,src=$job/credentials/npm_token"; fi
build_started=true
podman build --http-proxy=true --tls-verify="$tls_verify" --authfile "$job/credentials/registry.json" --rm --force-rm \
  "$@" -f "$containerfile" -t "$local_image" "$context"
podman push --tls-verify="$tls_verify" --authfile "$job/credentials/registry.json" \
  --digestfile "$job/digest" "$local_image" "docker://$image"
digest=$(cat "$job/digest")
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'Podman returned an invalid digest.' >&2; exit 1; }
printf 'TEKTON_IMAGE_DIGEST=%s\n' "$digest"
