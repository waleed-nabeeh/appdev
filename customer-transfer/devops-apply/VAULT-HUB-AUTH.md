# Hub ESO authentication to Vault

The customer-provided configuration shows `auth/kubernetes/` pointing at the
Pre-Production API with an explicit reviewer token. Hub service-account tokens
must use a separate auth mount. Leave the existing mount and its roles unchanged.
These steps configure authentication only; they do not restart or initialize
Vault, alter its storage, or delete secrets. Hub execution remains unverified.

## 1. Check Hub identity and prerequisites

From the bastion, confirm the server is the intended Hub cluster:

```bash
oc whoami --show-server
oc -n infra-platforms get pods \
  -o custom-columns='POD:.metadata.name,SA:.spec.serviceAccountName'
oc auth can-i create tokenreviews.authentication.k8s.io \
  --as=system:serviceaccount:infra-platforms:vault
oc -n infra-platforms get svc vault-active
oc -n devops get serviceaccount eso-vault-reader
```

The Vault server pods must use service account `vault`, and the permission check
must return `yes`. Otherwise stop and confirm the correct identity. If that
account lacks reviewer access, a cluster administrator can grant it with:

```bash
oc adm policy add-cluster-role-to-user system:auth-delegator \
  system:serviceaccount:infra-platforms:vault
```

Repeat the permission check. The previously supplied ESO egress exception must
allow TCP 8200 to Vault. The supplied patch uses HTTP because the current Vault
listener has TLS disabled; if listener TLS changes, use HTTPS with CA trust.

## 2. Configure a separate Vault auth mount

Open a shell in an existing Vault server pod (replace `vault-0` if necessary):

```bash
oc -n infra-platforms rsh vault-0
```

Inside the pod, use an approved Vault administrator session. Enter the token at
the hidden prompt, never as a command argument or in Git/logs:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
vault login
vault auth list
```

If `kubernetes-hub/` already exists, inspect its configuration and roles before
changing it. Do not disable/recreate a mount used by other consumers. If absent:

```bash
vault auth enable -path=kubernetes-hub kubernetes
```

For this new mount, configure Hub's internal API and the pod's local CA. With no
explicit reviewer JWT configured and local JWT loading enabled, Vault uses its
mounted, rotating service-account token for TokenReview:

```bash
vault write auth/kubernetes-hub/config \
  kubernetes_host=https://kubernetes.default.svc:443 \
  kubernetes_ca_cert=@/var/run/secrets/kubernetes.io/serviceaccount/ca.crt \
  disable_local_ca_jwt=false
vault read auth/kubernetes-hub/config
vault policy read eso-devops-test
```

Stop if `token_reviewer_jwt_set` is `true`: an existing explicit reviewer needs
review before reuse. Confirm the policy permits reading
`secret/data/devops/eso-test`. Reuse the existing policy without widening it.

Create the role under the new Hub mount (inspect first if it already exists):

```bash
vault write auth/kubernetes-hub/role/eso-devops-test \
  bound_service_account_names=eso-vault-reader \
  bound_service_account_namespaces=devops \
  token_policies=eso-devops-test \
  token_ttl=1h
vault read auth/kubernetes-hub/role/eso-devops-test
exit
```

Use the established secure admin-session cleanup procedure after configuration.
Do not copy or publish the Vault CLI token file.

## 3. Update the Hub SecretStore and verify

From the appdev repository root on the bastion:

```bash
oc -n devops patch secretstore vault-backend --type=merge \
  --patch-file customer-transfer/devops-apply/eso-vault-hub-auth-patch.yaml
oc -n devops describe secretstore vault-backend
oc -n devops describe externalsecret eso-vault-test
oc -n devops get secret eso-vault-test
```

Expect SecretStore and ExternalSecret `Ready=True`, followed by Secret creation
in `devops`. A successful login does not prove the Vault path/property exists;
inspect the latest ExternalSecret event if the secret is still absent. Do not
print real application secret values during validation.

The patch preserves other SecretStore fields, including CA configuration and KV
settings. Capture the current endpoint/auth settings before applying for rollback.
If necessary, restore those SecretStore fields; leave both Vault auth mounts
intact. Do not revoke or disable the existing Pre-Production auth mount.

The generic `external-secret-vault-test.yaml` still references `kubernetes` and
the Route. Reapplying it restores those settings. Persist the Hub endpoint and
`mountPath: kubernetes-hub` in the actual GitOps owner, or reapply this patch after
the generic test manifest. The patch file is input to `oc patch`, not `oc apply`.

Reference: https://developer.hashicorp.com/vault/docs/auth/kubernetes
