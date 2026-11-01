'use strict';
const fs = require('node:fs');
const yaml = require('../../pipelines/chart/files/vendor/js-yaml.js');
const {selectedServices, makePlan, promote} = require('../../pipelines/chart/files/application-promotion.js');
function check(ok, message) { if (!ok) throw Error(message); }
function reject(fn) { let failed = false; try { fn(); } catch (_) { failed = true; } check(failed, 'Expected rejection'); }
function clone(value) { return JSON.parse(JSON.stringify(value)); }
const registry = 'quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops';
for (const scope of ['backend', 'frontend']) {
  const source = yaml.load(fs.readFileSync('customer-transfer/backend-gitops/' + scope + '-preproduction.yaml', 'utf8'), {schema: yaml.JSON_SCHEMA});
  const catalog = JSON.parse(fs.readFileSync('pipelines/chart/files/' + scope + '-services.json', 'utf8'))
    .filter(s => !['payment-service', 'gateway-service', 'authserver-service'].includes(s.name));
  const config = {catalog, imageRepository: registry, sourcePrefix: 'pre-', targets: [
    {name: 'prod', applicationPrefix: 'pre-'}, {name: 'dr', applicationPrefix: 'pre-'}]};
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
  console.log('Passed ' + scope + ' promotion: 1/2/all services, unchanged names/settings, source isolation, both targets, idempotence and validation failures');
}
