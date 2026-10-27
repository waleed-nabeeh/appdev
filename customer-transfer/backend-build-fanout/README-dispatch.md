# Backend runtime dispatcher

For the current combined frontend/backend setup, use
[Application Builds](../application-build/README.md). It replaces the multiple
overlay commands below with one values file and enables GitOps in both dispatchers.

For the optional backend + frontend Git tag-update test on RedHat_HelmCharts'
`dev` branch, see [../backend-gitops/README.md](../backend-gitops/README.md).

The successful fixed 14-service fanout remains unchanged as a fallback. This adds
a separate entry point with a runtime comma-separated service list. Helm's
`backendBuild.selectedServices` is the allowlist, not the list for every run.

## Apply and test manually

From appdev, keep any frontend overlay used in your existing Helm deployment:

```bash
helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/devops-apply/values-devops.yaml \
  -f customer-transfer/backend-build-fanout/values-backend.yaml
oc -n devops get pipeline application-backend-dispatch application-backend-service-build
oc -n devops get secret registry-auth -o jsonpath='{.type}{"\n"}'
oc -n devops get sa pipeline -o jsonpath='{.imagePullSecrets}{"\n"}'
```

The new `backend-dispatcher` ServiceAccount defaults to `registry-auth` for image
pulls. This must be a usable registry pull Secret, not only an Opaque Task
credential. If necessary, set `backendBuild.dispatch.imagePullSecrets` in your
Helm values to the same approved pull-secret names used by the working pipeline
SA. Child builds continue using the existing `pipeline` SA and Secrets.

Edit `params.services` in `pipelinerun-dispatch.yaml`, then:

```bash
oc create -f customer-transfer/backend-build-fanout/pipelinerun-dispatch.yaml
```

Examples: `acl-service`, `acl-service,core-service`, or `all` for the configured
14. Spaces are trimmed and duplicates removed. Empty/unknown names fail before
child builds. Payment, Gateway and AuthServer remain excluded. `source-revision`
defaults to `test`; an empty `source-commit` resolves that branch once. All children
use the same full SHA, bare eight-character image tag and `CERT_KEYWORD=dev`.

## Copy-paste curl test, no Azure webhook required

This directly tests the dispatcher through the Kubernetes API. It does NOT test
the Azure webhook/Route. Use the existing `oc login` session. In terminal 1:

```bash
oc proxy --address=127.0.0.1 --port=8001
```

In terminal 2, paste this single curl command. Change only `services` to test a
different selection; no password, route, fake SHA, yq or Azure permissions needed:

```bash
curl --fail-with-body -sS \
  -H 'Content-Type: application/json' \
  http://127.0.0.1:8001/apis/tekton.dev/v1/namespaces/devops/pipelineruns \
  --data-binary @- <<'JSON'
{
  "apiVersion": "tekton.dev/v1",
  "kind": "PipelineRun",
  "metadata": {"generateName": "backend-dispatch-", "namespace": "devops"},
  "spec": {
    "pipelineRef": {"name": "application-backend-dispatch"},
    "taskRunTemplate": {"serviceAccountName": "backend-dispatcher"},
    "timeouts": {"pipeline": "12h0m0s", "tasks": "11h50m0s"},
    "params": [
      {"name": "services", "value": "acl-service,core-service"},
      {"name": "selection-mode", "value": "manual"},
      {"name": "source-revision", "value": "test"}
    ],
    "workspaces": [{"name": "git-credentials", "secret": {"secretName": "git-credentials"}}]
  }
}
JSON
```

Stop `oc proxy` with Ctrl-C after testing; keep it localhost-only.

## Watch, results and storage

Use the parent name printed by create/curl:

```bash
read -r -p 'Parent PipelineRun name: ' BATCH
oc -n devops get pipelinerun "$BATCH"
oc -n devops get pipelineruns -l "customer.mofa.gov.sa/batch=$BATCH"
oc -n devops get pvc -l pipeline=backend-dispatch \
  -L customer.mofa.gov.sa/batch,customer.mofa.gov.sa/service
oc -n devops get pipelinerun "$BATCH" -o jsonpath='{.status.results}{"\n"}'
```

One child per selected service: settings, clone, test, build, ACS scan, gate,
sign. No verification, Helm publication or GitOps deployment in this build path.
Those remain promotion work. Backend test failures are blocking by default.
The UI shows a small parent and separate child PipelineRuns, not 14 lanes in one
graph. A failed child stops queued services; already-active children finish.

`release-record` is the name of an immutable ConfigMap containing `release.json`:
full SHA, selected services, successful image digests, failed and unstarted
services. Inspect/export it before pruning. It is build evidence, not proof of
deployment or promotion approval. A no-change diff succeeds with no child images.

Each child gets a separate 3Gi PVC, labeled `pipeline=backend-dispatch`, batch
and service. PVC names remain Tekton-generated; use labels, not name matching.
The parent uses no PVC. `maxParallel: 3` limits running children per batch (9Gi
active claims), NOT total retained storage or concurrency across separate batches.
Fourteen retained claims can still request 42Gi. No shared per-service PVC is
used, so simultaneous runs cannot overwrite another run's workspace.

To remove only one completed batch's workspaces while keeping runs/logs/results,
first confirm every child is terminal and no Pods are still using its PVCs:

```bash
oc -n devops get pipelineruns -l "customer.mofa.gov.sa/batch=$BATCH"
oc -n devops get pvc -l "pipeline=backend-dispatch,customer.mofa.gov.sa/batch=$BATCH"
# DESTRUCTIVE: only after checking the batch is complete and its data is no longer needed.
oc -n devops delete pvc -l "pipeline=backend-dispatch,customer.mofa.gov.sa/batch=$BATCH"
```

These labels apply to NEW dispatcher PVCs, not old fanout runs. Do not bulk-delete
all namespace PVCs. Rerun by creating a new parent; it allocates fresh workspaces.
Deleting a parent also garbage-collects its child runs, PVCs and result ConfigMap;
archive needed records first and coordinate any installed pruning policy.

Cancellation: cancelling a parent can terminate its dispatcher before it cancels
children. Explicitly cancel active children too (or delete the batch deliberately).
Each child has a two-hour limit. The dispatcher has an eleven-hour limit. Do not
edit the Helm catalog/allowlist while a batch is active.

## Optional Azure PR mode

Disabled by default. Both modes use `application-backend-dispatch`; PR mode sets
`selection-mode=diff`, with the full source and target SHAs from the Azure event.
It compares source against merge-base, not just the last commit. Changes inside
an executable project's Dockerfile directory select that service; shared code,
libraries/contracts, build metadata and unmapped paths conservatively select all
allowed services. Missing shallow history also selects all. No changed files
means no children. This is not a complete .NET dependency graph.

Before enabling, verify the installed Pipelines/Triggers versions and RBAC:

```bash
oc get csv -A
oc get clusterrole tekton-triggers-eventlistener-roles tekton-triggers-eventlistener-clusterroles
oc get clusterinterceptor cel
```

Create the webhook Basic Authorization secret in Bash without putting the password
in Git or a command argument. Choose the same username/password in Azure:

```bash
read -r -p 'Webhook username: ' WEBHOOK_USER
read -r -s -p 'Webhook password: ' WEBHOOK_PASSWORD; printf '\n'
{ printf 'Basic '; printf '%s:%s' "$WEBHOOK_USER" "$WEBHOOK_PASSWORD" | base64 | tr -d '\r\n'; } |
  oc -n devops create secret generic backend-pr-webhook-auth --from-file=authorization=/dev/stdin
unset WEBHOOK_PASSWORD WEBHOOK_USER
```

Set `backendBuild.dispatch.triggers.enabled: true` in the customer overlay and
repeat Helm upgrade. Helm installs the listener, binding/template, RBAC and edge
TLS Route; no nginx proxy is needed. Confirm the listener is Ready and the service
has endpoints before sending events:

```bash
oc -n devops get eventlistener backend-pr
oc -n devops get svc el-backend-pr
oc -n devops get endpointslice -l kubernetes.io/service-name=el-backend-pr
oc -n devops get route backend-pr-webhook -o jsonpath='https://{.spec.host}{"\n"}'
oc -n devops logs deployment/el-backend-pr --all-containers --tail=100
```

Configure Azure service hooks for PR created/updated, repository
`RedHat_UnifiedVisaPlatform.Backend`, target branch `test`, the above HTTPS URL
and Basic auth credentials. The filter requires active internal PRs, exact
configured repository remoteUrl, both full SHAs, and rejects fork PRs. It builds
the source SHA, not a synthetic merge commit. Repeated PR ID + source/base SHAs
reuse one event name; manually create a new parent to retry a failed identical
revision. An HTTP acceptance response alone is not proof a PipelineRun succeeded.

Only trusted contributors should invoke builds: source code executes with existing
pipeline credentials. The dispatcher has namespaced PipelineRun create/get/patch
and ConfigMap create/get permissions. Creating PipelineRuns remains a powerful
permission; this is not an untrusted-public-PR sandbox.

## Simulated Azure PR curl (no authentication, restricted-network test)

This tests the real backend webhook Route, CEL filter and diff dispatcher, unlike
the Kubernetes API curl above. No Azure service-hook creation permission is
needed. As requested for the restricted customer network, this test explicitly
disables webhook authentication. No authentication Secret, username, password,
Authorization header or Secret lookup is used. Skip the Secret creation section
above for this mode. Anyone able to reach the Route can submit matching requests;
repository/branch filters are not authentication. Keep access restricted.

Enable the listener first, from appdev (retain your other existing Helm overlays):

```bash
helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/devops-apply/values-devops.yaml \
  -f customer-transfer/backend-build-fanout/values-backend.yaml \
  --set backendBuild.dispatch.triggers.enabled=true \
  --set backendBuild.dispatch.triggers.authRequired=false
oc -n devops get eventlistener backend-pr
oc -n devops get route backend-pr-webhook
```

Chart defaults remain authenticated and triggers remain disabled. The command
above explicitly enables this temporary unauthenticated test. To retain it across
upgrades, set both values in your customer overlay deliberately. Restore
`backendBuild.dispatch.triggers.authRequired=true` and create the Secret when
switching to authenticated hooks, or disable the listener after testing.

Run the script **inside the backend source checkout**, on a
branch with changes relative to `test`. Push its commit first. The customer route
and repository are filled in; both commits are real, not random placeholders.
The route below is the expected default host; check it against `oc get route`
above if your cluster uses a custom hostname. Do not run with `set -x`.

```bash
# From appdev, switch to the sibling backend checkout first:
cd ../RedHat_UnifiedVisaPlatform.Backend
bash ../appdev/customer-transfer/backend-build-fanout/simulate-pr.sh
```

The script contains the complete curl with the configured customer Route and
repository. Run it with `bash`, not `source`. It validates the checkout and exits
only its own process on failure, leaving your SSH session open. If your checkouts
are not sibling directories, adjust only the local paths above.

If HEAD already equals `test`, test without creating a branch or editing code:

```bash
# Run inside the backend checkout, after pulling the latest appdev scripts.
bash ../appdev/customer-transfer/backend-build-fanout/simulate-pr.sh --previous-commit
```

This sends a synthetic PR event with HEAD as source and its first parent as
target. Both are real commits, but the target SHA intentionally does not represent
the current `test` branch tip. It exercises the webhook and dispatcher using the
last commit's diff; it does not create a real PR or force all services. HEAD must
already be pushed and its parent available locally (not a depth-one checkout).
No Git network lookup or credential prompt is used by this simulation option.

Git may separately prompt for Azure repository credentials when resolving `test`.
This is not a webhook password prompt. The simulated PR ID is timestamp-based
so each test starts a fresh batch. No real PR is created in Azure. Selection is
still based on the real merge-base diff, so this does not force all 14 services.

```bash
oc -n devops get pipelineruns -l customer.mofa.gov.sa/trigger=azure-pr \
  --sort-by=.metadata.creationTimestamp
oc -n devops logs deployment/el-backend-pr --all-containers --tail=100
```

## Webhook accepted but no PipelineRun: authorization check

HTTP 202 means receipt, not successful PipelineRun creation. Check permission:

```bash
oc auth can-i create pipelineruns.tekton.dev \
  --as=system:serviceaccount:devops:backend-pr-listener -n devops
```

Only if the answer is `no`, have an administrator apply this namespaced repair:

```bash
oc -n devops create role backend-pr-create-runs \
  --verb=create \
  --resource=pipelineruns.tekton.dev \
  --dry-run=client -o yaml | oc apply -f -

oc -n devops create rolebinding backend-pr-create-runs \
  --role=backend-pr-create-runs \
  --serviceaccount=devops:backend-pr-listener \
  --dry-run=client -o yaml | oc apply -f -

oc auth can-i create pipelineruns.tekton.dev \
  --as=system:serviceaccount:devops:backend-pr-listener -n devops
```

Expected: `yes`. From the backend checkout, resend the event:

```bash
bash ../appdev/customer-transfer/backend-build-fanout/simulate-pr.sh --previous-commit
```

The Helm chart already declares this permission in Role/RoleBinding
`backend-pr-listener`. The commands above create a separate temporary repair;
they do not repair a failed Helm release. Reconcile the Helm-managed RBAC and
remove the temporary binding/role once no longer needed. An impersonation error
from `oc auth can-i --as` means your login cannot perform the check; it is not
evidence that the listener lacks permission.

If permission already returns `yes`, do not add more access. Inspect the error:

```bash
oc -n devops logs deployment/el-backend-pr --all-containers=true --since=15m --tail=200
oc -n devops get eventlistener backend-pr -o yaml
oc -n devops get triggerbinding backend-azure-pr
oc -n devops get triggertemplate backend-azure-pr
oc -n devops get pipeline application-backend-dispatch
oc -n devops get pipelineruns --sort-by=.metadata.creationTimestamp
```

## Validation and references

```bash
ruby tests/backend-build/dispatch-validate.rb
node tests/backend-build/dispatch.test.cjs
helm lint pipelines/chart -f customer-transfer/devops-apply/values-devops.yaml \
  -f customer-transfer/backend-build-fanout/values-backend.yaml
```

Local rendering and mocked JavaScript checks do not establish customer runtime
compatibility. Test two services manually first, then `all`, then PR mode.
Official references: [Tekton Triggers](https://tekton.dev/docs/getting-started/triggers/),
[CEL secret comparison](https://tekton.dev/vault/triggers-main/cel_expressions/),
[workspace claims](https://tekton.dev/docs/pipelines/workspaces/).
