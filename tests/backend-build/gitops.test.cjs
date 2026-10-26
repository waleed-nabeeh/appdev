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
function record(names) {
  return {schemaVersion: 1, succeeded: true, sourceCommit: sha, selected: names, failed: [], notStarted: [],
    images: Object.fromEntries(names.map(name => {
      const repository = config.imageRepository + '/' + name;
      const digest = 'sha256:' + 'b'.repeat(64);
      return [name, {repository, tag: sha.slice(0, 8), digest, image: repository + '@' + digest}];
    }))};
}
const before = JSON.stringify(core);
const apps = core['argocd-applications'].applications;
check(Object.keys(apps).length === 15, 'All 15 existing backend definitions must remain');
const frontend = yaml.load(fs.readFileSync('customer-transfer/backend-gitops/frontend.yaml', 'utf8'), {schema: yaml.JSON_SCHEMA});
check(Object.keys(frontend['argocd-applications'].applications).length === 3, 'Three frontend definitions');
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
console.log('Passed backend/frontend split, 0/1/2/14-service updates, YAML round-trip and rejection checks');
