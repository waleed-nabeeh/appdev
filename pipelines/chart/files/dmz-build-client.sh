#!/bin/sh
set -euo pipefail
umask 077
unset HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy
for tool in ssh ssh-keygen tar tee; do command -v "$tool" >/dev/null; done
case "$DMZ_HOST" in ""|*[!A-Za-z0-9.-]*) echo 'Invalid DMZ host' >&2; exit 1 ;; esac
case "$DMZ_USER" in ""|*[!A-Za-z0-9_-]*) echo 'Invalid DMZ user' >&2; exit 1 ;; esac
case "$DMZ_ROOT" in ""|/|.|..|-*|../*|*/../*|*/..|*[!A-Za-z0-9_./-]*) echo 'Invalid dedicated DMZ work root' >&2; exit 1 ;; esac
case "$JOB_ID" in ""|*[!A-Za-z0-9-]*) exit 1 ;; esac
for number in "$DMZ_PORT" "$DMZ_MAX_BUILDS" "$DMZ_WAIT_SECONDS"; do
  case "$number" in ""|*[!0-9]*|0) echo 'Invalid numeric DMZ configuration' >&2; exit 1 ;; esac
done
for path in "$BUILD_CONTEXT" "$CONTAINERFILE"; do
  case "$path" in ""|/*|..|../*|*/../*|*/..) echo 'Build paths must be repository-relative' >&2; exit 1 ;; esac
done
test -s /ssh-auth/ssh-privatekey
case "${DMZ_HOST_KEY_POLICY:-strict}" in
  strict)
    test -s /ssh-auth/known_hosts || { echo 'Add a verified known_hosts entry to the dmz-build-ssh Secret.' >&2; exit 1; }
    host_key_check=yes ;;
  accept-new)
    host_key_check=accept-new
    echo 'SSH test mode: accept-new. A new host key is trusted on first contact for this TaskRun only.' ;;
  *) echo 'hostKeyPolicy must be strict or accept-new.' >&2; exit 1 ;;
esac
local_work=$(mktemp -d)
remote_dir="$DMZ_ROOT/jobs/$JOB_ID"
remote_created=false
runner_started=false
ssh_vm() {
  ssh -F /dev/null -p "$DMZ_PORT" -i "$local_work/key" \
    -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking="$host_key_check" \
    -o UserKnownHostsFile="$local_work/known_hosts" -o ConnectTimeout=15 \
    -o ServerAliveInterval=20 -o ServerAliveCountMax=3 \
    "$DMZ_USER@$DMZ_HOST" "$@"
}
cleanup() {
  # Once started, the remote runner owns cleanup, even if SSH disconnects.
  if [ "$remote_created" = true ] && [ "$runner_started" = false ]; then
    ssh_vm "rm -rf -- '$remote_dir'" >/dev/null 2>&1 || true
  fi
  rm -rf "$local_work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp /ssh-auth/ssh-privatekey "$local_work/key"
if [ -s /ssh-auth/known_hosts ]; then
  cp /ssh-auth/known_hosts "$local_work/known_hosts"
else
  : > "$local_work/known_hosts"
fi
chmod 600 "$local_work/key"
ssh-keygen -y -P '' -f "$local_work/key" >/dev/null || {
  echo 'SSH private key is invalid or requires a passphrase. Use an approved unattended key.' >&2; exit 1;
}
mkdir "$local_work/credentials" "$local_work/metadata"
authfile="$REGISTRY_AUTH/config.json"
if [ ! -f "$authfile" ]; then authfile="$REGISTRY_AUTH/.dockerconfigjson"; fi
test -s "$authfile"
cp "$authfile" "$local_work/credentials/registry.json"
if [ "$NPM_AUTH_BOUND" = true ]; then
  test -s "$NPM_AUTH/NPM_TOKEN"
  cp "$NPM_AUTH/NPM_TOKEN" "$local_work/credentials/npm_token"
fi
chmod 600 "$local_work/credentials/"*
printf '%s' "$BUILD_IMAGE" > "$local_work/metadata/image"
printf '%s' "$BUILD_CONTEXT" > "$local_work/metadata/context"
printf '%s' "$CONTAINERFILE" > "$local_work/metadata/containerfile"
: > "$local_work/metadata/build-args0"
for argument in "$@"; do printf '%s\0' "$argument" >> "$local_work/metadata/build-args0"; done
cp /opt/dmz-build/runner.sh "$local_work/runner.sh"
# Relative work roots are resolved under the SSH account's home directory.
ssh_vm "umask 077; test ! -e '$remote_dir' && mkdir -p -- '$remote_dir/source' '$remote_dir/credentials'"
remote_created=true
printf 'Transferring full repository build context for task %s to %s\n' "$JOB_ID" "$DMZ_HOST"
tar -C "$SOURCE_DIR" --exclude=.git -czf - . | ssh_vm "tar --no-same-owner -xzf - -C '$remote_dir/source'"
tar -C "$local_work" -czf - credentials metadata runner.sh | ssh_vm "tar --no-same-owner -xzf - -C '$remote_dir'"
runner_started=true
ssh_vm "bash '$remote_dir/runner.sh' '$DMZ_ROOT' '$JOB_ID' '$DMZ_MAX_BUILDS' '$DMZ_WAIT_SECONDS'" | tee "$local_work/build.log"
digest=$(sed -n 's/^TEKTON_IMAGE_DIGEST=//p' "$local_work/build.log" | tail -n 1)
printf '%s\n' "$digest" | grep -Eq '^sha256:[0-9a-f]{64}$' || { echo 'VM returned no valid image digest.' >&2; exit 1; }
printf '%s' "$digest" > "$RESULT_DIGEST"
printf '%s@%s' "$BUILD_IMAGE" "$digest" > "$RESULT_IMAGE"
printf '\nRemote build and push completed.\nPublished image: %s\nDigest: %s\n' "$BUILD_IMAGE" "$digest"
