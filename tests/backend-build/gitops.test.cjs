'use strict';
const fs = require('node:fs');
const yaml = require('../../pipelines/chart/files/vendor/js-yaml.js');
const {updateCore} = require('../../pipelines/chart/files/backend-gitops-update.js');
const core = yaml.load(fs.readFileSync('customer-transfer/backend-gitops/backend.yaml', 'utf8'), {schema: yaml.JSON_SCHEMA});
const catalog = JSON.parse(fs.readFileSync('pipelines/chart/files/backend-services.json', 'utf8')).filter(s => !['payment-service', 'gateway-service', 'authserver-service'].includes(s.name));
const config = {catalog, imageRepository: 'quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops'};
const sha = '12345678' + 'a'.repeat(32);
function check(ok, message) { if (!ok) throw new Error(message); }
function reject(fn) { let failed = false; try { fn(); } catch (_) { failed = true; } check(failed, 'Expected rejection'); }
function record(names, tag = sha.slice(0, 8)) {
  return {schemaVersion: 1, succeeded: true, sourceCommit: sha, selected: names, failed: [], notStarted: [],
    images: Object.fromEntries(names.map(name => {
      const repository = config.imageRepository + '/' + name;
      const digest = 'sha256:' + 'b'.repeat(64);
      return [name, {repository, tag, digest, image: repository + '@' + digest}];
    }))};
}
const before = JSON.stringify(core);
const apps = core['argocd-applications'].applications;
check(Object.keys(apps).length === 15, 'All 15 existing backend definitions must remain');
const frontend = yaml.load(fs.readFileSync('customer-transfer/backend-gitops/frontend.yaml', 'utf8'), {schema: yaml.JSON_SCHEMA});
check(Object.keys(frontend['argocd-applications'].applications).length === 3, 'Three frontend definitions');
const frontendCatalog = ['admin-portal', 'applicant-portal', 'operational-portal'].map(name => ({name}));
const frontendConfig = {...config, scope: 'frontend', catalog: frontendCatalog};
for (const count of [0, 1, 2, 3]) {
  const selected = frontendCatalog.slice(0, count).map(s => s.name);
  const updated = updateCore(frontend, record(selected), frontendConfig, sha);
  for (const [key, original] of Object.entries(frontend['argocd-applications'].applications)) {
    const expected = JSON.parse(JSON.stringify(original));
    if (selected.includes(key.slice(0, -4))) expected.overrideValues.image.tag = sha.slice(0, 8);
    check(JSON.stringify(updated['argocd-applications'].applications[key]) === JSON.stringify(expected), 'Changed unrelated frontend settings: ' + key);
  }
}
for (const count of [0, 1, 2, 14]) {
  const selected = catalog.slice(0, count).map(s => s.name);
  const updated = updateCore(core, record(selected), config, sha);
  check(JSON.stringify(core) === before, 'Must not mutate input');
  const updatedApps = updated['argocd-applications'].applications;
  for (const [key, original] of Object.entries(apps)) {
    const expected = JSON.parse(JSON.stringify(original));
    if (selected.includes(key.slice(0, -4))) expected.overrideValues.image.tag = sha.slice(0, 8);
    check(JSON.stringify(updatedApps[key]) === JSON.stringify(expected), 'Changed unrelated settings: ' + key);
  }
  check(JSON.stringify(yaml.load(yaml.dump(updated, {schema: yaml.JSON_SCHEMA}), {schema: yaml.JSON_SCHEMA})) === JSON.stringify(updated), 'YAML round-trip changed values');
}
const one = record([catalog[0].name]);
// Current customer files use pre- app names; service/image names stay unchanged.
for (const [scope, activeConfig, counts] of [
  ['backend', config, [0, 1, 2, 14]], ['frontend', frontendConfig, [0, 1, 2, 3]]
]) {
  const preproduction = yaml.load(fs.readFileSync('customer-transfer/backend-gitops/' + scope + '-preproduction.yaml', 'utf8'), {schema: yaml.JSON_SCHEMA});
  const original = JSON.stringify(preproduction);
  const mappedConfig = {...activeConfig, applicationNamePrefix: 'pre-', applicationNameSuffix: ''};
  for (const count of counts) {
    const selected = activeConfig.catalog.slice(0, count).map(s => s.name);
    const expected = JSON.parse(original);
    for (const name of selected) expected['argocd-applications'].applications['pre-' + name].overrideValues.image.tag = sha.slice(0, 8);
    const updated = updateCore(preproduction, record(selected), mappedConfig, sha);
    check(JSON.stringify(updated) === JSON.stringify(expected), 'Preproduction changed unrelated settings: ' + scope + '/' + count);
    check(JSON.stringify(preproduction) === original, 'Preproduction input was mutated');
    check(JSON.stringify(yaml.load(yaml.dump(updated, {schema: yaml.JSON_SCHEMA}), {schema: yaml.JSON_SCHEMA})) === JSON.stringify(expected), 'Preproduction YAML round-trip failed');
    const manualTag = 'pre-test-20261028-01';
    for (const name of selected) expected['argocd-applications'].applications['pre-' + name].overrideValues.image.tag = manualTag;
    check(JSON.stringify(updateCore(preproduction, record(selected, manualTag), mappedConfig, sha, manualTag)) === JSON.stringify(expected), 'Manual tag must update only selected preproduction applications');
  }
  const name = activeConfig.catalog[0].name;
  const missing = JSON.parse(original);
  // An old development entry must never serve as fallback for a missing pre- app.
  missing['argocd-applications'].applications[name + '-dev'] = missing['argocd-applications'].applications['pre-' + name];
  delete missing['argocd-applications'].applications['pre-' + name];
  reject(() => updateCore(missing, record([name]), mappedConfig, sha));
}
reject(() => updateCore(core, one, {...config, applicationNamePrefix: 7}, sha));
reject(() => updateCore(core, record([catalog[0].name], 'manual-tag'), config, sha));
reject(() => updateCore(core, one, config, sha, 'manual-tag'));
for (const tag of ['-bad', '.bad', 'bad/tag', 'valid\n', 'a'.repeat(129), '$(id)']) {
  reject(() => updateCore(core, record([catalog[0].name], tag), config, sha, tag));
}
reject(() => updateCore(core, {...one, succeeded: false}, config, sha));
reject(() => updateCore(core, {...one, failed: [{service: catalog[0].name}]}, config, sha));
reject(() => updateCore(core, {...one, selected: [catalog[0].name, catalog[0].name]}, config, sha));
reject(() => updateCore(core, one, config, 'f'.repeat(40)));
reject(() => updateCore(core, record(['payment-service']), config, sha));
const missing = JSON.parse(before);
delete missing['argocd-applications'].applications[catalog[0].name + '-dev'];
reject(() => updateCore(missing, one, config, sha));
const wrong = JSON.parse(before);
wrong['argocd-applications'].applications[catalog[0].name + '-dev'].overrideValues.image.repository = 'wrong/repository';
reject(() => updateCore(wrong, one, config, sha));
check(apps['acl-service-dev'].overrideValues.extraVolumes[0].secret.defaultMode === 256, 'Preserve secret file permissions');
console.log('Passed backend/frontend development and preproduction mapping, subset updates, YAML round-trip and rejection checks');

// Exercise the deployed entry point with an in-memory filesystem/API. Fixed
// fanout must never require a service-account token or a ConfigMap API request.
async function checkEntry(env, expectedCalls, expectedError, immutable = true, frontendScope = false) {
  const source = fs.readFileSync('pipelines/chart/files/backend-gitops-update.js', 'utf8');
  const activeConfig = frontendScope ? frontendConfig : config;
  const activeDocument = frontendScope ? frontend : core;
  const activeRecord = record(frontendScope ? ['admin-portal'] : [catalog[0].name], env.IMAGE_TAG || sha.slice(0, 8));
  const relative = 'app-chart/' + (frontendScope ? 'frontend' : 'backend') + '.yaml';
  const filename = '/work/repo/' + relative;
  let calls = 0;
  let written;
  let error;
  const proc = {env: {SOURCE_COMMIT: sha, VALUES_FILE: relative, NAMESPACE: 'devops', ...env}};
  const mod = {exports: {}};
  const mockFs = {
    realpathSync: p => p,
    readFileSync: p => {
      if (p === '/config/config.json') return JSON.stringify(activeConfig);
      if (p === filename) return yaml.dump(activeDocument, {schema: yaml.JSON_SCHEMA});
      throw new Error('Unexpected filesystem read: ' + p);
    },
    writeFileSync: (p, data) => { check(p === filename, 'Unexpected write path'); written = yaml.load(data, {schema: yaml.JSON_SCHEMA}); }
  };
  const req = name => {
    if (name === 'node:fs') return mockFs;
    if (name === 'node:path') return require('node:path');
    if (name === '/config/js-yaml.js') return yaml;
    if (name === 'node:https') { check(expectedCalls > 0, 'Fixed fanout must not initialize API access'); return {}; }
    if (name === '/config/backend-dispatch.js') return {kubeClient: () => async (method, url) => {
      calls++;
      check(method === 'GET' && url === '/api/v1/namespaces/devops/configmaps/' + (frontendScope ? 'frontend' : 'backend') + '-result-' + 'a'.repeat(16), 'Wrong batch lookup');
      return {immutable, data: {'release.json': JSON.stringify(activeRecord)}};
    }};
    throw new Error('Unexpected dependency: ' + name);
  };
  req.main = mod;
  new Function('module', 'require', 'process', 'console', source)(mod, req, proc, {log() {}, error(message) { error = message; }});
  // Allow the async ConfigMap branch and its catch handler to finish.
  for (let i = 0; i < 8; i++) await Promise.resolve();
  check(calls === expectedCalls, 'Unexpected Kubernetes API calls');
  if (expectedError) {
    check(proc.exitCode === 1 && error && !written, 'Invalid input must fail without writing');
  } else {
    check(!proc.exitCode && !error, error || 'Unexpected entry point failure');
    check(JSON.stringify(written) === JSON.stringify(updateCore(activeDocument, activeRecord, activeConfig, sha, env.IMAGE_TAG)), 'Entry point did not update only selected tags');
  }
}
module.exports = (async () => {
  await checkEntry({RELEASE_JSON: JSON.stringify(one)}, 0, false);
  for (const front of [false, true]) {
    const manualRecord = record(front ? ['admin-portal'] : [catalog[0].name], 'pre-test-20261028-01');
    await checkEntry({RELEASE_JSON: JSON.stringify(manualRecord), IMAGE_TAG: 'pre-test-20261028-01'}, 0, false, true, front);
    await checkEntry({RELEASE_JSON: JSON.stringify(manualRecord)}, 0, true, true, front);
  }
  await checkEntry({RELEASE_RECORD: 'backend-result-' + 'a'.repeat(16)}, 1, false);
  await checkEntry({RELEASE_JSON: JSON.stringify(one), RELEASE_RECORD: 'backend-result-' + 'a'.repeat(16)}, 0, true);
  await checkEntry({RELEASE_JSON: '{'}, 0, true);
  await checkEntry({RELEASE_RECORD: 'backend-result-' + 'a'.repeat(16)}, 1, true, false);
  await checkEntry({RELEASE_RECORD: 'frontend-result-' + 'a'.repeat(16)}, 1, false, true, true);
  await checkEntry({RELEASE_RECORD: 'backend-result-' + 'a'.repeat(16)}, 0, true, true, true);
  console.log('Passed fixed-fanout input without API access, dispatcher compatibility and invalid-input rejection');
})().catch(error => { console.error(error); process.exitCode = 1; });
