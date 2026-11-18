# Move existing Vault and RHTAS deployments to GitOps

Adopt the running resources in place with two Argo CD Applications. Keep the
existing Vault chart, release name, namespace, images, configuration and storage.
For RHTAS, manage the existing `Securesign` custom resource; its Operator continues
managing the component resources. Start with manual sync and pruning disabled.

This procedure moves deployment configuration into Git. Vault initialization,
unseal material, secret values, RHTAS signing keys and generated trust material
remain outside Git. Vault policies and auth configuration are a separate scope.

## 1. Identify the current deployments

Run these read-only commands on the customer Hub cluster. The namespaces below
must come from this output, because earlier installations used different ones.

```bash
oc whoami --show-server
oc get clusterversion version
oc get csv -A
oc get argocds.argoproj.io -A
oc get applications.argoproj.io -A
helm list -A
oc get statefulsets -A
oc get securesigns.rhtas.redhat.com -A
```

If either deployment is already managed by an Application, update that
Application's existing Git source instead of creating a second owner. Confirm the
installed GitOps and RHTAS versions before selecting their documentation/API.

Set these to the discovered values; the values shown are historical defaults:

```bash
ARGO_NS=openshift-gitops
VAULT_NS=infra-platforms
VAULT_RELEASE=vault
VAULT_STS=vault
RHTAS_NS=trusted-artifact-signer
RHTAS_NAME=securesign

oc -n "$VAULT_NS" get statefulset "$VAULT_STS"
oc -n "$VAULT_NS" get pods,pvc,service,route
oc -n "$RHTAS_NS" get securesign "$RHTAS_NAME"
oc -n "$RHTAS_NS" get pods,pvc,service,route
```

If `helm list` does not show Vault, establish its current deployment owner and
original manifests before continuing with the Helm-specific steps below.

## 2. Preserve configuration and recovery material

Choose a protected backup directory outside all Git checkouts. Helm values and
manifests can contain credentials; inspect and sanitize them before copying any
configuration into Git. Do not send the backup files in chat or attach them to PRs.

```bash
umask 077
BACKUP_DIR=$(mktemp -d /var/tmp/mofa-platform-backup.XXXXXX)
helm get values "$VAULT_RELEASE" -n "$VAULT_NS" -o yaml \
  > "$BACKUP_DIR/vault-user-values.yaml"
helm get values "$VAULT_RELEASE" -n "$VAULT_NS" --all -o yaml \
  > "$BACKUP_DIR/vault-computed-values.yaml"
helm get manifest "$VAULT_RELEASE" -n "$VAULT_NS" \
  > "$BACKUP_DIR/vault-helm-manifest.yaml"
oc -n "$VAULT_NS" get statefulset "$VAULT_STS" -o yaml \
  > "$BACKUP_DIR/vault-statefulset.yaml"
oc -n "$VAULT_NS" get pvc -o yaml > "$BACKUP_DIR/vault-pvcs.yaml"
oc -n "$RHTAS_NS" get securesign "$RHTAS_NAME" -o yaml \
  > "$BACKUP_DIR/securesign-live.yaml"
oc -n "$RHTAS_NS" get pvc -o yaml > "$BACKUP_DIR/rhtas-pvcs.yaml"
```

Have the Vault owner take and verify a Raft snapshot using the existing approved
authentication and CA trust. On an authenticated Vault CLI configured for this
instance, the commands are:

```bash
vault status
vault operator raft list-peers
vault operator raft snapshot save "$BACKUP_DIR/vault-raft.snap"
```

These CLI commands require Integrated Storage/Raft and sufficient Vault policy.
Keep recovery/unseal access available. Back up RHTAS persistent data, databases
and signing/trust Secrets using the procedure for the installed RHTAS version;
the `Securesign` YAML export alone is not a RHTAS backup.

## 3. Prepare the Git source

Use the approved internal repository. `RedHat_HelmCharts`, branch `dev`, is the
existing writable repository used by the application pipelines; confirm it is
also the intended platform repository. Prepare this layout there:

```text
platform/
  vault/
    chart/                  # Exact deployed chart, including custom templates
      Chart.yaml
      templates/
      values.yaml
      values-hub.yaml       # Sanitized current environment overrides
  rhtas/
    instance/
      securesign.yaml       # Existing CR desired configuration
```

For Vault, copy the exact chart source/version used for the running release and
its sanitized user values. Preserve all original values-file and `--set`
overrides. Review computed values and the live StatefulSet for manual drift.
Reference existing Secrets by name instead of committing their contents.

The appdev Vault chart is version **0.31.0**. The earlier customer notes mention
a customized split **0.32.0** chart. Use appdev's chart only if comparison confirms
it matches the deployed installation. Keep image upgrades and changes to TLS,
unseal, storage, injector and networking out of the adoption change.

For RHTAS, copy `apiVersion`, `kind`, `metadata.name`, `metadata.namespace`, the
required user annotations/labels and the complete desired `spec` from the current
CR. Remove `status` and server metadata such as `uid`, `resourceVersion`,
`generation`, `creationTimestamp` and `managedFields`. Do not copy runtime
finalizers, owner references or previous Argo tracking metadata into the new file.
Review inline fields for sensitive values before committing.

Preserve its existing hosts, OIDC settings, certificate/key Secret references,
TUF configuration, TSA configuration and database/storage settings. The existing
appdev RHTAS chart models a subset of these settings, so the current CR is the
baseline for this adoption. Do not add its generated Deployments, child CRs,
Services or generated Secrets as independently managed manifests.

## 4. Add two Applications

Configure repository credentials and CA trust through the existing Argo CD
administration process. The Application Controller also needs access to the
existing namespaces and any cluster-scoped resources rendered by the Vault chart.
An AppProject allowlist alone does not grant Kubernetes RBAC.

Have the GitOps administrator use an existing appropriately scoped project or
create one restricted to this repository, the two destinations, and the exact
required resource kinds. Use that project name below. Do not grant cluster-admin
as a migration shortcut.

Save the following as `vault-application.yaml` and `rhtas-application.yaml`.
Replace `EXISTING_PLATFORM_PROJECT` and the pinned `REVIEWED_GIT_COMMIT_SHA`.
Set namespaces/names from discovery. The Vault Application name and Helm
`releaseName` should both equal the current Helm release name to preserve chart
labels as well as resource names. Change the repository/path if the approved
repository differs.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: vault
  namespace: openshift-gitops
spec:
  project: EXISTING_PLATFORM_PROJECT
  source:
    repoURL: https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_HelmCharts
    targetRevision: REVIEWED_GIT_COMMIT_SHA
    path: platform/vault/chart
    helm:
      releaseName: vault
      valueFiles:
        - values-hub.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: infra-platforms
  syncPolicy:
    syncOptions:
      - FailOnSharedResource=true
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: rhtas
  namespace: openshift-gitops
spec:
  project: EXISTING_PLATFORM_PROJECT
  source:
    repoURL: https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_HelmCharts
    targetRevision: REVIEWED_GIT_COMMIT_SHA
    path: platform/rhtas/instance
  destination:
    server: https://kubernetes.default.svc
    namespace: trusted-artifact-signer
  syncPolicy:
    syncOptions:
      - FailOnSharedResource=true
```

There is no automated sync block or Application deletion finalizer. Leave
**Prune**, **Force** and **Replace** off during migration. Keep existing
namespaces; these Applications do not create or rename them. The RHTAS Operator
installation/Subscription stays under its existing owner for this first step.

## 5. Compare before the first sync

From the prepared repository checkout, render the Vault chart using the current
release identity and values. Store the output outside Git because charts may
render Secret resources:

```bash
helm lint platform/vault/chart \
  -f platform/vault/chart/values-hub.yaml
helm template "$VAULT_RELEASE" platform/vault/chart -n "$VAULT_NS" \
  -f platform/vault/chart/values-hub.yaml \
  > "$BACKUP_DIR/vault-desired.yaml"
oc diff -n "$VAULT_NS" -f "$BACKUP_DIR/vault-desired.yaml"
oc diff -n "$RHTAS_NS" -f platform/rhtas/instance/securesign.yaml
```

`oc diff` returns 1 when there are differences and can display sensitive manifest
fields; review it in the protected administration session. It does not write
resources. Resolve any API/RBAC failure separately from an ordinary diff.

Check StatefulSet name/selectors, Pod template, service account, image, replicas,
Raft configuration, claim-template names/sizes/storage classes and mounted Secret
names. Check RHTAS's complete spec against the current CR. A chart that renders
different resources is not ready for adoption. Review Helm hooks/generated
certificates if present; avoid regenerating credentials or certificates on sync.

Apply only the reviewed Application definitions, which start in manual mode:

```bash
oc apply --dry-run=server -f vault-application.yaml -f rhtas-application.yaml
oc apply -f vault-application.yaml -f rhtas-application.yaml
oc -n "$ARGO_NS" get applications.argoproj.io
```

Open each Application in Argo CD and inspect **Diff** again before clicking
**Sync**. With pruning disabled, a matching adoption should update tracking
metadata without recreating workloads. Investigate any proposed Pod-template or
storage change before syncing. Sync one Application and validate it before the
other. Do not use Force/Replace to bypass immutable-field or ownership errors.

## 6. Validate and establish the new owner

```bash
oc -n "$ARGO_NS" get applications.argoproj.io
oc -n "$VAULT_NS" get statefulset,pods,pvc
oc -n "$RHTAS_NS" get securesign "$RHTAS_NAME" -o yaml
oc -n "$RHTAS_NS" get pods,pvc,route
oc -n "$VAULT_NS" get events --sort-by=.lastTimestamp
oc -n "$RHTAS_NS" get events --sort-by=.lastTimestamp
```

Use `vault status` on every Vault server and `vault operator raft list-peers`
through the approved authenticated connection. Confirm the existing initialized,
unsealed cluster and Raft membership. Verify an existing application/ESO secret
consumer still works without displaying its secret value.

For RHTAS, inspect CR conditions and perform a fresh signing/verification test
with the existing private endpoints, issuer and identity. Also verify an image
signed before adoption to check trust continuity. Keep the existing TUF roots
and signing material. Kubernetes Pod readiness alone is insufficient.

Argo CD renders Helm templates and applies resources; it does not take over the
Helm release history as a new Helm release. The old release record can remain
for reference, but stop direct `helm upgrade`, `helm rollback` and especially
`helm uninstall` after handover. The Helm release record will become stale.
Document Argo CD as the deployment owner and make future changes through Git.
Keep manual sync until the adoption checks pass; choose automation separately.

If a problem occurs, stop syncing and correct/revert the configuration in Git.
If an Application was added to an app-of-apps parent, remove/disable it in that
parent first when suspending management. Do not delete Vault, Securesign, PVCs
or trust Secrets to undo adoption. A metadata-only adoption needs no data restore;
actual data recovery follows the approved product recovery procedure.

## Official references

- [Red Hat OpenShift GitOps permissions and declarative configuration](https://docs.redhat.com/en/documentation/red_hat_openshift_gitops/1.19/html-single/declarative_cluster_configuration/)
- [RHTAS 1.4 deployment and Securesign configuration](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/1.4/html/deployment_guide/index)
- [RHTAS administration and backup procedures](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/1/html-single/administration_guide/index)
- [Argo CD Helm rendering and release names](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/)
- [Argo CD sync options and shared resource protection](https://argo-cd.readthedocs.io/en/stable/user-guide/sync-options/)
- [Vault Raft snapshot commands](https://developer.hashicorp.com/vault/docs/commands/operator/raft)

Use the documentation version matching the discovered installation. The local
examples do not establish the current customer Operator or chart versions.
