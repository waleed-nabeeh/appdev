# RHTAS Sign and Verify Test

This folder is an isolated validation procedure for the customer RHTAS keyless
signing flow. It does not contain registry credentials, Vault keys, or tokens.

## 1. Mirror a test image

Run this from the bastion machine after creating `pullsecret.txt-quay` with the
approved source and internal Quay credentials:

```bash
./mirror-image.sh \
  registry.redhat.io/ubi9/ubi-minimal@sha256:8eb2830d0936237fc13a1f2f7e45aecf90d69043380ad167fad0343632937f41 \
  quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/ubi9-ubi-minimal:rhtas-test-2026-10-14 \
  /secure/path/pullsecret.txt-quay
```

The target repository and tag can be changed, but signing must always use the
immutable digest after the push. Confirm it with:

```bash
skopeo inspect --authfile /secure/path/pullsecret.txt-quay \
  docker://quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/ubi9-ubi-minimal:rhtas-test-2026-10-14
```

## 2. Run the signing test

Run the direct signing test without executing the full application pipeline:

```bash
./sign-image.sh \
  quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/<repo>@sha256:<digest>
```

The script defaults to the customer demo settings:

```text
Namespace: infra-platforms
ServiceAccount: pipeline
Registry secret: registry-auth
RHTAS domain: apps.hub-visa-ocp.mofa.gov.sa
RHTAS client image: quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/rhtas-client-server:1.4.3
```

Override a value when required:

```bash
NAMESPACE=infra-platforms \
SERVICE_ACCOUNT=pipeline \
REGISTRY_SECRET=registry-auth \
APPS_DOMAIN=apps.hub-visa-ocp.mofa.gov.sa \
RHTAS_CLIENT_IMAGE=quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/rhtas-client-server:1.4.3 \
./sign-image.sh quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/<repo>@sha256:<digest>
```

The signing script:

1. Downloads Cosign from the in-cluster RHTAS `cli-server`.
2. Initializes the private TUF mirror.
3. Requests a projected Kubernetes OIDC token.
4. Obtains a Fulcio certificate and records the signature in Rekor.

The full reusable `sign-image` Task is also rendered by the pipeline chart.
Use the existing pipeline example as the base when testing the full pipeline:

```text
pipelines/examples/pipelinerun-demo-test.yaml
```

Replace its image with the mirrored test image and keep:

```yaml
- name: perform-gitops-update
  value: "false"
```

## 3. Verify the signature

After the signing PipelineRun succeeds, verify the same immutable digest:

```bash
NAMESPACE=customer-cicd \
TUF_URL=https://tuf-trusted-artifact-signer.<CUSTOMER_APPS_DOMAIN> \
CERTIFICATE_IDENTITY_REGEXP='^https://kubernetes.io/namespaces/customer-cicd/serviceaccounts/pipeline$' \
OIDC_ISSUER=https://kubernetes.default.svc \
OC_BIN=oc \
./scripts/rhtas/verify-image.sh \
  quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/ubi9-ubi-minimal@sha256:<SIGNED_IMAGE_DIGEST>
```

The verify pod uses the in-cluster RHTAS client image and TUF mirror. It does
not download Cosign from the public internet.

## 4. Initialize and unseal Vault separately

Vault is not used as the key provider for RHTAS keyless signing. It stores
pipeline/application secrets. Initialize Vault only once, after confirming the
PVCs are new and the Vault pods are running:

```bash
VAULT_NAMESPACE=infra-platforms \
OC_BIN=oc \
./scripts/vault/initialize-and-unseal.sh \
  /secure/encrypted/vault-init.json
```

For a manual one-time initialization, use the following only after confirming
that the Vault PVCs are new and that Vault is not already initialized:

```bash
export VAULT_NAMESPACE=infra-platforms
export VAULT_POD=vault-0
oc exec -n "$VAULT_NAMESPACE" "$VAULT_POD" -- \
  vault operator init -key-shares=5 -key-threshold=3 -format=json \
  > /secure/encrypted/vault-init.json
chmod 600 /secure/encrypted/vault-init.json
```

Unseal with three different key shares. Do not paste the keys into Git or
pipeline logs:

```bash
for pod in vault-0 vault-1 vault-2; do
  for index in 0 1 2; do
    key="$(jq -r ".unseal_keys_b64[${index}]" /secure/encrypted/vault-init.json)"
    oc exec -n "$VAULT_NAMESPACE" "$pod" -- vault operator unseal "$key" >/dev/null
  done
done
```

Verify initialization and sealing state:

```bash
for pod in vault-0 vault-1 vault-2; do
  oc exec -n "$VAULT_NAMESPACE" "$pod" -- vault status
done
```

For a single-replica demo, run the initialization and unseal commands only for
`vault-0`. The production three-replica profile must unseal all three pods.

The file contains the five unseal keys and initial root token. Keep it outside
Git with mode `0600`. Move it immediately to the approved custody process.
Do not paste its contents into terminal recordings, tickets, or PipelineRun
logs.

For a three-replica production deployment, the helper unseals `vault-0`,
`vault-1`, and `vault-2`. The single-replica demo profile must use the demo
procedure separately.
