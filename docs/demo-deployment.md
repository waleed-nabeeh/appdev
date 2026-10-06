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
