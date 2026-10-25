#!/usr/bin/env bash
# Run with bash from the backend checkout; failures exit only this script.
set +x
set -euo pipefail
ROUTE_URL='https://backend-pr-webhook-devops.apps.hub-visa-ocp.mofa.gov.sa/'
REPO_URL='https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_UnifiedVisaPlatform.Backend'
SOURCE_BRANCH=$(git branch --show-current)
case "$(git remote get-url origin)" in
  */RedHat_UnifiedVisaPlatform.Backend|*/RedHat_UnifiedVisaPlatform.Backend.git) ;;
  *) echo 'Run this from RedHat_UnifiedVisaPlatform.Backend, not appdev.' >&2; exit 1 ;;
esac
case "$SOURCE_BRANCH" in
  ''|*[!a-zA-Z0-9_./-]*) echo 'Use a named backend source branch.' >&2; exit 1 ;;
esac
SOURCE_SHA=$(git rev-parse HEAD)
TARGET_SHA=$(git ls-remote --exit-code "$REPO_URL" refs/heads/test | awk '{print $1}')
if [ "${#SOURCE_SHA}" -ne 40 ] || [ "${#TARGET_SHA}" -ne 40 ]; then
  echo 'Could not resolve full source and target commits.' >&2; exit 1
fi
if [ "$SOURCE_SHA" = "$TARGET_SHA" ]; then
  echo 'HEAD equals test: use a pushed branch with changes to test PR fanout.' >&2; exit 1
fi
curl --fail-with-body -sS -i \
    --header 'Content-Type: application/json' \
    "$ROUTE_URL" \
    --data-binary "{
      \"eventType\": \"git.pullrequest.created\",
      \"resource\": {
        \"pullRequestId\": $(date +%s),
        \"status\": \"active\",
        \"sourceRefName\": \"refs/heads/${SOURCE_BRANCH}\",
        \"targetRefName\": \"refs/heads/test\",
        \"repository\": {
          \"name\": \"RedHat_UnifiedVisaPlatform.Backend\",
          \"remoteUrl\": \"${REPO_URL}\"
        },
        \"lastMergeSourceCommit\": {\"commitId\": \"${SOURCE_SHA}\"},
        \"lastMergeTargetCommit\": {\"commitId\": \"${TARGET_SHA}\"}
      }
    }"
