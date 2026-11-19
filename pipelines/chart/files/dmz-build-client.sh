#!/bin/sh
set -euo pipefail
umask 077
unset HTTP_PROXY HTTPS_PROXY NO_PROXY ALL_PROXY FTP_PROXY http_proxy https_proxy no_proxy all_proxy ftp_proxy
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
DMZ_TLS_VERIFY=${DMZ_TLS_VERIFY:-true}
case "$DMZ_TLS_VERIFY" in true|false) ;; *) echo 'tlsVerify must be true or false.' >&2; exit 1 ;; esac
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
# Normalize pasted Windows line endings and restore the required final newline.
awk '{sub(/\r$/, ""); print}' /ssh-auth/ssh-privatekey > "$local_work/key"
if [ -s /ssh-auth/known_hosts ]; then
  cp /ssh-auth/known_hosts "$local_work/known_hosts"
else
  : > "$local_work/known_hosts"
fi
chmod 600 "$local_work/key"
ssh-keygen -y -P '' -f "$local_work/key" >/dev/null || {
  echo 'SSH client could not parse the private key. Check the complete original key, supported format/algorithm and passphrase requirements. No VM connection was attempted.' >&2; exit 1;
}
mkdir "$local_work/credentials" "$local_work/metadata"
authfile="$REGISTRY_AUTH/config.json"
if [ ! -f "$authfile" ]; then authfile="$REGISTRY_AUTH/.dockerconfigjson"; fi
test -s "$authfile"
cp "$authfile" "$local_work/credentials/registry.json"
if [ "${NUGET_AUTH_BOUND:-false}" = true ]; then
  test -s "$NUGET_AUTH/.git-credentials"
  case "${NUGET_CREDENTIAL_URL:-}" in
    https://*) ;;
    *) echo 'NuGet credential lookup requires an HTTPS source URL.' >&2; exit 1 ;;
  esac
  # Use Git's URL decoding and host matching without interactive prompts or logs.
  printf 'url=%s\n\n' "$NUGET_CREDENTIAL_URL" | \
    GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
    GIT_ASKPASS=/bin/false git -c credential.helper= -c credential.useHttpPath=false \
    -c "credential.helper=store --file=$NUGET_AUTH/.git-credentials" credential fill \
    > "$local_work/nuget-credential-response" 2>/dev/null || {
      echo 'Could not resolve NuGet credentials from the existing Git Secret.' >&2; exit 1;
    }
  nuget_user=$(sed -n 's/^username=//p' "$local_work/nuget-credential-response")
  nuget_password=$(sed -n 's/^password=//p' "$local_work/nuget-credential-response")
  carriage_return=$(printf '\r')
  case "$nuget_user$nuget_password" in
    *';'*|*'
'*|*"$carriage_return"*) echo 'Unsupported delimiter in NuGet credentials.' >&2; exit 1 ;;
  esac
  test -n "$nuget_user" && test -n "$nuget_password"
  # Escape XML attributes; never write credentials into the source checkout.
  nuget_user=$(printf '%s' "$nuget_user" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')
  nuget_password=$(printf '%s' "$nuget_password" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g')
  printf '<?xml version="1.0" encoding="utf-8"?>\n<configuration><packageSourceCredentials><MofaNuget><add key="Username" value="%s"/><add key="ClearTextPassword" value="%s"/><add key="ValidAuthenticationTypes" value="Basic"/></MofaNuget></packageSourceCredentials></configuration>\n' \
    "$nuget_user" "$nuget_password" > "$local_work/credentials/nuget.config"
  printf '%s' "${NUGET_USER_CONFIG_PATH:-/opt/app-root/.nuget/NuGet/NuGet.Config}" > "$local_work/metadata/nuget-config-path"
  unset nuget_user nuget_password
  rm -f "$local_work/nuget-credential-response"
fi
if [ "$NPM_AUTH_BOUND" = true ]; then
  test -s "$NPM_AUTH/NPM_TOKEN"
  cp "$NPM_AUTH/NPM_TOKEN" "$local_work/credentials/npm_token"
fi
DMZ_PROXY_ENABLED=${DMZ_PROXY_ENABLED:-false}
case "$DMZ_PROXY_ENABLED" in true|false) ;; *) echo 'Invalid DMZ proxy setting.' >&2; exit 1 ;; esac
if [ "$DMZ_PROXY_ENABLED" = true ]; then
  mkdir "$local_work/credentials/proxy"
  for key in HTTP_PROXY HTTPS_PROXY NO_PROXY; do
    test -f "/dmz-proxy/$key" || { echo "Proxy Secret must contain $key" >&2; exit 1; }
    tr -d '\r\n' < "/dmz-proxy/$key" > "$local_work/credentials/proxy/$key"
    chmod 600 "$local_work/credentials/proxy/$key"
  done
  test -s "$local_work/credentials/proxy/HTTP_PROXY"
  test -s "$local_work/credentials/proxy/HTTPS_PROXY"
fi
printf '%s' "$DMZ_PROXY_ENABLED" > "$local_work/metadata/proxy-enabled"
find "$local_work/credentials" -type f -exec chmod 600 {} \;
printf '%s' "$DMZ_TLS_VERIFY" > "$local_work/metadata/tls-verify"
printf '%s' "${DIAGNOSTIC_BASE_IMAGE:-}" > "$local_work/metadata/diagnostic-image"
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
