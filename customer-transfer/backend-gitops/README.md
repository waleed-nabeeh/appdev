# Backend and frontend GitOps test

All deliverables are in appdev. The reference repository under `Mofa/wel` is
READ-ONLY and has not been edited. Customer screenshot confirms:

- Repository: `RedHat_argocd`
- Branch: `pre-production`
- Directory: `pre-production/apps/`

## Files to copy

| From this folder | Customer GitOps destination | Contents |
| --- | --- | --- |
| `backend.yaml` | `pre-production/apps/backend.yaml` | 15 existing backend definitions |
| `frontend.yaml` | `pre-production/apps/frontend.yaml` | Three frontend portals |

Create/paste these two files in Azure Repos on branch **pre-production**, not in
the backend source repo. These are Helm values files, not manifests for `oc apply`.
They replace the requested combined core.yaml with the agreed split. Integration
services are excluded. Payment and AuthServer are not in the reference core-apps
file, so no deployment definitions were invented for them.

The normal `argocd-applications.applications` YAML structure is retained.
Repositories use `quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/<service>`.
All application Route hosts now end in `apps.pre-visa-ocp.mofa.gov.sa`.
Secret file mode 0400 is represented as decimal 256 (same permission).

IMPORTANT: initial image tags are inherited from the reference, not verified
artifacts in hub Quay. Auto-sync is false for the first Git-update-only test.
Do not sync applications until the images and environment configuration are ready.
Gateway and frontend tags remain unchanged by the 14-service backend run.

## Run backend and frontend fanout

1. Copy and commit both values files to the GitOps destination above.
2. Ensure `git-credentials` in devops can read the backend source and read/write
   `RedHat_argocd` on `pre-production`. Branch policy must permit this automation
   commit; the Task does not create an Azure PR or bypass branch policy.
3. From appdev apply the Helm overlay, retaining your existing frontend/trigger
   overlays or flags. No changes to the working child build stages are required:

```bash
helm lint pipelines/chart \
  -f customer-transfer/devops-apply/values-devops.yaml \
  -f customer-transfer/backend-build-fanout/values-backend.yaml \
  -f customer-transfer/backend-gitops/values-gitops.yaml

helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/devops-apply/values-devops.yaml \
  -f customer-transfer/backend-build-fanout/values-backend.yaml \
  -f customer-transfer/backend-gitops/values-gitops.yaml

oc -n devops get tasks backend-gitops-base backend-gitops-update
oc create -f customer-transfer/backend-gitops/pipelinerun.yaml
oc create -f customer-transfer/frontend-release-test/pipelinerun.yaml
```

The backend example selects `all` for the configured 14. Change `params.services`
to `acl-service,core-service` or another allowed subset for a smaller test. Backend source
is still `test`, with `CERT_KEYWORD=dev`. The GitOps destination branch is
`pre-production`; these are deliberately separate settings.

The frontend run builds all three portals from `pre-prod`, using
`BUILD_ENVIRONMENT=dev`. The overlay enables ACS scan and gate for all three,
then sign and update of `pre-production/apps/frontend.yaml`. Frontend unit tests
still allow failure temporarily; scan/gate failures block GitOps. Verification is
disabled in this test overlay for promotion later, not bypassed inside a verify Task.

The dispatcher captures the GitOps branch SHA before starting children. After
every selected child succeeds through scan, gate and sign, `update-gitops`:

1. Clones RedHat_argocd/pre-production and checks its target file has not changed during builds.
2. Reads the immutable successful batch ConfigMap and validates service names,
   full source SHA, eight-character tag, hub repository and recorded image digest.
3. Parses backend.yaml and updates only
   `argocd-applications.applications.<service>-dev.overrideValues.image.tag`.
4. Commits only backend.yaml and pushes without force.

If a child fails, no GitOps task runs. Missing app entries, mismatched repositories,
incomplete records or concurrent changes to the SAME GitOps file fail closed.
A no-change diff creates no image updates. Backend and frontend can run together:
changes to the other file are allowed. On a push race, the Task fetches and rebases
its single update commit only when the target file is unchanged, then retries up
to three times. No force push is used. Review a rejected same-file update before rerunning.

The YAML parser preserves values and normal YAML layout, but serializes the file:
comments and quote/sequence formatting can be normalized on the first update.
Semantic tests assert every unselected application and every non-tag field stays
unchanged. No npm downloads, yq installation or extra PVC is needed at runtime.

## Check the result

```bash
oc -n devops get pipelineruns --sort-by=.metadata.creationTimestamp
read -r -p 'Parent PipelineRun name: ' RUN
oc -n devops get taskruns -l "tekton.dev/pipelineRun=$RUN"
oc -n devops logs -l "tekton.dev/pipelineRun=$RUN,tekton.dev/pipelineTask=update-gitops" \
  --all-containers=true --tail=100 --prefix=true
```

In Azure Repos, inspect the commit on pre-production. For the two-service example,
only ACL and Core image tag values should change to the source commit's first
eight characters. Other backend tags and the entire frontend.yaml stay unchanged.
For `all`, 14 backend tags change and Gateway remains untouched.

GitOps updates require BOTH Helm `backendBuild.dispatch.gitops.enabled: true` and
PipelineRun `update-gitops: "true"`. Existing manual runs and Azure PR templates
default to false, so enabling the Task does not turn the unauthenticated webhook
into a deployment endpoint. The fixed 14-lane fanout remains build-only; use the
dispatcher PipelineRun for this update test.

The overlay explicitly switches `application-frontend-release-test` from its old
JSON release record to frontend.yaml. The older validation/PR pipeline is not
rewired. Use the two PipelineRun commands above for this test. Neither run calls
Argo directly or publishes a chart; both only commit their respective values file.

## Argo CD setup after the Git test

Changing Route hostnames does NOT choose the deployment cluster. The reference
still has app names ending `-dev`, namespaces `dev-backend`/`dev-frontend`, worker
hostname affinity, Secret names and chart version `app-chart:1.0.0`. Those were
preserved rather than guessed. Confirm or update them for preprod before sync.
The customer must confirm Argo's registered preprod destination name/API URL,
AppProject permissions, app namespaces, existing Secrets and worker labels.

The parent Application must point to RedHat_argocd, branch `pre-production`, path
`pre-production`. In its existing `spec.source.helm.valueFiles`, replace the old
combined core-apps entry with these two entries, retaining other required files:

```yaml
valueFiles:
  - apps/global.yaml
  - apps/backend.yaml
  - apps/frontend.yaml
```

Do not keep old definitions of the same app keys in another loaded values file.
Helm merges values, so simply adding the split files while still loading the old
core-apps.yaml can retain integration apps. Review any Argo prune operation before
removing already-managed applications from the desired configuration.

Check the parent chart dependency registry and global child chart repoURL in
`pre-production/Chart.yaml` and `pre-production/apps/global.yaml`: the reference
uses the old central Quay. The required app-chart and argocd-applications chart
versions must exist in an approved accessible registry with Argo credentials.
This tag-update Task does not package or push OCI charts.

Keep the parent unsynced during the initial Git-only test. After reviewing the
rendered Applications and environment settings, sync the parent, then the intended
child applications. Enable automated sync deliberately only after validation.
The backend updater never changes autoSync or root configuration.

Signature verification remains promotion work; this build-only tag update does
not claim verified promotion. Tags are eight-character SHA strings, not digest
pins. Digests remain in the batch record. Verify and deploy by digest in the
promotion workflow before claiming immutable production delivery.

For rollback, revert the reviewed GitOps commit and sync only the intended apps.
Reverting tags requires the previous image artifacts to still exist. Do not
overwrite the current GitOps files with these starter files after successful runs.

## Local checks

```bash
ruby tests/backend-build/gitops-validate.rb
node tests/backend-build/gitops.test.cjs
```

Local tests are not a live cluster deployment. The current environment has no Node
CLI, so the JavaScript tests were executed in the tool's V8 runtime using the same
bundled YAML parser and actual input files. Real container execution, Azure Git
permissions and Argo sync still need customer validation.

References: [Argo CD Helm values](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/),
[app-of-apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/).
