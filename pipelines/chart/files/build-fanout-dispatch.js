'use strict';

function check(ok, message) { if (!ok) throw new Error(message); }
function makeFanoutRun(template, config, selected, commit, revision, dispatcher) {
  check(['backend', 'frontend'].includes(config.scope), 'Invalid build scope');
  check(template.metadata?.name === config.fanoutPipeline, 'Unexpected fanout template');
  check(typeof commit === 'string' && /^[a-f0-9]{40}$/.test(commit), 'Expected full source SHA');
  check(typeof revision === 'string' && /^[A-Za-z0-9_./-]+$/.test(revision) && !revision.startsWith('-'), 'Invalid source branch');
  check(Array.isArray(selected) && selected.length > 0 && new Set(selected).size === selected.length, 'Select at least one unique service');
  check(typeof dispatcher.metadata?.uid === 'string' && /^[a-f0-9-]+$/.test(dispatcher.metadata.uid), 'Invalid dispatcher identity');
  check(dispatcher.metadata.namespace === template.metadata.namespace, 'Namespace mismatch');
  selected.forEach(name => check(config.catalog.some(s => s.name === name), 'Unknown or disabled service: ' + name));
  let spec = JSON.parse(JSON.stringify(template.spec));
  const names = new Set(['resolve-source', 'update-gitops']);
  for (const name of selected) {
    for (const stage of ['clone', 'test', 'build', 'scan', 'gate', 'sign']) {
      const taskName = stage + '-' + name;
      check(spec.tasks.some(t => t.name === taskName), 'Missing working fanout stage: ' + taskName);
      names.add(taskName);
    }
  }
  spec.tasks = spec.tasks.filter(t => names.has(t.name));
  check(spec.tasks.some(t => t.name === 'resolve-source'), 'Missing source resolution');
  const update = spec.tasks.find(t => t.name === 'update-gitops');
  check(update?.taskRef?.name === config.scope + '-gitops-update', 'GitOps must be part of the fanout template');
  const images = Object.fromEntries(selected.map(name => {
    const repository = config.imageRepository + '/' + name;
    const digest = '$(tasks.build-' + name + '.results.image-digest)';
    return [name, {repository, tag: '$(tasks.resolve-source.results.tag)', digest, image: repository + '@' + digest}];
  }));
  update.runAfter = selected.map(name => 'sign-' + name);
  update.params = [
    {name: 'source-commit', value: '$(tasks.resolve-source.results.commit)'},
    {name: 'release-json', value: JSON.stringify({schemaVersion: 1, succeeded: true,
      sourceCommit: '$(tasks.resolve-source.results.commit)', selected, images, failed: [], notStarted: []})}
  ];
  const workspaceNames = new Set(['git-credentials', 'registry-auth', ...(config.npmAuth ? ['npm-auth'] : []),
    ...selected.map(name => 'source-' + name)]);
  spec.workspaces = spec.workspaces.filter(w => workspaceNames.has(w.name));
  check(spec.workspaces.length === workspaceNames.size, 'Missing fanout workspace');
  spec.results = (spec.results || []).filter(result => {
    const references = JSON.stringify(result).matchAll(/\$\(tasks\.([^.]+)\.results\.[^)]+\)/g);
    return [...references].every(match => names.has(match[1]));
  });
  // This records the launch input; the graph was already reduced before creation.
  spec.params = [...spec.params.filter(p => p.name !== 'services'), {name: 'services', type: 'string', default: selected.join(',')}];
  spec.tasks.find(t => t.name === 'resolve-source').params.push({name: 'services', value: selected.join(',')});
  spec = JSON.parse(JSON.stringify(spec).replaceAll('resolve-source', 'dispatch-service-selection'));
  const bindings = [
    {name: 'git-credentials', secret: {secretName: 'git-credentials'}},
    {name: 'registry-auth', secret: {secretName: 'registry-auth'}},
    ...(config.npmAuth ? [{name: 'npm-auth', secret: {secretName: 'npm-auth'}}] : []),
    ...selected.map(service => ({name: 'source-' + service, volumeClaimTemplate: {
      metadata: {labels: {pipeline: config.scope + '-build-fanout', service}},
      spec: {accessModes: ['ReadWriteOnce'], resources: {requests: {storage: config.workspaceSize}}}
    }}))
  ];
  return {apiVersion: 'tekton.dev/v1', kind: 'PipelineRun', metadata: {
    name: config.scope + '-build-fanout-' + dispatcher.metadata.uid.replaceAll('-', '').slice(0, 16),
    namespace: dispatcher.metadata.namespace,
    labels: {'app.kubernetes.io/component': config.scope, 'app.kubernetes.io/part-of': 'application-build',
      'tekton.dev/pipeline': config.fanoutPipeline, 'customer.mofa.gov.sa/dispatch-uid': dispatcher.metadata.uid},
    annotations: {'customer.mofa.gov.sa/source-commit': commit, 'customer.mofa.gov.sa/services': JSON.stringify(selected),
      'customer.mofa.gov.sa/dispatcher': dispatcher.metadata.name}
    // No ownership by the short-lived launch TaskRun: pruning it must not delete a running build.
  }, spec: {pipelineSpec: spec, taskRunTemplate: {serviceAccountName: config.buildServiceAccount},
    timeouts: {pipeline: '4h0m0s', tasks: '3h50m0s'},
    params: [{name: 'source-revision', value: revision}, {name: 'source-commit', value: commit}, {name: 'services', value: selected.join(',')}],
    workspaces: bindings}};
}

async function launchFanout(api, config, selected, commit, revision, dispatcher) {
  if (selected.length === 0) return null;
  const prefix = '/apis/tekton.dev/v1/namespaces/' + dispatcher.metadata.namespace;
  const template = await api('GET', prefix + '/pipelines/' + config.fanoutPipeline);
  const run = makeFanoutRun(template, config, selected, commit, revision, dispatcher);
  try { return await api('POST', prefix + '/pipelineruns', run); }
  catch (error) {
    if (error.status !== 409) throw error;
    const existing = await api('GET', prefix + '/pipelineruns/' + run.metadata.name);
    check(existing.metadata.labels?.['customer.mofa.gov.sa/dispatch-uid'] === dispatcher.metadata.uid &&
      existing.metadata.annotations?.['customer.mofa.gov.sa/source-commit'] === commit &&
      existing.metadata.annotations?.['customer.mofa.gov.sa/services'] === JSON.stringify(selected), 'Existing fanout run differs; refusing to reuse it');
    const actual = Object.fromEntries((existing.spec.params || []).map(p => [p.name, p.value]));
    check(actual['source-commit'] === commit && actual['source-revision'] === revision && actual.services === selected.join(','), 'Existing fanout inputs differ');
    return existing;
  }
}
module.exports = {makeFanoutRun, launchFanout};

if (require.main === module) {
  (async () => {
    const fs = require('node:fs');
    const {selectServices, selectDiff, kubeClient} = require('/config/backend-dispatch.js');
    const config = JSON.parse(fs.readFileSync('/config/config.json', 'utf8'));
    const commit = fs.readFileSync('/work/commit', 'utf8');
    const selected = process.env.MODE === 'manual' ? selectServices(process.env.SERVICES, config.catalog) :
      selectDiff(fs.readFileSync('/work/changed', 'utf8').split('\0'), config.catalog, fs.existsSync('/work/all-services'));
    const api = kubeClient(fs, require('node:https'));
    const dispatcher = {metadata: {name: process.env.DISPATCHER_NAME, uid: process.env.DISPATCHER_UID, namespace: process.env.NAMESPACE}};
    const run = await launchFanout(api, config, selected, commit, process.env.REVISION, dispatcher);
    fs.writeFileSync('/tekton/results/services', JSON.stringify(selected));
    fs.writeFileSync('/tekton/results/commit', commit);
    fs.writeFileSync('/tekton/results/pipeline-run', run ? run.metadata.name : 'none');
    console.log('Selected services: ' + (selected.join(',') || '(none)'));
    console.log(run ? 'Build PipelineRun: ' + run.metadata.name : 'No changed services; no build PipelineRun created.');
  })().catch(error => { console.error(error.message); process.exitCode = 1; });
}
