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

### One-time copy of existing values into Vault

If the bastion reports `vault: command not found`, reuse the CLI from the existing
Vault pod instead of downloading another version. First confirm the pod name and
that its binary architecture matches the bastion:

```bash
oc -n infra-platforms get pods
uname -m
oc -n infra-platforms exec vault-0 -- vault version
```

For a matching Linux architecture (for example, bastion `x86_64` and Vault
`linux/amd64`), run the following in the bastion Bash shell. Substitute the actual
pod/container if it is not `vault-0` or has multiple containers:

```bash
VAULT_CLI_DIR=$(mktemp -d /tmp/mofa-vault-cli.XXXXXX)

VAULT_BIN_PATH=$(oc -n infra-platforms exec vault-0 -- \
  sh -c 'command -v vault')

oc -n infra-platforms exec vault-0 -- \
  cat "$VAULT_BIN_PATH" > "$VAULT_CLI_DIR/vault"

chmod 700 "$VAULT_CLI_DIR/vault"
export PATH="$VAULT_CLI_DIR:$PATH"

vault version
```

Do not continue if the copy fails or `vault version` cannot execute. The binary
is outside the Git checkout; this PATH addition applies to the current shell.
This copies only the executable, not credentials or configuration from the pod.
Host/container library compatibility must also allow that binary to run.

#### If Vault Route login returns Service Unavailable

Check Vault directly first. These commands use the HTTP listener documented for
the current customer setup; they do not change Vault or its Route configuration.

```bash
oc -n infra-platforms exec vault-0 -- \
  vault status -address=http://127.0.0.1:8200
```

If `Sealed: true`, stop and follow the established unseal procedure. Do not
initialize/reinstall Vault or repeat login attempts to fix a sealed server.

If `Sealed: false`, open a **second terminal on the same bastion** and leave this
command running:

```bash
oc -n infra-platforms port-forward svc/vault-active 18200:8200
```

Back in the **original terminal where `vault version` worked**, run the commands
below in order. Continue to migration only after status and login succeed:

```bash
export VAULT_ADDR=http://127.0.0.1:18200

vault status
vault login -no-print

bash customer-transfer/application-build/migrate-secrets-to-vault.sh git-credentials

oc -n devops get externalsecret pipeline-vault-git-credentials
```

The original terminal retains the temporary CLI PATH; new terminals do not
inherit that shell export. Keep the port-forward running for all migration
commands and stop it with Ctrl+C afterward. If the listener uses TLS instead,
use the approved HTTPS/CA configuration rather than this HTTP example.

Use `migrate-secrets-to-vault.sh` on the customer bastion with `oc` and `vault`
CLIs installed. Use an approved migration login that can read the six Kubernetes
Secrets, inspect the Vault KV mount metadata and create those Vault paths. This
is separate from ESO's read-only policy; do not grant the ESO role write access.
Point `VAULT_ADDR` at the same existing Vault instance, through an address
reachable from the bastion, and authenticate without printing a token:

```bash
export VAULT_ADDR='https://<existing-vault-route>'
vault login -no-print
bash customer-transfer/application-build/migrate-secrets-to-vault.sh git-credentials
```

After confirming this entry synchronizes, migrate the others:

```bash
bash customer-transfer/application-build/migrate-secrets-to-vault.sh \
  registry-auth npm-auth rhacs-auth pipeline-proxy dmz-build-ssh
```

With no Secret-name arguments, the script processes all six. It verifies the Hub
API identity and KV v2, extracts raw values into a private temporary directory,
and uses `vault kv put -cas=0` with file references. Secret contents do not appear
in command arguments, output or Git. It preserves hidden property names and
multiline content. Temporary migration files are removed on normal exit and
handled signals; a host crash/SIGKILL can leave them, so use an approved protected
temporary location (`TMPDIR`) and inspect it after interrupted migrations.

Existing Vault entries (including soft-deleted versioned entries) are **never
overwritten**. On a CAS/access failure the script stops; already created entries
remain. Review the existing entry and run the script with only the remaining
names. Do not delete existing Vault data just to make bootstrap pass.

Defaults match the chart: namespace `devops`, mount `secret`, relative prefix
`devops/pipelines`. Only if your reviewed store differs, set `PIPELINE_NAMESPACE`,
`VAULT_KV_MOUNT`, `VAULT_PIPELINE_PREFIX` and/or `EXPECTED_OCP_SERVER` explicitly.
The script does not modify cluster Secrets, Vault roles/policies or Helm resources.
It handles the textual credentials used by these pipelines; it is not a general
binary Secret migration tool. Confirm ESO readiness and a fresh build afterward.

Local checks: `bash -n customer-transfer/application-build/migrate-secrets-to-vault.sh`
and `python3 tests/application-build/vault-migration-test.py` use synthetic values
and mocked CLIs only. No customer credentials were read by those checks.

### Apply the mappings

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
