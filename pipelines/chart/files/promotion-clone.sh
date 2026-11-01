#!/bin/sh
set -eu
mkdir -p "$HOME"
cp -R /credentials/git/. "$HOME"/
chmod -R go-rwx "$HOME"
git config --global credential.helper store
git check-ref-format "refs/heads/$GITOPS_BRANCH"
git clone --single-branch --branch "$GITOPS_BRANCH" "$GITOPS_URL" /work/repo
cd /work/repo
if [ -z "$APPROVED_COMMIT" ]; then APPROVED_COMMIT=$(git rev-parse HEAD); fi
[ "${#APPROVED_COMMIT}" -eq 40 ] && printf '%s' "$APPROVED_COMMIT" | grep -Eq '^[a-f0-9]{40}$' || { echo 'Expected full GitOps commit SHA' >&2; exit 1; }
git merge-base --is-ancestor "$APPROVED_COMMIT" HEAD || { echo 'Approved commit is not on the configured GitOps branch' >&2; exit 1; }
if [ -n "${EXPECTED_BASE:-}" ]; then
  [ "${#EXPECTED_BASE}" -eq 40 ] && printf '%s' "$EXPECTED_BASE" | grep -Eq '^[a-f0-9]{40}$' || { echo 'Invalid initial GitOps base' >&2; exit 1; }
  git merge-base --is-ancestor "$EXPECTED_BASE" HEAD || { echo 'GitOps branch history changed since approval was read' >&2; exit 1; }
  for filename in "$SOURCE_FILE" "$PROD_FILE" "$DR_FILE"; do
    git diff --quiet "$EXPECTED_BASE" HEAD -- "$filename" || { echo "Concurrent change to $filename since promotion started" >&2; exit 1; }
  done
fi
git show "$APPROVED_COMMIT:$SOURCE_FILE" > /work/approved-source.yaml
chmod -R g+rwX /work/repo
chmod g+r /work/approved-source.yaml
printf '%s' "$APPROVED_COMMIT" > /work/source-commit
if [ "${EMIT_SOURCE_RESULTS:-false}" = true ]; then
  printf '%s' "$APPROVED_COMMIT" > /tekton/results/source-commit
  git rev-parse HEAD | tr -d '\n' > /tekton/results/base-commit
fi
printf 'Preproduction GitOps commit: %s\nSource file: %s\n' "$APPROVED_COMMIT" "$SOURCE_FILE"
