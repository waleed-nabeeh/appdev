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
the task-by-task release behavior.

## Bootstrap order

1. Install the OpenShift GitOps, Pipelines, RHTAS, Vault Secrets, and RHACS
   operators through the approved catalog.
2. Configure repository access in Argo CD without committing credentials.
3. Install `bootstrap/app-of-apps` using `values-demo.yaml`.
4. Initialize and unseal Vault using an approved operational process.
5. Configure Vault authentication and the Vault Secrets Operator.
6. Deploy RHTAS and validate its Fulcio, Rekor, and TUF endpoints.
7. Install the local Tekton catalog and run the sample pipeline.

No credentials, Vault recovery keys, unseal keys, root tokens, or private keys
belong in this repository.
