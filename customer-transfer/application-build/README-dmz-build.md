# Frontend/backend builds on the DMZ VM

VM: `172.28.50.40` (`SIT-UVSA-AND-RD`), SSH account: `appdevpipeline`.
The customer values install these **manual build/push smoke tests**:

- `application-backend-dmz-test`: defaults to `acl-service`, source branch `test`.
- `application-frontend-dmz-test`: defaults to `admin-portal`, source branch `pre-prod`.

Smoke-test flow: **clone on Hub → transfer full checkout → rootless Podman build
and push on DMZ → return image digest to Tekton**. These smoke tests do not run
unit tests, scan/sign images, update GitOps or deploy applications. Their images
are test artifacts, not release-approved images.

The existing application pipelines remain unchanged until
`remoteBuild.useForApplicationBuilds` is explicitly enabled. Keycloak and Helm
chart CI pipelines do not switch to the DMZ VM.

## Readiness

1. Add the dedicated private key to the
   `dmz-build-ssh` Secret in namespace `devops`, using keys `ssh-privatekey` and
   `known_hosts` when available. Opaque and `kubernetes.io/ssh-auth` Secrets both work.
   Current customer values use `hostKeyPolicy: accept-new` for private-key-only
   testing: the first server key is accepted and remembered within this TaskRun;
   subsequent SSH connections in that run reject a changed key. The temporary
   file is removed afterward, so the initial trust is repeated on the next run.
   First contact is not independently verified. To restore strict verification,
   add verified `known_hosts` and set `remoteBuild.hostKeyPolicy: strict` (chart
   default), then upgrade Helm. Use the
   replacement for any key exposed in a screenshot. The private key must support
   approved unattended authentication; this implementation has no passphrase agent.
2. The matching public key must be authorized for `appdevpipeline`. Hub pipeline
   pods need TCP 22 access to the VM using their actual network/SNAT source.
3. The dedicated account needs rootless Podman, subordinate UID/GID mappings,
   runtime/storage/networking prerequisites, and trusted CA certificates.
   Verify with noninteractive SSH under this account, without sudo. Do not use
   root's image storage or login credentials as the pipeline account.
4. VM commands required: **Bash, Podman, tar/gzip, coreutils (including realpath),
   and flock** (`util-linux`). `flock` is additionally required for the shared
   build limit. The Hub Git task image must contain SSH, ssh-keygen, tar/gzip,
   tee and normal shell utilities; the task checks client commands before transfer.
5. The account's home must be writable for the default `tekton-builds` directory.
   To use the Linux team's provisioned build storage, set `remoteBuild.workRoot`
   to its approved absolute path in the customer values before applying Helm.
   This root is dedicated to pipeline builds; do not point it at a shared source
   directory or system directory. Confirm usable space on that exact filesystem,
   as well as Podman's graph root filesystem.
6. VM connectivity and trust must cover every registry/feed actually referenced
   by the Dockerfiles and npm/NuGet configurations, including private ABP as
   applicable. VM CA trust alone does not install CAs inside builder images.
   Existing `registry-auth` must permit base pulls and image pushes. Frontend
   `npm-auth` must provide the existing `NPM_TOKEN` key.
7. Start with one backend and one frontend test sequentially. VM CPU/RAM/storage
   sizing and build performance still require actual measurements.

No new client image is introduced: the task uses the configured internal Git
image, currently `devops/alpine-git:2026-10-07`. There is no runtime package
installation. The shared pipeline-proxy Secret is mounted only when DMZ proxy support is enabled. It does not
configure VM internet access or rewrite Dockerfiles/package sources.

## Install and start from the UI

From the updated appdev checkout:

```bash
git pull --ff-only origin develop
helm lint ./pipelines/chart -f customer-transfer/application-build/values.yaml
helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/application-build/values.yaml
```

Under **devops → Pipelines**, start `application-backend-dmz-test` first:

- Keep the source URL/revision, `context: .` and default ACL `containerfile`.
- `image` defaults to internal `devops/acl-service:dmz-test-1`; increment the test
  tag before repeating runs. Never select a deployed/release tag.
- Keep `CERT_KEYWORD=dev` in the `build-args` array.
- Bind `source` to a new 3Gi ReadWriteOnce VolumeClaimTemplate, `git-credentials`
  to Secret `git-credentials`, and `registry-auth` to Secret `registry-auth`.
- Select service account `pipeline` and a suitable pipeline timeout (two hours
  for the single-service smoke test). Watch the build Task's logs.

Then start `application-frontend-dmz-test` similarly:

- The defaults select `deployment/admin-portal/Dockerfile`, full context `.`,
  `BUILD_ENVIRONMENT=dev`, and internal `devops/admin-portal:dmz-test-1`.
- Bind the same workspaces plus `npm-auth` to Secret `npm-auth`.
- The SSH Secret is mounted automatically only into the remote-build Task;
  there is no SSH workspace or key parameter to fill in on the start form.

For CLI starts, the chart also installs run templates:

```bash
oc -n devops get configmap backend-dmz-test-run-template \
  -o jsonpath='{.data.pipelinerun\.yaml}' > /tmp/backend-dmz-test.yaml
oc -n devops get configmap frontend-dmz-test-run-template \
  -o jsonpath='{.data.pipelinerun\.yaml}' > /tmp/frontend-dmz-test.yaml
# Review/edit image parameters if repeating tests, then create one run at a time.
oc create -f /tmp/backend-dmz-test.yaml
# After backend success:
oc create -f /tmp/frontend-dmz-test.yaml
```

Success requires a successful PipelineRun, published image/digest in Quay, and
`image-url`/`image-digest` results. Logs print the acquired VM slot and final
published image/digest. A missing host key in strict mode, SSH failure, Podman build failure or
push failure stops the Task and does not publish successful Task results.

## Workspace, credentials, concurrency and cleanup

Every service TaskRun transfers the full checkout (excluding `.git`) to:

```text
<remoteBuild.workRoot>/jobs/<TaskRun UID>/
  source/         # full repository, preserving .dockerignore
  credentials/    # temporary Quay auth and optional npm_token; outside context
  metadata/       # build context, Dockerfile path, image, build arguments
  runner.sh
```

Podman uses the original service context/Dockerfile/build arguments. The frontend
npm token remains a Podman build secret named `npm_token`, matching its Dockerfile.
Build arguments must not contain passwords/tokens. The SSH private key stays on
Hub; it is never copied to the VM. Source checkouts may contain existing sensitive
configuration, so protect build storage and keep source credentials out of Git.

All runs using the same account and work root share **four flock-protected
build slots**. Additional builds wait; each run is not given another four slots.
Transfers may overlap while builds wait, so size workspace storage accordingly.
The configured slot-wait timeout is three hours; enclosing PipelineRun timeouts
still apply. All active clients must use the same root and maxParallel value.
A changed concurrency setting is rejected against the stored limit: drain all
builds before the Linux/DevOps team changes the shared `slots/max-builds` file
and the Helm value together. Do not delete slot lock files during operation.

Each build has its own local Podman tag to avoid collisions between simultaneous
builds targeting the same destination. After normal completion/failure the VM
runner removes its source/credentials directory and its temporary local image
tag. Shared base images and build caches are retained; no global prune/reset is
run. Arrange coordinated disk monitoring/cache maintenance separately.

A terminated SSH connection or host/process crash can leave an abandoned job;
remote execution is not guaranteed to stop instantly when a Tekton run is
cancelled. The remote runner cleans on normal exit/signals, but SIGKILL/power loss
cannot guarantee cleanup. Inspect processes and lock ownership before manually
removing abandoned directories. Never delete active jobs or run broad Podman
prunes while other builds run. Only source/credentials are transferred out; the
completed image stays in Quay and Tekton receives its digest.

## Activate the existing frontend/backend workflows after validation

Keep `remoteBuild.enabled: true` and add this setting in the same customer values:

```yaml
remoteBuild:
  enabled: true
  useForApplicationBuilds: true
```

Run the same Helm upgrade again. This changes the image-build Task reference in
the selected-service frontend/backend fanouts and their supported dispatch/release
variants to `build-image-dmz`. Parameters, source PVCs, image results, scanning,
policy gates, signing and GitOps logic remain unchanged. All 14 selected backend
services can be requested as usual; only four VM builds run at once. Older
standalone validation pipelines remain unchanged.

**Backend tests remain on Hub** and currently run NuGet restore with the existing
proxy Secret. Frontend tests, when enabled, also need package access. Remote image
building does not fix Hub-side test dependency access. Do not claim the complete
workflow is proxy-free until that separate dependency path is resolved. These
smoke tests intentionally isolate build connectivity without silently disabling
unit tests in the actual release workflows.

Rollback: set `useForApplicationBuilds: false` and upgrade Helm to restore existing
Hub Buildah routing for new runs. This does not cancel already-running VM jobs.
To remove the smoke resources as well, set `enabled: false` after reverting
routing and draining runs. Do not remove Secrets or source PVCs as a rollback step.

## Local validation

```bash
ruby tests/dmz-build/validate.rb
python3 tests/dmz-build/transport_test.py
```

Transport tests use mocked SSH and Podman with real tar transfers and file locks;
they exercise full-context transfer, optional npm secrets, success/failure
results, cleanup and six concurrent jobs sharing four slots. They are not live
VM or OpenShift tests. Verify installed Podman/client compatibility on the VM.

References: [Podman build](https://docs.podman.io/en/stable/markdown/podman-build.1.html),
[Podman push](https://docs.podman.io/en/stable/markdown/podman-push.1.html),
[flock](https://www.man7.org/linux/man-pages/man1/flock.1.html).

### SSH key parsing fails before connection

`Load key ... error in libcrypto` occurs while reading the private key locally,
not while authenticating to the VM. The client normalizes CRLF line endings and
ensures a final newline in its temporary key copy; the Secret itself is unchanged.
If parsing still fails, re-upload the complete original OpenSSH/PEM private key
using Browse in the Secret UI rather than retyping it. Confirm format/algorithm
compatibility and whether the supplied key is passphrase-encrypted; a PuTTY PPK
file needs conversion to an OpenSSH format. Never paste the key into logs/chat.
No format normalization can repair missing or altered key data.

### Temporary Podman registry TLS bypass

Current customer values set `remoteBuild.tlsVerify: false` to unblock the reported
Quay certificate error. Both Podman build (registry pulls) and push receive
`--tls-verify=false`; the runner logs this temporary setting. Other pipelines and
TLS checks inside Dockerfile RUN commands (npm/NuGet/curl) are unchanged. This
setting skips registry certificate verification; it does not fix certificate
trust. Install the approved CA on the VM, restore `remoteBuild.tlsVerify: true`
(the chart default), and upgrade Helm to restore verification for new runs.

## DMZ proxy configuration

Connectivity tests confirmed that this VM reaches public npm/NuGet endpoints
through `http://172.24.223.254:8080`, while direct connections time out. Customer
values therefore enable `remoteBuild.proxy.enabled` with Secret
`pipeline-proxy`. The chart default is disabled. This reuses the existing `pipeline-proxy` Secret. Updating its values also
affects older Hub tasks that reference that Secret.

In **devops → Workloads → Secrets → Create → Key/value secret**, edit the existing
`pipeline-proxy` Secret with these three keys:

| Key | Value |
| --- | --- |
| `HTTP_PROXY` | `http://172.24.223.254:8080` |
| `HTTPS_PROXY` | `http://172.24.223.254:8080` |
| `NO_PROXY` | `localhost,127.0.0.1,172.28.50.40,azuredevops.mofa.gov.sa,quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa,.svc,.cluster.local` |

Use the bypass list agreed with the network team: the listed internal services
must be directly reachable. Neither public npm/NuGet nor ABP belongs in NO_PROXY
while its direct path is blocked. All three keys are required; NO_PROXY may be
empty only if all target connections must intentionally traverse the proxy.
Do not add proxy credentials to Helm values or pipeline parameters.

Apply the usual Helm upgrade and start a new run. With proxy enabled, the Secret
is mounted only into the remote-build Task. The Hub client keeps its SSH connection
free of proxy variables, copies proxy files into the per-job credentials directory
and transfers them through SSH. The VM reads the files as data, sets upper/lower
case HTTP_PROXY/HTTPS_PROXY/NO_PROXY, and runs `podman build --http-proxy=true` so
RUN commands such as npm install and dotnet restore receive the proxy environment.
Podman registry pulls/pushes also use this environment and the bypass list.
The files are outside the source build context and use the same cleanup as other
per-job credentials. Runner code does not print values or put them in build args;
application Dockerfiles/scripts must also avoid logging credentials.

This does not grant Hub pods external internet access or depend on root's shell
profile on the VM. It also does not repair CA trust inside builder images.
Remove stale conflicting proxy settings from application configs as appropriate;
package-source configuration and credentials are not rewritten by this Task.
To disable the feature later, set `remoteBuild.proxy.enabled: false` and upgrade
Helm; the runner will again clear inherited proxy variables for new builds.

Reference: [Podman build proxy forwarding](https://docs.podman.io/en/stable/markdown/podman-build.1.html#http-proxy).

## Frontend base-image diagnostic

`application-frontend-dmz-test` now defaults `diagnostic-base-image` to the
configured Node builder image. Before running the Dockerfile, the same VM task
inspects that local image ID/platform and starts it as numeric UID/GID `0:0`,
with `/bin/sh`, to print `id`, Node version and npm version. It uses
`--pull=never --network=none`, mounts no build credentials, and removes the
container afterward. It neither prunes storage nor refreshes images/cache.

Look in **build logs** for `BASE IMAGE CHECK PASSED` or `BASE IMAGE CHECK FAILED`.
A failed check stops before Dockerfile build/push. Missing local image, missing
shell/loader, missing Node/npm, or runtime/storage errors need investigation;
the check alone cannot distinguish all those causes. A pass confirms basic
base-image execution but does not prove cached intermediate layers are healthy.
The backend test and normal application workflows default this optional task
parameter to empty, so their behavior is unchanged. For another Node base tag,
set `diagnostic-base-image` to the exact Dockerfile base reference on the UI.
Set it empty to disable after troubleshooting; the test requires that image
already in appdevpipeline's local Podman store.

On a failed base-image check, the runner also logs Podman/storage metadata,
the local manifest digest, and (when Skopeo/coreutils timeout are available)
Quay manifest metadata with a 30-second request limit. Registry and local
manifest digests may differ for a multi-architecture index, so a difference
alone does not prove corruption. It then creates an unstarted temporary
container and streams its exported filesystem to a filename listing, showing
passwd/shell/Node/loader paths without printing file contents. The container
and listing are cleaned with the job. It does not pull, prune, reset storage,
or overwrite the mirrored image. These details narrow the failure before
any image replacement or storage repair.
