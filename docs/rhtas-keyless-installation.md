# RHTAS Keyless Installation

## Design

- Fulcio issues short-lived signing certificates from an OIDC identity.
- Rekor records signatures in the private transparency log.
- TUF publishes the private trust root.
- CTLog records Fulcio certificate issuance.
- TSA is optional and disabled in the reproducible customer profile.
- Vault stores pipeline secrets but is not the image-signing key provider.

The demo uses projected OpenShift service-account tokens. The customer must
replace this issuer with the approved enterprise identity provider when that is
required by the security design.

## Prepare the namespace

```bash
oc apply -f bootstrap/namespaces/trusted-artifact-signer.yaml
```

## Deploy through GitOps

Install the app-of-apps chart after setting `applications.rhtas.enabled: true`:

```bash
helm template customer-bootstrap bootstrap/app-of-apps \
  --namespace openshift-gitops \
  --values bootstrap/app-of-apps/values-demo.yaml | oc apply -f -
```

## Validate

```bash
oc get application rhtas -n openshift-gitops
oc get securesign securesign -n trusted-artifact-signer
oc get pods,pvc,route -n trusted-artifact-signer
```

Initialize a Cosign client from the private TUF service:

```bash
export TUF_URL=https://tuf-trusted-artifact-signer.APPS_DOMAIN
cosign initialize --mirror="$TUF_URL" --root="$TUF_URL/root.json"
```

The pipeline downloads the version-matched Cosign binary from the internal
RHTAS `cli-server` service. No public download occurs during signing. For the
disconnected environment, mirror the `client-server-rhel9` image by digest and
set `images.rhtasClientServer` in the pipeline values file.

The pipeline signing task must request a projected service-account token with
audience `trusted-artifact-signer` and pass that identity token to Cosign. The
image must always be signed by immutable digest, never by a mutable tag.

Verify a signed image using the checked-in helper. It creates a temporary pod,
uses the existing `registry-auth` Secret, verifies against private TUF, and
deletes the pod afterward:

```bash
OC_BIN=oc ./scripts/rhtas/verify-image.sh \
  REGISTRY/ORGANIZATION/IMAGE@sha256:DIGEST
```

Fulcio keyless signing, Rekor recording, and TUF trust remain mandatory. TSA
can be introduced later only after its PKI and RFC3161 response are validated
with the approved Cosign client.
