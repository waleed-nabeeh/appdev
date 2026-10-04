# Air-Gap Readiness

The GitOps YAML is portable, but container images and operator catalogs must be
prepared separately for the disconnected customer environment.

Before customer deployment:

1. Pin every operator, operand, build, and runtime image by digest.
2. Mirror those images and required operator catalogs into the internal registry.
3. Replace demo image repositories in environment values with internal paths.
4. Store all Tekton Tasks in this repository; do not resolve public hub content
   during a PipelineRun.
5. Mirror .NET/NuGet dependencies into the approved internal artifact service.
6. Configure trusted internal certificate authorities for Git, Vault, Quay,
   RHACS, RHTAS, and artifact endpoints.
7. Validate DNS, NTP, storage classes, routes, and backup destinations.
8. Test with public network access blocked.

Secrets are provisioned through Vault, External Secrets, sealed delivery, or an
approved manual bootstrap. They are never stored in Git.
