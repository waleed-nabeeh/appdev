# Existing pipeline Secrets maintained by Vault and ESO

The same Helm release can install six `ExternalSecret` mappings. Existing pipeline
Tasks, Secret names, Secret types and credential keys remain unchanged. The chart
does not install ESO, replace `vault-backend`, change Vault authentication, write
secret values into Vault, or create Kubernetes Secrets containing credentials.

## Prepare the existing Vault connection and values

Verify the already configured connection, without printing credential values:

```bash
oc whoami --show-server
oc -n devops get secretstore vault-backend
oc -n devops get externalsecrets
oc -n devops get secrets git-credentials registry-auth npm-auth rhacs-auth pipeline-proxy dmz-build-ssh
oc explain externalsecret.spec.target --api-version=external-secrets.io/v1
```

The store must be Ready. Reuse its current mount, role, endpoint, CA and KV version;
do not reapply the older generic test SecretStore manifest, which could replace
working Hub authentication settings. Verify no other ExternalSecret/controller
already manages the same target keys; do not run competing synchronizers. Existing
Secrets must be writable (not immutable). Do not delete/recreate them to migrate.

In the existing Vault KV v2 mount `secret`, populate the following entries through
the approved Vault administrator process/UI, initially using the exact current
working values. Vault object properties must match existing Kubernetes data keys:

| Kubernetes Secret | Vault relative key | Expected properties |
| --- | --- | --- |
| git-credentials | devops/pipelines/git-credentials | `.git-credentials` |
| registry-auth | devops/pipelines/registry-auth | existing `config.json` and/or `.dockerconfigjson` |
| npm-auth | devops/pipelines/npm-auth | `NPM_TOKEN` |
| rhacs-auth | devops/pipelines/rhacs-auth | `endpoint`, `token` |
| pipeline-proxy | devops/pipelines/pipeline-proxy | `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` |
| dmz-build-ssh | devops/pipelines/dmz-build-ssh | `ssh-privatekey`, existing `known_hosts` if present |

Preserve any other required existing properties. Use raw strings, including the
complete registry JSON string, multiline Git credentials and SSH key newlines.
Do not store Kubernetes `.data` base64 encodings as the Vault property values.
No actual credentials belong in Helm values, manifests, Git or shared logs.

The role used by the existing SecretStore needs a read policy such as:

```hcl
path "secret/data/devops/pipelines/*" {
  capabilities = ["read"]
}
```

Have the Vault administrator add the pipeline-read policy to that role while
preserving its existing policies and service-account bindings. This example
assumes the existing store's KV mount is `secret`, version v2; check its actual
configuration. ExternalSecret `remoteKey` is relative to the mount, so it does
not include `secret/data/`. Do not alter other Vault auth mounts or initialize,
unseal, restart or recreate Vault as part of this Secret migration.

## Install through the existing Helm release

Customer `values.yaml` enables `externalSecrets.enabled: true`, store
`vault-backend`, refresh `1m`; the chart defaults leave the feature off elsewhere.
The configured API is `external-secrets.io/v1`, matching the existing test
manifest. If the installed CRD serves only v1beta1, select that API in
`externalSecrets.apiVersion` before installing; do not infer upstream API support
from the Red Hat Operator version number alone.

After confirming the store, existing Secrets, Vault values and policy:

```bash
git pull --ff-only origin develop
helm lint ./pipelines/chart -f customer-transfer/application-build/values.yaml
helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/application-build/values.yaml
oc -n devops get externalsecrets -l app.kubernetes.io/component=vault-secret-sync
oc -n devops wait externalsecret \
  -l app.kubernetes.io/component=vault-secret-sync --for=condition=Ready --timeout=120s
```

The chart creates `pipeline-vault-<secret-name>` ExternalSecrets targeting the
original Secret names. `creationPolicy: Merge` requires existing target Secrets
and updates their managed data; it does not create or take ownership of them.
A metadata-only target template labels the credential source as Vault without
copying Helm ownership annotations to the existing Secret. It defines no Secret
type or data template, preserving existing registry/SSH/Opaque types and keys.
`deletionPolicy: Retain` preserves the target when the Vault source disappears,
with a synchronization error. It is not a backup of previous values.

For gradual migration, override `externalSecrets.secrets` in the customer values
with only the git-credentials entry first; validate one fresh ACL run, then add
the remaining entries. Helm replaces lists rather than merging list items. All
entries must have `name` and `remoteKey`. Do not apply the separate older draft
ExternalSecrets on top of these Helm-managed mappings.

## Verify and troubleshoot

For the first synchronized credential:

```bash
oc -n devops describe externalsecret pipeline-vault-git-credentials
oc -n devops get secret git-credentials \
  -o go-template='{{range $key, $value := .data}}{{printf "%s\n" $key}}{{end}}'
```

The second command lists key names only. Validate matching values using an
approved secure method; do not paste Secret YAML, decoded credentials or Vault
values into chat/logs. Start a fresh ACL build and then an admin-portal build to
exercise Git/versioning, registry, scans, proxy/SSH and npm paths. Existing Pods
may retain credentials copied at startup; use new runs to validate rotation.

- Store not Ready: inspect the existing Vault connection/authentication.
- Vault permission denied: check policy attachment to the actual role.
- Vault path not found: verify KV mount/version, relative path and population.
- Required keys absent/invalid: compare property names and raw formats securely.
- Target Secret absent: Merge deliberately cannot recreate it. Restore it through
  the approved Secret provisioning process before retrying synchronization.

Helm success only establishes that mappings were installed; it does not prove
Vault synchronization or successful pipeline authentication. ESO writes may
update Secrets shortly after Helm completes, so preserve existing valid values
in Vault before enabling sync.

## Stop synchronization / rollback

Set `externalSecrets.enabled: false` and upgrade the same Helm release. This
removes its ExternalSecrets while leaving existing Secrets and their last values
in place (Merge ownership). It does not restore earlier values automatically.
If a wrong value was synchronized, stop its reconciliation before restoring the
approved previous credential. Do not remove Vault roles/auth mounts or pipeline
Secrets as a rollback shortcut.

Local validation: `ruby tests/application-build/external-secrets-validate.rb`.
It validates Helm mappings and preservation of pipeline resources; it does not
connect to Vault or synchronize customer Secrets.

References: [ESO lifecycle policies](https://external-secrets.io/v1.1.1/guides/ownership-deletion-policy/),
[Vault provider configuration](https://external-secrets.io/v1.2.0/provider/hashicorp-vault/).
