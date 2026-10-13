# Vault and RHTAS deployment bundle

This phase deploys Vault 1.21.2-ubi and keyless RHTAS without TSA. Vault stores
pipeline/application secrets; RHTAS signing does not use a Vault signing key.
ESO synchronization is a separate integration and is not installed by these
two charts. The Vault chart in appdev remains upstream 0.31.0 with an explicit
server image override; it is not the customer's customized split 0.32.0 chart.

## Transfer

Package all three charts with:

```bash
bash scripts/bootstrap/package-platform.sh /tmp/customer-platform-charts
```

Copy appdev into the approved internal Git repository. Do not include customer
source checkouts, credentials, Vault keys or snapshots. The source charts are:

- platform/vault/chart
- platform/rhtas/chart
- bootstrap/app-of-apps

The complete runtime list for this profile is mirror/vault-rhtas-images.csv
(15 images). Vault 1.21.2-ubi replaces the previous 1.20.4-ubi transfer.
No Vault injector or CSI provider images are needed for this profile.

```bash
bash scripts/mirror/copy-vault-rhtas.sh pullsecret.txt-quay
```

This copies all architectures while preserving source digests. Authenticate to
both source registries and internal Quay in the auth file. Ensure direct access
to internal Quay through proxy exclusions and trust its CA.

## Infrastructure prerequisites

GitOps and RHTAS operators and their matching runtime dependencies must already
be available offline. This list excludes operator/catalog installation images.
Match the RHTAS operator to the demo baseline 1.4.3 before relying on its operand
digests. Confirm its installed CSV requirements, including cert-manager and
any database operator dependencies, with the platform team.

The infrastructure team must map every original RHTAS operand repository in
the CSV to its destination repository using ImageDigestMirrorSet. Tags alone
do not redirect operator-generated digest references. Verify the exact source
digest exists in the destination, including init/job images. Configure cluster
pull credentials and CA trust for those mirrors. Do not patch generated pods.

The mapping is supplied as mirror/rhtas-idms.example.yaml. Have the platform
team review it before applying this cluster-wide configuration. It disables
fallback to public source repositories. It does not provide credentials or CA trust.

## Configure GitOps

1. Copy platform/vault/chart/values-customer.example.yaml to values-customer.yaml
   in the same directory. Set server.image.repository to INTERNAL_QUAY/devops/vault,
   retain tag 1.21.2-ubi, and set route hostname and storage class.
2. Copy platform/rhtas/chart/values-customer.example.yaml to values-customer.yaml
   in its directory. Set cluster domain, storage class and organization details.
   Keep tsa.enabled false. Confirm the actual service-account OIDC issuer and
   discovery/JWKS connectivity; do not assume the example issuer matches every cluster.
3. Copy bootstrap/app-of-apps/values-platform-only.example.yaml to an approved
   environment values file. Set internal repository URL and branch.
4. Configure GitOps repository access, namespace pull secrets, registry/route CA
   trust, and approved storage. Commit only configuration, not credentials.
5. Render and review before applying:

```bash
helm template customer-platform bootstrap/app-of-apps \
  -n openshift-gitops -f bootstrap/app-of-apps/values-platform-only.yaml
helm template customer-platform bootstrap/app-of-apps \
  -n openshift-gitops -f bootstrap/app-of-apps/values-platform-only.yaml | oc apply -f -
```

This installs the AppProject and two child Applications. Auto-sync and prune
start disabled. Sync Vault and RHTAS deliberately through ArgoCD. Do not apply
over an existing environment without reviewing ownership and names.

## Initialize and validate

For a new Vault installation, initialize exactly once and retain keys and the
root token in approved secure storage. Use scripts/vault/initialize-and-unseal.sh
with a protected JSON key-file path. Unseal/join all three nodes. Existing data
must not be initialized again. Check vault status on every node: version 1.21.2,
initialized true, sealed false; then verify three Raft voters and secret read/write.
The bootstrap readiness probe accepts sealed nodes, so Kubernetes Ready alone
is not proof of usable Vault. Establish backup, audit and TLS policies before
production; the example uses edge TLS and plaintext pod-side listeners.

For RHTAS, check Securesign conditions, pods including init/jobs, Fulcio/Rekor/TUF
routes and TUF trust initialization. Sign a test image using a service-account
token with the configured audience and verify its digest, issuer and identity.
Internal routes and OCI signatures must be accessible without public services.
Do not claim ESO readiness until an ExternalSecret successfully synchronizes
and its consumer reads the intended test secret.

## Demo validation on 2026-10-13

- Backed up the existing Vault Raft data outside Git.
- GitOps reconciled Vault image 1.21.2-ubi, then recreated and unsealed each pod.
- All three nodes reported version 1.21.2, initialized true and sealed false.
- Raft membership showed three voters, one leader and two followers.
- Temporary KV v2 secret write/read passed; the test mount was removed.
- Fresh keyless signing TaskRun platform-sign-validation-oct13 succeeded.
- Verification of the demo image digest and signing certificate passed.
- All three Helm charts and the platform-only bootstrap values passed lint.
- ESO synchronization and the customer disconnected registry have not been tested.
- Existing demo RHTAS still has an old TSA deployment. The new chart profile
  omits TSA; this was not a clean no-TSA reinstall. Its CTLogAvailable condition
  remains false despite running pods and a successful fresh signing request.
- Trust initialization currently retrieves root.json without an independently
  pinned checksum; establish the customer's trusted bootstrap root before use.
