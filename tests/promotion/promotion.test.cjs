'use strict';
const fs = require('node:fs');
const yaml = require('../../pipelines/chart/files/vendor/js-yaml.js');
const {selectedServices, makePlan, promote, packImages, parseImages, resolvedRows} = require('../../pipelines/chart/files/application-promotion.js');
function check(ok, message) { if (!ok) throw Error(message); }
function reject(fn) { let failed = false; try { fn(); } catch (_) { failed = true; } check(failed, 'Expected rejection'); }
function clone(value) { return JSON.parse(JSON.stringify(value)); }
const registry = 'quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops';
for (const scope of ['backend', 'frontend']) {
  const source = yaml.load(fs.readFileSync('customer-transfer/backend-gitops/' + scope + '-preproduction.yaml', 'utf8'), {schema: yaml.JSON_SCHEMA});
  const catalog = JSON.parse(fs.readFileSync('pipelines/chart/files/' + scope + '-services.json', 'utf8'))
    .filter(s => !['payment-service', 'gateway-service', 'authserver-service'].includes(s.name));
  const config = {catalog, imageRepository: registry, sourcePrefix: 'pre-', targets: [
    {name: 'prod', applicationPrefix: 'pre-', file: 'app-chart/prod-' + scope + '.yaml'},
    {name: 'dr', applicationPrefix: 'pre-', file: 'app-chart/dr-' + scope + '.yaml'}], sourceFile: 'app-chart/' + scope + '.yaml'};
  const targets = {prod: clone(source), dr: clone(source)};
  for (const [env, document] of Object.entries(targets)) {
    for (const app of Object.values(document['argocd-applications'].applications)) {
      app.project = env + '-project';
      app.destination.namespace = env + '-' + scope;
      app.overrideValues.image.tag = 'old-image';
      app.overrideValues.image.repository = 'old-registry.example/old/image';
      app.overrideValues.env = {ENVIRONMENT: env};
    }
  }
  const originalSource = JSON.stringify(source), originalTargets = JSON.stringify(targets);
  check(selectedServices(' ' + catalog[0].name + ',' + catalog[0].name + ' ', catalog).length === 1, 'CSV must trim/deduplicate');
  for (const count of [1, 2, catalog.length]) {
    const names = catalog.slice(0, count).map(s => s.name);
    const plan = makePlan(source, targets, config, names.join(','));
    const packed = packImages(plan.entries);
    const entries = parseImages(packed, config);
    check(entries.map(e => e.service).join(',') === names.join(','), 'Task result must preserve selected order');
    const digestList = names.map(() => 'sha256:' + 'a'.repeat(64)).join(',');
    check(resolvedRows(entries, digestList).trim().split('\n').length === names.length, 'Artifact results must cover every selected service');
    reject(() => resolvedRows(entries, 'bad-digest'));
    const resolved = Object.fromEntries(names.map(name => [name, 'sha256:' + 'a'.repeat(64)]));
    const updated = promote(plan, source, targets, config, resolved);
    const expected = clone(targets);
    for (const env of ['prod', 'dr']) {
      for (const service of names) {
        const key = 'pre-' + service;
        const image = expected[env]['argocd-applications'].applications[key].overrideValues.image;
        image.repository = registry + '/' + service;
        image.tag = source['argocd-applications'].applications[key].overrideValues.image.tag;
      }
    }
    check(JSON.stringify(updated) === JSON.stringify(expected), 'Only selected image repository/tag may change in both targets');
    check(JSON.stringify(source) === originalSource && JSON.stringify(targets) === originalTargets, 'Input documents mutated');
    check(JSON.stringify(promote(makePlan(source, updated, config, names.join(',')), source, updated, config, resolved)) === JSON.stringify(updated), 'Promotion must be idempotent');
    check(JSON.stringify(yaml.load(yaml.dump(updated), {schema: yaml.JSON_SCHEMA})) === JSON.stringify(updated), 'YAML round trip changed environment settings');
    reject(() => promote(plan, source, targets, config, {}));
    reject(() => promote(plan, source, targets, config, {...resolved, [names[0]]: 'invalid'}));
  }
  for (const selection of ['', 'unknown-service', catalog[0].name + ',']) reject(() => makePlan(source, targets, config, selection));
  const name = catalog[0].name, key = 'pre-' + name;
  const missing = clone(targets); delete missing.dr['argocd-applications'].applications[key];
  reject(() => makePlan(source, missing, config, name));
  const autoSync = clone(targets); autoSync.prod['argocd-applications'].applications[key].autoSync = true;
  reject(() => makePlan(source, autoSync, config, name));
  const wrong = clone(source); wrong['argocd-applications'].applications[key].overrideValues.image.repository = 'wrong/repo';
  reject(() => makePlan(wrong, targets, config, name));
  wrong['argocd-applications'].applications[key].overrideValues.image.repository = registry + '/' + name;
  wrong['argocd-applications'].applications[key].overrideValues.image.tag = 'bad tag';
  reject(() => makePlan(wrong, targets, config, name));
  reject(() => makePlan(source, targets, {...config, targets: [config.targets[0]]}, name));
  reject(() => parseImages(name + '=tag,' + name + '=tag', config));
  reject(() => parseImages(name + '=bad tag', config));
  reject(() => parseImages('unknown=tag', config));
  // Each Task starts with a fresh filesystem. Only bounded result values cross
  // Task boundaries; no emptyDir or private credential HOME can be shared.
  const initial = () => Object.fromEntries([
    ['/config/promotion.json', JSON.stringify(config)],
    ['/work/approved-source.yaml', yaml.dump(source)],
    ['/work/repo/' + config.sourceFile, yaml.dump(source)],
    ...config.targets.map(t => ['/work/repo/' + t.file, yaml.dump(targets[t.name])])]);
  const execute = (files, env) => {
    const req = moduleName => {
      if (moduleName === 'node:fs') return {realpathSync: p => p,
        readFileSync: p => { check(Object.hasOwn(files, p), 'Unexpected file read: ' + p); return files[p]; },
        writeFileSync: (p, data) => { files[p] = data; }};
      if (moduleName === 'node:path') return require('node:path');
      if (moduleName === '/config/js-yaml.js') return yaml;
      throw Error('Unexpected dependency: ' + moduleName);
    };
    const mod = {exports: {}}; req.main = mod;
    new Function('module', 'require', 'process', 'console', fs.readFileSync('pipelines/chart/files/application-promotion.js', 'utf8'))
      (mod, req, {env}, {log() {}});
  };
  const manifestFiles = initial();
  execute(manifestFiles, {ACTION: 'plan', SERVICES: catalog.slice(0, 2).map(s => s.name).join(','), EMIT_PLAN_RESULTS: 'true'});
  const images = manifestFiles['/tekton/results/images'];
  const artifactFiles = {'/config/promotion.json': JSON.stringify(config)};
  execute(artifactFiles, {ACTION: 'prepare-images', IMAGES: images});
  artifactFiles['/work/resolved.tsv'] = artifactFiles['/work/images.tsv'].trim().split('\n').map(row => row + '\tsha256:' + 'c'.repeat(64)).join('\n') + '\n';
  execute(artifactFiles, {ACTION: 'emit-digests', IMAGES: images});
  const digestResult = artifactFiles['/tekton/results/digests'];
  const verifierFiles = {'/config/promotion.json': JSON.stringify(config)};
  execute(verifierFiles, {ACTION: 'prepare-verification', IMAGES: images, DIGESTS: digestResult});
  check(verifierFiles['/work/resolved.tsv'] === artifactFiles['/work/resolved.tsv'], 'Verifier must receive exactly the approved lookup artifacts');
  const updateFiles = initial();
  execute(updateFiles, {ACTION: 'plan', SERVICES: manifestFiles['/tekton/results/services'], IMAGES: images,
    DIGESTS: digestResult, VERIFIED_DIGESTS: digestResult});
  execute(updateFiles, {ACTION: 'update'});
  for (const target of config.targets) {
    check(yaml.load(updateFiles['/work/repo/' + target.file])['argocd-applications'].applications['pre-' + catalog[0].name].overrideValues.image.tag ===
      source['argocd-applications'].applications['pre-' + catalog[0].name].overrideValues.image.tag, 'Target did not receive selected preprod tag');
  }
  reject(() => execute(initial(), {ACTION: 'update'}));
  reject(() => execute(initial(), {ACTION: 'plan', SERVICES: catalog[0].name, IMAGES: images, DIGESTS: digestResult, VERIFIED_DIGESTS: 'wrong'}));
  console.log('Passed ' + scope + ' promotion: 1/2/all services, unchanged names/settings, source isolation, both targets, idempotence and validation failures');
}
const fullCatalog = JSON.parse(fs.readFileSync('pipelines/chart/files/backend-services.json', 'utf8'));
const worst = fullCatalog.map(s => ({service: s.name, tag: 'a'.repeat(128)}));
const packed = packImages(worst);
const selected = fullCatalog.map(s => s.name).join(',');
const message = JSON.stringify([{key: 'images', value: packed, type: 1}, {key: 'services', value: selected, type: 1}]);
check(message.length < 3500, 'Worst-case 17-service Task results need headroom below the 4KiB termination limit');
const digests = fullCatalog.map(() => 'sha256:' + 'b'.repeat(64)).join(',');
check(JSON.stringify([{key: 'digests', value: digests, type: 1}]).length < 1500, 'Digest results must stay bounded');
console.log('Passed compact Task result round trips, invalid artifacts and maximum-tag 17-service result budgets');
