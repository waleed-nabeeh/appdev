# Vault and RHTAS GitOps

Clean overlay for the approved internal HelmCharts mirror. Copy these folders
into its working checkout, preserving existing content and Git history. No
customer source code, demo workloads, pipelines or credentials are included.
Do not replace another team's bootstrap directory without reviewing conflicts.

## Contents

- charts/vault: upstream chart 0.31.0, deployed with Vault server 1.21.2-ubi.
- charts/rhtas: Securesign chart for keyless signing; TSA omitted.
- bootstrap: app-of-apps chart creating only Vault and RHTAS Applications.
- root-application.yaml: entry point watching bootstrap in the internal Git repo.
- images: 15 runtime-image mappings and an example RHTAS ImageDigestMirrorSet.
- scripts/initialize-and-unseal.sh: manual Vault initialization/unseal helper.

The Vault chart is the demo-tested chart with a server-version override, not
the customer's customized vault-runtime 0.32.0 chart. Always load its
values-customer.yaml; upstream defaults alone are not the deployment profile.

## 1. Confirm prerequisites

OpenShift GitOps and the approved RHTAS operator (demo: 1.4.4, checked
2026-10-18) must be
installed with their matching dependencies mirrored. Operator/catalog images
are not part of the 15-image list. Configure internal Git credentials, Quay pull
credentials and CA trust outside this repository. Confirm RWO storage and
capacity for three Vault replicas. ESO must be provided separately; this folder
does not install ESO or configure Vault authentication/policies for it.

Have the infrastructure team verify destination digests from images/vault-rhtas-images.csv
and review/apply images/rhtas-idms.example.yaml. RHTAS generates source-digest
image references, so readable Quay tags alone are insufficient. That mapping
disables fallback to public registries and may affect cluster-wide image pulls.

## 2. Set environment values

Edit before committing:

- root-application.yaml: internal Git URL and branch; approved root project.
- bootstrap/values.yaml: the same internal Git URL and branch.
- charts/vault/values-customer.yaml: both storage classes; confirm route hostname.
- charts/rhtas/values.yaml: storage class, organization name/email; confirm domain
  and actual service-account OIDC issuer and discovery access.

For the no-TSA RHTAS profile, follow
`charts/rhtas/APPLY-NO-TSA.md` before syncing or installing the chart.

The Hub domain and internal Vault repository are prefilled from the supplied
Quay endpoint. Confirm them. Keep the Vault image tag 1.21.2-ubi. Disable injector
and CSI as already configured. The example Vault route uses edge TLS with a
plaintext pod-side listener; obtain approval or configure end-to-end TLS before
production. Readiness permits sealed/uninitialized pods for bootstrap and is not
a substitute for vault status.

## 3. Validate and push the overlay

```bash
helm lint charts/vault -f charts/vault/values-customer.yaml
helm lint charts/rhtas
helm lint bootstrap
helm template vault charts/vault -n vault -f charts/vault/values-customer.yaml
helm template rhtas charts/rhtas -n trusted-artifact-signer
helm template customer-platform bootstrap -n openshift-gitops
```

Review rendered output. Commit and push to the approved internal mirror branch.
Configure the repository in ArgoCD, then:

```bash
oc apply -f root-application.yaml
```

In ArgoCD, sync customer-platform-root to create the project and child apps.
Then sync vault and rhtas deliberately. Automatic sync, pruning and cascading
deletion finalizers are intentionally absent. Application names vault/rhtas
must not collide with existing unrelated ArgoCD Applications. This root expects
OpenShift GitOps in openshift-gitops; adjust all bootstrap namespaces if different.
Charts are vendored and have no remote chart dependencies; no Helm dependency
download is needed. This profile reads chart source directly from internal Git;
publishing these charts to Quay OCI requires separately changing ArgoCD sources.

## 4. Initialize Vault and validate

For a NEW Vault installation only, with oc and jq on the bastion:

```bash
bash scripts/initialize-and-unseal.sh /approved/secure/path/vault-init.json
oc exec -n vault vault-0 -- vault status
oc exec -n vault vault-1 -- vault status
oc exec -n vault vault-2 -- vault status
```

Retain the JSON file securely outside Git. Never reinitialize existing storage.
Use an authorized token to check Raft voters and test secret write/read. Configure
Vault policies, Kubernetes auth and ESO SecretStore/ExternalSecret separately;
validate an actual synchronization before handing it to applications.

For RHTAS, validate Securesign conditions, all init/job images, Fulcio/Rekor/TUF
connectivity, trusted TUF bootstrap root, and a fresh sign/verify request with the
intended pipeline service account. Keyless signing does not require Vault keys.

## Validation provenance

On 2026-10-13 the demo's three Vault nodes were upgraded to 1.21.2, unsealed,
and confirmed as three Raft voters. A temporary KV v2 read/write test passed.
Fresh RHTAS keyless signing and signature verification passed in the working
`trusted-artifact-signer` instance. It retains an older TSA deployment. This
is not proof of a clean no-TSA install or customer air-gap readiness.
The clean folder has been rendered/linted locally, not applied to the customer.
