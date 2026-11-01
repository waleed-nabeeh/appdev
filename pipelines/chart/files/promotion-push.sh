#!/bin/sh
set -eu
cd /work/repo
git config user.name 'Tekton Pipeline'
git config user.email 'pipeline@customer.invalid'
while IFS= read -r filename; do git add -- "$filename"; done < /work/targets.txt
if git diff --cached --quiet; then
  git fetch origin "$GITOPS_BRANCH"
  git merge-base --is-ancestor HEAD FETCH_HEAD || { echo 'GitOps branch history changed; review before retrying.' >&2; exit 1; }
  while IFS= read -r filename; do
    git diff --quiet HEAD FETCH_HEAD -- "$filename" || { echo "Concurrent change to $filename; review before retrying." >&2; exit 1; }
  done < /work/watched.txt
  git merge --ff-only FETCH_HEAD
  echo 'Production and DR already contain the selected image references; no Git commit needed.'
else
  git commit -m "Promote $SCOPE images to production and DR [skip ci]" \
    -m "Source GitOps commit: $(cat /work/source-commit)"
  pushed=false
  for attempt in 1 2 3; do
    if git push origin "HEAD:refs/heads/$GITOPS_BRANCH"; then pushed=true; break; fi
    git fetch origin "$GITOPS_BRANCH"
    git merge-base --is-ancestor HEAD^ FETCH_HEAD || { echo 'GitOps branch history changed; review before retrying.' >&2; exit 1; }
    while IFS= read -r filename; do
      if ! git diff --quiet HEAD^ FETCH_HEAD -- "$filename"; then
        echo "Concurrent change to $filename; refusing to overwrite it." >&2
        exit 1
      fi
    done < /work/watched.txt
    git rebase FETCH_HEAD
  done
  [ "$pushed" = true ] || { echo 'Promotion Git push failed after three attempts.' >&2; exit 1; }
fi
git rev-parse HEAD | tr -d '\n' > /tekton/results/gitops-commit
