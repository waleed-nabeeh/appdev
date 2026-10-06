# Demo Validation Record

Validated on OpenShift 4.22 on 2026-10-06.

## Successful release path

PipelineRun `dotnet-sample-security-test-hgv85` completed successfully:

| Task | Result |
| --- | --- |
| `clone` | Passed |
| `unit-test` | Passed |
| `build-image` | Passed; image pushed to Quay by immutable digest |
| `scan-image` | Passed using RHACS Scanner V4 |
| `security-gate` | Passed; one non-blocking low-severity package-manager policy finding |
| `sign-image` | Passed using RHTAS Fulcio and Rekor |
| `update-helm-chart` | Intentionally skipped by `perform-gitops-update=false` |

The resulting Cosign signature was independently verified against the private
RHTAS TUF root and Kubernetes OIDC issuer. Verification confirmed the image
claims, Rekor inclusion, and Fulcio code-signing certificate chain.

## Remaining full-flow test

Before customer rollout, provide a dedicated Git automation identity and run
`pipelines/examples/pipelinerun.yaml` with `perform-gitops-update=true`. Confirm
that the task commits only the approved Helm image digest and that Argo CD
synchronizes the intended workload environment.

Do not reuse demo endpoints, image digests, robot credentials, RHACS tokens,
Vault initialization data, or RHTAS private keys in another cluster.

## Successful promotion path

PipelineRun `dotnet-sample-promotion-wrl8f` completed successfully on
2026-10-06:

| Task | Result |
| --- | --- |
| `get-approved-image` | Resolved the approved Quay tag to an immutable digest |
| `verify-image` | Verified the Fulcio identity, signature, private TUF trust, and Rekor evidence |
| `update-helm-chart` | Committed the approved digest to the `develop` GitOps branch |
| Argo CD | Synchronized commit `7764f84` and reported `Healthy` |

The promoted digest was
`sha256:97d34a37e6ceda3595370920faf23c8741fad8f15783cfb14a6e5b7cd9c72d75`.
The deployment completed with one Ready pod and the OpenShift route returned a
successful `/healthz` response.

Git write access uses a write-enabled deploy key scoped only to this demo
repository. Its private key is stored outside Git and in the `git-credentials`
Secret. Use the customer-approved service identity and repository controls in
the customer environment.

After changing the RHTAS desired state to omit TSA, PipelineRun
`dotnet-sample-promotion-txqw9` also completed all three promotion tasks. This
validated Quay digest resolution, RHTAS verification, and GitOps update behavior
using only Fulcio, Rekor, and TUF.
