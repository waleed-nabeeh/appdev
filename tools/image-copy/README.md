# Copy Images to Customer Quay

Copy images individually using `copy-image.sh`. Maintain the required commands
here; no CSV or bulk-copy procedure is required. Operator/catalog mirroring is
handled separately. This folder does not perform signing or cluster deployment.

From the appdev repository root:

```bash
cd tools/image-copy
```

The transfer host needs Bash, Skopeo, access to both registries, and an existing
auth file with the necessary source pull and destination push permissions.
Replace `/secure/path/pullsecret.txt-quay` below with your auth-file location.
Keep this file outside Git.

## Backend Images

```bash
./copy-image.sh registry.access.redhat.com/ubi9/dotnet-100-aspnet:10.0 quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/ubi-aspnet:10.0 /secure/path/pullsecret.txt-quay
./copy-image.sh registry.access.redhat.com/ubi9/dotnet-100:10.0 quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/ubi-sdk:10.0 /secure/path/pullsecret.txt-quay
```

## Frontend Images

Copy the pinned frontend builder and runtime images:

```bash
./copy-image.sh registry.access.redhat.com/ubi9/nodejs-24:9.8-1782938304 quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nodejs-24:9.8-1782938304 /secure/path/pullsecret.txt-quay
./copy-image.sh registry.access.redhat.com/hi/nginx:1.30.3-fips quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nginx-fips:1.30.3-fips /secure/path/pullsecret.txt-quay
```

After copying, use these destinations in the frontend Dockerfile stages:

```dockerfile
FROM quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nodejs-24:9.8-1782938304 AS frontend
FROM quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nginx-fips:1.30.3-fips
```

### Temporary Certificate Bypass

TLS verification is enabled by default. For the reported source-layer download
failure at `cdn.quay.io`, append `--src-tls-verify=false` to the copy command:

```bash
./copy-image.sh registry.access.redhat.com/hi/nginx:1.30.3-fips quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nginx-fips:1.30.3-fips /secure/path/pullsecret.txt-quay --src-tls-verify=false
./copy-image.sh registry.access.redhat.com/ubi9/nodejs-24:9.8-1782938304 quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nodejs-24:9.8-1782938304 /secure/path/pullsecret.txt-quay --src-tls-verify=false
```

If the certificate error names the destination Quay registry, append
`--dest-tls-verify=false` instead. Both flags can be supplied when needed.
These flags disable certificate verification only for that invocation. Install
the approved CA on the transfer host for the permanent correction.

The script inherits exported proxy settings from the current shell. Load the
existing proxy configuration before copying, and include internal Quay in
`NO_PROXY`/`no_proxy` when it must be reached directly.

### Diagnose a Copy That Produces No Progress

Add `--debug --command-timeout=60s` for a bounded diagnostic attempt:

```bash
./copy-image.sh registry.access.redhat.com/ubi9/nodejs-24:9.8-1782938304 quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nodejs-24:9.8-1782938304 /secure/path/pullsecret.txt-quay --src-tls-verify=false --debug --command-timeout=60s
```

The timeout limits the entire copy; use a longer duration such as `30m` for the
real transfer. The default command has no added overall timeout. Debug output
identifies the last registry or layer request before a stall. Redact credentials,
tokens and signed URL query strings before sharing that output.

If a new terminal or SSH session is used, load the proxy configuration again.
An unset proxy, a conflicting uppercase/lowercase proxy setting, or a blocked
registry/CDN connection requires a connectivity fix; TLS-bypass flags do not
resolve those conditions.

### Previous UBI Copy References

```bash
./copy-image.sh registry.access.redhat.com/ubi9/nodejs-24:latest quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nodejs-24:ubi9 /secure/path/pullsecret.txt-quay
./copy-image.sh registry.access.redhat.com/ubi9/nginx-126:latest quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nginx-126:ubi9 /secure/path/pullsecret.txt-quay
```

These are the existing copy references. UBI Nginx follows S2I conventions;
validate the application's Dockerfile and startup configuration before use.
It is not established as a FIPS-validated replacement for the private image.

## Webhook Proxy Image

```bash
./copy-image.sh docker.io/nginxinc/nginx-unprivileged:1.28.1-alpine3.23 quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nginx-unprivileged:1.28.1-alpine3.23 /secure/path/pullsecret.txt-quay
```

The pipeline chart's `frontendPr.proxyImage` must reference the same destination.

## Helm Chart Publishing Image

Copy this image for the planned Helm chart validation, packaging, and OCI
publication pipeline:

```bash
./copy-image.sh docker.io/alpine/helm:3.19.0 quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/helm:3.19.0 /secure/path/pullsecret.txt-quay
```

This is a community image, not a Red Hat-supported image. OpenShift execution
and internal CA trust still require validation. Copying it does not install
or start the planned pipeline.

## Optional Docker Hub Alternatives

These retained alternatives require source-tag availability and compatibility
checks before copying or selecting them in Dockerfiles. Listing an image here
does not establish security or FIPS approval.

```bash
./copy-image.sh docker.io/library/node:24-bookworm-slim quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nodejs:24-bookworm-slim /secure/path/pullsecret.txt-quay
./copy-image.sh docker.io/library/nginx:1.30.6 quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nginx:1.30.6 /secure/path/pullsecret.txt-quay
```

## Confirm the Copy

For example, inspect the destination after copying Node.js:

```bash
skopeo inspect --authfile /secure/path/pullsecret.txt-quay \
  docker://quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/nodejs-24:ubi9
```

Use the destination digest when pinning a workload or verifying/signing through
the existing pipelines. Copying an image does not sign it or validate its runtime.
The script retains the existing single-image Skopeo copy behavior; it does not
request all architectures. Mutable source tags such as latest can change.
