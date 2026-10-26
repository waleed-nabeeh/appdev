'use strict';

function check(ok, message) { if (!ok) throw new Error(message); }
function updateCore(document, record, config, expectedCommit) {
  check(record.schemaVersion === 1 && record.succeeded === true, 'Only a successful batch can update GitOps');
  check(typeof expectedCommit === 'string' && expectedCommit.length === 40 && /^[a-f0-9]+$/.test(expectedCommit) && record.sourceCommit === expectedCommit, 'Batch source SHA mismatch');
  check(Array.isArray(record.selected) && new Set(record.selected).size === record.selected.length, 'Invalid selected services');
  check(Array.isArray(record.failed) && record.failed.length === 0 && Array.isArray(record.notStarted) && record.notStarted.length === 0, 'Incomplete batch');
  const images = record.images;
  check(images && Object.keys(images).length === record.selected.length, 'Batch images do not match selection');
  const output = JSON.parse(JSON.stringify(document));
  const apps = output['argocd-applications']?.applications;
  check(apps && typeof apps === 'object' && !Array.isArray(apps), 'Expected argocd-applications.applications in GitOps values');
  for (const name of record.selected) {
    check(config.catalog.some(s => s.name === name), 'Unknown or disabled service: ' + name);
    const image = images[name];
    const repository = config.imageRepository + '/' + name;
    check(image && image.repository === repository && image.tag === expectedCommit.slice(0, 8), 'Unexpected image identity: ' + name);
    check(typeof image.digest === 'string' && image.digest.length === 71 && /^sha256:[a-f0-9]{64}$/.test(image.digest) && image.image === repository + '@' + image.digest, 'Invalid image digest: ' + name);
    const key = name + '-dev';
    check(Object.hasOwn(apps, key), 'Missing GitOps application: ' + key);
    const target = apps[key].overrideValues?.image;
    check(target && target.repository === repository && typeof target.tag === 'string', 'GitOps repository mismatch: ' + key);
    check(!target.digest, 'Existing digest override requires promotion-aware handling: ' + key);
    target.tag = image.tag;
  }
  return output;
}
module.exports = {updateCore};

if (require.main === module) {
  (async () => {
    const fs = require('node:fs');
    const path = require('node:path');
    const yaml = require('/config/js-yaml.js');
    const {kubeClient} = require('/config/backend-dispatch.js');
    const api = kubeClient(fs, require('node:https'));
    const recordName = process.env.RELEASE_RECORD;
    check(/^backend-result-[a-f0-9]{16}$/.test(recordName), 'Invalid batch record name');
    const cm = await api('GET', '/api/v1/namespaces/' + process.env.NAMESPACE + '/configmaps/' + recordName);
    check(cm.immutable === true, 'Batch record must be immutable');
    const record = JSON.parse(cm.data['release.json']);
    const config = JSON.parse(fs.readFileSync('/config/config.json', 'utf8'));
    const repo = fs.realpathSync('/work/repo');
    const relative = process.env.VALUES_FILE;
    check(relative && !path.isAbsolute(relative) && !relative.split('/').includes('..'), 'Invalid GitOps path');
    const filename = fs.realpathSync(path.join(repo, relative));
    check(filename.startsWith(repo + path.sep), 'GitOps path escapes repository');
    check(filename === path.resolve(repo, relative), 'GitOps values path must not contain symlinks');
    const original = fs.readFileSync(filename, 'utf8');
    const document = yaml.load(original, {schema: yaml.JSON_SCHEMA, maxDepth: 100});
    const updated = updateCore(document, record, config, process.env.SOURCE_COMMIT);
    if (JSON.stringify(updated) !== JSON.stringify(document)) {
      fs.writeFileSync(filename, yaml.dump(updated, {schema: yaml.JSON_SCHEMA, noRefs: true, lineWidth: -1, quotingType: '"'}));
    }
    console.log('GitOps services: ' + (record.selected.join(',') || '(none; no changes)'));
  })().catch(error => { console.error(error.message); process.exitCode = 1; });
}
