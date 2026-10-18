# Apply RHTAS without TSA

Use this chart from the `RedHat_HelmCharts` directory in the `appdev` repo.
The template sets the three TUF keys required when TSA is disabled; it omits
`tsa.certchain.pem` and the TSA resource.

1. Edit `charts/rhtas/values.yaml`. Keep `tsa.enabled: false`. Replace
   `APPROVED_RWO_STORAGE_CLASS`, `CUSTOMER_ORGANIZATION`, and
   `PLATFORM_TEAM_EMAIL`; confirm the domain and OIDC issuer for this cluster.
   Check available storage classes with `oc get storageclass`.
2. Render and inspect the manifest. Under `spec.tuf.keys`, expect only
   `rekor.pub`, `ctfe.pub`, and `fulcio_v1.crt.pem`; there must be no `spec.tsa`.
3. Apply the chart to `infra-platforms`.

```bash
helm template rhtas charts/rhtas -n infra-platforms \
  -f charts/rhtas/values.yaml --show-only templates/securesign.yaml
helm upgrade --install rhtas charts/rhtas -n infra-platforms \
  -f charts/rhtas/values.yaml
```

Verify the operator-created resources:

```bash
oc get securesign,tuf,rekor -n infra-platforms
oc get tuf securesign -n infra-platforms \
  -o jsonpath='{.spec.keys}{"\n"}{.status.conditions}{"\n"}'
```

No TSA signer, password, or certificate-chain Secrets are needed in this mode.
If TUF remains Pending, inspect its failed key condition. In the demo no-TSA
test, the three-key list was accepted, but `rekor.pub` could not resolve because
the Rekor service was not ready. Also verify that the storage class is real,
not the placeholder in the example values.

If ArgoCD owns the RHTAS release, commit this template and the edited values
to its tracked branch and sync the Application instead of running Helm directly.
