#!/usr/bin/env bash
set -euo pipefail
umask 077
unset HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
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
podman build --authfile "$job/credentials/registry.json" --rm --force-rm \
  "$@" -f "$containerfile" -t "$local_image" "$context"
podman push --authfile "$job/credentials/registry.json" \
  --digestfile "$job/digest" "$local_image" "docker://$image"
digest=$(cat "$job/digest")
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo 'Podman returned an invalid digest.' >&2; exit 1; }
printf 'TEKTON_IMAGE_DIGEST=%s\n' "$digest"
