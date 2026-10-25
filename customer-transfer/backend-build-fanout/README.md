# Backend Build Fanout (17 Services)

For runtime comma-separated selection, the new dispatcher, copy-paste curl test
and labeled PVC cleanup, use [README-dispatch.md](README-dispatch.md).
The fixed fanout below remains available and unchanged as the working fallback.

Current customer selection: **14 services**, matching the /services folders
shown on the customer's `test` branch on 2026-10-25. Payment is not shown there;
Gateway and AuthServer are outside this selected folder scope. All three remain
in the reference catalog but have no tasks, results or PVCs in the shipped
selection. Existing PipelineRuns are not changed by this exclusion.

Selected: acl, administration, applicant, audit-logging, core, document, event,
identity, language, notification, realtime, request, stakeholder, visitVisa.
The local Payment Dockerfile's case mismatch is a separate reference-copy issue;
it does not prove the cause of a restore failure in the customer branch.

Helm release: `release-pipeline`, namespace: `devops`.
New Pipeline: `application-backend-build-fanout`.

Each selected service runs `clone -> test -> build/push -> ACS scan -> gate -> sign`.
There is deliberately NO verification, GitOps update, OCI chart push, or Argo
deployment in this build-only Pipeline. Verification belongs in promotion.
The all-service promotion/OCI publishing flow is not delivered by this change.
Existing ACL and frontend resources are left unchanged.

## Catalog and Source Requirements

The 17 services are ACL, gateway, administration, audit logging, core, identity,
language, document, event, notification, request, stakeholder, applicant,
visit visa, realtime, payment, and authserver. Their exact image names, project
paths and Dockerfiles are in `pipelines/chart/files/backend-services.json`.
The first 15 were derived from the read-only backend reference's service-dev.yaml;
Payment and AuthServer were added from their project directories.

The source branch defaults to `test`, matching the existing successful ACL
example. Change `backendBuild.sourceRevision` if the prepared Dockerfiles are
on another branch. All lanes checkout the same full source SHA; image tags are
the first eight characters without a prefix. Backend builds use
`CERT_KEYWORD=dev` (not the frontend-only BUILD_ENVIRONMENT argument).

Before selecting all services, apply the same approved base-image, proxy,
NuGet/CA and certificate changes used for ACL to their customer Dockerfiles.
Pipeline proxy settings continue to come from `pipeline-proxy`.
The pipeline does not rewrite customer Dockerfiles or disable TLS verification.

Known source prerequisites found in the local reference (customer branch may differ):

- Payment's Dockerfile has `services/Payment` COPY/WORKDIR paths, but the actual
  directory is `services/payment`. Correct the case in the customer repo;
  a case-insensitive workstation can hide this Linux build failure.
- AuthServer's Dockerfile copies `bin/Release/net10.0/publish` without building
  the project. It is not a repository-root multistage Dockerfile. Convert it to
  the same approved .NET multistage pattern as ACL, publishing
  `apps/auth-server/MOFA.UnifiedVisaPlatform.AuthServer/MOFA.UnifiedVisaPlatform.AuthServer.csproj`.
  Use the mirrored SDK/runtime images and a non-privileged listener port such
  as 8080. This source change is required before expecting its build to pass.
- Other reference Dockerfiles still use the old private registry. Check each
  selected Dockerfile's FROM/COPY paths before starting all 17 builds.

The existing `unit-test` Task is reused with each application csproj, matching
ACL. A successful dotnet test on a non-test application project does NOT prove
test coverage. Point the catalog `project` at the intended test csproj/solution
after developers confirm the test projects and dependencies. Errors block by
default, unlike the temporary frontend test concession.

## 1. Apply Helm

From appdev, keep all existing feature overlays on the Helm upgrade. This example
keeps the frontend release resources while adding the backend fanout:

```bash
git pull origin develop
oc -n devops get secret git-credentials registry-auth pipeline-proxy rhacs-auth
helm lint pipelines/chart \
  -f customer-transfer/devops-apply/values-devops.yaml \
  -f customer-transfer/frontend-release-test/values-release.yaml \
  -f customer-transfer/backend-build-fanout/values-backend.yaml
helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/devops-apply/values-devops.yaml \
  -f customer-transfer/frontend-release-test/values-release.yaml \
  -f customer-transfer/backend-build-fanout/values-backend.yaml
```

Only if the already-diagnosed kubectl-create field ownership conflict recurs,
review/back up the conflicting Pipeline and intentionally transfer its fields
to Helm using `--force-conflicts` on Helm versions that support it. Do not use
resource replacement or delete working Pipelines to resolve it.

ACS must have read access to all selected Quay repositories. Registry push
permissions and RHTAS configuration are reused from the working customer values.

## 2. Select Services

`values-backend.yaml` explicitly selects the 14 customer services above.
Do not replace this list with `[]` unless you intend to enable the other three:
an empty list selects all 17 catalog entries. To run only one or two, set an
explicit list and repeat the Helm upgrade:

```yaml
backendBuild:
  enabled: true
  sourceRevision: test
  selectedServices:
    - acl-service
    - core-service
  workspaceSize: 3Gi
  allowTestFailure: false
  buildArgs:
    - CERT_KEYWORD=dev
```

Selection is at Helm configuration time, not per-run Git diff. Unknown/duplicate
names fail rendering. The Pipeline and its run-template ConfigMap use the same
selected list, so unselected lanes do not allocate PVCs. Change selection only
when you intend subsequent runs to use that set. Already-started runs are not
rewritten. Automatic PR dispatch and a queued child-run controller are not added.

## 3. Start a Fresh Build

Helm installs the Pipeline and a ConfigMap containing a matching run template;
it never starts a build during install/upgrade. No yq or Python is needed:

```bash
oc -n devops get configmap backend-build-run-template \
  -o jsonpath='{.data.pipelinerun\.yaml}' > /tmp/backend-build.yaml
oc create -f /tmp/backend-build.yaml
oc -n devops get pipelineruns --sort-by=.metadata.creationTimestamp
```

Each lane gets its own 3Gi RWO workspace. The shipped 14-service selection requests
**42Gi per run**; all 17 would request 51Gi, plus
container/node ephemeral storage. This is parallel fanout, not a three-build
queue. Start with a smaller selection if quota or node capacity is limited.
3Gi is the requested trial size, not measured proof of sufficient peak usage.
Completed runs retain their PVCs until approved cleanup; export results/logs
before deleting old completed runs. Never delete all namespace PVCs.

## 4. Keep Digests for Promotion

Replace RUN with the name returned by oc create:

```bash
RUN=backend-build-REPLACE_WITH_CREATED_SUFFIX
oc -n devops get pipelinerun "$RUN" \
  -o jsonpath='{range .status.conditions[*]}{.type}{" "}{.status}{" "}{.reason}{"\n"}{end}'
oc -n devops get pipelinerun "$RUN" \
  -o jsonpath='{range .status.results[*]}{.name}{"="}{.value}{"\n"}{end}'
oc -n devops get pipelinerun "$RUN" -o json > "$RUN.json"
```

Results include `source-commit`, `image-tag`, and `<service>-image` /
`<service>-digest`. The image result includes @sha256 and must be used exactly
for promotion verification. A digest result alone is not evidence that scan,
gate or signing passed: require the run to have Succeeded=True before promotion.
Do not promote partial failed batches automatically. Same-commit rebuilds can
overwrite the short tag; immutable digests identify the actual approved image.

To rebuild the same source after fixing infrastructure, get a fresh run template
and set `source-commit` to the previous full SHA before oc create. Leave it empty
to resolve the branch's current HEAD. No automatic retries of failed builds or
deployment occur. A promotion retry must reuse recorded digests, not rebuild.

## Validation

```bash
ruby tests/backend-build/validate.rb
ruby tests/frontend-release/validate.rb
git diff --check
```

Optional exact-case source path validation:
`ruby tests/backend-build/validate.rb /path/to/RedHat_UnifiedVisaPlatform.Backend`.
Local rendering is not customer cluster validation. No 17-service builds,
signature verification, OCI publication, or deployment has been run locally.
Tekton workspace/results behavior follows the existing customer-tested APIs;
see https://tekton.dev/docs/pipelines/workspaces/ and https://tekton.dev/docs/pipelines/pipelines/.
