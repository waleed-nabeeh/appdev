# Copy approved preproduction images to production and DR GitOps

This first version updates Git only, as agreed. The Helm-managed promotion
Pipelines use the existing Quay repositories and tags, verify signatures, and
update selected image references in both production and DR files. They do not
build, mirror, retag, publish Helm charts, or invoke Argo CD sync. uvisa-versioning
integration remains separate work.

Use the same single configuration as the working builds:
`customer-transfer/application-build/values.yaml`. It enables
`applicationPromotion.enabled`. The older generic `application-promotion` is
preserved; use the scope-specific Pipelines below for this workflow.

| Pipeline | Source in RedHat_HelmCharts/dev | Target files in the same branch |
| --- | --- | --- |
| `application-backend-promotion` | `app-chart/backend.yaml` | `app-chart/prod-backend.yaml`, `app-chart/dr-backend.yaml` |
| `application-frontend-promotion` | `app-chart/frontend.yaml` | `app-chart/prod-frontend.yaml`, `app-chart/dr-frontend.yaml` |

## Names and file preparation

The current agreement is to keep **the same application names in all three files**.
For example, the source and both backend targets contain `pre-acl-service`; the
frontend files contain `pre-admin-portal`, `pre-applicant-portal` and
`pre-operational-portal`. No names are rewritten. The configurable target prefixes
default to `pre-` for this test; do not switch them to `prod-`/`dr-` unless the
destination definitions have been prepared with those names.

The target files must already contain the selected applications, with
`autoSync: false`. Missing files or applications fail before any Git commit.
Promotion changes only `overrideValues.image.repository` and `.tag`.
Namespaces, projects, routes, Secrets, chart versions, application names and
unselected services are retained. Source YAML is never edited.

For an initial Git-copy-only test where the target files do not yet exist, you
can seed them from the sources **in your writable RedHat_HelmCharts checkout**:

```bash
git switch dev
cp -n app-chart/backend.yaml app-chart/prod-backend.yaml
cp -n app-chart/backend.yaml app-chart/dr-backend.yaml
cp -n app-chart/frontend.yaml app-chart/prod-frontend.yaml
cp -n app-chart/frontend.yaml app-chart/dr-frontend.yaml
git add app-chart/prod-backend.yaml app-chart/dr-backend.yaml \
  app-chart/prod-frontend.yaml app-chart/dr-frontend.yaml
git commit -m 'Prepare same-name promotion test values'
git push origin dev
```

Skip those commands if the target files already contain approved environment
settings. A source copy keeps preproduction settings and is only a Git-copy test,
not a configured production/DR deployment. Identical tags produce a successful
no-change result; use a later signed preproduction build to see an actual update.
Keep these test files out of live deployment roots. Before deployment, distinct
environment configuration and unique Application identities within each Argo CD
namespace must be established. Keeping identical names in separate YAML files
does not create separate Applications in one Argo CD namespace.

## Install and run

From appdev:

```bash
git pull --ff-only origin develop
helm lint ./pipelines/chart -f customer-transfer/application-build/values.yaml
helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/application-build/values.yaml
```

In OpenShift project **devops**, open **Pipelines → Pipelines** and start either
**application-backend-promotion** or **application-frontend-promotion**.

| Input | Meaning |
| --- | --- |
| `services` | Comma-separated pipeline service names, such as `acl-service,core-service`; defaults list all 14 enabled backends or three portals. `all` is also accepted. |
| `gitops-commit` | Optional full SHA of the approved GitOps source snapshot on `dev`. Empty snapshots branch HEAD at start. This is a GitOps commit, not an application source commit. |

For a controlled test, select just `acl-service` or `admin-portal`. The run
requires no workspace/PVC input. Use the existing `pipeline` service account.
`git-credentials` must read/write RedHat_HelmCharts/dev; `registry-auth` must read
the selected Quay images and signatures. Existing RHTAS identity, issuer, TUF,
client endpoints and mirrored images are reused.

CLI examples start ACL and admin-portal independently:

```bash
oc create -f customer-transfer/application-promotion/backend-pipelinerun.yaml
oc create -f customer-transfer/application-promotion/frontend-pipelinerun.yaml
oc -n devops get pipelineruns -l app.kubernetes.io/part-of=application-promotion
```

Add a `gitops-commit` parameter to either example to pin a reviewed GitOps SHA.
Starting this run is not an implementation of a business approval workflow;
approve the source snapshot through the customer's process before promoting it.

## What the run does

The OpenShift graph now contains four separate Tasks, matching the application
promotion stages in the design:

```text
read-release-manifest → get-approved-artifacts → verify-image → update-gitops
```

| Graph Task | Task resource | Behavior |
| --- | --- | --- |
| `read-release-manifest` | `<scope>-promotion-read-release-manifest` | Snapshot the approved preprod GitOps revision, validate selection/targets, and emit the selected service versions. For this first test the source is the existing backend/frontend YAML, not a separate release manifest file. |
| `get-approved-artifacts` | `<scope>-promotion-get-approved-artifacts` | Resolve the selected Quay tags to digests. |
| `verify-image` | `<scope>-promotion-verify-image` | Verify every selected digest with existing RHTAS trust and signing identity. Any failure blocks GitOps. |
| `update-gitops` | `<scope>-promotion-update-gitops` | Re-read the pinned source, reject intervening source/target changes, recheck tags, and push both target-file updates together. |

Each Task runs in its own Pod with its own `emptyDir`. Small, bounded Task results
pass selected versions and digests between Tasks; no checkout, credential HOME or
PVC is shared across Pods. The final Task makes a fresh checkout rather than
relying on another Task's local files. The verifier returns the exact digest list
it verified, and the updater checks that it matches the artifact lookup result.
This keeps failed or mismatched verification from publishing GitOps changes.

`argocd-sync` is still outside this agreed Git-only test. The split does not add
approval automation, Foundation chart promotion, CDN invalidation or uvisa
versioning integration.

There is no separate dispatcher or build run and no PVC. A same-file concurrent
change, or source change during a rejected push/retry, fails rather than
overwriting it. Unrelated changes, including a parallel promotion of the other
scope, can be rebased safely. Backend and frontend are independent runs/commits;
all four destination files are not one combined transaction.

The result `source-commit` records the GitOps source snapshot; `gitops-commit`
records the resulting branch commit. If both targets already match, no commit is
created. Signature verification establishes signing identity, not release
approval or proof of healthy preproduction deployment.

The existing application chart deploys `repository:tag`. Use immutable Quay tags:
the recheck detects movement during verification, but cannot prevent someone from
overwriting a tag after promotion. Storing digests in an approved release manifest
and adding digest-aware chart deployment are future work. The pipeline rejects
nonempty digest overrides rather than silently changing their meaning.

## Verify the Git-only result

```bash
oc -n devops get pipelineruns --sort-by=.metadata.creationTimestamp
read -r -p 'Promotion PipelineRun name: ' RUN
oc -n devops logs -l "tekton.dev/pipelineRun=$RUN" \
  --all-containers=true --tail=200 --prefix=true
oc -n devops get pipelinerun "$RUN" \
  -o jsonpath='{range .status.results[*]}{.name}={.value}{"\n"}{end}'
```

Review the resulting commit in RedHat_HelmCharts/dev. Only selected image fields
in the two scope-specific target files should change. YAML comments/formatting
can normalize; tests compare semantic values. GitOps success is not a deployment
or rollout-health check. Review actual Argo CD root/child sync settings before
connecting these files to a live deployment.

Local checks:

```bash
ruby tests/promotion/validate.rb
node tests/promotion/promotion.test.cjs
git diff --check
```

Where Node CLI is unavailable, the JavaScript tests can be executed in V8 with
mocked filesystem reads. Local checks do not perform customer Git/registry writes,
RHTAS verification, Argo CD sync, or production/DR deployment.

References: [RHTAS administration](https://docs.redhat.com/en/documentation/red_hat_trusted_artifact_signer/1/html-single/administration_guide/index),
[Argo CD automatic sync](https://argo-cd.readthedocs.io/en/stable/user-guide/auto_sync/).
