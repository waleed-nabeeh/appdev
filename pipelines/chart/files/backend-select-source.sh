#!/bin/sh
set -eu
mkdir -p "$HOME"
cp -R "$CREDENTIALS_PATH"/. "$HOME"/
chmod -R go-rwx "$HOME"
git config --global credential.helper store
REVISION="${REVISION#refs/heads/}"
case "$REVISION" in ''|*[!a-zA-Z0-9_./-]*) echo 'Invalid source branch' >&2; exit 1 ;; esac
git check-ref-format "refs/heads/$REVISION"
validate_sha() {
  [ "${#1}" -eq 40 ] && printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'
}
case "$MODE" in manual|diff) ;; *) echo 'selection-mode must be manual or diff' >&2; exit 1 ;; esac
if [ -z "$COMMIT" ]; then
  COMMIT=$(git ls-remote --exit-code "$SOURCE_URL" "refs/heads/$REVISION" | cut -f1)
fi
validate_sha "$COMMIT" || { echo 'Invalid source SHA' >&2; exit 1; }
printf '%s' "$COMMIT" > /work/commit
: > /work/changed
if [ "$MODE" = diff ]; then
  validate_sha "$TARGET_COMMIT" || { echo 'Diff requires a full target-commit SHA' >&2; exit 1; }
  git init /work/repo
  git -C /work/repo remote add origin "$SOURCE_URL"
  git -C /work/repo fetch --depth=1000 origin "$COMMIT"
  source_head=$(git -C /work/repo rev-parse FETCH_HEAD)
  [ "$source_head" = "$COMMIT" ] || exit 1
  git -C /work/repo fetch --depth=1000 origin "$TARGET_COMMIT"
  target_head=$(git -C /work/repo rev-parse FETCH_HEAD)
  [ "$target_head" = "$TARGET_COMMIT" ] || exit 1
  base=$(git -C /work/repo merge-base "$COMMIT" "$TARGET_COMMIT" || true)
  if [ -z "$base" ]; then
    # Missing shallow history must never silently omit an affected service.
    touch /work/all-services
  else
    git -C /work/repo diff --no-renames --name-only -z "$base" "$COMMIT" > /work/changed
  fi
fi
