# RHTAS Keyless Signing

This chart deploys a `Securesign` instance through the installed RHTAS Operator.
It follows the supplied installation reference while using Fulcio with an OIDC
identity instead of a persistent Cosign signing key.

The demo uses projected OpenShift service-account tokens issued by
`https://kubernetes.default.svc` with audience `trusted-artifact-signer`. The
customer values must use the approved enterprise OIDC provider and identity
claims.

The TSA private key, password, and certificate chain are prerequisite Secrets
created outside Git. Only their names and keys are referenced by the chart.

RHTAS keyless signing and Vault Transit signing are separate patterns. Vault is
used for pipeline secrets; RHTAS Fulcio/Rekor/TUF provides signing identity,
transparency, and trust roots.
