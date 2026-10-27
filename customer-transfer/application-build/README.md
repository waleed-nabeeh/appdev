# Backend and frontend builds in one graph

Use the existing Helm chart `pipelines/chart`, release `release-pipeline`, namespace
`devops`, with this folder's **single values.yaml**. No extra values files or
`--set` arguments are needed.

The dispatcher is a short TaskRun that accepts a comma-separated service list.
It reads the Helm-installed fanout Pipeline, keeps only the selected lanes, then
creates **one build PipelineRun for that scope**. That run shows:

**Service selection → parallel clone/test/build/scan/gate/sign lanes → update-gitops**

Unselected services have no lanes, TaskRuns, results or PVCs in the generated run.
There are no per-service child PipelineRuns and no parent dispatcher PipelineRun.
The generated run stores its selected graph in `spec.pipelineSpec`, so later Helm
changes cannot add or remove its lanes. Its `tekton.dev/pipeline` label records
which Helm-installed template was used. The live console layout still requires
customer validation.

| Scope | Dispatcher Task | Helm-installed fanout template | Source branch | GitOps file |
| --- | --- | --- | --- | --- |
| Backend | `backend-build-dispatch` | `application-backend-build-fanout` | `test` | `app-chart/backend.yaml` |
| Frontend | `frontend-build-dispatch` | `application-frontend-build-fanout` | `pre-prod` | `app-chart/frontend.yaml` |

## Apply and test both scopes

From the customer appdev checkout:

```bash
git pull --ff-only origin develop
oc -n devops get secret git-credentials registry-auth npm-auth pipeline-proxy rhacs-auth

helm lint ./pipelines/chart -f customer-transfer/application-build/values.yaml
helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/application-build/values.yaml
```

After the upgrade succeeds, launch both builds:

```bash
oc create --dry-run=server -f customer-transfer/application-build/dispatches.yaml
oc create -f customer-transfer/application-build/dispatches.yaml
oc -n devops get pipelineruns -l app.kubernetes.io/part-of=application-build
```

The file contains two dispatcher TaskRun documents, each defaulting to `services:
all`. That means the currently enabled 14 backend services or three frontends.
Helm itself starts no builds. The dispatcher logs and its `pipeline-run` result
identify the created run, named `backend-build-fanout-...` or
`frontend-build-fanout-...`. Open that **PipelineRun** for the selected-lane graph.
A successful dispatcher TaskRun means the build was created; check the build
PipelineRun's own Succeeded condition for the build/GitOps outcome.

## Choose services for each run

Edit `dispatches.yaml` before `oc create`. For a two-service backend example:

```yaml
- name: services
  value: "acl-service,core-service"
```

For a single frontend, use `value: "admin-portal"`; for two, use
`value: "admin-portal,applicant-portal"`. No Helm upgrade is needed to choose fewer
services. Keep only one TaskRun document to launch a single scope. To change the
service selection, launch a new dispatcher TaskRun; editing the recorded services
parameter on an already-generated build run does not regenerate its graph.

| Input | Manual use |
| --- | --- |
| `services` | `all` or comma-separated allowed names; spaces trimmed, duplicates deduplicated, unknown/empty names rejected. |
| `source-revision` | Prepared source branch: backend `test`, frontend `pre-prod`. |
| `source-commit` | Empty resolves branch HEAD once; optionally supply a full 40-character SHA to rebuild the same source. |
| `selection-mode` | `manual` for the supplied list; `diff` for PR integration. |
| `target-commit` | Omit for manual; full target SHA required for `diff`. |

The allowed names are the `selectedServices` lists in `values.yaml`. Backend
currently enables `acl-service`, `administration-service`, `audit-logging-service`,
`core-service`, `identity-service`, `language-service`, `document-service`,
`event-service`, `notification-service`, `request-service`, `stakeholder-service`,
`applicant-service`, `visitvisa-service`, `realtime-service`. Frontend enables
`admin-portal`, `applicant-portal`, `operational-portal`.

The backend catalog supports 17 services. Add prepared services to the allowed
list and apply Helm before selecting more than the current 14. Gateway, Payment
and AuthServer remain excluded by default; confirm their source Dockerfiles and
GitOps application entries before enabling them. Empty backend `selectedServices`
enables all 17 catalog entries. Names must match the catalog exactly.

## Build, GitOps and storage

Each lane reuses the working build Tasks, with `CERT_KEYWORD=dev` for backend and
`BUILD_ENVIRONMENT=dev` for frontend. Tags are the bare first eight source commit
characters. Frontend unit-test failure remains temporarily allowed; build, scan,
gate and sign failures block GitOps. Signature verification belongs to promotion.

The final GitOps Task receives only selected build results and updates only their
image tags in `RedHat_HelmCharts`, branch `dev`, in the scope's file above.
`git-credentials` must have source read and GitOps write access, and the target
entries must already exist with matching image repositories. Backend/frontend
writes to different files can coexist; a same-file push race fails for review.
Argo CD must watch and sync these values for deployment. This flow updates Git;
it does not publish an OCI chart or invoke Argo CD.

The dispatcher uses emptyDir and no PVC. The build allocates one isolated **3Gi
PVC per selected service**, labeled `pipeline=backend-build-fanout` or
`pipeline=frontend-build-fanout`, plus `service`. Two selected services request 6Gi;
14 backend plus three frontend services request 51Gi. All selected lanes can run
in parallel as in the working fanout; the earlier child-dispatch `maxParallel`
setting does not limit this graph. Completed runs retain PVCs until pruned or
deleted. Pruning the short-lived dispatcher will not delete the build run.
No pruner is installed by this change.

## PR integration and checks

The existing routes are Helm-maintained and feed the same dispatcher Tasks:

- `https://backend-pr-webhook-devops.apps.hub-visa-ocp.mofa.gov.sa/`
- `https://frontend-pr-webhook-devops.apps.hub-visa-ocp.mofa.gov.sa/`

Azure PR created/updated payloads supply the source branch, source SHA and target
SHA, with `selection-mode: diff`. Shared/unmapped changes or insufficient merge-base
history select all enabled services conservatively. A no-change diff creates no
build run. Auth remains disabled for this restricted-network test as requested.
The frontend route points directly at its listener, replacing the old proxy flow.
Azure service hooks and live controller reconciliation still need customer testing.

```bash
oc -n devops get tasks backend-build-dispatch frontend-build-dispatch
oc -n devops get taskruns -l app.kubernetes.io/part-of=application-build
oc -n devops get pipelineruns -l app.kubernetes.io/part-of=application-build
oc -n devops get eventlisteners backend-pr frontend-pr
oc -n devops get route backend-pr-webhook frontend-pr-webhook
```

Local validation covers Helm rendering, generated 1/2/14/17-backend and 1/2/3-frontend
graphs, Task/results/workspace bindings, selected-only PVCs and GitOps data,
namespace RBAC, launch retry/no-op handling, shell syntax and Git push races.
JavaScript simulations use V8 with mocked API/filesystem access. No customer
build, registry write or Argo deployment was executed here.

References: [embedded Pipeline specifications](https://tekton.dev/docs/pipelines/pipelineruns/#specifying-a-pipeline),
[TaskRun context variables](https://tekton.dev/docs/pipelines/variables/).
