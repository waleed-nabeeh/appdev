# Apply in the target `devops` namespace

This folder uses Azure DevOps HTTPS Git credentials and the mirrored repositories.
It is intended to be applied after the centralized pipeline chart is installed.

## 1. Create required secrets in the UI

Create these secrets in namespace `devops`:

```text
git-credentials: key `.git-credentials`
registry-auth:   key `config.json` or `.dockerconfigjson`
rhacs-auth:      keys `endpoint`, `token`
npm-auth:        key `NPM_TOKEN` (raw Azure Artifacts PAT for frontend builds)
```

The `.git-credentials` value is:

```text
https://<azure-user>:<azure-pat>@azuredevops.mofa.gov.sa
```

Use minimum approved permissions. Do not commit these values.

## 2. Install the pipeline and tasks

From the `appdev` repository root, run:

```bash
oc project devops
helm upgrade --install customer-release-pipeline \
  ./pipelines/chart \
  --namespace devops \
  -f customer-transfer/devops-apply/values-devops.yaml
```

Verify:

```bash
oc get tasks,pipelines -n devops
oc get sa pipeline -n devops
```

## 3. Prepare the PipelineRun

Replace `<source-pvc-name>` in `pipelinerun-acl.yaml` with a Bound PVC in
`devops`. The PVC must be writable by Tekton and large enough for the complete
backend repository and image build workspace.

## 4. Run ACL validation

```bash
oc create -f customer-transfer/devops-apply/pipelinerun-acl.yaml
oc get pipelineruns -n devops
oc describe pipelinerun -n devops <run-name>
```

The first run performs clone, .NET test, image build, RHACS scan, security
gate, and RHTAS signing. GitOps write-back is disabled.

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
parameters if a different service account or issuer is used.

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

The pipeline passes the proxy arguments and sets the proxy environment for
Buildah. With `NO_PROXY=.mofa.gov.sa`, the internal Azure Artifacts npm feed
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
./tests/rhtas-sign-verify/mirror-image.sh \
  registry.access.redhat.com/ubi9/nodejs-24:latest \
  quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nodejs-24:ubi9 \
  /secure/path/pullsecret.txt-quay

./tests/rhtas-sign-verify/mirror-image.sh \
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
helm upgrade --install customer-release-pipeline ./pipelines/chart \
  --namespace devops -f customer-transfer/devops-apply/values-devops.yaml
yq eval 'select(.kind == "Pipeline")' customer-transfer/devops-apply/frontend-build-validation.yaml | oc apply -f -
yq eval 'select(.kind == "PipelineRun")' customer-transfer/devops-apply/frontend-build-validation.yaml | oc create -f -
```

This diagnostic runs the admin-portal unit tests, then the Dockerfile's `npm i`
and `nx run admin-portal:build --configuration=dev`, and finally pushes, signs,
and verifies the image. It does not run RHACS scan or GitOps write-back.

## 7. Image tag location

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
