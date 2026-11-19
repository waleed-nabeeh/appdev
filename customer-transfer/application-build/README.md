# Frontend and backend application builds

Helm chart: `pipelines/chart/`. Release: `release-pipeline`. Namespace: `devops`.
Use this folder's **single values.yaml**; no other overlays or `--set` flags are
required for the current customer setup.

The customer values enable **DMZ image builds for the full frontend/backend
workflows** (`remoteBuild.useForApplicationBuilds: true`). Clone, RHACS
scan/policy gate, signing and GitOps updates stay on Hub. Backend and frontend
unit tests are temporarily disabled in this customer configuration. Only container
build/push runs on the VM, with 14 shared build slots across both scopes.
For SSH, credentials, workspaces, smoke tests and rollback, use the
[DMZ build instructions](README-dmz-build.md).

For firewall/proxy preparation and the internal-only target, use the
[network access requirements](README-network-access.md). It separates package
feeds, registry/CDN downloads and conditional installer endpoints by source.

For the new Git-only copy of selected preproduction images into production and
DR values, use [Application Promotion](../application-promotion/README.md).
It uses this same values file and keeps the current application names unchanged.

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

For the first full-workflow validation, start one service per scope:
`acl-service` for backend and `admin-portal` for frontend. Once successful, expand
the service list. Other portals use their own Dockerfiles; apply the working
frontend builder image and required fixes there before selecting all three.
Backend unit tests are temporarily omitted with `backendBuild.testsEnabled: false`.
If restored, the existing test Task still runs on Hub and needs package access;
VM test execution has not been implemented. RHACS policy gates remain blocking for both application workflows.
Successful full runs update the selected `pre-` GitOps entries; Argo CD deployment
and application readiness must be checked separately.

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

For PRs, the dispatcher computes the merge-base diff between the supplied source
and target SHAs, then matches changed paths against the catalog. Backend service
paths include the full service folder: `services/acl/` selects ACL, including
changes in its sibling domain/application projects. Two changed service folders
select two lanes. Shared, certificate, unmapped or build dependency metadata
changes conservatively select all enabled services. The launcher logs changed
files and the resulting selection; no-change diffs create no build.

The factory executes from the existing mounted ConfigMap, not an inline Task
script. This preserves generated `$(params.services)` references until the actual
build starts and avoids the reported `Services differ from the prepared graph`
failure. Reapply Helm and start a fresh launcher after upgrading. Restarting the
failed prepared build retains its old graph and does not repair this issue.

Backend allows `acl-service`, `administration-service`, `audit-logging-service`,
`core-service`, `identity-service`, `language-service`, `document-service`,
`event-service`, `notification-service`, `request-service`, `stakeholder-service`,
`applicant-service`, `visitvisa-service`, `realtime-service`. Frontend allows
`admin-portal`, `applicant-portal`, `operational-portal`.

The allowlists are `selectedServices` in values.yaml. The backend catalog contains
17 services; add prepared services and reapply Helm to allow more than the current
14. Gateway, Payment and AuthServer are excluded by default; prepare their source
Dockerfiles and GitOps entries before enabling them. Empty backend selectedServices
enables all 17 known catalog entries. Backend and frontend currently omit unit
tests (`backendBuild.testsEnabled: false`, `frontendRelease.testsEnabled: false`).
Both scopes run:

**clone → build/push → ACS scan → policy gate → sign → final combined GitOps update**

To restore backend tests, set `backendBuild.testsEnabled: true`, reapply Helm,
and start a fresh entry run. Restored backend tests run on Hub and block builds
on failure (`backendBuild.allowTestFailure: false`). The chart default keeps
backend tests enabled for other installations.

To restore frontend tests, set `frontendRelease.testsEnabled: true` in the same
values file, reapply Helm, and start a fresh run. The existing `allowTestFailure: true`
then allows failed frontend tests to continue; set it to false when tests must
block the build. Existing prepared runs retain their original graph.

Build, scan, gate and sign failures block GitOps. Verification belongs to promotion. Tags remain the
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

Expected Azure values:

| Azure payload field | Trigger handling |
| --- | --- |
| `eventType` | Accepts `git.pullrequest.created` and `git.pullrequest.updated` |
| `resource.status` | Must be `active`; completed/abandoned PRs are not built |
| `resource.repository.remoteUrl` | Must exactly match the configured backend/frontend source URL |
| `resource.targetRefName` | Backend `refs/heads/test`; frontend `refs/heads/pre-prod` |
| `resource.sourceRefName` | Passed as `source-revision`; resolver removes `refs/heads/` |
| `resource.lastMergeSourceCommit.commitId` | Full source SHA passed as `source-commit` |
| `resource.lastMergeTargetCommit.commitId` | Full target SHA passed as `target-commit` for Git diff |
| `resource.pullRequestId` | Used with both commit prefixes to name the launcher run |

Source/target SHAs must each be 40 lowercase hexadecimal characters. Fork PRs
are excluded. Service names come from the Git diff, not a service list in the
Azure payload. `env` stays `dev`; `image-tag` defaults to the source SHA's first
eight characters. Both hooks use internally managed credentials, as console
starts do. These test hooks run before merge and can update GitOps after the
selected builds succeed; production approval/promotion is a separate decision.

For the first real test, create a source branch with a pushed change in a known
enabled service, then open a PR targeting the branch above. Use the matching
route and repository for each hook. In Azure Service Hooks history, inspect the
actual request payload and delivery result. Azure's Test button can send sample
values that do not match these filters. An HTTP 202 response alone does not prove
a PipelineRun was created; check listener logs and the generated runs:

```bash
oc -n devops logs deployment/el-backend-pr --all-containers=true --since=10m --tail=150
oc -n devops logs deployment/el-frontend-pr --all-containers=true --since=10m --tail=150
oc -n devops get pipelineruns -l customer.mofa.gov.sa/trigger=azure-pr \
  --sort-by=.metadata.creationTimestamp
```

Open the launcher's `build-pipeline-run` result to find the actual selected-lane
build graph. A diff selecting no enabled services creates no build run. Repeated
delivery for the same PR/source/target produces the same launcher name and can
return AlreadyExists; it does not intentionally create duplicate builds.

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

## Custom Keycloak image

The same Helm upgrade above now installs `application-keycloak-build` because
this folder's values enable `keycloakBuild.enabled`. Chart defaults leave it
disabled for other consumers. Upgrading installs resources only; it starts no build.

Flow: **clone → validate → build-image → scan-image → security-gate → push-image → sign-image**.
The pipeline remains independent of Application Foundation Helm packaging,
configuration deployment and GitOps updates.

- `build-image` reuses the proxy-free Buildah task and uploads to the same Quay
  repository with a unique `candidate-<PipelineRun UID>` tag.
- `scan-image` reuses RHACS scanning against the uploaded image digest.
- `security-gate` checks the configured RHACS build-time enforcement policies.
  A successful vulnerability scan alone is not a policy approval. The current
  customer values temporarily set `keycloakBuild.allowSecurityGateFailure: true`: the
  gate still runs, but `onError: continue` lets publication/signing proceed after
  a policy-check failure. This also ignores other failures of that gate Task.
  Failed checks remain visible in the TaskRun logs/status; overall PipelineRun
  success in this mode is not evidence of policy compliance.
- `push-image` uses the existing Skopeo image to copy the scanned digest to the
  requested final tag with digest preservation; it never rebuilds the image.
- `sign-image` reuses the RHTAS task to sign the published digest.

The candidate upload is necessary because RHACS scans images from registries:
[RHACS 4.11 image scanning](https://docs.redhat.com/en/documentation/red_hat_advanced_cluster_security_for_kubernetes/4.11/html/roxctl_cli/image-scanning-by-using-the-roxctl-cli-1).
Copying uses [Skopeo digest preservation](https://github.com/containers/skopeo/blob/main/docs/skopeo-copy.1.md).
No Keycloak task reads `pipeline-proxy`; existing frontend/backend behavior is
unchanged. Registry credentials must permit both candidate and final tags.

A scan failure always prevents final-tag publication and signing. A policy-gate
failure blocks them only when `keycloakBuild.allowSecurityGateFailure` is false
(the chart default); any previously existing final tag is unchanged in that case.
To restore enforcement, set this value to false in
`customer-transfer/application-build/values.yaml` and run the same Helm upgrade. A signing failure leaves a published
but unsigned image and a failed PipelineRun: do not release it. Candidate tags
are retained for troubleshooting, including failed candidates; agree an approved
Quay retention policy separately. Do not deploy `candidate-*` tags. This same
repository is not an access-isolated quarantine; consumers must use approved,
signed digests. `candidate-` is reserved and cannot be used as a manual final tag.

Before starting:

1. [Load and push the Keycloak base image](../../tools/image-copy/README.md#keycloak-266-base-image)
   to `devops/keycloak-rhel9:26.6` in internal Quay.
2. In Azure repo `integration-rhsso`, branch `keycloak-custom`, change the root
   Dockerfile's single base-image line and commit it:

   ```dockerfile
   FROM quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/keycloak-rhel9:26.6
   ```

3. Include these actual binary files (not Git LFS pointers) in the build context,
   and ensure `.dockerignore` does not exclude them:
   - `JDBC-driver/mssql-jdbc.jar`
   - `SPI-jar-files/applicant-portal-keycloak-extension.jar`
   - `SPI-jar-files/nafath-keycloak-extension.jar`
4. The application team must confirm provider/JDBC compatibility with Keycloak
   26.6 and supply any additional required provider libraries. No Maven, npm,
   NuGet, or external package downloads are performed by the reviewed Dockerfile.
5. Existing `git-credentials` must allow source checkout. `registry-auth` must
   allow base-image pulls and pushes to `devops/keycloak-custom`; the pipeline
   account must have the same Buildah permissions as existing image builds.
   Internal Git and Quay connectivity/CA trust and PVC capacity remain required.
6. `rhacs-auth` must contain `endpoint` and `token` for the existing scan/gate
   tasks. RHACS must be able to pull the private Keycloak repository through its
   Quay integration, have usable vulnerability data, and enforce the agreed
   build-time policies. Confirm installed RHACS/server compatibility with the
   existing roxctl 4.11.4 image. Scan failures stop publication; gate failures
   currently remain advisory under the temporary customer setting.
7. Existing RHTAS URLs, trust, token audience and pipeline service-account
   identity must be valid. Fulcio/Rekor/TUF and the internal client service must
   be reachable. Quay credentials must allow signature publication. Signing
   failures fail the pipeline; signing is not optional in this flow.

After applying the Helm upgrade, generate and start a run:

```bash
oc -n devops get configmap keycloak-build-run-template \
  -o jsonpath='{.data.pipelinerun\.yaml}' > /tmp/keycloak-build-run.yaml
# Optional: set image-tag; empty uses the first eight source commit characters.
oc create -f /tmp/keycloak-build-run.yaml
oc -n devops get pipelineruns --sort-by=.metadata.creationTimestamp
```

Alternatively, in **devops → Pipelines**, start `application-keycloak-build`,
optionally provide `image-tag`, bind `git-credentials` and `registry-auth` to the corresponding
Secrets and `source` to a new 3Gi PVC, and use service account `pipeline`.
Optional `source-commit` pins a particular commit; otherwise the branch is cloned.

The output is:

```text
quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/keycloak-custom:<image-tag>
```

Check that the PipelineRun condition is `Succeeded=True`, then inspect its
`source-commit`, `image-tag`, `candidate-image`, `image-url` and `image-digest` results.
The published `image-url` is a digest reference; successful publication alone
does not prove the later signing task succeeded.
An empty `image-tag` uses the first eight source commit characters. A manual tag
such as `26.6-custom-1` must contain no spaces and must be at most 128 characters.
Validation checks tag syntax, required nonempty files, and the expected base-image
reference; it does not prove JAR compatibility. Buildah runs `kc.sh build` via the
Dockerfile. A subsequent deployment test must verify startup, SQL Server access,
health probes and both custom authentication flows. Ensure the installed Keycloak
Operator supports the selected server version before deploying.

The source repository was reviewed from the supplied Dockerfile screenshot;
its Dockerfile is not modified by this Helm upgrade. Runtime build and deployment
validation must be performed on the customer cluster.

Manual UI/CLI starts remain available for testing. No Keycloak webhook is created
by this change. Production initiation must be connected to the agreed Azure
branch/PR workflow with authenticated requests and an approved source commit;
this implementation does not claim automated source-control triggering is enabled.

Local regression check (from the appdev repository root):

```bash
ruby tests/keycloak-build/validate.rb
```

## Application Foundation chart CI (manual test)

The same values file now enables `application-foundation-ci` in the existing
pipeline Helm release. First source: `RedHat_HelmCharts`, branch `dev`, directory
`app-chart/1.0.0`. This is a single selected-chart test of the foundation CI
workflow; it does not yet detect all modified charts or create PR webhooks.

Flow: **clone → validate-chart → package-chart → publish-chart**.

- Clone uses the existing Git image and credentials.
- Validation copies the selected chart into a separate workspace directory,
  sets the manually approved chart version in that copy, then runs `helm lint
  --strict` and `helm template`. Optional `values-file` is repository-relative
  and affects validation only. Rendered manifests are not printed to logs.
- Packaging produces the versioned `.tgz` from the validated workspace copy.
  `appVersion`, dependency versions, source directory and Git are unchanged.
- Publication uses `helm push` to internal Quay. The chart name is derived from
  `Chart.yaml`; the OCI tag is derived from its approved version. The push logs
  print the published chart reference, version and registry digest.

Prerequisites:

1. Mirror `docker.io/alpine/helm:3.19.0` to internal `devops/helm:3.19.0`, using
   [the image-transfer instructions](../../tools/image-copy/README.md#helm-chart-publishing-image).
   It is the only new task image. The Git image is already configured internally.
2. `git-credentials` must allow read access to the selected repository/branch.
   `registry-auth` must contain `config.json` or `.dockerconfigjson` with Quay
   write access to `devops/app-chart`. Create the Quay repository first if the
   account cannot create it. Keep internal CA trust configured; TLS verification
   remains enabled.
3. Chart dependencies must be vendored under `charts/`. The inspected reference
   has the local `access-control` dependency included. No `helm dependency update`,
   public downloads, proxy Secret, or runtime tool installation is used.
4. The `pipeline` service account must be able to run the existing Git image and
   new Helm image with a writable source PVC. Confirm the actual Azure source
   branch/path and dependency completeness when running on the customer cluster.

Apply the same Helm upgrade documented above. Then use the UI:

1. Select **devops → Pipelines → application-foundation-ci → Start**.
2. Keep `source-url` and `source-revision: dev` unless testing another branch.
3. Set `chart-path: app-chart/1.0.0`.
4. Set `chart-version: 1.0.1-test.1` for the first test; increment for later runs.
   This intentionally differs from source directory `1.0.0` to avoid overwriting
   the existing chart version. Do not reuse an already published version: Helm
   push can replace an existing tag if the registry allows it.
5. Leave `source-commit` and `values-file` empty unless pinning a commit or using
   an environment-specific validation values file.
6. Bind `git-credentials` and `registry-auth` to their matching Secrets. Bind
   `source` to a new **ReadWriteOnce, 1Gi VolumeClaimTemplate** and select service
   account **pipeline**. Start the run.

For a CLI start with the same defaults:

```bash
oc -n devops get configmap foundation-ci-run-template \
  -o jsonpath='{.data.pipelinerun\.yaml}' > /tmp/foundation-ci-run.yaml
# Edit chart-version before repeating a test.
oc create -f /tmp/foundation-ci-run.yaml
```

Expected first-test artifact:

```text
oci://quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/app-chart:1.0.1-test.1
```

Check **PipelineRun → Output** for `source-commit`, `chart-name`, `chart-version`,
`chart-reference` and `chart-digest`. From a trusted, authenticated Helm client,
verify it can be retrieved:

```bash
helm pull oci://quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/app-chart \
  --version 1.0.1-test.1 --destination /tmp
helm show chart /tmp/app-chart-1.0.1-test.1.tgz
```

This publishes a chart only. It does not update Argo CD, deploy workloads, build
Keycloak images or sign chart artifacts. Foundation Keycloak, 3scale and AMQ
configuration charts can be tested individually later using their actual
`chart-path` and approved version, once those inputs are ready. PR triggering
and multi-chart change detection remain deferred.

Validation references: [Helm 3 OCI registries](https://helm.sh/docs/v3/topics/registries/).
Local check: `ruby tests/foundation-ci/validate.rb` (set `HELM_TEST_BINARY` to a
Helm 3.19.0 binary to match the pipeline image). Registry publication in this
check is mocked; customer Quay publication and UI execution require a live run.
