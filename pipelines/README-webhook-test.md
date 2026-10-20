# End-to-end Azure PR webhook and three-service fan-out test

First deploy the latest Helm chart (the short-SHA image-tag change is in this chart), then run the commands below from a clone of the Azure Repos frontend repository, with permission to push branches, and with `oc`, `git`, `jq`, and `curl` available. The test pushes a temporary base branch if `pre-prod` does not exist, then pushes a feature branch with marker-only files under all three service paths. The markers select all three lanes without changing application code. The webhook creates a Tekton PipelineRun; this is a simulated PR event, not an Azure PR, and does not report status to Azure.

Only set the webhook Route host and Basic Auth credentials yourself. The repository name, clone URL, branch filter, and target branch below match the Helm chart configuration.

## One-command webhook test

Run this from the Azure frontend repository on the pushed test branch that contains marker changes under `apps/admin-portal`, `apps/applicant-portal`, and `apps/operational-portal`. It uses the current branch and commit plus the remote `pre-prod` SHA, and sends the simulated Azure PR event directly. Replace only `<WEBHOOK_PASSWORD>`.

```bash
curl --fail-with-body -i -u "ado-hook:<WEBHOOK_PASSWORD>" -H 'Content-Type: application/json' -H 'X-Event-Key: git.pullrequest.created' 'https://frontend-pr-webhook-devops.apps.hub-visa-ocp.mofa.gov.sa/' --data "{\"eventType\":\"git.pullrequest.created\",\"resource\":{\"pullRequestId\":9999,\"status\":\"active\",\"sourceRefName\":\"refs/heads/$(git branch --show-current)\",\"targetRefName\":\"refs/heads/pre-prod\",\"repository\":{\"name\":\"RedHat_UnifiedVisaPlatform.Frontend\",\"remoteUrl\":\"https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_UnifiedVisaPlatform.Frontend\"},\"lastMergeSourceCommit\":{\"commitId\":\"$(git rev-parse HEAD)\"},\"lastMergeTargetCommit\":{\"commitId\":\"$(git ls-remote origin refs/heads/pre-prod | awk '{print $1}')\"}}}"
```

From the AppDev checkout, deploy the updated chart first:

```bash
oc project devops
helm upgrade --install release-pipeline ./pipelines/chart \
  --namespace devops \
  -f customer-transfer/devops-apply/values-devops.yaml \
  --force-conflicts
```

The `--force-conflicts` option resolves the existing server-side-apply ownership conflicts on the shared Pipeline; it does not delete and recreate resources. Confirm the revision is deployed before sending the test event:

```bash
helm status release-pipeline -n devops
oc get eventlistener frontend-pr -n devops
```

```bash
set -euo pipefail

# Set these three values from the OpenShift Route and Secret.
ROUTE_HOST='<frontend-pr-webhook-route-host>'
WEBHOOK_USER='<username-from-frontend-pr-webhook-auth>'
WEBHOOK_PASSWORD='<password-from-frontend-pr-webhook-auth>'

REPO_NAME='RedHat_UnifiedVisaPlatform.Frontend'
TARGET_BRANCH='pre-prod'
REMOTE_URL='https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_UnifiedVisaPlatform.Frontend'

if [ -n "$(git status --porcelain)" ]; then
  echo 'Start from a clean checkout so the test commit contains only its marker files.' >&2
  exit 1
fi

git fetch origin --prune

# Create the target branch from the repository's default branch only if missing.
if ! git ls-remote --exit-code --heads origin "refs/heads/${TARGET_BRANCH}" >/dev/null 2>&1; then
  echo "Remote ${TARGET_BRANCH} branch is missing; creating it from current HEAD."
  git push origin "HEAD:refs/heads/${TARGET_BRANCH}"
fi

git fetch origin "+refs/heads/${TARGET_BRANCH}:refs/remotes/origin/${TARGET_BRANCH}"
TEST_BRANCH="feature/tekton-fanout-smoke-$(date +%Y%m%d%H%M%S)"
git switch --create "$TEST_BRANCH" "origin/${TARGET_BRANCH}"

# Unique harmless marker files select each service in chart/files/service-pre-prod.tsv.
MARKER="tekton-fanout-smoke-$(date +%Y%m%d%H%M%S).txt"
for service in admin-portal applicant-portal operational-portal; do
  mkdir -p "apps/${service}"
  printf 'Temporary Tekton fan-out test marker. Safe to delete.\n' > "apps/${service}/${MARKER}"
done

git add \
  "apps/admin-portal/${MARKER}" \
  "apps/applicant-portal/${MARKER}" \
  "apps/operational-portal/${MARKER}"
git -c user.name='Tekton fan-out test' \
    -c user.email='tekton-fanout-test@example.invalid' \
    commit -m 'test: exercise frontend Tekton fan-out'
git push --set-upstream origin "$TEST_BRANCH"

SOURCE_SHA=$(git rev-parse HEAD)
SOURCE_SHA_SHORT=${SOURCE_SHA:0:7}
TARGET_SHA=$(git rev-parse "origin/${TARGET_BRANCH}")
PR_ID=$(date +%s)
printf 'Test branch: %s\nFull commit: %s\nImage tag suffix: %s\n' \
  "$TEST_BRANCH" "$SOURCE_SHA" "$SOURCE_SHA_SHORT"

jq -n \
  --arg repo "$REPO_NAME" \
  --arg remote "$REMOTE_URL" \
  --arg source_ref "refs/heads/${TEST_BRANCH}" \
  --arg source_sha "$SOURCE_SHA" \
  --arg target_sha "$TARGET_SHA" \
  --argjson pr_id "$PR_ID" \
  '{
    subscriptionId: "manual-tekton-fanout-test",
    notificationId: 1,
    eventType: "git.pullrequest.created",
    publisherId: "tfs",
    resource: {
      pullRequestId: $pr_id,
      status: "active",
      sourceRefName: $source_ref,
      targetRefName: "refs/heads/pre-prod",
      repository: {
        id: "00000000-0000-0000-0000-000000000001",
        name: $repo,
        project: {
          id: "00000000-0000-0000-0000-000000000002",
          name: "UnifiedVisaPlatform"
        },
        remoteUrl: $remote
      },
      lastMergeSourceCommit: {commitId: $source_sha},
      lastMergeTargetCommit: {commitId: $target_sha}
    }
  }' > /tmp/frontend-pr-webhook.json

curl --fail-with-body -i \
  -u "$WEBHOOK_USER:$WEBHOOK_PASSWORD" \
  -H 'Content-Type: application/json' \
  -H 'X-Event-Key: git.pullrequest.created' \
  --data-binary @/tmp/frontend-pr-webhook.json \
  "https://${ROUTE_HOST}/"
```

The full source SHA is used to fetch the exact commit. The chart derives its first seven characters for the image tags, for example `admin-portal:pr-a1b2c3d`.

Watch the run and confirm the dispatcher selected all lanes:

```bash
oc get pipelineruns,taskruns,pods -n devops -w
```

In the PipelineRun, the dispatcher logs should report `admin=true applicant=true operational=true`. The three images are pushed to the configured `devops` Quay repositories with the `pr-<7-character-sha>` tags.

After the test, delete the temporary remote feature branch (replace the printed branch name):

```bash
git push origin --delete '<printed-test-branch>'
```

The script only creates `pre-prod` if it is absent; it does not delete that branch because the configured pipeline expects it to remain available.
