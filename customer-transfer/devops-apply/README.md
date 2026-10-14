# Apply in the target `devops` namespace

This folder uses Azure DevOps HTTPS Git credentials and the mirrored repositories.
It is intended to be applied after the centralized pipeline chart is installed.

## 1. Create required secrets in the UI

Create these secrets in namespace `devops`:

```text
git-credentials: key `.git-credentials`
registry-auth:   key `config.json`
rhacs-auth:      keys `endpoint`, `token`
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

## 5. Image tag location

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
