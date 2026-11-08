'use strict';
const {execFileSync} = require('node:child_process');
const yaml = require('../../pipelines/chart/files/vendor/js-yaml.js');
const {makeFanoutRun, launchFanout} = require('../../pipelines/chart/files/build-fanout-dispatch.js');
const {selectDiff} = require('../../pipelines/chart/files/backend-dispatch.js');
function check(ok, message) { if (!ok) throw new Error(message); }
function reject(fn) { let failed = false; try { fn(); } catch (_) { failed = true; } check(failed, 'Expected rejection'); }
function rendered(extra = []) {
  const output = execFileSync('helm', ['template', 'release-pipeline', 'pipelines/chart', '-n', 'devops', '-f', 'customer-transfer/application-build/values.yaml', ...extra], {encoding: 'utf8'});
  const docs = []; yaml.loadAll(output, d => { if (d) docs.push(d); }); return docs;
}
const documents = rendered();
const allBackend = rendered(['--set-json', 'backendBuild.selectedServices=[]']);
const frontendTestsEnabled = rendered(['--set', 'frontendRelease.testsEnabled=true']);
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
  const values = Object.fromEntries(run.spec.params.map(p => [p.name, p.value]));
  const defaults = Object.fromEntries(spec.params.map(p => [p.name, p.default]));
  check(values.services === selected.join(',') && values['source-url'] === config.sourceUrl && values.env === 'dev' && values['image-tag'] === '', 'Generated PipelineRun inputs');
  check(JSON.stringify(defaults) === JSON.stringify(values), 'Prepared PipelineRun must contain matching editable defaults');
  const tasks = spec.tasks;
  const testsEnabled = scope !== 'frontend' || config.testsEnabled !== false;
  check(tasks.length === 2 + count * (testsEnabled ? 6 : 5), 'Only selected lanes plus selection and GitOps');
  check(tasks[0].name === 'dispatch-service-selection' && tasks.at(-1).name === 'update-gitops', 'Selection to GitOps graph');
  check(tasks[0].params.find(p => p.name === 'expected-services').value === selected.join(','), 'Must reject selection edits after graph preparation');
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
  check(update.params.find(p => p.name === 'image-tag').value === '$(params.image-tag)', 'GitOps must validate the same manual tag used for builds');
  check(tasks[0].params.find(p => p.name === 'image-tag').value === '$(params.image-tag)', 'Resolver must receive manual tag');
  check(JSON.stringify(update.runAfter) === JSON.stringify(selected.map(s => 'sign-' + s)), 'GitOps must wait for every selected sign');
  const record = JSON.parse(update.params.find(p => p.name === 'release-json').value);
  check(JSON.stringify(record.selected) === JSON.stringify(selected) && Object.keys(record.images).length === count, 'GitOps must update only selected entries');
  for (const service of config.catalog.filter(s => !selected.includes(s.name))) {
    check(!JSON.stringify(spec).includes(service.name), 'Unselected service appears in the graph');
  }
  check(run.spec.workspaces.some(w => w.name === 'npm-auth') === (scope === 'frontend'), 'Frontend-only npm credentials');
  for (const service of selected) {
    const unit = tasks.find(t => t.name === 'test-' + service);
    const build = tasks.find(t => t.name === 'build-' + service);
    check(Boolean(unit) === testsEnabled, 'Test presence must follow the scope configuration');
    check(build.runAfter.join() === (testsEnabled ? 'test-' : 'clone-') + service, 'Build must follow the active preceding stage');
    check(tasks.find(t => t.name === 'clone-' + service).params.find(p => p.name === 'url').value === '$(params.source-url)', 'Editable source-url must reach every clone');
    check(tasks.find(t => t.name === 'build-' + service).params.find(p => p.name === 'build-args').value.join() === (scope === 'backend' ? 'CERT_KEYWORD=$(params.env)' : 'BUILD_ENVIRONMENT=$(params.env)'), 'env must reach every build argument');
  }
  return {run, config, template, selected};
}
for (const count of [1, 2, 14]) verify(documents, 'backend', count);
for (const count of [1, 2, 3]) verify(documents, 'frontend', count);
for (const count of [1, 2, 3]) verify(frontendTestsEnabled, 'frontend', count);
verify(allBackend, 'backend', 17);
const {run, config, template, selected} = verify(documents, 'backend', 2);
const backendCatalog = fixture(documents, 'backend').config.catalog;
check(selectDiff(['services/acl/MOFA.UnifiedVisaPlatform.ACL/Controller.cs'], backendCatalog).join() === 'acl-service', 'ACL executable changes select ACL only');
check(selectDiff(['services/acl/MOFA.UnifiedVisaPlatform.ACL.Domain/Entity.cs'], backendCatalog).join() === 'acl-service', 'ACL sibling project changes select ACL only');
check(selectDiff(['services/core/Domain/Entity.cs'], backendCatalog).join() === 'core-service', 'Core service changes select Core only');
check(selectDiff(['services/acl/Controller.cs', 'services/core/Entity.cs'], backendCatalog).join() === 'acl-service,core-service', 'Two changed services select two lanes');
for (const path of ['shared/Common.cs', 'certificates/ca.crt', 'Directory.Build.props', 'NuGet.Config']) {
  check(selectDiff([path], backendCatalog).length === 14, 'Shared/build changes retain conservative fallback: ' + path);
}
reject(() => makeFanoutRun(template, config, ['not-a-service'], commit, 'test', dispatcher));
reject(() => makeFanoutRun(template, config, [selected[0], selected[0]], commit, 'test', dispatcher));
reject(() => makeFanoutRun(template, config, selected, 'bad', 'test', dispatcher));
reject(() => makeFanoutRun(template, config, selected, commit, 'test\n', dispatcher));
for (const sourceUrl of ['http://git.example/backend', 'https://user:password@git.example/backend', 'https://git.example/a"$(id)']) {
  reject(() => makeFanoutRun(template, config, selected, commit, 'test', dispatcher, {sourceUrl}));
}
reject(() => makeFanoutRun(template, config, selected, commit, 'test', dispatcher, {env: 'dev$(id)'}));
const override = makeFanoutRun(template, config, selected, commit, 'feature/build', dispatcher, {sourceUrl: 'https://git.example/team/backend', env: 'pre-prod'});
check(override.spec.params.find(p => p.name === 'source-url').value === 'https://git.example/team/backend', 'Editable source-url override');
check(override.spec.params.find(p => p.name === 'env').value === 'pre-prod' && override.spec.pipelineSpec.params.find(p => p.name === 'env').default === 'pre-prod', 'Editable env override/default');
const missing = JSON.parse(JSON.stringify(template)); missing.spec.tasks = missing.spec.tasks.filter(t => t.name !== 'gate-' + selected[0]);
reject(() => makeFanoutRun(missing, config, selected, commit, 'test', dispatcher));
for (const scope of ['backend', 'frontend']) {
  const {template, config} = fixture(documents, scope);
  const selected = config.catalog.slice(0, 2).map(s => s.name);
  const manual = makeFanoutRun(template, config, selected, commit, 'test', dispatcher, {imageTag: 'pre-test-20261028-01'});
  check(manual.spec.params.find(p => p.name === 'image-tag').value === 'pre-test-20261028-01', 'Manual tag must survive dispatch for ' + scope);
  for (const imageTag of ['-bad', '.bad', 'bad/tag', 'bad tag', 'valid\n', 'a'.repeat(129), '$(id)', 42]) {
    reject(() => makeFanoutRun(template, config, selected, commit, 'test', dispatcher, {imageTag}));
  }
}
async function renderedLaunch(scope, mode, services, paths, expected) {
  const {config, template} = fixture(documents, scope);
  const task = documents.find(d => d.kind === 'Task' && d.metadata.name === scope + '-build-dispatch');
  const values = Object.fromEntries(task.spec.params.map(p => [p.name, p.default]));
  Object.assign(values, {services, 'selection-mode': mode, 'source-commit': commit});
  // Tekton substitutes Task parameters before executing a Step. Code mounted
  // from a ConfigMap must not be substituted as though it were a Step script.
  const step = JSON.parse(JSON.stringify(task.spec.steps.at(-1)).replace(/\$\(params\.([^)]+)\)/g, (whole, name) => Object.hasOwn(values, name) ? values[name] : whole));
  check(step.command?.join() === 'node' && step.args?.join() === '/config/build-fanout-dispatch.js' && !step.script, 'Factory must execute from mounted code');
  const code = documents.find(d => d.kind === 'ConfigMap' && d.metadata.name === scope + '-dispatch-config').data['build-fanout-dispatch.js'];
  check(typeof code === 'string', 'Missing mounted factory');
  let created, failure;
  const writes = {};
  const api = async (method, path, body) => {
    if (method === 'GET') return template;
    check(method === 'POST' && path.endsWith('/pipelineruns'), 'Unexpected API request');
    created = body; return body;
  };
  const fs = {existsSync: () => false, readFileSync: path => {
    if (path === '/config/config.json') return JSON.stringify(config);
    if (path === '/work/commit') return commit;
    if (path === '/work/changed') return paths.join('\0') + '\0';
    throw Error('Unexpected file read: ' + path);
  }, writeFileSync: (path, data) => { writes[path] = data; }};
  const proc = {env: {...Object.fromEntries(step.env.map(e => [e.name, e.value])), MODE: mode,
    NAMESPACE: dispatcher.metadata.namespace, DISPATCHER_NAME: dispatcher.metadata.name, DISPATCHER_UID: dispatcher.metadata.uid}};
  const mod = {exports: {}};
  const req = name => {
    if (name === 'node:fs') return fs;
    if (name === 'node:https') return {};
    if (name === '/config/backend-dispatch.js') return {...require('../../pipelines/chart/files/backend-dispatch.js'), kubeClient: () => api};
    throw Error('Unexpected module: ' + name);
  };
  req.main = mod;
  new Function('module', 'require', 'process', 'console', code)(mod, req, proc, {log() {}, error(message) { failure = message; }});
  for (let tick = 0; tick < 16; tick++) await Promise.resolve();
  check(!proc.exitCode && !failure, failure || 'Rendered launch failed');
  check(created && writes['/tekton/results/services'] === JSON.stringify(expected), 'Diff/CSV selection was not used');
  const params = Object.fromEntries(created.spec.params.map(p => [p.name, p.value]));
  const source = created.spec.pipelineSpec.tasks[0];
  const resolve = value => value.replace(/\$\(params\.([^)]+)\)/g, (whole, name) => params[name]);
  const received = resolve(source.params.find(p => p.name === 'services').value);
  const prepared = source.params.find(p => p.name === 'expected-services').value;
  check(received === expected.join(',') && received === prepared, 'Service selection guard would fail after nested substitution');
  const stageCount = scope === 'frontend' && config.testsEnabled === false ? 5 : 6;
  check(params.services === expected.join(',') && created.spec.pipelineSpec.tasks.length === 2 + expected.length * stageCount, 'Generated graph includes unselected lanes');
}
module.exports = (async () => {
  await renderedLaunch('backend', 'diff', '', ['services/acl/MOFA.UnifiedVisaPlatform.ACL/Controller.cs'], ['acl-service']);
  await renderedLaunch('backend', 'diff', '', ['services/acl/Domain.cs', 'services/core/Domain.cs'], ['acl-service', 'core-service']);
  await renderedLaunch('backend', 'diff', '', ['shared/Common.cs'], backendCatalog.map(s => s.name));
  await renderedLaunch('backend', 'manual', ' acl-service,core-service,acl-service ', [], ['acl-service', 'core-service']);
  await renderedLaunch('frontend', 'diff', '', ['apps/admin-portal/src/app/app.ts'], ['admin-portal']);
  await renderedLaunch('frontend', 'manual', 'admin-portal, applicant-portal', [], ['admin-portal', 'applicant-portal']);
  console.log('Passed rendered dispatcher execution after Task substitution: PR diff, manual CSV and matching selected-service guard');
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
  const envChanged = JSON.parse(JSON.stringify(run)); envChanged.spec.params.find(p => p.name === 'env').value = 'pre-prod';
  rejected = false;
  try { await launchFanout(async (method, path) => path.includes('/pipelines/') ? template : method === 'POST' ? conflictApi(method, path) : envChanged, config, selected, commit, 'test', dispatcher); }
  catch (_) { rejected = true; }
  check(rejected, 'Retry must reject an existing run with changed env');
  rejected = false;
  try { await launchFanout(conflictApi, config, selected, commit, 'test', dispatcher, {imageTag: 'another-tag'}); }
  catch (_) { rejected = true; }
  check(rejected, 'Retry must reject an existing run with a different image tag');
  console.log('Passed selected-only 1/2/14/17-backend and 1/2/3-frontend graphs, working Task references, PVCs, GitOps wiring, one-run launch, retry and no-op checks');
})();
