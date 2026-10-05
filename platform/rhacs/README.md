# RHACS Deployment

The chart deploys Central and Scanner V4 first. Keep `securedCluster.enabled`
set to `false` until Central is Ready and the cluster registration secret has
been generated and applied outside Git. Then enable the SecuredCluster and let
Argo CD reconcile it.

The RHACS API token used by Tekton is runtime secret material. Create it with
the minimum image scan and policy-check permissions and expose it to the
pipeline as the `rhacs-auth` Secret. Never commit the token or registration
secret.
