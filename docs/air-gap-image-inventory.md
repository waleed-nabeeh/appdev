# Air-Gap Image Inventory

Use two mechanisms for mirroring:

1. Mirror the filtered operator catalog with `oc-mirror`. This includes the
   operator and operand `relatedImages` for GitOps, Pipelines, RHTAS, RHACS,
   and Quay.
2. Mirror the explicit additional images used directly by Tekton, Vault, and
   application builds.

Do not copy only the five operator images. RHTAS, RHACS, Quay, Pipelines, and
GitOps each reference multiple operand images.

For manual `pull`, `tag`, and `push`, use
`mirror/manual-image-mapping.csv`. It contains only the images directly needed
by the pipelines, application bases, Vault, and the no-TSA RHTAS deployment,
with suggested human-readable target repositories and tags.

The suggested tags are labels for the target Quay. The source digest remains
the integrity reference. Configure Quay to prevent tag overwrite, record the
source-to-target digest mapping, and pin production GitOps values to the target
digest where the consuming chart supports it.

Pipeline and Vault values can directly reference the target Quay repositories
and readable tags. RHTAS is different: the RHTAS Operator generates operand
pods with Red Hat source repositories and digests. After manually pushing those
images, the infrastructure team must configure an `ImageDigestMirrorSet` that
maps the source RHTAS, UBI, and OpenShift repositories to their internal Quay
locations. A readable tag can coexist in Quay for operators, but the cluster
pull is resolved by digest through that mapping.

## Directly used images

| Scope | Connected source image | Use |
| --- | --- | --- |
| Git tasks | `docker.io/alpine/git@sha256:a4bb51f1...` | Clone and GitOps commit/push |
| .NET build and tested runtime | `registry.access.redhat.com/ubi9/dotnet-100@sha256:744226d7...` | Restore, test, publish, and run the tested sample |
| Image build | `registry.redhat.io/rhel9/buildah@sha256:ad3ac00d...` | Build and push application images |
| Promotion lookup | `registry.redhat.io/rhel9/skopeo@sha256:4a6e11df...` | Resolve an approved Quay tag to a digest |
| ACS pipeline client | `registry.redhat.io/advanced-cluster-security/rhacs-roxctl-rhel9@sha256:b407cb46...` | Image scan and security policy gate |
| RHTAS client server | `registry.redhat.io/rhtas/client-server-rhel9@sha256:3d08a27f79bda1f19369786723cb8d1e130c3d46cbb8a7f44e30571d5a213240` | Supplies the matching Cosign client for sign and verify |
| Vault | `registry.connect.redhat.com/hashicorp/vault:1.20.4-ubi` | Vault HA server |

The RHTAS signing task downloads Cosign from the in-cluster RHTAS
`cli-server`; it does not download Cosign from the internet. The
`client-server-rhel9` image must therefore be mirrored even when it also appears
in the RHTAS operator related images.

## Application base images

Current .NET sample:

```text
registry.access.redhat.com/ubi9/dotnet-100@sha256:744226d7703123413cd58495e7395bf7e544dc035bd10486831bcc0ff5e808bb
```

The current tested Containerfile uses this image for both build and runtime.
For a later optimization, the ASP.NET runtime-specific image is
`registry.access.redhat.com/ubi9/dotnet-100-aspnet`, but changing the runtime
base requires another build, scan, sign, promotion, and application test.

Planned Angular application:

```text
registry.access.redhat.com/ubi9/nodejs-20@sha256:74cc7b1d13592b1e425074f434b90e470ab209da85fd1fdb8e6e9e4cabaec51a
registry.access.redhat.com/ubi9/nginx-124@sha256:da54bbccb61ef4c1229b501276e6af35878455471598426346bb3014571843ed
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
| Certificate Manager for RHTAS | `openshift-cert-manager-operator` | `stable-v1` |
| CloudNativePG for RHTAS | `cloudnative-pg` | `stable-v1` from `certified-operator-index` |

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

The additional images were resolved to multi-architecture manifest-list digests
on 2026-10-07. Vault remains tag-based because the certified registry rejected
anonymous inspection; authenticate to `registry.connect.redhat.com`, resolve
its approved digest, and update both mirror files before transfer.

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

This produces `mirror/operator-related-images.txt`. The checked-in snapshot was
exported from the demo cluster on 2026-10-07 and contains the installed
digest-pinned related images. Compare it with the `oc-mirror` output as an audit
check.
