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

Mirror the two bases from a transfer host whose auth file can pull from the
source Quay and push to the customer Quay:

```bash
REGISTRY_AUTH_FILE=/path/to/auth.json \
  bash scripts/mirror/pull-push-customer-images.sh mirror/frontend-base-images.csv
```

Update the `FROM` references in the three frontend portal Dockerfiles to these
internal images, then commit the Dockerfile update to the source branch used by
the PipelineRun:

```text
quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nodejs-24:9.8-1782938304
quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nginx-fips:1.30.3-fips
```

The mirror uses the existing transfer script and source-to-target list in
`mirror/frontend-base-images.csv`. The source registry is the test-dev Quay
host, so its pull credentials must be present in `auth.json` along with the
internal Quay push credentials.

After adding `npm-auth` in namespace `devops` and updating the frontend
Dockerfiles, upgrade the chart to install the optional Buildah secret
workspace, then apply the Pipeline and create its run:

```bash
helm upgrade --install customer-release-pipeline ./pipelines/chart \
  --namespace devops -f customer-transfer/devops-apply/values-devops.yaml
yq eval 'select(.kind == "Pipeline")' customer-transfer/devops-apply/frontend-build-validation.yaml | oc apply -f -
yq eval 'select(.kind == "PipelineRun")' customer-transfer/devops-apply/frontend-build-validation.yaml | oc create -f -
```

This diagnostic runs the Dockerfile's `npm i` and `nx run admin-portal:build
--configuration=dev`, then pushes, signs, and verifies the image. It does not
run RHACS scan or GitOps write-back.

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
