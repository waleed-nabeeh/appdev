'use strict';

function check(ok, message) { if (!ok) throw Error(message); }
function apps(document) {
  const value = document?.['argocd-applications']?.applications;
  check(value && typeof value === 'object' && !Array.isArray(value), 'Expected argocd-applications.applications');
  return value;
}
function validTag(tag) {
  return typeof tag === 'string' && tag.length > 0 && tag.length <= 128 && /^[A-Za-z0-9_]/.test(tag) && !/[^A-Za-z0-9_.-]/.test(tag);
}
function selectedServices(input, catalog) {
  check(typeof input === 'string' && input.trim(), 'Provide services as a comma-separated list or all');
  const names = input.trim() === 'all' ? catalog.map(s => s.name) : [...new Set(input.split(',').map(s => s.trim()))];
  check(names.length > 0 && names.every(name => name && catalog.some(s => s.name === name)), 'Unknown, disabled or empty service name');
  return names;
}
function makePlan(source, targets, config, selection) {
  const selected = selectedServices(selection, config.catalog);
  check(config.targets.length === 2 && new Set(config.targets.map(t => t.name)).size === 2 &&
    config.targets.every(t => ['prod', 'dr'].includes(t.name)), 'Promotion must include production and DR');
  const sourceApps = apps(source);
  const targetApps = Object.fromEntries(config.targets.map(t => [t.name, apps(targets[t.name])]));
  const entries = selected.map(service => {
    const key = config.sourcePrefix + service;
    const image = sourceApps[key]?.overrideValues?.image;
    const repository = config.imageRepository + '/' + service;
    check(image && image.repository === repository && validTag(image.tag) && !image.digest, 'Invalid preproduction image: ' + key);
    const destinations = config.targets.map(t => {
      const name = t.applicationPrefix + service;
      const app = targetApps[t.name][name];
      check(app && (!app.name || app.name === name) && app.overrideValues?.image &&
        typeof app.overrideValues.image.repository === 'string' && typeof app.overrideValues.image.tag === 'string' &&
        !app.overrideValues.image.digest, 'Missing or invalid target image: ' + name);
      check(app.autoSync === false, 'Git-only promotion requires autoSync: false for ' + name);
      return {environment: t.name, application: name};
    });
    return {service, sourceApplication: key, repository, tag: image.tag, destinations};
  });
  return {schemaVersion: 1, entries};
}
function promote(plan, source, targets, config, resolved) {
  check(plan.schemaVersion === 1 && Array.isArray(plan.entries) && plan.entries.length > 0, 'Invalid promotion plan');
  const selection = plan.entries.map(e => e.service).join(',');
  check(JSON.stringify(makePlan(source, targets, config, selection)) === JSON.stringify(plan), 'Promotion plan no longer matches its source/targets');
  check(Object.keys(resolved).length === plan.entries.length, 'Missing verified images');
  const output = JSON.parse(JSON.stringify(targets));
  for (const entry of plan.entries) {
    check(typeof resolved[entry.service] === 'string' && /^sha256:[a-f0-9]{64}$/.test(resolved[entry.service]) && resolved[entry.service].length === 71,
      'Invalid verified digest: ' + entry.service);
    for (const target of entry.destinations) {
      const image = apps(output[target.environment])[target.application].overrideValues.image;
      image.repository = entry.repository;
      image.tag = entry.tag;
    }
  }
  return output;
}
function packImages(entries) {
  const value = entries.map(e => e.service + '=' + e.tag).join(',');
  check(value.length <= 3000, 'Image selection exceeds the bounded Task result size');
  return value;
}
function parseImages(value, config) {
  check(typeof value === 'string' && value.length > 0 && value.length <= 3000, 'Invalid image selection result');
  const entries = value.split(',').map(row => {
    const fields = row.split('=');
    check(fields.length === 2 && config.catalog.some(s => s.name === fields[0]) && validTag(fields[1]), 'Unexpected image selection entry');
    return {service: fields[0], repository: config.imageRepository + '/' + fields[0], tag: fields[1]};
  });
  check(new Set(entries.map(e => e.service)).size === entries.length, 'Duplicate image selection entry');
  return entries;
}
function resolvedRows(entries, value) {
  check(typeof value === 'string', 'Missing artifact digest result');
  const digests = value.split(',');
  check(digests.length === entries.length && digests.every(d => d.length === 71 && /^sha256:[a-f0-9]{64}$/.test(d)), 'Artifact digests do not match selection');
  return entries.map((entry, i) => [entry.service, entry.repository, entry.tag, digests[i]].join('\t')).join('\n') + '\n';
}
module.exports = {selectedServices, makePlan, promote, packImages, parseImages, resolvedRows};

if (require.main === module) {
  const fs = require('node:fs');
  const path = require('node:path');
  const yaml = require('/config/js-yaml.js');
  const config = JSON.parse(fs.readFileSync('/config/promotion.json', 'utf8'));
  if (['prepare-images', 'prepare-verification', 'emit-digests'].includes(process.env.ACTION)) {
    const entries = parseImages(process.env.IMAGES, config);
    if (process.env.ACTION === 'prepare-images') {
      fs.writeFileSync('/work/images.tsv', entries.map(e => [e.service, e.repository, e.tag].join('\t')).join('\n') + '\n');
    } else if (process.env.ACTION === 'prepare-verification') {
      fs.writeFileSync('/work/resolved.tsv', resolvedRows(entries, process.env.DIGESTS));
    } else {
      const rows = fs.readFileSync('/work/resolved.tsv', 'utf8').trim().split('\n').map(row => row.split('\t'));
      const digests = rows.map(row => row[3]).join(',');
      check(resolvedRows(entries, digests) === rows.map(row => row.join('\t')).join('\n') + '\n', 'Resolved artifacts differ from approved image selection');
      fs.writeFileSync('/tekton/results/digests', digests);
    }
  } else {
    const root = fs.realpathSync('/work/repo');
    const safePath = relative => {
      check(typeof relative === 'string' && /^[A-Za-z0-9_./-]+$/.test(relative) && !path.isAbsolute(relative) &&
        !relative.split('/').includes('..'), 'Invalid promotion file path');
      const filename = fs.realpathSync(path.join(root, relative));
      check(filename === path.resolve(root, relative) && filename.startsWith(root + path.sep), 'Promotion path escapes checkout or uses a symlink');
      return filename;
    };
    const read = filename => yaml.load(fs.readFileSync(filename, 'utf8'), {schema: yaml.JSON_SCHEMA, maxDepth: 100});
    const targetPaths = Object.fromEntries(config.targets.map(t => [t.name, safePath(t.file)]));
    check(new Set([config.sourceFile, ...config.targets.map(t => t.file)]).size === 3, 'Source and target files must be distinct');
    safePath(config.sourceFile);
    const source = read('/work/approved-source.yaml');
    const targets = Object.fromEntries(Object.entries(targetPaths).map(([name, filename]) => [name, read(filename)]));
    if (process.env.ACTION === 'plan') {
      const plan = makePlan(source, targets, config, process.env.SERVICES);
      const images = packImages(plan.entries);
      if (process.env.IMAGES) check(images === process.env.IMAGES, 'Preproduction images differ from the approved Task result');
      fs.writeFileSync('/work/plan.json', JSON.stringify(plan));
      fs.writeFileSync('/work/images.tsv', plan.entries.map(e => [e.service, e.repository, e.tag].join('\t')).join('\n') + '\n');
      fs.writeFileSync('/work/targets.txt', config.targets.map(t => t.file).join('\n') + '\n');
      fs.writeFileSync('/work/watched.txt', [config.sourceFile, ...config.targets.map(t => t.file)].join('\n') + '\n');
      if (process.env.EMIT_PLAN_RESULTS === 'true') {
        fs.writeFileSync('/tekton/results/services', plan.entries.map(e => e.service).join(','));
        fs.writeFileSync('/tekton/results/images', images);
      }
      if (process.env.VERIFIED_DIGESTS) {
        check(process.env.DIGESTS === process.env.VERIFIED_DIGESTS && process.env.IMAGES === images, 'Verified artifacts do not match the approved selection');
        fs.writeFileSync('/work/resolved.tsv', resolvedRows(parseImages(images, config), process.env.VERIFIED_DIGESTS));
        fs.writeFileSync('/work/verified', 'passed');
      }
      for (const entry of plan.entries) console.log(entry.service + ': ' + entry.repository + ':' + entry.tag + ' -> ' + entry.destinations.map(t => t.application).join(', '));
    } else if (process.env.ACTION === 'update') {
      check(fs.readFileSync('/work/verified', 'utf8') === 'passed', 'Signature verification did not complete');
      const plan = JSON.parse(fs.readFileSync('/work/plan.json', 'utf8'));
      const rows = fs.readFileSync('/work/resolved.tsv', 'utf8').trim().split('\n').map(line => line.split('\t'));
      check(rows.length === plan.entries.length && new Set(rows.map(r => r[0])).size === rows.length, 'Invalid verified image list');
      const resolved = {};
      rows.forEach(([service, repository, tag, digest]) => {
        check(plan.entries.some(e => e.service === service && e.repository === repository && e.tag === tag), 'Verified image does not match plan');
        resolved[service] = digest;
      });
      const updated = promote(plan, source, targets, config, resolved);
      for (const [name, filename] of Object.entries(targetPaths)) {
        if (JSON.stringify(updated[name]) !== JSON.stringify(targets[name])) {
          fs.writeFileSync(filename, yaml.dump(updated[name], {schema: yaml.JSON_SCHEMA, noRefs: true, lineWidth: -1, quotingType: '"'}));
        }
      }
      console.log('Updated selected image repositories/tags in production and DR; environment configuration preserved.');
    } else throw Error('Unknown promotion action');
  }
}
