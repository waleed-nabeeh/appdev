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

The promotion acceptance test uses `application-promotion` and must prove all
of the following: approved Quay tag resolution, RHTAS verification, GitOps
digest commit, Argo CD synchronization, successful workload rollout, and a
healthy application route.
