# Apply in the target `devops` namespace

This folder uses Azure DevOps HTTPS Git credentials and the mirrored repositories.
It is intended to be applied after the centralized pipeline chart is installed.

For the new manual three-frontend release test with eight-character commit tags,
OCI chart publication, and digest-pinned GitOps deployment, use
[the separate release test guide](../frontend-release-test/README.md).
It does not require the Azure webhook or replace the existing validation pipelines.

For the 17-service backend build/scan/gate/sign fanout (verification deferred
to promotion), use [the backend build guide](../backend-build-fanout/README.md).

## 1. Create required secrets in the UI

Create these secrets in namespace `devops`:

```text
git-credentials: key `.git-credentials`
registry-auth:   key `config.json` or `.dockerconfigjson`
rhacs-auth:      keys `endpoint`, `token`
npm-auth:        key `NPM_TOKEN` (raw Azure Artifacts PAT for frontend builds)
pipeline-proxy:  keys `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`
```

The frontend PR pipeline also pushes verified image references to the configured
GitOps repository. The `git-credentials` PAT must have Azure Repos **Code Read
and Write** permission for both the frontend source repo and `RedHat_argocd`.
The current Argo CD root Application tracks branch `dev`, path `development`,
and reads `development/apps/core-apps.yaml`; the pipeline therefore updates
only the selected frontend apps' image repository and tag in that file. It does
not change the `app-chart` Helm `targetRevision` (`1.0.0`).
The Azure PR trigger opts into that GitOps update. A manually created
PipelineRun leaves `perform-gitops-update` false unless explicitly enabled.

The `.git-credentials` value is:

```text
https://<azure-user>:<azure-pat>@azuredevops.mofa.gov.sa
```

Use minimum approved permissions. Do not commit these values.

The `pipeline-proxy` Secret is the single proxy configuration used by both
backend and frontend test/build Tasks. Add the approved proxy endpoint(s) and
the internal bypass list there; PipelineRuns do not take proxy parameters.
RHTAS Fulcio, Rekor, TUF, client, and verification identity values are set once
in `values-devops.yaml` and rendered into the shared signing Tasks.

In the OpenShift console, select project `devops`, open **Workloads → Secrets**,
choose **Create → Key/value secret**, name it `pipeline-proxy`, and add the three
keys above with the platform-approved values. Save it before launching a run.
Do not put proxy values in Git or PipelineRun YAML. Secret values are hidden from
PipelineRun parameters, but remain readable to principals permitted to read
Secrets in the namespace.

For a non-production ESO connectivity test, use
`external-secret-vault-test.yaml`. It creates a dedicated Kubernetes service
account, a `SecretStore` in `devops` pointing to the Vault route, and an
`ExternalSecret` that materializes a harmless value as Secret `eso-vault-test`.
Vault remains in project `infra-platforms`; the Kubernetes Secret is created in
`devops`.

### Test ESO syncing from Vault

1. In an approved Vault admin session (Vault is in `infra-platforms`), write a
   harmless test value to KV v2 and grant a narrow policy to only that path:

   ```bash
   vault kv put -mount=secret devops/eso-test message=hello-eso
   vault policy write eso-devops-test - <<'EOF'
   path "secret/data/devops/eso-test" {
     capabilities = ["read"]
   }
   EOF
   vault write auth/kubernetes/role/eso-devops-test \
     bound_service_account_names=eso-vault-reader \
     bound_service_account_namespaces=devops \
     policies=eso-devops-test \
     ttl=1h
   ```

   This assumes Vault's Kubernetes auth mount is already configured at
   `kubernetes/`, as used by the existing ESO setup. Do not put Vault tokens in
   Git or pipeline logs.

2. Ensure the ESO controller is allowed to request a token for ServiceAccount
   `eso-vault-reader` in `devops`, and that the Vault route certificate is
   trusted by ESO. If `SecretStore` reports an x509 error, configure the
   approved Vault CA using the store's `caBundle` or `caProvider` before retrying.

3. From the repo root, apply the test resources:

   ```bash
   oc apply -f customer-transfer/devops-apply/external-secret-vault-test.yaml
   oc get secretstore vault-backend -n devops
   oc get externalsecret eso-vault-test -n devops
   oc describe externalsecret eso-vault-test -n devops
   ```

4. Wait for `Ready=True`, then confirm the generated Secret contains the test
   field (this value is deliberately non-sensitive):

   ```bash
   oc get secret eso-vault-test -n devops \
     -o jsonpath='{.data.message}' | base64 -d
   printf '\n'
   ```

   Expected output: `hello-eso`. If it is not Ready, inspect the ExternalSecret
   and SecretStore conditions and ESO controller logs. Common blockers are a
   missing Store, Vault policy/role binding, TokenRequest permission, or CA trust.

## 2. Install the pipeline and tasks

From the `appdev` repository root, run:

```bash
oc project devops
helm upgrade --install release-pipeline \
  ./pipelines/chart \
  --namespace devops \
  -f customer-transfer/devops-apply/values-devops.yaml
```

Verify:

```bash
oc get tasks,pipelines -n devops
oc get sa pipeline -n devops
```

## 3. Per-run workspaces for parallel builds

Both frontend and backend PipelineRuns use a `volumeClaimTemplate` for the
`source` workspace. Tekton provisions a dedicated `ReadWriteOnce` PVC for each
run, so parallel clones and builds cannot overwrite each other's checkout.
Each manifest requests `3Gi`; confirm the `devops` storage quota and storage
class can accommodate two simultaneous runs (10Gi requested total) before
launching them. Secret workspaces remain shared and read-only.

## 4. Run ACL validation

```bash
oc create -f customer-transfer/devops-apply/pipelinerun-acl.yaml
oc get pipelineruns -n devops
oc describe pipelinerun -n devops <run-name>
```

The first run performs clone, .NET test, image build, RHACS scan, security
gate, and RHTAS signing. GitOps write-back is disabled.

To test one frontend and one backend run concurrently, create both runs in
separate terminals (or issue both commands back-to-back):

```bash
oc create -f customer-transfer/devops-apply/pipelinerun-acl.yaml
yq eval 'select(.kind == "PipelineRun")' customer-transfer/devops-apply/frontend-build-validation.yaml | oc create -f -
```

Track them independently with `oc get pipelineruns,taskruns,pods,pvc -n devops`.
Use a unique image tag per run if you launch repeated builds; never let
concurrent runs push different content to the same tag.

## 5. Temporary build-only diagnostic

To test clone, unit tests, image build, signing, and signature verification
without RHACS scan or GitOps write-back, apply the diagnostic Pipeline and
create a fresh PipelineRun from the two documents in the manifest (`yq` is
required):

```bash
yq eval 'select(.kind == "Pipeline")' customer-transfer/devops-apply/build-only-validation.yaml | oc apply -f -
yq eval 'select(.kind == "PipelineRun")' customer-transfer/devops-apply/build-only-validation.yaml | oc create -f -
```

The verification Task checks the image digest produced by this run against the
signature from the preceding signing Task. Its expected certificate identity
defaults to the `pipeline` service account in `devops`; adjust the Pipeline
chart values if a different service account or issuer is used.

The `sign-image` and `verify-image` Tasks accept either `config.json` or
`.dockerconfigjson` in the `registry-auth` Secret. Buildah uses this Secret to
push; Cosign needs the same credentials to read the image manifest from Quay
before signing. After updating the chart, rerun the Helm command in section 2
and create a new PipelineRun. Existing TaskRuns do not use the updated Task.

The diagnostic run does not update Helm or deploy through ArgoCD. Remove the
temporary Pipeline after validation:

```bash
oc delete pipeline application-build-only-validation -n devops
```

## 6. Frontend admin-portal build diagnostic

The frontend Dockerfile builds `admin-portal` with Nx and consumes `NPM_TOKEN`
through a Buildah secret mount. The token is not passed as a build argument.
The frontend source checkout must contain the updated Dockerfile base-image
references shown below before the run can use the customer Quay mirror.

In the frontend build stage, declare the proxy build arguments before the
dependency-install `RUN` so npm can use the proxy values passed by the pipeline.
Keep these as `ARG` values (not `ENV`) so they do not persist in the final image:

```dockerfile
FROM quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nodejs-24:ubi9 AS frontend

ARG BUILD_ENVIRONMENT
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY

WORKDIR /app
# Keep the existing COPY and npm install steps below this point.
```

The shared Tasks read the proxy values from `pipeline-proxy` and pass them as
Buildah proxy build args. With `NO_PROXY=.mofa.gov.sa`, the internal Azure Artifacts npm feed
(`azuredevops.mofa.gov.sa`) is reached directly; public npm registry requests
use the proxy. Keep the feed URL and scoped package mappings in the Dockerfile's
existing temporary `.npmrc` creation, and continue mounting `NPM_TOKEN` as
`id=npm_token` rather than adding the token to build arguments or the image.
The frontend pipeline now also runs `npx nx test admin-portal` before the image
build, using the same internal feed, npm secret, and proxy settings.

The test-dev Quay source is not reachable from this transfer host, so mirror
the latest public Red Hat UBI 9 Node.js and Nginx images. The auth file needs
internal Quay push credentials; the UBI source images are publicly accessible:

```bash
./tools/image-copy/copy-image.sh \
  registry.access.redhat.com/ubi9/nodejs-24:latest \
  quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nodejs-24:ubi9 \
  /secure/path/pullsecret.txt-quay

./tools/image-copy/copy-image.sh \
  registry.access.redhat.com/ubi9/nginx-126:latest \
  quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nginx-126:ubi9 \
  /secure/path/pullsecret.txt-quay
```

Update the `FROM` references in the three frontend portal Dockerfiles to these
internal images, then commit the Dockerfile update to the source branch used by
the PipelineRun:

```text
quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nodejs-24:ubi9
quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nginx-126:ubi9
```

The UBI Node.js 24 image is the intended build-stage base. UBI Nginx 1.26 is
not the private Nginx 1.30.3 FIPS image and must not be treated as FIPS-
validated. Its OpenShift/S2I paths and configuration differ from the current
private image, so adapt and test the runtime Dockerfile before using it. Inspect
each target and record its immutable digest after mirroring.

After adding `npm-auth` in namespace `devops` and updating the frontend
Dockerfiles, upgrade the chart to install the optional Buildah secret
workspace, then apply the Pipeline and create its run:

```bash
helm upgrade --install release-pipeline ./pipelines/chart \
  --namespace devops -f customer-transfer/devops-apply/values-devops.yaml
yq eval 'select(.kind == "Pipeline")' customer-transfer/devops-apply/frontend-build-validation.yaml | oc apply -f -
yq eval 'select(.kind == "PipelineRun")' customer-transfer/devops-apply/frontend-build-validation.yaml | oc create -f -
```

This diagnostic runs the admin-portal unit tests, then the Dockerfile's `npm i`
and `nx run admin-portal:build --configuration=dev`, and finally pushes, signs,
and verifies the image. For this diagnostic, a frontend unit-test failure is
non-blocking so the remaining stages can be tested; remove `onError: continue`
from the frontend Pipeline after investigating/fixing the current test failure.
The backend unit-test task remains blocking. This run does not run RHACS scan or
GitOps write-back.

## 7. Fan out frontend validation to all three portals

The Helm chart installs the frontend validation Pipeline. The sample
`frontend-three-service-fanout.yaml` PipelineRun has three
independent lanes: `admin-portal`, `applicant-portal`, and
`operational-portal`. Each lane clones the same source revision into its own
3Gi PVC, runs that portal's Nx test, builds its Dockerfile with
`BUILD_ENVIRONMENT=dev`, then signs and verifies its own image. The three lanes
run concurrently. Unit-test failures are temporarily non-blocking, matching the
existing frontend diagnostic; remove `onError: continue` from all three test
tasks when tests should gate image builds.

The sample run selects all three services. PR-triggered runs use the diff-based
selector below. The run reserves three 3Gi PVCs (9Gi total), plus the
dispatcher workspace when using `diff` mode. Change the source revision to the
branch or commit containing your Dockerfile changes, and use fresh image tags
for each concurrent/repeated run.

```bash
yq eval 'select(.kind == "PipelineRun")' customer-transfer/devops-apply/frontend-three-service-fanout.yaml | oc create -f -
oc get pipelineruns,taskruns,pods,pvc -n devops
```

The sample PipelineRun uses branch `test` and the `dev-validation` image tags.
Before each run, edit `source-revision` and the three image tags in the
manifest as needed. The source commit must already be pushed to Azure DevOps;
Tekton cannot build uncommitted Dockerfile edits on your workstation.

## 8. Trigger frontend validation from Azure Repos PRs

The Helm chart installs the frontend Pipeline, selector ConfigMap, EventListener,
TriggerBinding/Template, and authenticated HTTPS webhook proxy together when
`frontendPr.enabled: true` is set. Active PR create/update events targeting
`pre-prod` compare the pinned source commit with the target branch and select
lanes using `pipelines/chart/files/service-pre-prod.tsv`. An unmapped changed
path conservatively selects all three. The manual PipelineRun defaults to `all`.

Before applying, confirm OpenShift Pipelines Triggers CRDs exist:

```bash
oc get crd eventlisteners.triggers.tekton.dev triggerbindings.triggers.tekton.dev triggertemplates.triggers.tekton.dev
```

The proxy needs a Basic Auth htpasswd Secret before Helm creates its Deployment.
On a trusted admin workstation with `htpasswd` installed, run:

```bash
htpasswd -B -c /tmp/frontend-pr.htpasswd ado-hook
oc -n devops create secret generic frontend-pr-webhook-auth \
  --from-file=htpasswd=/tmp/frontend-pr.htpasswd
rm -f /tmp/frontend-pr.htpasswd
helm upgrade --install release-pipeline ./pipelines/chart \
  --namespace devops -f customer-transfer/devops-apply/values-devops.yaml
oc get route frontend-pr-webhook -n devops
oc get eventlistener,triggerbinding,triggertemplate,pipeline -n devops
```

Wait for the proxy pod to become Ready and copy the Route's HTTPS host. In
Azure DevOps, open **Project Settings → Service Hooks → Create Subscription →
Web Hooks**. Create subscriptions for **Pull request created** and **Pull
request updated**. Filter each to repository
`RedHat_UnifiedVisaPlatform.Frontend` and target branch `pre-prod`. Set the URL
to `https://<frontend-pr-webhook-route-host>/`, enable Basic Authentication
with username `ado-hook` and the password used above, and enable TLS
certificate validation. Use the full resource payload. Send a test event and
check **Service Hooks → History** for a successful delivery.

Then create or update an active PR into `pre-prod`. The listener rejects other
target branches, repositories, and event types. Check the resulting run:

```bash
oc get eventlistener,triggerbinding,triggertemplate -n devops
oc get pods,pipelineruns,taskruns,pvc -n devops
oc logs deployment/el-frontend-pr -n devops --since=10m
oc describe pipelinerun -n devops <run-name>
```

### GitOps rollout

After a PR PipelineRun succeeds, confirm that its `update-frontend-gitops` task
created a commit on `RedHat_argocd` branch `dev`. The root Argo CD Application
currently has automated sync disabled, so sync `dev-root-applications` once
from the Argo CD UI/CLI. Its update applies the selected child Application
image overrides; those child apps have auto-sync enabled and should roll out
the new image tags. Check the three child apps and their workloads in Argo CD
and OpenShift. Before enabling automatic root sync, confirm the desired prune
and self-heal policy with the platform owner.

The PR images use immutable `pr-<7-character-commit-SHA>` tags. This is suitable
for a PR deployment test, not a release tag. A later protected post-merge or
release pipeline can publish a SemVer tag. Do not bump or republish `app-chart`
for an application-only image change: keep its `targetRevision` at `1.0.0`.
Publish a new OCI chart version and update `targetRevision` only when the Helm
chart itself changes.

Each run reserves about 17Gi across its workspaces (2Gi dispatch plus three
3Gi lane PVCs), even when the diff selects fewer lanes. Leave sufficient quota
for concurrent PRs. To test the selector without Azure, set `selection-mode`
to `diff`, provide a source branch/commit and target ref in a PipelineRun, and
bind the chart-managed `frontend-service-selector` ConfigMap workspace. Edit
`pipelines/chart/files/service-pre-prod.tsv` to adjust path ownership, then run
the Helm upgrade again.

Important security boundary: this PR Pipeline currently runs tests and
Dockerfiles with `npm-auth`, Quay push credentials, and RHTAS signing
credentials. Only enable this trigger for a repository where PR authors are
trusted to execute code with those credentials. For broader contributor access,
use a separate unprivileged PR validation Pipeline (no registry push/signing
secrets), and keep image publication/signing on a protected post-merge run.
This trigger starts Tekton but does not report its result as an Azure PR status
check or block PR completion; that requires a separate Azure status reporter
and branch policy.

## 9. Image tag location

After approval, enable GitOps write-back and use this values file in the
`RedHat_HelmCharts` repository:

```text
development/apps/core-apps.yaml
```

The application key must match the existing ACL entry, for example:

```yaml
argocd-applications:
  applications:
    acl-service-dev:
      overrideValues:
        image.tag: <approved-tag-or-digest>
```

ArgoCD then consumes the Helm chart and deploys the approved image. Do not
grant cluster-admin to ArgoCD.
