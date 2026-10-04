# Demo Deployment

## Prerequisites

- OpenShift cluster-admin access.
- OpenShift GitOps catalog content available.
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
helm template customer-bootstrap bootstrap/app-of-apps \
  --namespace openshift-gitops \
  --values bootstrap/app-of-apps/values-demo.yaml | oc apply -f -
```

The `vault` Argo CD Application deploys the vendored chart from the `develop`
branch. RHTAS remains disabled until its identity-provider configuration is
supplied and validated.

## Validate

```bash
oc get applications.argoproj.io -n openshift-gitops
oc get pods,pvc,route -n vault
oc get route vault -n vault
```

Vault is expected to start sealed. Initialize and unseal it only through the
approved operational procedure. Do not print or commit recovery keys, unseal
keys, or the initial root token.
