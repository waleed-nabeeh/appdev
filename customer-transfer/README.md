# RedHat mirrored-repository pipeline setup

Repositories:

```text
RedHat_UnifiedVisaPlatform.Backend
RedHat_UnifiedVisaPlatform.Frontend
RedHat_HelmCharts
RedHat_ArgoCD
```

All Git operations use Azure DevOps. No credentials belong in this folder.

## 1. Check the pipeline namespace

```bash
oc project devops
oc get pipeline application-release
oc get sa pipeline
```

## 2. Prepare Azure DevOps credentials

Create an approved Azure DevOps service identity and PAT with minimum Code read
permission. Do not commit the PAT or place it in YAML:

```bash
printf 'https://<user>:<pat>@azuredevops.mofa.gov.sa\n' > .git-credentials
chmod 600 .git-credentials
```

Create or update the OpenShift secret securely, then remove the local file:

```bash
oc -n devops create secret generic git-credentials \
  --from-file=.git-credentials=.git-credentials \
  --dry-run=client -o yaml | oc apply -f -
rm -f .git-credentials
```

Required key:

```text
.git-credentials
```

The pipeline configures Git's credential-store helper for Azure DevOps clone
and Helm values write-back.

## 3. Prepare the Quay secret

Create an approved Quay robot account with push/pull permission, then create
the secret without committing the token:

```bash
oc -n devops create secret docker-registry registry-auth \
  --docker-server=<quay-host> \
  --docker-username='<robot-user>' \
  --docker-password='<robot-token>' \
  --dry-run=client -o yaml | oc apply -f -
```

## 4. Prepare the RHACS secret

In RHACS open **Platform Configuration > Integrations > Authentication
Tokens**, create a minimum-permission CI/CD token, and store it securely.

```bash
oc -n devops create secret generic rhacs-auth \
  --from-literal=endpoint='<acs-endpoint>' \
  --from-literal=token='<acs-token>' \
  --dry-run=client -o yaml | oc apply -f -
```

Required keys are `endpoint` and `token`.

## 5. Run the backend pipeline

The ready example is in `backend-acl-pipeline/`:

```bash
oc create -f backend-acl-pipeline/pipelinerun-acl-validation.yaml
oc get pipelineruns -n devops
oc describe pipelinerun -n devops <run-name>
```

Source repository:

```text
https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_UnifiedVisaPlatform.Backend
```

The first run builds ACL, runs tests, builds the image, scans it, applies the
security gate, and signs it. GitOps write-back is disabled initially.

## 6. Frontend pipeline inputs

`RedHat_UnifiedVisaPlatform.Frontend/service-dev.yaml` defines:

```text
admin-portal-dev       deployment/admin-portal/Dockerfile
applicant-portal-dev   deployment/applicant-portal/Dockerfile
operational-portal-dev deployment/operational-portal/Dockerfile
```

Frontend builds also require the approved `NPM_TOKEN`. The installed
`application-release` pipeline is currently .NET-specific, so a frontend
pipeline task must be installed before running these services. It must run
`npm ci`, the selected Nx build/test commands, image build, RHACS scan, gate,
and RHTAS signing.

## 7. Image tag update location

The release pipeline updates the approved values file in:

```text
RedHat_HelmCharts/development/apps/core-apps.yaml
```

Update only the selected application image tag, for example:

```yaml
argocd-applications:
  applications:
    acl-service-dev:
      overrideValues:
        image.tag: <new-tag-or-digest>
```

The exact application key must match the existing values file. Keep
`perform-gitops-update: "false"` for the first validation run.

## 8. ArgoCD deployment

`RedHat_ArgoCD` contains the ArgoCD application definitions. After the Helm
values change is merged, ArgoCD reads charts from `RedHat_HelmCharts`:

```bash
oc get applications -n visa-argocd
oc describe application <application-name> -n visa-argocd
```

Do not grant cluster-admin to ArgoCD. Restrict the `infra-platforms`
AppProject to approved namespaces and resource kinds.

## Repository URLs

```text
Backend:  https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_UnifiedVisaPlatform.Backend
Frontend: https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_UnifiedVisaPlatform.Frontend
Charts:   https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_HelmCharts
ArgoCD:   https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_ArgoCD
```
