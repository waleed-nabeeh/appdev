# Air-Gap Image Inventory

Use two mechanisms for mirroring:

1. Mirror the filtered operator catalog with `oc-mirror`. This includes the
   operator and operand `relatedImages` for GitOps, Pipelines, RHTAS, RHACS,
   and Quay.
2. Mirror the explicit additional images used directly by Tekton, Vault, and
   application builds.

Do not copy only the five operator images. RHTAS, RHACS, Quay, Pipelines, and
GitOps each reference multiple operand images.

## Directly used images

| Scope | Connected source image | Use |
| --- | --- | --- |
| Git tasks | `docker.io/alpine/git:latest` | Clone and GitOps commit/push |
| .NET build and tested runtime | `registry.access.redhat.com/ubi9/dotnet-100:latest` | Restore, test, publish, and run the tested sample |
| Image build | `registry.redhat.io/rhel9/buildah:latest` | Build and push application images |
| Promotion lookup | `registry.redhat.io/rhel9/skopeo:latest` | Resolve an approved Quay tag to a digest |
| ACS pipeline client | `registry.redhat.io/advanced-cluster-security/rhacs-roxctl-rhel9:4.11` | Image scan and security policy gate |
| RHTAS client server | `registry.redhat.io/rhtas/client-server-rhel9@sha256:3d08a27f79bda1f19369786723cb8d1e130c3d46cbb8a7f44e30571d5a213240` | Supplies the matching Cosign client for sign and verify |
| Vault | `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi` | Vault HA server |

The RHTAS signing task downloads Cosign from the in-cluster RHTAS
`cli-server`; it does not download Cosign from the internet. The
`client-server-rhel9` image must therefore be mirrored even when it also appears
in the RHTAS operator related images.

## Application base images

Current .NET sample:

```text
registry.access.redhat.com/ubi9/dotnet-100:latest
```

The current tested Containerfile uses this image for both build and runtime.
For a later optimization, the ASP.NET runtime-specific image is
`registry.access.redhat.com/ubi9/dotnet-100-aspnet`, but changing the runtime
base requires another build, scan, sign, promotion, and application test.

Planned Angular application:

```text
registry.access.redhat.com/ubi9/nodejs-20:latest
registry.access.redhat.com/ubi9/nginx-124:latest
```

Node.js builds the Angular static assets and Nginx serves them. Angular support
has not yet been added to the tested Tekton pipeline. Confirm the actual
frontend's Angular/Node compatibility before freezing the Node.js stream.

## Operator content

The OpenShift 4.22 example mirrors these packages from
`registry.redhat.io/redhat/redhat-operator-index:v4.22`:

| Product | Package | Channel in example |
| --- | --- | --- |
| OpenShift GitOps | `openshift-gitops-operator` | `gitops-1.22` |
| OpenShift Pipelines | `openshift-pipelines-operator-rh` | `pipelines-1.24` |
| RHTAS | `rhtas-operator` | `stable-v1.4` |
| RHACS | `rhacs-operator` | `stable` |
| Quay | `quay-operator` | `stable-3.17` |

Review and freeze approved versions before mirroring. The supplied file is:

```text
mirror/imageset-config.example.yaml
```

Example disconnected workflow:

```bash
oc mirror --v2 \
  --config mirror/imageset-config.yaml \
  file:///approved-transfer/oc-mirror

oc mirror --v2 \
  --config mirror/imageset-config.yaml \
  --from file:///approved-transfer/oc-mirror \
  docker://INTERNAL_QUAY/MIRROR_NAMESPACE
```

Follow the generated instructions to apply the catalog source and mirror
mapping resources to the disconnected cluster.

## Freeze immutable digests

The example contains several floating tags because they match the connected
demo. Before customer use, resolve each tag to a multi-architecture manifest
digest, mirror it, and replace the customer values with internal digest-pinned
references.

After logging into the source registry:

```bash
while IFS= read -r image; do
  case "$image" in ''|'#'*) continue ;; esac
  skopeo inspect --raw "docker://${image}" | sha256sum
done < mirror/additional-images.txt
```

Use `skopeo inspect` or `oc image info` to record the source manifest-list
digest. Do not treat the local `sha256sum` example as the registry digest unless
the registry's manifest representation is confirmed unchanged.

## Export installed operator images

After `oc login`, export the exact `relatedImages` from the installed CSVs:

```bash
OC_BIN=oc ./scripts/mirror/export-operator-images.sh
```

This produces `mirror/operator-related-images.txt`. Compare it with the
`oc-mirror` output as an audit check. The export could not be refreshed during
the latest documentation update because the demo cluster login had expired.
