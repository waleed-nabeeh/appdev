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

The reusable `sign-image` Task is rendered by the pipeline chart. Create a
PipelineRun with `perform-gitops-update=false`, an approved registry-auth
secret, and the immutable Quay image reference. The signing task:

1. Downloads Cosign from the in-cluster RHTAS `cli-server`.
2. Initializes the private TUF mirror.
3. Requests a projected Kubernetes OIDC token.
4. Obtains a Fulcio certificate and records the signature in Rekor.

Use the existing pipeline example as the base:

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

## 4. Initialize Vault separately

Vault is not used as the key provider for RHTAS keyless signing. It stores
pipeline/application secrets. Initialize Vault only once, after confirming the
PVCs are new and the Vault pods are running:

```bash
VAULT_NAMESPACE=infra-platforms \
OC_BIN=oc \
./scripts/vault/initialize-and-unseal.sh \
  /secure/encrypted/vault-init.json
```

The file contains the five unseal keys and initial root token. Keep it outside
Git with mode `0600`. Move it immediately to the approved custody process.
Do not paste its contents into terminal recordings, tickets, or PipelineRun
logs.

For a three-replica production deployment, the helper unseals `vault-0`,
`vault-1`, and `vault-2`. The single-replica demo profile must use the demo
procedure separately.
