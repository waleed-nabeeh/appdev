# Vault GitOps Application

The chart is vendored from the MT OpenShift Vault reference so an air-gapped
cluster does not need to download a Helm dependency at reconciliation time.

- `chart/values-demo.yaml` provides demo sizing and OpenShift settings.
- `chart/values-customer.example.yaml` documents customer substitutions.
- Production TLS, auto-unseal/KMS, backup, recovery, and disaster-recovery
  decisions must be approved before customer deployment.

Argo CD deploys the Kubernetes resources only. Vault initialization, recovery
keys, unseal material, and the initial root token are handled out of band.
