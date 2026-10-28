# Frontend and backend application builds

Helm chart: `pipelines/chart/`. Release: `release-pipeline`. Namespace: `devops`.
Use this folder's **single values.yaml**; no other overlays or `--set` flags are
required for the current customer setup.

## Manual start in the OpenShift console

1. Select project **devops**, then **Pipelines → Pipelines**.
2. Choose **application-backend-build** or **application-frontend-build**.
3. Select **Start**. The Pipeline provides defaults for the full service list,
   source URL, source revision, `env: dev`, and optional commit/diff inputs.
4. Change only `services` for the usual manual test, for example
   `acl-service,core-service` or `admin-portal,applicant-portal`.
5. Leave `selection-mode: manual` and the other defaults, then select **Start**.
   Use the existing `pipeline` service account if the form asks for one.
6. The short entry run prepares the build. Its **build-pipeline-run** result names
   the actual run: `backend-build-fanout-...` or `frontend-build-fanout-...`.
   Open that run to see every selected service lane and the final GitOps task.

The console entry declares **no workspaces**. Credential mounts, approved images,
source defaults, build arguments and selected-service PVCs are managed internally.
You see one short launcher PipelineRun plus one build PipelineRun per scope.
There are no per-service child PipelineRuns. A successful launcher means the
build was created; check the actual build run's status for the build/GitOps outcome.
The console interaction still needs live validation on the customer cluster.

| Scope | Start this Pipeline | Defaults | Actual build template | GitOps file |
| --- | --- | --- | --- | --- |
| Backend | `application-backend-build` | 14 services, source branch `test`, env `dev` | `application-backend-build-fanout` | `app-chart/backend.yaml` |
| Frontend | `application-frontend-build` | 3 portals, source branch `pre-prod`, env `dev` | `application-frontend-build-fanout` | `app-chart/frontend.yaml` |

Both GitOps files are updated in **RedHat_HelmCharts**, branch **dev**. Their
application keys use the preproduction prefix: `acl-service` updates
`pre-acl-service.overrideValues.image.tag`, and `operational-portal` updates
`pre-operational-portal.overrideValues.image.tag`, under
`argocd-applications.applications`. The single values file sets
`dispatch.gitops.applicationNamePrefix: "pre-"` and `applicationNameSuffix: ""`
for both scopes. Keep service inputs and Quay image names without that prefix.
Only selected services' tags change; a missing `pre-` entry fails the update.
Existing applications must already be present in the two destination files.

## Apply Helm and test from the CLI

From the customer appdev checkout:

```bash
git pull --ff-only origin develop
helm lint ./pipelines/chart -f customer-transfer/application-build/values.yaml
helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/application-build/values.yaml
```

After the upgrade succeeds, these two manual PipelineRun files start the same
entry Pipelines as the console. They supply **only services** as a parameter:

```bash
oc create -f customer-transfer/application-build/backend-pipelinerun.yaml
oc create -f customer-transfer/application-build/frontend-pipelinerun.yaml
oc -n devops get pipelineruns -l app.kubernetes.io/part-of=application-build
```

Edit `params.services` in either file before creating it. All other inputs come
from Pipeline defaults. The manual files use the existing `pipeline` service
account and need no workspace bindings. Helm installation itself starts no builds.
Required existing Secrets are `git-credentials`, `registry-auth`, `npm-auth`,
`pipeline-proxy` and `rhacs-auth`. The dispatcher also retains its optional
credential workspace for earlier standalone TaskRun examples.

## Parameters and selected-only graphs

| Parameter | Default / use |
| --- | --- |
| `services` | Explicit full comma-separated enabled list. Edit to choose fewer; `all` is also accepted. Spaces are trimmed, duplicates deduplicated, unknown/empty names rejected. |
| `source-url` | Matching customer backend/frontend HTTPS repository URL. Used for resolution and cloning. |
| `source-revision` | Backend `test`; frontend `pre-prod`. |
| `env` | `dev`. Backend builds receive `CERT_KEYWORD=$(params.env)`; frontend builds receive `BUILD_ENVIRONMENT=$(params.env)`. |
| `source-commit` | Empty resolves the source branch once; optionally provide a full SHA for a rebuild. |
| `image-tag` | Empty uses the first eight source SHA characters. Optional manual tag, such as `pre-test-20261028-01`, applies to every selected image and its GitOps entry. |
| `selection-mode` | `manual` for console/CLI service lists; PR triggers supply `diff`. |
| `target-commit` | Empty for manual; a full target SHA is required for diff selection. |

For a manual tag in the console, open **application-backend-build** or
**application-frontend-build → Start**, select your comma-separated `services`,
and set **image-tag** to `pre-test-20261028-01` (choose a fresh tag for each test).
Keep `env: dev` and the other source defaults unless needed. The dispatcher
passes the tag through build, scan, gate, sign and the final GitOps update.
For example, `acl-service` builds `devops/acl-service:pre-test-20261028-01` and
updates `pre-acl-service.overrideValues.image.tag` to that exact value.
This builds from the selected source; it does not just retag an existing image.
Reusing a tag already present in GitOps can produce no Git change; with tag-only
deployment values it also does not guarantee a rollout. PR triggers continue
using automatic commit tags by default. Manual tags use the
[OCI tag format](https://github.com/opencontainers/distribution-spec/blob/main/spec.md#pulling-manifests),
up to 128 ASCII characters with letters, numbers, underscores, dots and hyphens;
the first character must be a letter, number or underscore.

The entry Pipeline calls the same dispatcher used for PRs. Before starting the
build, it copies the Helm-installed fanout template and retains only selected
lanes, their results/workspaces, and one GitOps task. The generated build run
stores this graph in `spec.pipelineSpec`. Unselected services have no lanes,
TaskRuns or PVCs. Changing the services parameter on an already-prepared build
cannot regenerate its graph; start the entry Pipeline again with the new list.

Backend allows `acl-service`, `administration-service`, `audit-logging-service`,
`core-service`, `identity-service`, `language-service`, `document-service`,
`event-service`, `notification-service`, `request-service`, `stakeholder-service`,
`applicant-service`, `visitvisa-service`, `realtime-service`. Frontend allows
`admin-portal`, `applicant-portal`, `operational-portal`.

The allowlists are `selectedServices` in values.yaml. The backend catalog contains
17 services; add prepared services and reapply Helm to allow more than the current
14. Gateway, Payment and AuthServer are excluded by default; prepare their source
Dockerfiles and GitOps entries before enabling them. Empty backend selectedServices
enables all 17 known catalog entries. Every selected lane reuses:

**clone → test → build/push → ACS scan → policy gate → sign → final combined GitOps update**

Frontend unit-test failure remains temporarily allowed. Build, scan, gate and
sign failures block GitOps. Verification belongs to promotion. Tags remain the
bare first eight source-commit characters. Different env builds of the same commit
therefore share a tag; env does not select a different GitOps destination.

## GitOps, storage and alternate entry points

Both scopes update `RedHat_HelmCharts`, branch `dev`, in the file listed above.
The final updater consumes only selected build results and changes only those
application image tags. The matching YAML entries and Quay repositories must
exist. `git-credentials` needs source read and GitOps write access. Updates to
different files can coexist; a concurrent same-file update is rejected.
Argo CD must watch and sync these values to deploy them. This flow updates Git;
it does not publish an OCI Helm chart or directly invoke Argo CD.

The entry allocates no PVC. The build allocates one 3Gi PVC per selected service,
with `pipeline` and `service` labels. Two services request 6Gi; 14 backend plus
three frontends request 51Gi. Selected lanes run in parallel. Completed builds
retain PVCs until runs are pruned/deleted; no pruner is enabled here. Pruning the
short launcher must not delete the independent build run.

The direct `application-*-build-fanout` Pipelines remain valid for full configured
service runs with explicit workspace bindings from their `*-build-run-template`
ConfigMaps. For the simple console flow and any service subset, use the
`application-*-build` entries above. The earlier `dispatches.yaml` standalone
TaskRun examples are still supported but are not needed for the normal UI flow.

## Azure PR triggers

Helm installs routes for both scopes:

- `https://backend-pr-webhook-devops.apps.hub-visa-ocp.mofa.gov.sa/`
- `https://frontend-pr-webhook-devops.apps.hub-visa-ocp.mofa.gov.sa/`

PR created/updated events start **the same application-*-build entry Pipelines**,
with diff mode, source branch, source SHA and target SHA. Shared/unmapped changes
or insufficient merge-base history select all enabled services conservatively.
A no-change diff creates no build. Current restricted-network test authentication
remains disabled as requested. Azure hook registration/delivery still needs the
customer administrator and live verification.

```bash
oc -n devops get pipelines application-backend-build application-frontend-build
oc -n devops get eventlisteners backend-pr frontend-pr
oc -n devops get route backend-pr-webhook frontend-pr-webhook
oc -n devops auth can-i create pipelineruns --as=system:serviceaccount:devops:pipeline
oc -n devops auth can-i get pipelines/application-backend-build-fanout --as=system:serviceaccount:devops:pipeline
```

Local validation covers Helm render/lint, default/manual/PR input wiring, no-input
workspace entry Pipelines, credential fallback, namespace RBAC, selected-only
1/2/14/17-backend and 1/2/3-frontend graphs, PVCs, GitOps results and launch retry/no-op
behavior. JavaScript tests use V8 with mocked filesystem/API access. No customer
build, registry write, console click-through or Argo deployment was executed here.

References: [Tekton PipelineRun specifications](https://tekton.dev/docs/pipelines/pipelineruns/),
[Red Hat console workflow](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.22/html/creating_cicd_pipelines/working-with-pipelines-web-console).
The console reference is for 1.22; the customer reports Pipelines 1.23.2.
