# Manual Three-Frontend Release Test

This test uses bare eight-character Git commit tags (for example `a1b2c3d4`),
checks out the full commit, and deploys the signed/verified image digests.
All three builds use `BUILD_ENVIRONMENT=dev`, even though the source branch is
`pre-prod`. No webhook, Azure service hook, listener, or versioning repository
is required for this test. Existing webhook configuration is left untouched.

## What Runs

`application-frontend-release-test` resolves one source commit, then runs three
parallel lanes: clone -> test -> build/push -> sign -> verify, matching the
previous working frontend fanout. ACS scan/gate are disabled because ACS is not
ready; this run does not constitute vulnerability or policy validation.
After all three verify successfully, one Task commits
`tekton-frontend-test/releases/frontend.json` to `RedHat_argocd`, branch `dev`.
This JSON document records the full source SHA, eight-character tag, PipelineRun,
and each image repository/digest. The new app-of-apps chart consumes it.

Unit-test failures temporarily remain non-blocking, as requested for frontend
testing. Build, signing, verification, and GitOps failures are blocking.
Set `frontendRelease.allowTestFailure=false` to enforce tests. When ACS is ready,
set `frontendRelease.scanEnabled=true` to add blocking scan/gate stages. RHACS needs
registry integration to pull the private images; its credentials are separate
from the pipeline registry Secret.

Chart `frontend-app:0.1.0` is published separately, once before the first run.
It is reused across image builds. Bump Chart.yaml/version and GitOps
chart.version together for chart changes; do not overwrite published versions.
Configure Quay tag immutability for release charts where available. Image tags
can be overwritten on a same-commit rebuild, but deployments use the exact
verified digest, not the mutable tag.

## 1. Preconditions

Run commands from the customer `appdev` checkout. Tools: `oc`, Helm with OCI
support (Helm 3.8+ or a tested Helm 4), Git, Bash. No yq or Python is required.
Verify installed GitOps/Pipelines versions before applying APIs; local rendering
does not validate the customer's Operator versions or RBAC.

```bash
oc whoami --show-server
oc get clusterversion version
oc get csv -A
oc -n devops get secret git-credentials registry-auth npm-auth pipeline-proxy
oc get argocd -A
```

The existing `git-credentials` Secret must provide the `.git-credentials` format
used by the tested HTTPS clone workflow: read access to the frontend source and
write access to RedHat_argocd/dev. Do not embed tokens in URLs or these files.
The pipeline service account remains `pipeline` in `devops`.

The GitOps directory from step 3 must exist before running the full release.
Installing only the Pipeline does not seed that directory: build/sign/verify
can run, but the final GitOps update fails when its release JSON is missing.
Do not seed GitOps during a running release; the concurrent-change guard will
reject a branch changed after that run started. Prepare GitOps, then start a
new PipelineRun. Chart publication and Argo setup are also needed to deploy.

The new workloads use namespace `frontend-tekton-test`, unique names and routes,
and port 8080. Confirm the built nginx image runs under restricted OpenShift SCC
and listens on 8080. If the customer's Dockerfile listens on another port, set
`containerPort` in the GitOps chart values to that port. Do not grant anyuid to
work around a runtime-image mismatch. Public image alternatives are not claimed
as FIPS-validated substitutes.

## 2. Publish the New Application Chart to Quay

Source: `apps/frontend/helm`. To keep it in the customer's chart repo, copy it
to a NEW directory such as `frontend-app/0.1.0` on `RedHat_HelmCharts/ocp`, review,
and commit it there. Do not replace their existing app-chart. No local reference
repository under wel is modified by this procedure.

Publish from appdev, supplying your existing registry auth-file path:

```bash
bash customer-transfer/frontend-release-test/publish-chart.sh /secure/path/pullsecret.txt-quay
helm show chart oci://quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/frontend-app \
  --version 0.1.0 --registry-config /secure/path/pullsecret.txt-quay
```

The helper also accepts a second argument pointing to the committed customer
chart directory. The Quay identity needs push access to `devops/frontend-app`;
pre-create that repository if automatic creation is disallowed. The auth file
must contain direct credentials Helm can use, not unavailable credential helpers.

## 3. Seed the Separate GitOps Directory Once

From appdev, point `GITOPS_CHECKOUT` to the customer's local RedHat_argocd clone.
Check out `dev` before this copy, with a clean worktree. The guard prevents
overwriting an existing release record. Adjust the local path as necessary.

```bash
GITOPS_CHECKOUT=../RedHat_argocd
git -C "$GITOPS_CHECKOUT" status --short --branch
git -C "$GITOPS_CHECKOUT" branch --show-current
test "$(git -C "$GITOPS_CHECKOUT" branch --show-current)" = dev
test -z "$(git -C "$GITOPS_CHECKOUT" status --porcelain)"
test ! -e "$GITOPS_CHECKOUT/tekton-frontend-test" && \
  cp -R customer-transfer/frontend-release-test/gitops/tekton-frontend-test "$GITOPS_CHECKOUT/"
git -C "$GITOPS_CHECKOUT" add tekton-frontend-test
git -C "$GITOPS_CHECKOUT" diff --cached --stat
git -C "$GITOPS_CHECKOUT" commit -m 'Add isolated Tekton frontend test applications'
git -C "$GITOPS_CHECKOUT" push origin dev
```

Review `tekton-frontend-test/values.yaml`: OCI chart repository/version, workload
namespace, port, pull-secret name, and routes. Its release JSON starts empty,
so no child Applications are created until a verified release is committed.
Do not copy the empty JSON over a successful release when updating templates.

## 4. Prepare Argo CD and the Destination Namespace

The reference installation uses Argo CD namespace `development`. Verify it in
step 1. If different, edit BOTH occurrences of `namespace: development` in
`argocd-bootstrap.yaml`, and use that namespace for `oc apply` below.

Argo CD needs read access to RedHat_argocd and an OCI Helm repository connection
to `quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops` (type Helm, OCI enabled,
without the oci:// prefix). Configure those using the existing Argo CD credential
process/UI, including the trusted CA. Pipeline Git/registry Secrets do not
automatically grant repository access to Argo CD.

```bash
oc create namespace frontend-tekton-test --dry-run=client -o yaml | oc apply -f -
oc -n frontend-tekton-test create secret generic registry-auth \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=/secure/path/pullsecret.txt-quay \
  --dry-run=client -o yaml | oc apply -f -
oc -n development apply -f customer-transfer/frontend-release-test/argocd-bootstrap.yaml
```

Use a pull-only auth file for the workload Secret. The Argo CD controller also
needs permission to manage the destination namespace through the installation's
approved namespace-management configuration. AppProject permissions alone do
not grant Kubernetes RBAC. The new project allows only Application, Deployment,
Service, and Route resources; the namespace and pull Secret are provisioned above.

The new root and children auto-sync, with pruning disabled for the test. This
does not alter the old dev-root-applications root or its existing Applications.

## 5. Install the Pipeline Changes

```bash
helm lint pipelines/chart \
  -f customer-transfer/devops-apply/values-devops.yaml \
  -f customer-transfer/frontend-release-test/values-release.yaml
helm upgrade --install release-pipeline ./pipelines/chart -n devops \
  -f customer-transfer/devops-apply/values-devops.yaml \
  -f customer-transfer/frontend-release-test/values-release.yaml
oc -n devops get pipeline application-frontend-release-test
oc -n devops get task frontend-release-resolve frontend-release-update
```

Do not change source branch to switch the build argument: it is deliberately
fixed to dev in this test Pipeline. The new release feature defaults off unless
the overlay is used. Keep this overlay on subsequent release-pipeline upgrades
to retain its resources. Existing validation/backend Pipelines are unchanged.

## 6. Run All Three Services

```bash
oc create -f customer-transfer/frontend-release-test/pipelinerun.yaml
oc -n devops get pipelineruns -w
```

Use the created PipelineRun name for details/results:

```bash
oc -n devops describe pipelinerun <created-run-name>
oc -n devops get taskruns -l tekton.dev/pipelineRun=<created-run-name>
```

Each run provisions three independent 5Gi PVCs. The GitOps Task uses an emptyDir
and small Task results, not those three PVCs. Quotas/storage must allow 15Gi per
run; follow the approved PipelineRun/PVC retention process after testing.

Only one release should be tested at a time. The resolver snapshots the GitOps
branch HEAD before builds. If it changes, the final Task fails without pushing;
inspect the newer release before rerunning. Pushes are never forced or rebased.
An eight-character collision with the current release is rejected, but eight
characters are not globally unique. Full SHA and immutable digests remain the
authoritative identities. No SemVer counter or old versioning-repo migration is
part of this selected SHA-based test.

## 7. Verify Deployment

```bash
oc -n development get applications
oc -n development get application frontend-release-test-root -o yaml
oc -n frontend-tekton-test get deployments,pods,routes
oc -n frontend-tekton-test rollout status deployment/admin-portal-tekton-test --timeout=180s
oc -n frontend-tekton-test rollout status deployment/applicant-portal-tekton-test --timeout=180s
oc -n frontend-tekton-test rollout status deployment/operational-portal-tekton-test --timeout=180s
oc -n frontend-tekton-test get deployments -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.spec.template.spec.containers[0].image}{"\n"}{end}'
```

Confirm each image uses @sha256 and matches the corresponding build result and
GitOps JSON. Check child Applications are Synced/Healthy, then test the routes:
`https://<service>-tekton-test.apps.hub-visa-ocp.mofa.gov.sa`.
The frontend still contains dev build-time configuration; this is not pre-prod
functional certification. The pipeline reports the GitOps commit, not Argo CD
rollout completion. Root polling may take a few minutes.

For rollback, revert only the release JSON to the prior successful release in
RedHat_argocd/dev, review the three digests, and commit/push. Argo CD restores
that image set. Do not revert unrelated customer GitOps changes or delete shared
resources. A first failed deployment has no previous successful release to restore.

## Scope and Documentation

Local validation on 2026-10-22 passed Helm lint, rendered Pipeline/Task parameter,
result and workspace checks, three-service GitOps/application-chart rendering,
shell syntax, and 14 release-data checks. The JavaScript checks ran in V8 with
the CommonJS module loader stubbed, not in the customer Node.js container; Node
filesystem operations and Git push concurrency still need runtime testing.
Repeat the local checks with:

```bash
ruby tests/frontend-release/validate.rb
node tests/frontend-release/update.test.cjs
bash -n customer-transfer/frontend-release-test/publish-chart.sh
git diff --check
```

No changes are made to the reference repositories or customer cluster by merely
preparing these files. Real registry pushes, permissions, Git writes, image
startup, and Argo CD reconciliation must be tested in the customer environment.
No API/backend environment configuration is invented here.

References: [Helm OCI registries](https://helm.sh/docs/topics/registries/),
[Tekton results](https://tekton.dev/docs/pipelines/pipelines/#using-results),
[Argo CD Helm](https://argo-cd.readthedocs.io/en/stable/user-guide/helm/),
[Argo CD private registries](https://argo-cd.readthedocs.io/en/stable/user-guide/private-repositories/).
The attempted Red Hat Pipelines documentation page was unavailable during local
preparation; installed-version compatibility still requires customer validation.
