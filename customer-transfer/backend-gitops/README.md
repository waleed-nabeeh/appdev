# Backend and frontend GitOps test

All deliverables are in appdev. The reference repository under `Mofa/wel` is
READ-ONLY and has not been edited. Customer screenshot confirms:

- Repository: `RedHat_HelmCharts`
- Branch: `dev`
- Directory: `app-chart/`

This destination replaces RedHat_argocd/pre-production because the current user
does not have write access there. Both updater Tasks use the accessible HelmCharts
repository. This tests Git tag updates only; it does not repoint Argo CD or publish
an OCI chart. No local reference repository is modified by this configuration.

## Files to copy

| From this folder | Customer GitOps destination | Contents |
| --- | --- | --- |
| `backend.yaml` | `app-chart/backend.yaml` | 15 existing backend definitions |
| `frontend.yaml` | `app-chart/frontend.yaml` | Three frontend portals |

Create/paste these two files in Azure Repos on branch **dev**, not in
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

## Run backend fanout with GitOps

The backend test now uses **application-backend-build-fanout**, the working
14-lane Pipeline, with the existing `pipeline` service account. It adds one
GitOps update after all selected signing tasks, with no separate base-check task.
It does not launch the dispatcher parent or child PipelineRuns.
With this overlay installed, `update-gitops` is a normal stage in
`application-backend-build-fanout`, including console starts and the ordinary
Helm-generated run template. There is no `update-gitops` run parameter or `when`
guard. It runs after every selected service successfully completes signing.
Apply the Helm upgrade, then create a new run; existing runs keep their old spec.

1. Confirm both values files exist at the destination above. The customer's latest
   screenshot already shows them; do not overwrite existing updated tags with starter files.
2. Ensure `git-credentials` in devops can read the backend source and read/write
   `RedHat_HelmCharts` on `dev`. Branch policy must permit this automation
   commit; the Task does not create an Azure PR or bypass branch policy.
3. From appdev apply the Helm overlay, retaining your existing frontend/trigger
   overlays or flags. The clone/test/build/scan/gate/sign stages are reused:

```bash
git pull --ff-only origin develop

helm lint pipelines/chart \
  -f customer-transfer/devops-apply/values-devops.yaml \
  -f customer-transfer/backend-build-fanout/values-backend.yaml \
  -f customer-transfer/backend-gitops/values-gitops.yaml

helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/devops-apply/values-devops.yaml \
  -f customer-transfer/backend-build-fanout/values-backend.yaml \
  -f customer-transfer/backend-gitops/values-gitops.yaml

oc -n devops get tasks backend-gitops-base backend-gitops-update
oc -n devops get pipeline application-backend-build-fanout
oc create --dry-run=server -f customer-transfer/backend-gitops/pipelinerun.yaml
oc create -f customer-transfer/backend-gitops/pipelinerun.yaml
```

The checked-in run is for the configured 14 services. Backend source
is still `test`, with `CERT_KEYWORD=dev`. The GitOps destination branch is
`dev` in RedHat_HelmCharts; these are deliberately separate settings.

For a smaller test, set `backendBuild.selectedServices` in your Helm overlay
(for example `[acl-service, core-service]`) and repeat the upgrade. Then create
the run from Helm's generated ConfigMap so workspace bindings match the selection:

```bash
oc -n devops get configmap backend-build-run-template \
  -o jsonpath='{.data.gitops-pipelinerun\.yaml}' > /tmp/backend-gitops-run.yaml
oc create --dry-run=server -f /tmp/backend-gitops-run.yaml
oc create -f /tmp/backend-gitops-run.yaml
```

Use either the checked-in 14-service run or the generated run, not both.
This fixed fanout selects services at Helm render time. Runtime comma-separated
selection remains available separately through the dispatcher.
Each selected service has one isolated 3Gi PVC: 42Gi requested for 14 services,
6Gi for two. The GitOps tasks use `emptyDir` and add no PVCs.
The dispatcher's `maxParallel` setting does not limit this fixed fanout.

If your backend webhook is already enabled, preserve these flags on the upgrade:
`--set backendBuild.dispatch.triggers.enabled=true --set backendBuild.dispatch.triggers.authRequired=false`.
Helm changes do not restart a failed run: create a new run with the command above.

To retest frontend separately after applying this release:

```bash
oc create -f customer-transfer/frontend-release-test/pipelinerun.yaml
```

The frontend run builds all three portals from `pre-prod`, using
`BUILD_ENVIRONMENT=dev`. The overlay enables ACS scan and gate for all three,
then sign and update of `app-chart/frontend.yaml`. Frontend unit tests
still allow failure temporarily; scan/gate failures block GitOps. Verification is
disabled in this test overlay for promotion later, not bypassed inside a verify Task.

After every selected lane succeeds through scan, gate and sign, `update-gitops`:

1. Clones the current RedHat_HelmCharts/dev branch.
2. Takes the selected service list and image digests from the fanout's Task results
   and validates service names, full source SHA, eight-character tag and hub repository.
3. Parses backend.yaml and updates only
   `argocd-applications.applications.<service>-dev.overrideValues.image.tag`.
4. Commits only backend.yaml and pushes without force.

If a lane fails, the final GitOps update does not run. Missing app entries, mismatched repositories,
incomplete records or concurrent changes to the SAME GitOps file after the updater
clones it fail closed. Changes completed before that clone are used as the starting
point; this flow does not prevent an older build finishing later from publishing
its selected tags. Run releases for the same services in the intended order.
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
read -r -p 'Backend PipelineRun name: ' RUN
oc -n devops get taskruns -l "tekton.dev/pipelineRun=$RUN"
oc -n devops logs -l "tekton.dev/pipelineRun=$RUN,tekton.dev/pipelineTask=update-gitops" \
  --all-containers=true --tail=100 --prefix=true
```

In RedHat_HelmCharts, inspect the commit on dev. For the two-service example,
only ACL and Core image tag values should change to the source commit's first
eight characters. Other backend tags and the entire frontend.yaml stay unchanged.
For the default selection, 14 backend tags change and Gateway remains untouched.

GitOps tasks require Helm `backendBuild.dispatch.gitops.enabled: true` (with
`backendBuild.dispatch.enabled` enabled by values-backend.yaml). In the fixed
fanout, GitOps is a normal stage with no run switch. The separate dispatcher/Azure
PR flow still defaults to false.
Despite the existing `dispatch.gitops` setting name,
the same configuration now enables GitOps Tasks for both backend Pipelines.
The fixed fanout passes results directly and needs no additional API RBAC.

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

An Argo administrator must configure the parent app-of-apps to consume the files
from RedHat_HelmCharts/dev (or approve a separate transfer into the existing GitOps
repository). Until that is done, changes here will NOT deploy through an Application
still watching RedHat_argocd. Do not assume the directory name makes Argo discover them.

These files contain `argocd-applications.applications`, which are values for the
parent app-of-apps chart. They are NOT direct values for `app-chart/1.0.0` and
must not simply be passed to that workload chart. The parent needs the matching
argocd-applications dependency, global values, chart registry access and preprod
destination configuration. The administrator must choose the supported repository
layout or multi-source arrangement for the installed Argo version.

Do not load old and new definitions of the same app keys together. Review any
prune operation before removing already-managed apps. Required app-chart and
argocd-applications versions must exist in an approved accessible registry with
Argo credentials. This tag-update Task does not package or push OCI charts.

Keep the parent unsynced during the initial Git-only test. After reviewing the
rendered Applications and environment settings, sync the parent, then the intended
child applications. Enable automated sync deliberately only after validation.
The backend updater never changes autoSync or root configuration.

Signature verification remains promotion work; this build-and-tag-update run does
not claim verified promotion. Tags are eight-character SHA strings, not digest
pins. Digests remain in the build Task/Pipeline results (or the dispatcher batch
record when using that separate flow). Verify and deploy by digest in the
promotion workflow before claiming immutable production delivery.

For rollback, revert the reviewed GitOps commit and sync only the intended apps.
Reverting tags requires the previous image artifacts to still exist. Do not
overwrite the current GitOps files with these starter files after successful runs.

## PVC retention and cleanup

Keep the 3Gi workspaces isolated per service and per run. A shared named RWO PVC
can make parallel runs wait on attachment or overwrite each other's checkout.
With 14 lanes the active run requests 42Gi; pruning removes accumulation from old
runs but does not reduce that active capacity. To reduce peak use, select fewer
services or use the separate dispatcher with a concurrency limit.

New fixed-fanout PVCs carry `pipeline=backend-build-fanout` and `service` labels:

```bash
oc -n devops get pvc -l pipeline=backend-build-fanout
oc -n devops get pvc -o custom-columns=NAME:.metadata.name,OWNER:.metadata.ownerReferences[0].name,SIZE:.spec.resources.requests.storage
```

Recommended retention for this test: prune completed PipelineRuns older than
24 hours, hourly. Template-created PVCs have owner references and are garbage
collected when their owning PipelineRun is deleted. This removes run history,
TaskRuns and Pod logs as well, so archive results/logs needed for promotion first.
An explicit full rerun creates fresh PVCs. Old PVCs without owner references
need a separate review; namespace annotations do not clean arbitrary PVCs.

The customer reports OpenShift Pipelines 1.23.2. First inspect the active pruner:

```bash
oc get tektonconfig config -o jsonpath='{.spec.pruner}{"\n"}{.spec.tektonpruner}{"\n"}'
oc -n openshift-pipelines get deployments,cronjobs
```

If the Operator's scheduled/job-based pruner is active, the namespace admin can
apply this policy to devops only. It affects all completed PipelineRuns in devops,
including frontend, not just the backend test. It does not change other namespaces:

```bash
oc annotate namespace devops --overwrite \
  operator.tekton.dev/prune.skip="false" \
  operator.tekton.dev/prune.resources="pipelinerun" \
  operator.tekton.dev/prune.strategy="keep-since" \
  operator.tekton.dev/prune.keep-since="1440" \
  operator.tekton.dev/prune.schedule="0 * * * *"

oc -n openshift-pipelines get cronjobs,jobs
oc -n devops get pipelineruns --sort-by=.metadata.creationTimestamp
oc -n devops get pvc
```

Use only the active pruner mechanism. If `spec.tektonpruner` shows the event-driven
pruner enabled, configure retention through that existing controller instead;
do not enable a second pruner. If neither pruner is active, the platform admin
must enable/configure it before namespace annotations can have an effect.
No pruner or namespace modification is applied automatically by this Helm chart.
The 1.23 English configuration page was unavailable during preparation; the
scheduled annotation syntax was checked against accessible Red Hat 1.22 docs.
Confirm the installed pruner mode before applying these commands.

StorageClass reclaim policy also matters: `Retain` can leave backing PVs after
PVC deletion. Check it with `oc get storageclass` and have the storage admin
handle retained volumes. PVC labels alone do not perform automatic cleanup.

References: [Red Hat pruning configuration](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.22/html-single/installing_and_configuring/index),
[Tekton template PVC lifecycle](https://tekton.dev/docs/pipelines/workspaces/#volumeclaimtemplate).

## Local checks

```bash
ruby tests/backend-build/gitops-validate.rb
ruby tests/backend-build/dispatch-validate.rb
ruby tests/frontend-release/validate.rb
node tests/backend-build/gitops.test.cjs
```

Local tests are not a live cluster deployment. The current environment has no Node
CLI, so the JavaScript tests were executed in the tool's V8 runtime using the same
bundled YAML parser and actual input files. Real container execution, Azure Git
permissions and Argo sync still need customer validation.

The reported `chmod: /tekton/home: Operation not permitted` is addressed by
creating a private `/work/home` directory on an `emptyDir` in the backend resolvers.
The frontend `EACCES` when writing frontend.yaml is addressed in both updaters:
the Git clone step grants group read/write access to its checkout before the
Node step edits it. Credential HOME stays private. No root UID or extra SCC
grant is added. The customer's shared group permissions still need a live run;
if EACCES persists, collect `id` in both step images and `ls -ld` on the checkout
and target file to check their actual UID/GID and modes.

References: [Argo CD Helm values](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/),
[app-of-apps](https://argo-cd.readthedocs.io/en/stable/operator-manual/cluster-bootstrapping/),
[Tekton Task result dependencies](https://tekton.dev/docs/pipelines/pipelines/#using-results),
[Red Hat container file permissions](https://developers.redhat.com/blog/2020/10/26/adapting-docker-and-kubernetes-containers-to-run-on-red-hat-openshift-container-platform).
