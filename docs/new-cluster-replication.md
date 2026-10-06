# New Cluster Replication

This procedure reproduces the tested release-engineering flow from a jump host.
The infrastructure team installs the operators and provides working Quay and
RHACS services. This repository then deploys Vault, RHTAS, Pipelines, and the
sample application through one app-of-apps bootstrap.

RHTAS is keyless and TSA is disabled. Vault is deployed independently and is
not required for signing.

## 1. Infrastructure readiness

The following must be installed from the approved mirrored catalogs before
running GitOps:

| Product | Package | Required state |
| --- | --- | --- |
| OpenShift GitOps | `openshift-gitops-operator` | Argo CD Ready |
| OpenShift Pipelines | `openshift-pipelines-operator-rh` | Tekton CRDs and console plugin Ready |
| RHTAS | `rhtas-operator` | Operator Ready |
| RHACS | `rhacs-operator` | Central and Scanner V4 Ready |
| Quay | `quay-operator` | Registry Ready and reachable |

Run:

```bash
OC_BIN=oc ./scripts/bootstrap/validate-prerequisites.sh
```

Also confirm DNS, storage classes, internal registry mirrors, Git access, and
the cluster wildcard/internal CA trust.

## 2. Copy the repository to the jump host

```bash
git clone CUSTOMER_GITOPS_REPOSITORY_URL appdev
cd appdev
git checkout CUSTOMER_GITOPS_BRANCH
```

For an air-gapped environment, import this repository through the approved
transfer process instead of cloning from the internet.

## 3. Create customer values

```bash
cp platform/vault/chart/values-customer.example.yaml \
  platform/vault/chart/values-customer.yaml
cp platform/rhtas/chart/values-customer.example.yaml \
  platform/rhtas/chart/values-customer.yaml
cp pipelines/chart/values-customer.example.yaml \
  pipelines/chart/values-customer.yaml
cp apps/dotnet-sample/helm/values-customer.example.yaml \
  apps/dotnet-sample/helm/values-customer.yaml
cp bootstrap/app-of-apps/values-replica.example.yaml \
  bootstrap/app-of-apps/values-replica.yaml
cp bootstrap/root-application.example.yaml \
  bootstrap/root-application.yaml
```

Replace every placeholder with the customer Git URL and branch, applications
domain, RWO storage class, internal image digests, internal Quay repository,
and approved organization details. Update the root Application with the same
Git URL and branch. Keep `tsa.enabled: false`.

Validate before committing:

```bash
helm lint platform/vault/chart -f platform/vault/chart/values-customer.yaml
helm lint platform/rhtas/chart -f platform/rhtas/chart/values-customer.yaml
helm lint pipelines/chart -f pipelines/chart/values-customer.yaml
helm lint apps/dotnet-sample/helm \
  -f apps/dotnet-sample/helm/values-customer.yaml
helm lint bootstrap/app-of-apps \
  -f bootstrap/app-of-apps/values-replica.yaml
```

Commit and push these non-secret values to the customer GitOps branch. Configure
that repository credential in Argo CD outside Git.

## 4. Bootstrap app-of-apps

```bash
OC_BIN=oc HELM_BIN=helm \
  ./scripts/bootstrap/apply-app-of-apps.sh \
  bootstrap/app-of-apps/values-replica.yaml \
  bootstrap/root-application.yaml
```

The root `customer-app-of-apps` Application continuously manages the child
applications and creates three ownership boundaries:

| Argo project | Applications |
| --- | --- |
| `customer-platform` | Vault and RHTAS |
| `customer-cicd` | Tekton Tasks and Pipelines |
| `customer-apps` | Workload applications |

The application is initially disabled. Vault, RHTAS, and Pipelines synchronize
first.

## 5. Verify platform synchronization

```bash
oc get applications -n openshift-gitops
oc get pods,pvc,route -n vault
oc get securesign,tuf -n trusted-artifact-signer
oc get pipeline,task -n customer-cicd
```

Required results:

- `vault`, `rhtas`, and `pipelines` are `Synced` and `Healthy`.
- RHTAS Fulcio, Rekor, and TUF are Ready.
- No TSA secrets or TSA certificates are required.
- `application-release` and `application-promotion` exist.

## 6. Initialize Vault once

Vault starts sealed and cannot be initialized through declarative GitOps.

```bash
export VAULT_KEY_FILE=/approved/encrypted/location/vault-init.json
OC_BIN=oc ./scripts/vault/initialize-and-unseal.sh "$VAULT_KEY_FILE"
```

Move the unseal shares and initial root token into the approved custody system.
Vault is not currently consumed by the pipelines; integrate Vault Secrets
Operator later if credentials must be delivered from Vault.

## 7. Create runtime credentials outside Git

Create these Kubernetes Secrets in `customer-cicd`:

| Secret | Purpose |
| --- | --- |
| `registry-auth` | Quay robot pull/write Docker configuration |
| `rhacs-auth` | RHACS endpoint and least-privilege API token |
| `git-credentials` | Repository-scoped Git service identity or deploy key |

Create `quay-pull-secret` in each application namespace. Configure the RHACS
Quay integration and ensure Scanner V4 has completed its vulnerability-feed
initialization.

## 8. Run release and promotion

Create environment-specific PipelineRuns from the checked-in examples. Replace
all demo endpoints and use the customer GitOps values path.

Release sequence:

```text
clone -> unit-test -> build-image -> scan-image -> security-gate
-> sign-image -> optional GitOps update
```

Promotion sequence:

```text
get-approved-image -> verify-image -> update-helm-chart -> Argo CD sync
```

RHTAS automatically uses the projected `customer-cicd/pipeline` service-account
OIDC token. No permanent Cosign key, Vault signing key, TSA key, or manual action
is required for each PipelineRun.

## 9. Enable and verify the application

After the promotion pipeline writes the verified digest to
`apps/dotnet-sample/helm/values-customer.yaml`, change
`applications.customer-dotnet-sample.enabled` to `true` in
`values-replica.yaml`, commit, and push.

```bash
oc get application customer-dotnet-sample -n openshift-gitops
oc rollout status deployment -n customer-demo --timeout=5m
oc get pod,service,route -n customer-demo
```

Acceptance requires a healthy Argo application, a Ready deployment, a route
health response, the RHACS gate result, and successful RHTAS verification of
the deployed digest.
