# ACL service full pipeline validation

This bundle runs the existing `application-release` Tekton pipeline for the
`RedHat_UnifiedVisaPlatform.Backend` ACL service. It executes clone, .NET unit test, Buildah image build,
RHACS scan, security gate, RHTAS signing, and stops before GitOps write-back.

## Apply

```bash
oc apply -f pipelinerun-acl-validation.yaml
oc get pipelineruns -n customer-cicd --sort-by=.metadata.creationTimestamp
oc describe pipelinerun -n customer-cicd <run-name>
oc logs -n customer-cicd -l tekton.dev/pipelineRun=<run-name> --all-containers=true -f
```

The source revision is `test`. The target image is pushed to the demo Quay
route using the existing `registry-auth` secret. GitOps update is deliberately
disabled for validation.

## Required customer-side adjustments

Before applying in the customer environment, replace the demo image route,
PVC name, source repository URL, and GitOps repository/revision. Keep the
pipeline run in the namespace where the centralized pipeline is installed.
The namespace must contain these existing secret contracts:

- `git-credentials`: `id_ed25519`, `known_hosts`, and `ssh_config`
- `registry-auth`: Docker `config.json` for the target Quay registry
- `rhacs-auth`: RHACS `endpoint` and `token`

Do not commit PATs, registry passwords, Vault tokens, or signing keys. The
existing pipeline service account must be authorized to use these secrets.

## Demo validation result

The run `acl-service-full-vd6df` was created successfully in the demo cluster,
but the clone task stopped with exit code 128 because the demo cluster could
not resolve `azuredevops.mofa.gov.sa`. No unit-test, build, scan, gate, or
signing task was executed after that dependency failure. Run this same manifest
in the customer cluster, or provide approved DNS/egress from the demo cluster,
before treating the service pipeline as validated.

## GitOps write-back

After the validation run succeeds, create a separate controlled run with
`perform-gitops-update: "true"` and the approved values-file and image path.
Do not enable it in the first validation run.
