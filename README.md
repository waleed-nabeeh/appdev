# Customer Release Engineering Demo

GitOps and pipeline-as-code assets for the Customer release-engineering demo. The
same structure is intended for customer use after replacing demo endpoints,
storage classes, image references, and credentials with approved internal
values.

## Repository layout

| Path | Purpose |
| --- | --- |
| `bootstrap/app-of-apps` | Argo CD bootstrap chart |
| `platform/vault` | Vendored Vault chart and environment values |
| `platform/rhtas` | RHTAS SecureSign GitOps chart |
| `pipelines` | Tekton Tasks and Pipelines stored locally for air-gapped use |
| `apps/dotnet-sample` | .NET sample source and deployment chart |
| `docs` | Branching, air-gap, bootstrap, and validation runbooks |

Start with [Customer Cluster Implementation](docs/customer-cluster-implementation.md)
for the complete migration order and [Pipeline Flow](docs/pipeline-flow.md) for
the task-by-task release behavior. The tested outcome is recorded in
[Demo Validation](docs/demo-validation.md).

For a clean installation on another cluster, follow
[New Cluster Replication](docs/new-cluster-replication.md).

## Bootstrap order

1. Install the OpenShift GitOps, Pipelines, RHTAS, RHACS, and Quay operators
   through the approved mirrored catalog. Vault Secrets Operator is optional.
2. Configure repository access in Argo CD without committing credentials.
3. Install `bootstrap/app-of-apps` using `values-demo.yaml`.
4. Initialize and unseal Vault using an approved operational process.
5. Initialize and unseal Vault. Configure Vault Secrets Operator later only if
   pipelines will consume credentials from Vault.
6. Deploy RHTAS and validate its Fulcio, Rekor, and TUF endpoints.
7. Install the local Tekton catalog and run the sample pipeline.
8. Run the promotion pipeline to verify the signed digest, update GitOps, and
   deploy through Argo CD.

No credentials, Vault recovery keys, unseal keys, root tokens, or private keys
belong in this repository.
