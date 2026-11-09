# Network Access for Application Builds and Image Imports

Reviewed: 2026-11-09. This is a preparation allowlist based on the supplied
frontend/backend source snapshots, the current pipeline values, image-copy
commands and vendor documentation. It is not evidence that the customer firewall
rules are installed or that a complete disconnected build has passed.

## Connection Sources

| Source | Destination | Purpose |
| --- | --- | --- |
| Hub pipeline Pods / actual egress or SNAT addresses | Internal Azure DevOps and Quay | Git checkout, package downloads, image pulls/pushes and GitOps updates. |
| Approved package-acquisition host/service | External package endpoints below | Populate internal feeds with approved package versions and dependencies. |
| Approved image-transfer host | External image endpoints below, then internal Quay | Import approved base and tool images. |
| Hub build Pods, only if temporary external access is approved | Approved proxy, then external package endpoints | Continue the current builds before all dependencies are hosted internally. |

The proposed application proxy is `172.24.223.254:8080` (TCP). The infrastructure
proxy previously used is `100.64.255.227:3128` (TCP). Select the approved route;
these addresses are proxy endpoints, not package feeds. Confirm actual source
addresses, routing and any egress policy with the platform/network teams.

For the target air-gapped build environment, approve external access at the
acquisition/mirroring tier, and keep pipeline consumption internal. A working
upstream configuration still requires the relevant packages to be saved before
disconnected builds run.

## Internal Endpoints

All rows below use HTTPS/TCP 443. Internal connections normally bypass the
external proxy using the approved `NO_PROXY` list.

| Host / path | Purpose |
| --- | --- |
| `azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/` | Application and GitOps repositories. |
| `azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_packaging/uvisaLocal/npm/registry/` | Existing private frontend npm feed. |
| `azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_packaging/uvisaLocal/npm/` | npm authentication/download path used by the existing configuration. |
| `quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa` | Mirrored build images, application images and signatures. |

The internal backend NuGet feed URL is still to be supplied by its owner. Do not
assume the npm feed path is also a NuGet feed. A NuGet V3 index can advertise
additional metadata, package and audit URLs; keep those internal for disconnected
builds and validate the returned service index.

Existing internal RHACS and RHTAS connectivity must also remain available for
scan/gate/sign/verification. This list does not replace application runtime,
Operator/catalog, database, Keycloak, 3scale or AMQ network requirements.

## External Package Endpoints

Request HTTPS/TCP 443 from the approved acquisition service, or temporarily from
builds through the approved proxy when explicitly authorized.

| Host | Requirement |
| --- | --- |
| `registry.npmjs.org` | Current frontend default registry, package metadata and tarballs, including native platform packages. |
| `api.nuget.org` | Current backend NuGet V3 index, metadata and package endpoints. |
| `globalcdn.nuget.org` | NuGet package CDN downloads when selected/redirected by the client. |
| `nuget.abp.io` | Commercial ABP feed configured in the supplied backend reference; valid package entitlement is still required. |

The supplied frontend lockfile contains 2,494 resolved package entries for
`registry.npmjs.org` and 49 for internal Azure DevOps. These are package-entry
counts, not measured requests. The current build is therefore not internal-only.

NuGet also documents `dist.nuget.org` (client/tool distributions),
`symbols.nuget.org` (symbols) and `data.nuget.org` (audit data). Approve these
only when the chosen tools or audit configuration use them; symbol downloads
are not a normal requirement of the current application restore/build.

## Red Hat Container Image Sources and CDN

Required external registry for the currently requested Node.js/Nginx images and
the documented .NET base-image imports:

```text
registry.access.redhat.com
access.redhat.com
cdn.quay.io
cdn01.quay.io
cdn02.quay.io
cdn03.quay.io
cdn04.quay.io
cdn05.quay.io
cdn06.quay.io
```

`access.redhat.com` provides the signature store queried by Skopeo for these
images. The registry redirects image-layer GET requests to the CDN using
time-limited signed URLs. Permit those downloads and preserve their query
strings. Allowing only the registry's `/v2/` endpoint is insufficient.

The current requests use HTTPS/TCP 443. Red Hat's firewall guidance lists TCP
80 and 443 for the CDN hosts; include TCP 80 if required by the approved transfer
workflow. Use hostname rules rather than pinning CDN IP addresses.

For importing authenticated Red Hat tool images, also prepare:

```text
registry.redhat.io
```

Authentication/entitlement endpoints such as `sso.redhat.com` are conditional on
the selected login/download workflow. The current public
`registry.access.redhat.com` images do not require a separate Quay.io login just
because their blobs are served by the Quay CDN.

Current pinned frontend image references:

```text
registry.access.redhat.com/hi/nginx:1.30.3-fips
registry.access.redhat.com/ubi9/nodejs-24:9.8-1782938304
```

Maintain copy commands in [the image-copy README](../../tools/image-copy/README.md).
Once imported, Hub builds should pull these images from internal Quay.

## Conditional External Downloads

### Cypress Installation

The frontend lockfile includes Cypress 15.21.1 with an install script. If its
binary installation runs, the documented endpoints are:

```text
download.cypress.io
cdn.cypress.io
```

These use HTTPS/TCP 443. Disabling the Tekton unit-test stage does not itself
disable dependency installation inside the Dockerfile. The application team can
provide the Cypress binary internally, or explicitly skip its binary download
when no Cypress execution is required. Do not add Cypress Cloud endpoints for
this build-only use case.

### Docker Hub Imports

These are relevant only when the approved transfer host imports Docker Hub
images, such as the retained Node/Nginx alternatives or tool images. They are not
additional source registries for the two pinned Red Hat frontend images.

```text
auth.docker.io
registry-1.docker.io
production.cloudfront.docker.com
```

Use HTTPS/TCP 443. Include any additional storage hostname actually returned by
an approved image's redirect and validate against current vendor guidance. This
is not a request to allow Docker Desktop telemetry, update or account-UI URLs.

### Other Conditional Sources

- `quay.io`: only when an approved image is sourced directly from public Quay.
- `cdn-ubi.redhat.com`: if a Dockerfile adds OS package installation from UBI repositories.
- GitHub release/download hosts: only if a required installation script actually
  downloads there; no such URL is present in the inspected Dockerfile commands
  or frontend lockfile resolved URLs. Prefer hosting required binaries internally.

## Validation Before Acceptance

1. Verify DNS and TLS trust from the actual acquisition host and pipeline network.
2. Test authenticated Azure package metadata and an actual package tarball using
   the pipeline identity, not only browser access.
3. Test backend package restore from the agreed NuGet source, including ABP
   packages and any enabled vulnerability-audit endpoint.
4. Complete image copies through the redirected CDN download, then inspect the
   destination in internal Quay. An initial registry response is not a full copy.
5. Run clean frontend/backend builds with empty package caches and capture
   remaining requested hosts. A preliminary hostname list cannot prove that all
   install-script and future source-revision requirements are covered.
6. For air-gapped acceptance, block public egress from builds and verify all
   packages, native binaries and base images are served internally.

Trust the approved CA in the transfer host and relevant build images. TLS
verification bypass is a temporary diagnostic setting, not a firewall rule or
the final trust configuration. Do not include PATs, license-key URL paths or
signed CDN query strings in access requests or shared logs.

## References

- [Red Hat registry/CDN firewall requirements](https://access.redhat.com/articles/7084334)
- [Additional Red Hat outbound endpoints](https://access.redhat.com/solutions/2998411)
- [NuGet CDN guidance](https://github.com/NuGet/NuGetGallery/discussions/10313)
- [NuGet V3 and audit endpoints](https://learn.microsoft.com/en-us/nuget/nuget-org/overview-nuget-org)
- [ABP commercial package server](https://nuget.abp.io/)
- [Cypress installation and download endpoints](https://docs.cypress.io/app/references/advanced-installation)
- [Docker image-pull endpoint guidance](https://docs.docker.com/desktop/enterprise/allow-list/)
- [Azure Artifacts upstream-source behavior](https://learn.microsoft.com/en-us/azure/devops/artifacts/how-to/set-up-upstream-sources?view=azure-devops)
