# Customer Cluster Implementation

This runbook reproduces the tested demo design on the customer hub cluster.
Git stores desired state and executable automation. Credentials and private
cryptographic material are created separately on the cluster.

## 1. Prepare the disconnected content

Mirror the approved operator catalogs and every image referenced by the Vault,
RHTAS, and pipeline values files into the internal registry. Replace external
image references in the customer values files with immutable internal-registry
digests. The required operator packages are:

| Product | Operator package | Catalog |
| --- | --- | --- |
| OpenShift GitOps | `openshift-gitops-operator` | `redhat-operators` |
| OpenShift Pipelines | `openshift-pipelines-operator-rh` | `redhat-operators` |
| Red Hat Trusted Artifact Signer | `rhtas-operator` | `redhat-operators` |
| Red Hat Advanced Cluster Security | `rhacs-operator` | `redhat-operators` |
| Red Hat Quay | `quay-operator` | `redhat-operators` |
| Vault Secrets Operator | `vault-secrets-operator` | approved certified catalog |

Confirm that ImageContentSourcePolicy or ImageDigestMirrorSet resources resolve
all referenced images through the internal registry.

## 2. Prepare environment values

1. Copy each `values-customer.example.yaml` file to an environment-specific
   file such as `values-customer-hub.yaml`.
2. Set the storage class, applications domain, organization details, internal
   image references, and repository URL.
3. Change app-of-apps `targetRevision` to the protected customer branch or tag.
4. Review all rendered resources before merging.

```bash
helm lint platform/vault/chart -f platform/vault/chart/values-customer-hub.yaml
helm lint platform/rhtas/chart -f platform/rhtas/chart/values-customer-hub.yaml
helm lint pipelines/chart -f pipelines/chart/values-customer-hub.yaml
helm template customer-bootstrap bootstrap/app-of-apps \
  -f bootstrap/app-of-apps/values-customer-hub.yaml
```

## 3. Create namespaces and bootstrap GitOps

```bash
oc apply -f bootstrap/namespaces/vault.yaml
oc apply -f bootstrap/namespaces/trusted-artifact-signer.yaml
oc apply -f bootstrap/namespaces/customer-cicd.yaml
oc apply -f bootstrap/namespaces/stackrox.yaml

helm template customer-bootstrap bootstrap/app-of-apps \
  --namespace openshift-gitops \
  --values bootstrap/app-of-apps/values-customer-hub.yaml | oc apply -f -
```

Argo CD then creates and continuously reconciles the Vault, RHTAS, and pipeline
applications. Configure the private Git repository credential in Argo CD before
bootstrapping; do not place the credential in values files.

Enable the OpenShift Pipelines console plugin after the Pipelines Operator is
Ready. The helper preserves every console plugin already enabled on the cluster:

```bash
OC_BIN=oc ./scripts/openshift/enable-pipelines-console-plugin.sh
oc get console.operator.openshift.io cluster -o jsonpath='{.spec.plugins}'
```

Refresh the OpenShift console after the Console Operator completes its rollout.

## 4. Initialize Vault

Wait for all Vault pods, then initialize once and unseal every member:

```bash
export VAULT_KEY_FILE=/approved/encrypted/location/vault-init.json
OC_BIN=oc ./scripts/vault/initialize-and-unseal.sh "$VAULT_KEY_FILE"
```

Move the key shares and initial root token into the approved custody system.
Configure Kubernetes authentication, least-privilege policies, and Vault roles
for the pipeline and Vault Secrets Operator. Shamir-sealed pods must be unsealed
after restart; production should use an approved auto-unseal design where
available.

## 5. Prepare and deploy RHTAS

The reproducible customer profile uses keyless Fulcio signing with Rekor and
TUF, with `tsa.enabled: false`. No TSA private key or certificate secret is
required. After Argo CD syncs RHTAS, verify:

```bash
oc get securesign,tuf -n trusted-artifact-signer
oc get pods,pvc,route -n trusted-artifact-signer
```

The resources must report `Ready`. Fulcio uses the configured OIDC
issuer for keyless identities; Rekor records signatures; TUF publishes trust
material. TSA may be introduced later after its PKI and RFC3161 response are
validated with the mirrored Cosign client.

## 6. Deploy RHACS

Deploy Central first with `securedCluster.enabled: false`. Wait for Central and
Scanner V4 to become Ready, generate and apply the cluster registration secret
outside Git, and then change `securedCluster.enabled` to `true`. Argo CD creates
the local SecuredCluster services in the same `stackrox` namespace as Central.
Create a least-privilege RHACS API token for image scanning and policy checks.

## 7. Create pipeline credentials

Create these directly in `customer-cicd`, preferably through Vault Secrets
Operator. The names and keys are contracts used by the checked-in Tasks:

| Secret | Required data | Purpose |
| --- | --- | --- |
| `git-credentials` | Git-compatible `.gitconfig` and credential material | Clone source and push the approved GitOps update |
| `registry-auth` | `config.json` | Push the image and its Cosign signature |
| `rhacs-auth` | `endpoint`, `token` | Scan the image and evaluate RHACS policies |

The pipeline service account needs repository read access for application
source and write access only to the approved Helm/GitOps repository. The Quay
robot account needs push and pull access to the target image repository. The
RHACS token needs only image scan and policy-check permissions.

## 8. Run the release pipeline

Copy the example PipelineRun to a temporary file, replace the image destination
and revisions, and submit it:

```bash
oc create -f pipelines/examples/pipelinerun.yaml
oc get pipelinerun,taskrun -n customer-cicd
```

Do not commit a PipelineRun containing production identifiers or credentials.
For normal operation, an approved Azure DevOps/Git webhook or Pipelines as Code
event creates a PipelineRun with the commit SHA and immutable image tag.

## 9. Promotion and deployment

The pipeline never runs `oc apply` against a workload cluster. After successful
tests, RHACS gates, and keyless signing, it updates the Helm values file with the
immutable image digest and pushes a Git commit. OpenShift GitOps observes that
commit and deploys it to the environment allowed by the branch and promotion
policy. Production promotion requires the customer approval process and uses
the same already-signed digest; it does not rebuild the image.

Run promotion only after the image and target environment are approved:

```bash
oc create -f pipelines/examples/pipelinerun-promotion-demo.yaml
```

For customer use, create a separate environment-specific PipelineRun with the
internal Quay repository, approved tag, GitOps branch, and values path. The
pipeline resolves the digest from Quay and verifies its RHTAS signature before
it is permitted to change Git.

## 10. Acceptance checks

```bash
oc get applications -n openshift-gitops
oc get pipeline,task -n customer-cicd
oc get securesign -n trusted-artifact-signer
oc get vault -n vault
```

Additionally verify one end-to-end PipelineRun, the RHACS policy result, the
Rekor transparency-log entry, the Cosign signature against private TUF roots,
the GitOps commit, and Argo CD synchronization to the intended environment.

```bash
OC_BIN=oc ./scripts/rhtas/verify-image.sh \
  INTERNAL_REGISTRY/ORGANIZATION/IMAGE@sha256:DIGEST
```
