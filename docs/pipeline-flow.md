# Pipeline Flow

The pipeline implements the release sequence without SonarQube. Static code
analysis and its quality gate are intentionally excluded until that service is
available.

| Order | Task | Behavior and integration |
| --- | --- | --- |
| 1 | `clone` | Clones the requested source revision using the dedicated Git identity. |
| 2 | `unit-test` | Restores dependencies from approved internal feeds and runs .NET tests. |
| 3 | `build-image` | Builds with Buildah, pushes an unsigned candidate to Quay, and returns its immutable digest. |
| 4 | `scan-image` | Requests an RHACS image vulnerability scan for the digest. |
| 5 | `security-gate` | Applies RHACS build-time policies and stops the run on a violation. |
| 6 | `sign-image` | Uses a short-lived service-account OIDC token to obtain a Fulcio certificate, signs the digest, records it in Rekor, and requests a TSA timestamp. |
| 7 | `update-helm-chart` | Writes the approved digest to Helm values and pushes a GitOps commit. |
| 8 | Argo CD | Detects the commit and synchronizes the declared workload environment. |

The image is pushed before scanning because RHACS scans an image available in
the registry. It is not trusted or deployed at that point. Only a digest that
passes the security gate is signed and written to the GitOps repository.

Task failure stops all dependent tasks. Therefore a failed unit test prevents a
build, an RHACS violation prevents signing, and a signing failure prevents the
GitOps update. Argo CD receives no deployment change unless every pipeline gate
has succeeded.

The checked-in Pipeline and Tasks are cluster configuration and are reconciled
by Argo CD. PipelineRuns are execution records created by webhook, Pipelines as
Code, or an authorized operator. Secrets are materialized at runtime from Vault
and are never stored in Git.

The demo PipelineRun sets `perform-gitops-update=false` so build, scan, gate,
and signing can be validated without repository write credentials. Customer
runs use the default value `true`; the final task then updates the approved
Helm repository and Argo CD performs deployment.
