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
async function scenario({fail = false, cancel = false, selected = names, existing = false} = {}) {
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
    if (!run.status) children.set(name, completed(run, fail && run.spec.params[0].value === names[0]));
    return children.get(name);
  };
  const result = await dispatch({api, sleep: async () => {}, now: () => 0, parent, config, selected, commit, revision: 'test'});
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
  let cancelled = false;
  try { await scenario({cancel: true}); } catch (e) { cancelled = /cancelled/.test(e.message); }
  check(cancelled, 'Cancel parent');
  console.log('Passed selection, input safety, child construction, digest, concurrency, failure, retry and cancellation checks');
})();
