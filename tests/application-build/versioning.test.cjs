'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const {execute, bump, buildType, credential, azureStore} = require('../../pipelines/chart/files/application-versioning');
const {updateCore} = require('../../pipelines/chart/files/backend-gitops-update');
const {makeFanoutRun} = require('../../pipelines/chart/files/build-fanout-dispatch');
const yaml = require('../../pipelines/chart/files/vendor/js-yaml');
const copy = value => JSON.parse(JSON.stringify(value));
const commit = 'a'.repeat(40), gitops = 'b'.repeat(40);
const config = {scope: 'backend', sourceUrl: 'https://azure.example/team/project/_git/backend',
  imageRepository: 'quay.example/devops', catalog: [{name: 'acl-service', paths: ['services/acl/']}, {name: 'core-service', paths: ['services/core/']}],
  versioning: {enabled: true, repository: 'https://azure.example/team/project/_git/charts', revision: 'ocp',
    environment: 'preprod', directory: 'versioning', initialVersion: '1.0.0', bump: 'AUTO', createTags: true}};
const input = {sourceCommit: commit, sourceUrl: config.sourceUrl, sourceRevision: 'test',
  selected: ['acl-service'], runId: 'run-1', runName: 'backend-build-fanout-run1', imageTag: ''};
class Store {
  constructor() { this.files = {}; this.number = 0; this.commits = []; this.messages = []; this.conflicts = 0; }
  async head() { return this.number.toString(16).padStart(40, '0'); }
  async read(path) { return this.files[path] ? copy(this.files[path]) : null; }
  async sourceCommit() {}
  async sourceChanges() { return copy(this.messages); }
  async tag(name, path) { this.tags ||= {}; this.tags[name] = path; }
  async commit(head, changes, message) {
    if (this.conflicts-- > 0) { this.number++; return false; }
    if (head !== this.number.toString(16).padStart(40, '0')) return false;
    Object.assign(this.files, copy(changes)); this.number++;
    this.commits.push({changes: copy(changes), message}); return true;
  }
}
function completion(reservation, original = input) {
  const images = Object.fromEntries(original.selected.map(name => [name, {repository: config.imageRepository + '/' + name,
    tag: reservation.versions[name].version, digest: 'sha256:' + 'c'.repeat(64),
    image: config.imageRepository + '/' + name + '@sha256:' + 'c'.repeat(64)}]));
  return {...original, gitopsCommit: gitops, release: {schemaVersion: 1, succeeded: true,
    selected: original.selected, sourceCommit: original.sourceCommit, images, failed: [], notStarted: []}};
}
module.exports = (async () => {
  assert.equal(bump('1.2.3-alpha.7', 'PATCH', 'beta'), '1.2.4-beta.0');
  assert.equal(bump('1.2.3-rc.7', 'MINOR', 'rc'), '1.3.0-rc.0');
  assert.equal(bump('1.2.3-rc.7', 'MAJOR', 'rc'), '2.0.0-rc.0');
  assert.equal(buildType([{message: 'Merged PR 12: feat(api): add endpoint'}, {message: 'fix: correct validation'}]), 'MINOR');
  assert.equal(buildType([{message: 'feat!: remove endpoint'}]), 'MAJOR');
  assert.equal(buildType([{message: 'fix: x\n\nBREAKING CHANGE: changed schema'}]), 'MAJOR');
  const store = new Store(); store.conflicts = 2;
  const reserved = await execute(store, config, input, 'reserve');
  assert.equal(reserved.versions['acl-service'].version, '1.0.0-rc.1');
  assert.equal(Object.keys(store.files).filter(k => k.endsWith('/environment.yaml')).length, 3);
  assert.equal(store.files['versioning/product/preprod.yaml'].version, null);
  assert(!store.files['versioning/environments/preprod/acl-service.yaml'], 'Reservation must not claim build success');
  const writes = store.commits.length;
  assert.deepEqual(await execute(store, config, input, 'reserve'), reserved);
  assert.equal(store.commits.length, writes, 'Retry must not allocate twice');
  await assert.rejects(execute(store, config, {...input, selected: ['core-service']}, 'reserve'), /different build inputs/);
  await assert.rejects(execute(store, config, {...input, imageTag: 'manual'}, 'reserve'), /Manual image tags/);
  const pending = await execute(store, config, {...input, runId: 'run-2', runName: 'backend-build-fanout-run2'}, 'reserve');
  assert.equal(pending.versions['acl-service'].version, '1.0.0-rc.2', 'Concurrent pending reservations must not collide');
  const completed = await execute(store, config, completion(reserved), 'complete');
  assert.equal(completed.productVersion, '1.0.0-rc.1');
  assert.equal(store.tags['preprod/1.0.0-rc.1'], 'versioning/runs/preprod/backend-run-1.yaml');
  assert.equal(store.files['versioning/environments/preprod/acl-service.yaml'].imageDigest, 'sha256:' + 'c'.repeat(64));
  assert.equal(store.files['versioning/environments/preprod/acl-service.yaml'].status, 'gitops-updated');
  assert(store.files['versioning/releaseNotes/preprod/backend-run-1.md'].includes('1.0.0-rc.1'));
  const writeCount = store.commits.length;
  await execute(store, config, completion(reserved), 'complete');
  assert.equal(store.commits.length, writeCount, 'Finalization retry must be idempotent');
  await assert.rejects(execute(store, config, {...completion(pending, {...input, runId: 'run-2', runName: 'backend-build-fanout-run2'}), release: {...completion(pending).release, succeeded: false}}, 'complete'));
  assert.equal(store.files['versioning/product/preprod.yaml'].version, '1.0.0-rc.1');
  const changed = {...input, runId: 'run-3', runName: 'backend-build-fanout-run3', sourceCommit: 'd'.repeat(40)};
  store.messages = [{id: 'd'.repeat(40), message: 'feat: new capability'}];
  const feature = await execute(store, config, changed, 'reserve');
  assert.equal(feature.versions['acl-service'].version, '1.1.0-rc.0');
  const retry = await execute(store, config, {...changed, runId: 'run-4', runName: 'backend-build-fanout-run4'}, 'reserve');
  assert.equal(retry.versions['acl-service'].version, '1.1.0-rc.1', 'Failed feature attempt must not bump MINOR again');
  await execute(store, config, completion(feature, changed), 'complete');
  await assert.rejects(execute(store, config, completion(pending, {...input, runId: 'run-2', runName: 'backend-build-fanout-run2'}), 'complete'), /newer version/);
  const frontend = {...config, scope: 'frontend', catalog: [{name: 'admin-portal'}]};
  const feInput = {...input, selected: ['admin-portal'], runId: 'fe-1', runName: 'frontend-build-fanout-fe1'};
  const fe = await execute(store, frontend, feInput, 'reserve');
  assert.equal(fe.versions['admin-portal'].version, '1.0.0-rc.1');
  await execute(store, frontend, completion(fe, feInput), 'complete');
  assert(store.files['versioning/product/preprod.yaml'].components['backend/acl-service']);
  assert(store.files['versioning/product/preprod.yaml'].components['frontend/admin-portal']);
  assert.equal(store.files['versioning/environments/preprod/acl-service.yaml'].version, '1.1.0-rc.0', 'FE completion must preserve backend state');
  const concurrent = new Store();
  const [left, right] = await Promise.all([
    execute(concurrent, config, input, 'reserve'),
    execute(concurrent, config, {...input, runId: 'parallel', runName: 'backend-build-fanout-parallel'}, 'reserve')
  ]);
  assert.notEqual(left.versions['acl-service'].version, right.versions['acl-service'].version);
  const old = new Store();
  old.files['versioning/environments/preprod/acl-service.yaml'] = {schemaVersion: 1, scope: 'backend',
    service: 'acl-service', environment: 'preprod', commitId: commit, version: '4.2.0-rc.3'};
  assert.equal((await execute(old, config, input, 'reserve')).versions['acl-service'].version, '4.2.0-rc.4');
  const bad = new Store(); bad.files['versioning/state.yaml'] = {schemaVersion: 99};
  await assert.rejects(execute(bad, config, input, 'reserve'), /Incompatible/);
  const auth = credential(config.sourceUrl, 'https://fixture%40user:fixture-pat@azure.example\n');
  assert.equal(Buffer.from(auth, 'base64').toString(), 'fixture@user:fixture-pat');
  assert.throws(() => credential('https://other.example/team/_git/repo', 'https://user:pat@azure.example'), /No matching/);
  // Exercise the actual Azure REST adapter and its compare-and-swap payload.
  const requests = [];
  const https = {request(url, options, callback) {
    const events = {}, req = {setTimeout() {}, on(n, fn) { events[n] = fn; }, destroy(e) { events.error(e); },
      end(body) {
        requests.push({url: String(url), options, body: body && JSON.parse(body)});
        const responseEvents = {}, response = {statusCode: 200, on(n, fn) { responseEvents[n] = fn; }};
        callback(response);
        let result;
        if (url.pathname.endsWith('/refs') && options.method === 'POST') result = {value: [{success: true}]};
        else if (url.pathname.endsWith('/refs')) result = {value: url.searchParams.get('filter').startsWith('heads/') ? [{name: 'refs/heads/ocp', objectId: commit}] : []};
        else if (url.pathname.endsWith('/items')) { response.statusCode = 404; result = {}; }
        else if (url.pathname.endsWith('/commits') && url.searchParams.has('searchCriteria.itemPath')) result = {value: [{commitId: gitops}]};
        else if (url.pathname.endsWith('/commits')) result = {value: [{commitId: commit, comment: 'fix: ACL correction'}]};
        else if (url.pathname.endsWith('/changes')) result = {changes: [{item: {path: '/services/acl/File.cs'}}]};
        else result = {commits: [{commitId: gitops}]};
        responseEvents.data(JSON.stringify(result)); responseEvents.end();
      }};
    return req;
  }};
  const adapter = azureStore(config, fs, https, yaml, 'https://user:fixture-pat@azure.example');
  assert.equal(await adapter.head(), commit);
  assert.equal(await adapter.read('versioning/state.yaml', commit), null);
  assert(await adapter.commit(commit, {'versioning/state.yaml': {schemaVersion: 1}}, 'reserve'));
  const push = requests.find(r => r.body);
  assert.deepEqual(push.body.refUpdates, [{name: 'refs/heads/ocp', oldObjectId: commit}]);
  assert.equal(push.body.commits[0].changes[0].changeType, 'add');
  assert(!JSON.stringify(push.body).includes('fixture-pat'));
  await adapter.tag('preprod/1.0.0-rc.1', 'versioning/runs/preprod/backend-run-1.yaml');
  const tag = requests.find(r => r.options.method === 'POST' && r.url.includes('/refs?'));
  assert.deepEqual(tag.body, [{name: 'refs/tags/preprod/1.0.0-rc.1', oldObjectId: '0'.repeat(40), newObjectId: gitops}]);
  assert.equal((await adapter.sourceChanges(config.sourceUrl, commit, gitops, ['services/acl/'])).length, 1);
  assert.equal((await adapter.sourceChanges(config.sourceUrl, commit, gitops, ['services/core/'])).length, 0);
  // Validate generated selected-only graphs and tag validation with real Helm fixtures.
  const docs = JSON.parse(fs.readFileSync('/tmp/mofa-versioning-fixture.json', 'utf8'));
  for (const scope of ['backend', 'frontend']) {
    const cfg = JSON.parse(docs.find(d => d.kind === 'ConfigMap' && d.metadata.name === scope + '-dispatch-config').data['config.json']);
    const template = docs.find(d => d.kind === 'Pipeline' && d.metadata.name === cfg.fanoutPipeline);
    for (const count of [1, 2, cfg.catalog.length]) {
      const selected = cfg.catalog.slice(0, count).map(s => s.name);
      const run = makeFanoutRun(template, cfg, selected, commit, 'test',
        {metadata: {namespace: 'devops', name: 'launcher', uid: '12345678-abcd-1234-abcd-123456789abc'}});
      const tasks = run.spec.pipelineSpec.tasks;
      assert.equal(tasks.length, 4 + 5 * count);
      assert.equal(tasks.at(-1).name, 'record-versions');
      assert(tasks.some(t => t.name === 'reserve-versions'));
      for (const name of selected) {
        assert.deepEqual(tasks.find(t => t.name === 'clone-' + name).runAfter, ['reserve-versions']);
        assert(tasks.find(t => t.name === 'build-' + name).params.find(p => p.name === 'image').value.endsWith('$(tasks.reserve-versions.results.tag-' + name + ')'));
      }
      const release = tasks.find(t => t.name === 'update-gitops').params.find(p => p.name === 'release-json').value;
      assert.equal(tasks.at(-1).params.find(p => p.name === 'release-json').value, release);
      for (const service of cfg.catalog.filter(s => !selected.includes(s.name))) assert(!JSON.stringify(run.spec.pipelineSpec).includes(service.name));
    }
  }
  const document = {'argocd-applications': {applications: {'pre-acl-service': {overrideValues: {
    image: {repository: config.imageRepository + '/acl-service', tag: '1.0.0-rc.1'}}}}}};
  const updateConfig = {...config, applicationNamePrefix: 'pre-', applicationNameSuffix: ''};
  const release = completion(feature, changed).release;
  assert.equal(updateCore(document, release, updateConfig, changed.sourceCommit, '', {'acl-service': '1.1.0-rc.0'})
    ['argocd-applications'].applications['pre-acl-service'].overrideValues.image.tag, '1.1.0-rc.0');
  document['argocd-applications'].applications['pre-acl-service'].overrideValues.image.tag = '2.0.0-rc.1';
  assert.throws(() => updateCore(document, release, updateConfig, changed.sourceCommit, '', {'acl-service': '1.1.0-rc.0'}), /stale/);
  console.log('PASS: version initialization, bump rules, reservations, conflicts, retries, stale writes, partial failures, FE/BE history, REST payloads and selected-only graphs');
})();
