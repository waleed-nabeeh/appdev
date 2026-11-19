# Release 1 application versioning

Scope: V1.0 application CI/CD plus the user-approved frontend/backend versioning
addition. This does not implement V1.3 release-input manifests, approval PRs,
release-branch creation, Foundation orchestration or automatic Prod/DR release
tagging. Existing source repositories and reference snapshots are not modified.

## Customer configuration

Use the same `values.yaml` and Helm release as application builds. It enables:

```yaml
versioning:
  enabled: true
  repository: https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_HelmCharts
  revision: ocp
  directory: versioning
  environment: preprod
  initialVersion: 1.0.0
  createTags: true
  bump: AUTO
  apiVersion: "6.0"
```

The first new service version is **1.0.0-rc.1**, explicitly approved by the user.
The first product snapshot is independently **1.0.0-rc.1**. Existing supported
records take precedence over that seed; incompatible records fail without being
overwritten. The old `uvisa-versioning` repository is a read-only reference; its
historical versions are not automatically imported into the new series.

`versioning.environment` selects the version lineage: dev/alpha, test/beta,
preprod/rc. It does not change source branches or GitOps destinations. The current
customer build argument `env=dev`, backend/frontend source `test`, GitOps branch
**dev**, `pre-` application keys, and registry paths are
preserved. Metadata is written only to **ocp**. Do not enable another lifecycle
until its source/build/GitOps mappings are separately configured and reviewed.

Leave the UI `image-tag` parameter empty. Manual tags and alternate source URLs
are rejected while automatic versioning is enabled. Other chart installations
default to versioning disabled and retain their previous SHA/manual tag behavior.

## Existing access and prerequisites

- Both customer source repositories use `test` for manual builds and PR targets.
  Before using this configuration, create the frontend `test` branch from the
  intended `pre-prod` baseline in Azure Repos. Update any Azure frontend service
  hook target-branch filter from `pre-prod` to `test`; Helm changes the Tekton
  listener filter, not Azure service hook registration. Current hooks still run
  on active PR created/updated events, not post-merge events.
- `RedHat_HelmCharts/ocp` must already exist. The pipeline does not create or
  reset this branch, alter branch policies or bypass approvals.
- Existing `git-credentials`, key `.git-credentials`, is reused. Its Azure PAT
  needs Code Read/Write and permission to contribute to `ocp`, plus **Create tag**
  for metadata tags. Working GitOps writes to `dev` do not prove `ocp` permission.
- Source history needs read access. No write access to backend/frontend source
  branches is introduced. Source Git tags and binary/package.json version
  injection are not performed by this metadata/image-version implementation.
- The existing mirrored Node.js 24 image is used with system CA trust. The Hub
  Node Task must reach internal Azure HTTPS directly and trust its certificate.
  No insecure TLS flags, public tooling downloads or new container images are
  added. API version 6.0 endpoints are used; customer server compatibility and
  branch policy enforcement still require a live test.
- Keep the existing image-signing/gate and GitOps requirements. Configure Quay
  tag immutability through approved registry policy; the pipeline does not change
  registry policy. Do not overwrite previously signed version tags manually.

## Task graph and version rules

```text
dispatch-service-selection
  -> reserve-versions
  -> selected clone/[test]/build/scan/gate/sign lanes
  -> update-gitops
  -> record-versions
```

The first Task remains the existing source resolver. `reserve-versions` captures
one version per selected service before builds begin, using the PipelineRun UID.
It writes the reservation to Git atomically with counters, guarded by the old
branch commit ID. If another run moves the branch, the transaction is recalculated
against the new state. Bounded retries never force-push or reuse an uncommitted
allocation. Retrying the same reservation preserves its versions. Failed batches
leave reservations rather than reusing their tags; gaps are expected.

After the first successful version, AUTO examines commits since each service's
last successful source SHA. Azure commit changes are matched against catalog
service paths. Shared/unmapped changes conservatively affect selected services.
The highest Conventional Commit bump wins, including Azure squash-merge prefixes:

| Change | Bump |
| --- | --- |
| Breaking `!` or `BREAKING CHANGE` footer | MAJOR |
| `feat` | MINOR |
| `fix`, `hotfix`, `perf`, `revert` | PATCH |
| Maintenance, unrecognized or unchanged source | BUILD |

As in the legacy scripts, BUILD increments N; PATCH/MINOR/MAJOR reset the suffix
to `.0`. Examples: `1.0.0-rc.1` -> `1.0.0-rc.2` for a rebuild, or
`1.0.1-rc.0` for a fix. `versioning.bump` can explicitly select BUILD, PATCH,
MINOR or MAJOR after review; explicit mode does not query commit history.

The product snapshot combines the last successful backend and frontend service
records. Its version advances once per successful scope batch, using that batch's
highest bump. Service versions and the product version are separate identities;
a subset build does not renumber unchanged services. PI/sprint information from
the older `release.pi.sprint` implementation is not used to replace the approved
semantic version format.

## First-run setup and maintained records

The first reservation creates missing files without installing any applications:

```text
versioning/
  state.yaml
  environments/
    dev/environment.yaml
    test/environment.yaml
    preprod/environment.yaml
    preprod/acl-service.yaml          # only after successful GitOps update
    preprod/admin-portal.yaml         # only after successful GitOps update
  product/dev.yaml                    # initialized, no release fabricated
  product/test.yaml
  product/preprod.yaml
  runs/preprod/<scope>-<run-uid>.yaml
  releaseNotes/preprod/<scope>-<run-uid>.md
```

Canonical service IDs match the current catalogs and pipeline inputs. Each file
records scope/owner repository, version, source SHA, tag, exact digest, run identity
and GitOps commit. No previous registry/domain references are copied from the
historical repository. Missing unbuilt services are not presented as deployed.

`record-versions` runs only after every selected lane signs successfully and
GitOps commits. It validates that all image tags/digests match the reservation,
updates only selected service records, preserves the other scope, writes a full
product snapshot, and creates release notes. It creates an immutable metadata
Git tag `<environment>/<productVersion>` on RedHat_HelmCharts, pointing at that
record's completion commit. It does not retag application images during promotion.
Existing metadata tags are never moved.

Status is **gitops-updated**, not deployed/approved: Argo CD health and application
validation are separate checks. Disabled unit tests are not recorded as passed.
Raw RHACS vulnerability counts are not fabricated when unavailable as Task results.

The GitOps file and versioning metadata live on different branches, so those
updates are not one transaction. A metadata or tag failure after a GitOps push
fails the run and is visible in `record-versions`; it does not automatically roll
back application values. Finalization retries are idempotent, and reservations
retain the exact artifacts for reconciliation. Investigate that failure before
rebuilding. Older semantic versions cannot overwrite newer ones in the GitOps
updater, and stale metadata finalization is rejected.

## Install and first customer tests

From the updated appdev checkout:

```bash
git pull --ff-only origin develop
helm lint ./pipelines/chart -f customer-transfer/application-build/values.yaml
helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/application-build/values.yaml
oc -n devops get tasks backend-version-reserve backend-version-complete \
  frontend-version-reserve frontend-version-complete
```

1. Start `application-backend-build` with `services=acl-service`; leave image-tag
   empty. Check the actual `backend-build-fanout-...` run, not only the launcher.
2. Confirm reservation, image tag `1.0.0-rc.1` for a new ACL lineage, normal scan/
   gate/sign stages, and only `pre-acl-service` changed in the GitOps file on dev.
3. Check `ocp` for initialized environments, ACL record, product snapshot, notes
   and metadata Git tag. The recorded digest must match the build result.
4. Start `application-frontend-build` with `services=admin-portal`; confirm its
   first tag is `1.0.0-rc.1` and the product snapshot still includes the ACL record.
5. Rebuild the same source: a new run reserves the next BUILD version. A task
   retry within the same run must retain its existing reservation.
6. Try two selected services, then the full configured 14 backend and 3 frontend
   sets. Confirm only selected image fields change. Verify disk capacity on the
   DMZ VM before a full run; versioning does not solve VM storage exhaustion.

Inspect PipelineRun results without yq:

```bash
oc -n devops get pipelineruns --sort-by=.metadata.creationTimestamp
oc -n devops get pipelinerun <actual-build-run> \
  -o jsonpath='{range .status.results[*]}{.name}={.value}{"\n"}{end}'
```

Do not add the old `image-tag` override when retrying versioned builds. A policy
or credential error stops reservation before application builds. Product version
is returned only after successful finalization. Source/digest results remain.

## Local checks and rollback

```bash
ruby tests/application-build/versioning-validate.rb
node tests/application-build/versioning.test.cjs
ruby tests/application-build/validate.rb
helm lint pipelines/chart -f customer-transfer/application-build/values.yaml
git diff --check
```

The versioning tests use mocked Azure responses/state transactions and real Helm
rendered graphs; they do not contact the customer Git, Quay, RHTAS or cluster.
Existing GitOps/promotion tests separately exercise real local Git push races.

Rollback: set `versioning.enabled: false` in the customer values and upgrade Helm
before launching fresh runs. Existing prepared runs retain their graphs and must
finish or be deliberately cancelled. Do not delete version records, rewind the
ocp branch, move release tags, or reset counters to roll back. Changing the
versioning environment/seed does not move or roll back a deployed application.

References: [Azure atomic branch updates](https://learn.microsoft.com/en-us/rest/api/azure/devops/git/pushes/create?view=azure-devops-rest-6.0),
[Tekton Task results](https://tekton.dev/docs/pipelines/tasks/).
