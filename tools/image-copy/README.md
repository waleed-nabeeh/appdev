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
