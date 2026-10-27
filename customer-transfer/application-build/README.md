# Backend and frontend application builds

This is the current customer entry point. One `values.yaml` installs both scopes,
their dispatchers, shared build Tasks, GitOps updaters, RBAC and Azure PR triggers.
Do not combine it with the earlier example values files or add `--set` flags.
Existing fixed fanout Pipelines remain available for comparison; use the dispatcher
runs below for runtime service selection and selected-service PVC allocation.

| Scope | Parent Pipeline | Child Pipeline | Source branch | GitOps file |
| --- | --- | --- | --- | --- |
| Backend | `application-backend-dispatch` | `application-backend-service-build` | `test` | `app-chart/backend.yaml` |
| Frontend | `application-frontend-dispatch` | `application-frontend-service-build` | `pre-prod` | `app-chart/frontend.yaml` |

Both update `RedHat_HelmCharts`, branch `dev`. The application source branch and
GitOps branch are separate. Keep build arguments `CERT_KEYWORD=dev` and
`BUILD_ENVIRONMENT=dev` until the customer Dockerfiles support preprod inputs.
Infrastructure settings, approved image references, signing URLs, proxy Secret,
service allowlists and trigger settings live in `values.yaml`.

## Apply and run both scopes

From the customer appdev checkout, using the existing release:

```bash
git pull --ff-only origin develop
oc -n devops get secret git-credentials registry-auth npm-auth pipeline-proxy rhacs-auth

helm lint ./pipelines/chart -f customer-transfer/application-build/values.yaml
helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/application-build/values.yaml
```

Only after the upgrade succeeds, start both scopes:

```bash
oc create --dry-run=server -f customer-transfer/application-build/pipelineruns.yaml
oc create -f customer-transfer/application-build/pipelineruns.yaml
oc -n devops get pipelineruns --sort-by=.metadata.creationTimestamp
```

The run file contains two documents, one parent per scope. Keep only the desired
document when testing a single scope. Helm installation itself starts no builds.
The default `services: all` means the enabled 14 backend services or three portals,
not every service in the full reference catalog.

## Essential run inputs

Edit the two PipelineRun parameter sections before `oc create`, or enter the same
inputs in the OpenShift console. No Helm upgrade is needed to select fewer services.

| Parameter | Manual value | Purpose |
| --- | --- | --- |
| `services` | `all`, or `acl-service,core-service` / `admin-portal,applicant-portal` | Comma-separated names from that scope's allowlist; spaces are trimmed, duplicates deduplicated, unknown/empty names rejected. |
| `source-revision` | `test` / `pre-prod` | Prepared application source branch. |
| `source-commit` | Empty, or full 40-character SHA | Empty resolves the branch HEAD once; every selected build checks out that commit. Image tags are its bare first eight characters. |
| `selection-mode` | `manual` | Uses the supplied service list. PRs use `diff` instead. |
| `target-commit` | Empty/omitted for manual; full target SHA for `diff` | Merge-base comparison for PR selection. |

The frontend names are `admin-portal`, `applicant-portal`, `operational-portal`.
The backend names are `acl-service`, `administration-service`,
`audit-logging-service`, `core-service`, `identity-service`, `language-service`,
`document-service`, `event-service`, `notification-service`, `request-service`,
`stakeholder-service`, `applicant-service`, `visitvisa-service`, `realtime-service`.
The allowlists are the `selectedServices` lists in this one values file.

For example, changing backend `services` to `acl-service,core-service` creates two
child runs and two 3Gi PVCs. Changing frontend `services` to `admin-portal` creates
one child run and one 3Gi PVC. Each child runs clone, test, build/push, ACS scan,
policy gate and sign. Frontend unit-test failure is temporarily allowed; backend
tests, all builds, ACS and signing failures block the release. Verify belongs to
promotion. The parent updates GitOps only after every selected child succeeds,
using their validated image digests and source SHA. No GitOps run switch or
separate base-check Task is used in either dispatcher.

## GitOps and storage

`git-credentials` must read the source repositories and read/write
`RedHat_HelmCharts/dev`. The two YAML files must already exist with matching
application image repositories. The updater changes only selected
`<service>-dev.overrideValues.image.tag` entries; other settings and unselected
services remain unchanged. The YAML serializer can normalize comments/formatting.
Backend/frontend updates to different files can be rebased safely; a concurrent
change to the same file after checkout is rejected. A build finishing later can
publish its older source tag, so serialize overlapping releases of the same
services when moving beyond this manual test.

Argo CD must watch and sync these values for deployment. This flow commits Git;
it does not invoke Argo CD or package/push an OCI Helm chart.

Parents allocate no PVC. Children allocate one 3Gi PVC each, labeled
`pipeline=backend-dispatch` or `pipeline=frontend-dispatch`, plus parent and service
labels. Each parent allows three active child builds by default: together up to
six active children / 18Gi. Completed children retain their claims until owner
PipelineRuns are pruned/deleted; a full 14+3 run still requests 51Gi in total over
its lifetime. This does not install or enable a pruner. The existing retention
guidance is in [the GitOps README](../backend-gitops/README.md#pvc-retention-and-cleanup).

## PR integration

Both routes are installed by this values file:

- Backend: `https://backend-pr-webhook-devops.apps.hub-visa-ocp.mofa.gov.sa/`
- Frontend: `https://frontend-pr-webhook-devops.apps.hub-visa-ocp.mofa.gov.sa/`

Confirm actual hosts with `oc -n devops get route backend-pr-webhook frontend-pr-webhook`.
The frontend route now points directly at the dispatcher EventListener; this
configuration disables the old frontend validation/proxy webhook stack. Current
restricted-network test settings require no webhook authentication, as requested.
Azure service hooks for PR created/updated must use the corresponding source repo
and target branch above. The filters accept only active, non-fork PRs with valid
source/target commit IDs and the configured repository/target branch.

The TriggerTemplate starts the same parent with `selection-mode: diff`, source
branch, source SHA and target SHA. Backend service-directory changes select the
affected executable project; frontend app/deployment directories select the
affected portal. Shared, unmapped or build metadata changes select all enabled
services conservatively. Missing shallow merge-base history also selects all.
A no-change diff creates no child builds and leaves GitOps tags unchanged.
Azure service-hook delivery and live controller reconciliation still need the
customer test; a local render does not prove either works.

## Inspect one parent

```bash
oc -n devops get pipelines application-backend-dispatch application-frontend-dispatch
oc -n devops get eventlisteners backend-pr frontend-pr
oc -n devops get pipelineruns -l app.kubernetes.io/part-of=application-build
```

Set `RUN` to the created parent name to inspect its children and GitOps logs:

```bash
RUN=backend-build-dispatch-REPLACE_WITH_CREATED_SUFFIX
oc -n devops get pipelineruns -l "customer.mofa.gov.sa/batch=$RUN"
oc -n devops logs -l "tekton.dev/pipelineRun=$RUN,tekton.dev/pipelineTask=update-gitops" \
  --all-containers=true --tail=100 --prefix=true
oc -n devops get pvc -l pipeline=backend-dispatch
oc -n devops get pvc -l pipeline=frontend-dispatch
```

Locally validated with Helm lint/render, Task/Pipeline/result/workspace/RBAC
reference checks, JavaScript dispatcher/GitOps simulations in V8 with mocked
filesystem/API access, and real local Git race tests. The customer's Node image
and live OpenShift Pipelines 1.23.2 controller still require runtime validation.
No customer builds, registry writes or Argo deployments were executed here.

The trigger resources reuse the established EventListener/Binding/Template pattern
in [Red Hat's pipeline documentation](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.22/html/creating_cicd_pipelines/index).
That documentation is for 1.22; the installed version reported by the customer is
1.23.2. No new version-specific Pipelines feature is required by this change.
