'use strict';
const {selectServices, selectDiff, serviceSettings, makeChild, releaseImage, dispatch} = require('../../pipelines/chart/files/backend-dispatch.js');
function check(ok, message) { if (!ok) throw new Error(message); }
function rejects(fn) { let rejected = false; try { fn(); } catch (_) { rejected = true; } check(rejected, 'Expected rejection'); }
const commit = 'a'.repeat(40);
const digest = 'sha256:' + 'b'.repeat(64);
const catalog = ['acl', 'core', 'identity', 'event'].map(name => ({name: name + '-service', containerfile: 'services/' + name + '/Api/Dockerfile', project: name + '.csproj', context: '.'}));
const config = {catalog, imageRepository: 'quay.example/devops', workspaceSize: '3Gi', buildServiceAccount: 'pipeline', childTimeout: '2h0m0s', timeoutSeconds: 120, maxParallel: 2};
const parent = {metadata: {name: 'batch-test', namespace: 'devops', uid: '12345678-1234-1234-1234-123456789abc'}, spec: {}};
const names = catalog.map(s => s.name);
check(serviceSettings(names[0], commit, 'test', config).commit === commit, 'Settings must emit the full SHA for the Pipeline result');
check(JSON.stringify(selectServices(' acl-service,core-service,acl-service ', catalog)) === JSON.stringify(names.slice(0, 2)), 'Trim/dedup');
check(selectServices('all', catalog).length === 4, 'all');
['', 'acl-service,', 'payment-service', 'all,acl-service'].forEach(input => rejects(() => selectServices(input, catalog)));
check(selectDiff(['services/acl/Api/controller.cs'], catalog).join() === 'acl-service', 'Narrow diff');
check(selectDiff([], catalog).length === 0, 'No changes');
for (const path of ['shared/a.cs', 'services/acl/Domain/a.cs', 'services/acl/Api/a.csproj', 'README.md']) check(selectDiff([path], catalog).length === 4, 'Conservative diff ' + path);
check(selectDiff([], catalog, true).length === 4, 'History fallback');
for (const value of ['bad', commit + '\n', '$(touch /tmp/x)']) rejects(() => serviceSettings(names[0], value, 'test', config));
rejects(() => serviceSettings(names[0], commit, 'test\n', config));
const child = makeChild(parent, names[0], commit, 'test', config);
const frontendCatalog = require('../../pipelines/chart/files/frontend-services.json');
const frontendConfig = {...config, scope: 'frontend', childPipeline: 'application-frontend-service-build', npmAuth: true, catalog: frontendCatalog};
const frontendNames = frontendCatalog.map(s => s.name);
check(selectServices('admin-portal, applicant-portal', frontendCatalog).join() === frontendNames.slice(0, 2).join(), 'Frontend CSV selection');
rejects(() => selectServices('acl-service', frontendCatalog));
check(selectDiff(['apps/admin-portal/src/app/app.ts'], frontendCatalog).join() === 'admin-portal', 'Frontend app diff');
check(selectDiff(['deployment/applicant-portal/Dockerfile'], frontendCatalog).join() === 'applicant-portal', 'Frontend Dockerfile diff');
check(selectDiff(['libs/shared/auth.ts'], frontendCatalog).length === 3, 'Shared frontend change must build all');
const frontendChild = makeChild(parent, frontendNames[0], commit, 'pre-prod', frontendConfig);
check(frontendChild.spec.pipelineRef.name === 'application-frontend-service-build', 'Frontend child scope');
check(frontendChild.metadata.name.startsWith('frontend-'), 'Frontend child name');
check(frontendChild.spec.workspaces.some(w => w.name === 'npm-auth'), 'Frontend npm credentials');
check(!child.spec.workspaces.some(w => w.name === 'npm-auth'), 'Backend must not require npm credentials');
check(frontendChild.spec.workspaces[0].volumeClaimTemplate.metadata.labels.pipeline === 'frontend-dispatch', 'Frontend PVC scope');
check(child.spec.workspaces[0].volumeClaimTemplate.spec.resources.requests.storage === '3Gi', 'PVC size');
check(child.spec.workspaces[0].volumeClaimTemplate.metadata.labels.pipeline === 'backend-dispatch', 'PVC cleanup label');
check(child.metadata.ownerReferences[0].uid === parent.metadata.uid, 'Ownership');
function completed(run, failed = false) {
  const service = run.spec.params[0].value;
  return {...run, status: {conditions: [{type: 'Succeeded', status: failed ? 'False' : 'True'}], results: [
    {name: 'source-commit', value: commit}, {name: 'image-digest', value: digest},
    {name: 'image-url', value: config.imageRepository + '/' + service + ':aaaaaaaa@' + digest}
  ]}};
}
check(releaseImage(completed(child), names[0], commit, config).image.endsWith('@' + digest), 'Digest record');
rejects(() => releaseImage(completed(child, true), names[0], commit, config));
async function scenario({fail = false, cancel = false, selected = names, existing = false, settings = config} = {}) {
  const children = new Map(); let record; let peak = 0; let created = 0; let cancelled = 0;
  if (existing) children.set(child.metadata.name, completed(child));
  const api = async (method, path, body) => {
    const name = path.split('/').pop();
    if (method === 'GET' && name === parent.metadata.name) return cancel ? {...parent, spec: {status: 'Cancelled'}} : parent;
    if (method === 'POST' && path.endsWith('/configmaps')) { record = body; return body; }
    if (method === 'POST') {
      children.set(body.metadata.name, body); created++;
      peak = Math.max(peak, [...children.values()].filter(c => !c.status).length);
      return body;
    }
    if (method === 'PATCH') { cancelled++; return {}; }
    if (!children.has(name)) { const error = new Error('not found'); error.status = 404; throw error; }
    const run = children.get(name);
    if (!run.status) children.set(name, completed(run, fail && run.spec.params[0].value === selected[0]));
    return children.get(name);
  };
  const result = await dispatch({api, sleep: async () => {}, now: () => 0, parent, config: settings, selected, commit, revision: 'test'});
  check(peak <= 2, 'Concurrency bound');
  check(record.immutable, 'Immutable record');
  return {result, created, cancelled};
}
module.exports = (async () => {
  const success = await scenario();
  check(success.created === 4 && success.result.record.succeeded && Object.keys(success.result.record.images).length === 4, 'Success batch');
  const failure = await scenario({fail: true});
  check(failure.created === 2 && !failure.result.record.succeeded && failure.result.record.notStarted.length === 2, 'Failure stops queue');
  check((await scenario({existing: true})).created === 3, 'Reuse existing child');
  check((await scenario({selected: []})).created === 0, 'No-op selection');
  for (const count of [1, 2, 3]) {
    const front = await scenario({settings: frontendConfig, selected: frontendNames.slice(0, count)});
    check(front.created === count && front.result.record.succeeded, 'Only selected frontend children are created');
    check(Object.keys(front.result.record.images).length === count && front.result.name.startsWith('frontend-result-'), 'Frontend scoped release record');
  }
  const frontFailure = await scenario({settings: frontendConfig, selected: frontendNames, fail: true});
  check(!frontFailure.result.record.succeeded && frontFailure.created === 2, 'Frontend failure blocks queue/release');
  let cancelled = false;
  try { await scenario({cancel: true}); } catch (e) { cancelled = /cancelled/.test(e.message); }
  check(cancelled, 'Cancel parent');
  console.log('Passed selection, input safety, child construction, digest, concurrency, failure, retry and cancellation checks');
})();
