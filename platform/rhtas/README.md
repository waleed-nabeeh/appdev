# RHTAS Keyless Signing

This chart deploys a `Securesign` instance through the installed RHTAS Operator.
It follows the supplied installation reference while using Fulcio with an OIDC
identity instead of a persistent Cosign signing key.

The demo uses projected OpenShift service-account tokens issued by
`https://kubernetes.default.svc` with audience `trusted-artifact-signer`. The
customer values must use the approved enterprise OIDC provider and identity
claims.

TSA is optional and disabled by default. The tested pipeline uses Fulcio,
Rekor, and TUF and therefore requires no TSA private key or certificate Secret.
Enable TSA only after its PKI and RFC3161 response have been validated.

RHTAS keyless signing and Vault Transit signing are separate patterns. Vault is
used for pipeline secrets; RHTAS Fulcio/Rekor/TUF provides signing identity,
transparency, and trust roots.
