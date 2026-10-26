#!/bin/sh
set -eu
cd /work/repo
git config user.name 'Tekton Pipeline'
git config user.email 'pipeline@customer.invalid'
git add -- "$VALUES_FILE"
if ! git diff --cached --quiet; then
  git commit -m 'Update selected application image tags [skip ci]'
  pushed=false
  for attempt in 1 2 3; do
    if git push origin "HEAD:refs/heads/$GITOPS_BRANCH"; then pushed=true; break; fi
    git fetch origin "$GITOPS_BRANCH"
    # Rebase only over forward commits that did not change this pipeline's file.
    if ! git merge-base --is-ancestor HEAD^ FETCH_HEAD || ! git diff --quiet HEAD^ FETCH_HEAD -- "$VALUES_FILE"; then
      echo 'Concurrent update changed the same GitOps file; refusing to overwrite it.' >&2
      exit 1
    fi
    git rebase FETCH_HEAD
  done
  [ "$pushed" = true ] || { echo 'GitOps push failed after three attempts.' >&2; exit 1; }
fi
