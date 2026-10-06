# Demo Deployment

## Prerequisites

- OpenShift cluster-admin access.
- OpenShift GitOps catalog content available.
- OpenShift Pipelines, RHTAS, RHACS, Quay, and Vault Secrets Operator catalog
  content available.
- Cluster access to the configured Vault image or an internal mirror.
- The configured RWO storage class.
- Repository access from Argo CD.

## Install OpenShift GitOps

```bash
oc apply -f bootstrap/operators/openshift-gitops.yaml
oc wait --for=jsonpath='{.status.phase}'=Succeeded \
  csv -l operators.coreos.com/openshift-gitops-operator.openshift-operators \
  -n openshift-operators --timeout=10m
```

## Bootstrap Argo CD

```bash
oc apply -f bootstrap/namespaces/vault.yaml
oc apply -f bootstrap/namespaces/trusted-artifact-signer.yaml
oc apply -f bootstrap/namespaces/customer-cicd.yaml
oc apply -f bootstrap/namespaces/stackrox.yaml
helm template customer-bootstrap bootstrap/app-of-apps \
  --namespace openshift-gitops \
  --values bootstrap/app-of-apps/values-demo.yaml | oc apply -f -
```

The Argo CD Applications deploy Vault, RHTAS, and the reusable pipeline catalog
from the `develop` branch. Runtime credentials remain outside Git.

## Validate

```bash
oc get applications.argoproj.io -n openshift-gitops
oc get pods,pvc,route -n vault
oc get route vault -n vault
oc get securesign,timestampauthority,tuf -n trusted-artifact-signer
oc get central,securedcluster -n stackrox
oc get pipeline,task -n customer-cicd
```

Vault is expected to start sealed. Initialize and unseal it only through the
approved operational procedure. Do not print or commit recovery keys, unseal
keys, or the initial root token.

## Runtime bootstrap

Create these items outside Git before running the example PipelineRun:

1. A Quay organization, repository, and robot account with repository-scoped
   pull/write access.
2. `registry-auth` in `customer-cicd` containing the robot Docker config.
3. An RHACS API token with image scan and policy-check access, stored in
   `rhacs-auth` together with the Central endpoint.
4. The RHACS secured-cluster init bundle, applied directly and stored only in
   an approved protected location.
5. `git-credentials` when testing the final GitOps update task.

Enable the Pipelines console plugin and refresh the browser:

```bash
OC_BIN=oc ./scripts/openshift/enable-pipelines-console-plugin.sh
```

Run the security validation without Git write-back:

```bash
oc create -f pipelines/examples/pipelinerun-demo-test.yaml
oc get pipelinerun,taskrun -n customer-cicd
```

## Test promotion and deployment

Create the workload namespace and copy a repository-scoped Quay pull secret to
it. Create `git-credentials` in `customer-cicd` using the dedicated Git
automation identity; the secret must provide a Git-compatible `.gitconfig` and
credential file, or the `id_ed25519`, `known_hosts`, and `ssh_config` keys for a
repository-scoped write-enabled deploy key.

```bash
oc apply -f bootstrap/namespaces/customer-demo.yaml
oc create -f pipelines/examples/pipelinerun-promotion-demo.yaml
oc get pipelinerun,taskrun -n customer-cicd
```

The pipeline resolves `demo-test` to an immutable digest, verifies the existing
RHTAS signature, and pushes the digest change to
`apps/dotnet-sample/helm/values.yaml`. The `customer-dotnet-sample` Argo CD
Application then deploys it to `customer-demo`.

```bash
oc get application customer-dotnet-sample -n openshift-gitops
oc rollout status deployment -n customer-demo --timeout=5m
oc get pod,service,route -n customer-demo
```
