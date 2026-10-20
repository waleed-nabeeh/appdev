# Simulate the Azure PR webhook

Use this from a terminal that has `oc` access to the `devops` project. It sends a synthetic Azure Repos PR-created event through the deployed EventListener route. It does not create a real Azure PR or report status to Azure.

The repository name and target branch below match the EventListener filter in the Helm chart. For a trigger-smoke test, replace only the route host and webhook credentials. The PR ID and project/repository IDs are sample metadata; the filter does not validate them. The source branch and commit must exist in the configured repository: replace `feature/webhook-fanout-test` and the sample source commit with a real branch and its commit SHA, otherwise the PipelineRun will be created but its clone task will fail. The target commit value is informational for this trigger; the dispatcher fetches the target branch to calculate the diff.

```bash
ROUTE_HOST='<frontend-pr-webhook-route-host>'
WEBHOOK_USER='<username-from-frontend-pr-webhook-auth>'
WEBHOOK_PASSWORD='<password-from-frontend-pr-webhook-auth>'

curl --fail-with-body -i \
  -u "$WEBHOOK_USER:$WEBHOOK_PASSWORD" \
  -H 'Content-Type: application/json' \
  -H 'X-Event-Key: git.pullrequest.created' \
  -X POST "https://${ROUTE_HOST}/" \
  --data '{
    "subscriptionId": "manual-test",
    "notificationId": 1,
    "eventType": "git.pullrequest.created",
    "publisherId": "tfs",
    "resource": {
      "pullRequestId": 9999,
      "status": "active",
      "sourceRefName": "refs/heads/<EXISTING_FEATURE_BRANCH>",
      "targetRefName": "refs/heads/pre-prod",
      "repository": {
        "id": "00000000-0000-0000-0000-000000000001",
        "name": "RedHat_UnifiedVisaPlatform.Frontend",
        "project": {
          "id": "00000000-0000-0000-0000-000000000002",
          "name": "UnifiedVisaPlatform"
        },
        "remoteUrl": "https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_UnifiedVisaPlatform.Frontend"
      },
      "lastMergeSourceCommit": {
        "commitId": "<REAL_40_CHARACTER_SOURCE_COMMIT_SHA>"
      },
      "lastMergeTargetCommit": {
        "commitId": "0000000000000000000000000000000000000000"
      }
    }
  }'
```

Confirm that the request was accepted and a PipelineRun appeared:

```bash
oc get eventlistener frontend-pr -n devops
oc get pipelineruns -n devops --sort-by=.metadata.creationTimestamp
oc get pipelineruns,taskruns,pods -n devops -w
```

The PR dispatcher selects services by fetching the branch and computing its diff against `pre-prod`; Azure's webhook payload does not carry the changed-file list. To see all three lanes fan out, use a real feature branch whose diff touches paths mapped to all three services in `chart/files/service-pre-prod.tsv`. Then watch the PipelineRun and TaskRuns below.

If the route uses an edge TLS termination policy, call it with `https://`; the router terminates TLS and forwards HTTP to the webhook proxy.
