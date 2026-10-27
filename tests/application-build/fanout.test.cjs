'use strict';
const {execFileSync} = require('node:child_process');
const yaml = require('../../pipelines/chart/files/vendor/js-yaml.js');
const {makeFanoutRun, launchFanout} = require('../../pipelines/chart/files/build-fanout-dispatch.js');
function check(ok, message) { if (!ok) throw new Error(message); }
function reject(fn) { let failed = false; try { fn(); } catch (_) { failed = true; } check(failed, 'Expected rejection'); }
function rendered(extra = []) {
  const output = execFileSync('helm', ['template', 'release-pipeline', 'pipelines/chart', '-n', 'devops', '-f', 'customer-transfer/application-build/values.yaml', ...extra], {encoding: 'utf8'});
  const docs = []; yaml.loadAll(output, d => { if (d) docs.push(d); }); return docs;
}
const documents = rendered();
const allBackend = rendered(['--set-json', 'backendBuild.selectedServices=[]']);
const commit = '12345678' + 'a'.repeat(32);
const dispatcher = {metadata: {name: 'backend-dispatch-demo', namespace: 'devops', uid: '12345678-1234-1234-1234-123456789abc'}};
function fixture(docs, scope) {
  const config = JSON.parse(docs.find(d => d.kind === 'ConfigMap' && d.metadata.name === scope + '-dispatch-config').data['config.json']);
  return {config, template: docs.find(d => d.kind === 'Pipeline' && d.metadata.name === config.fanoutPipeline)};
}
function verify(docs, scope, count) {
  const {config, template} = fixture(docs, scope);
  const before = JSON.stringify(template);
  const selected = config.catalog.slice(0, count).map(s => s.name);
  const run = makeFanoutRun(template, config, selected, commit, scope === 'backend' ? 'test' : 'pre-prod', dispatcher);
  check(JSON.stringify(template) === before, 'Must not modify installed template');
  check(run.spec.pipelineSpec && !run.spec.pipelineRef, 'One embedded graph must be fixed before run creation');
  check(!run.metadata.ownerReferences, 'Pruning the launcher must not delete an active build');
  const spec = run.spec.pipelineSpec;
  const tasks = spec.tasks;
  check(tasks.length === 2 + count * 6, 'Only selected lanes plus selection and GitOps');
  check(tasks[0].name === 'dispatch-service-selection' && tasks.at(-1).name === 'update-gitops', 'Selection to GitOps graph');
  check(tasks.every(t => !t.when), 'No skipped/unselected lanes');
  const definitions = new Map(docs.filter(d => d.kind === 'Task').map(d => [d.metadata.name, d.spec]));
  const names = new Set(tasks.map(t => t.name));
  tasks.forEach(task => {
    check((task.runAfter || []).every(name => names.has(name)), 'Dependency on an omitted lane');
    const definition = definitions.get(task.taskRef.name);
    check(definition, 'Missing shared Task');
    const supplied = new Set((task.params || []).map(p => p.name));
    check([...supplied].every(name => (definition.params || []).some(p => p.name === name)), 'Unknown Task parameter');
    (definition.params || []).filter(p => !Object.hasOwn(p, 'default')).forEach(p => check(supplied.has(p.name), 'Missing Task argument'));
    (task.workspaces || []).forEach(w => check(spec.workspaces.some(p => p.name === w.workspace), 'Missing workspace'));
  });
  for (const [, producer, result] of JSON.stringify(spec).matchAll(/\$\(tasks\.([^.]+)\.results\.([^)]+)\)/g)) {
    const task = tasks.find(t => t.name === producer);
    check(task && definitions.get(task.taskRef.name).results.some(r => r.name === result), 'Result references an omitted task');
  }
  const claims = run.spec.workspaces.filter(w => w.volumeClaimTemplate);
  check(claims.length === count && claims.every(w => w.volumeClaimTemplate.spec.resources.requests.storage === '3Gi'), 'Only selected source PVCs');
  check(JSON.stringify([...spec.workspaces.map(w => w.name)].sort()) === JSON.stringify(run.spec.workspaces.map(w => w.name).sort()), 'Bindings must exactly match selected graph');
  const update = tasks.at(-1);
  check(JSON.stringify(update.runAfter) === JSON.stringify(selected.map(s => 'sign-' + s)), 'GitOps must wait for every selected sign');
  const record = JSON.parse(update.params.find(p => p.name === 'release-json').value);
  check(JSON.stringify(record.selected) === JSON.stringify(selected) && Object.keys(record.images).length === count, 'GitOps must update only selected entries');
  for (const service of config.catalog.filter(s => !selected.includes(s.name))) {
    check(!JSON.stringify(spec).includes(service.name), 'Unselected service appears in the graph');
  }
  check(run.spec.workspaces.some(w => w.name === 'npm-auth') === (scope === 'frontend'), 'Frontend-only npm credentials');
  return {run, config, template, selected};
}
for (const count of [1, 2, 14]) verify(documents, 'backend', count);
for (const count of [1, 2, 3]) verify(documents, 'frontend', count);
verify(allBackend, 'backend', 17);
const {run, config, template, selected} = verify(documents, 'backend', 2);
reject(() => makeFanoutRun(template, config, ['not-a-service'], commit, 'test', dispatcher));
reject(() => makeFanoutRun(template, config, [selected[0], selected[0]], commit, 'test', dispatcher));
reject(() => makeFanoutRun(template, config, selected, 'bad', 'test', dispatcher));
reject(() => makeFanoutRun(template, config, selected, commit, 'test\n', dispatcher));
const missing = JSON.parse(JSON.stringify(template)); missing.spec.tasks = missing.spec.tasks.filter(t => t.name !== 'gate-' + selected[0]);
reject(() => makeFanoutRun(missing, config, selected, commit, 'test', dispatcher));
module.exports = (async () => {
  let creates = 0;
  const api = async (method, path, body) => {
    if (method === 'GET') { check(path.endsWith('/pipelines/' + config.fanoutPipeline), 'Read only the installed fanout'); return template; }
    check(method === 'POST' && path.endsWith('/pipelineruns'), 'Expected exactly one build run create'); creates++; return body;
  };
  const created = await launchFanout(api, config, selected, commit, 'test', dispatcher);
  check(creates === 1 && created.spec.pipelineSpec.tasks.length === 14, 'Two services must create one run with two complete lanes');
  check(await launchFanout(() => { throw Error('No API needed'); }, config, [], commit, 'test', dispatcher) === null, 'Empty PR diff is a no-op');
  const conflictApi = async (method, path) => {
    if (path.endsWith('/pipelines/' + config.fanoutPipeline)) return template;
    if (method === 'POST') { const e = Error('exists'); e.status = 409; throw e; }
    return run;
  };
  check((await launchFanout(conflictApi, config, selected, commit, 'test', dispatcher)).metadata.name === run.metadata.name, 'Retry must reuse the same run');
  let rejected = false;
  const different = JSON.parse(JSON.stringify(run)); different.metadata.annotations['customer.mofa.gov.sa/services'] = '[]';
  try { await launchFanout(async (method, path) => path.includes('/pipelines/') ? template : method === 'POST' ? conflictApi(method, path) : different, config, selected, commit, 'test', dispatcher); }
  catch (_) { rejected = true; }
  check(rejected, 'Conflicting retry must not reuse a different run');
  console.log('Passed selected-only 1/2/14/17-backend and 1/2/3-frontend graphs, working Task references, PVCs, GitOps wiring, one-run launch, retry and no-op checks');
})();
