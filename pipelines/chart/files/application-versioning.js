'use strict';

function check(ok, message) { if (!ok) throw new Error(message); }
const sha = value => typeof value === 'string' && /^[a-f0-9]{40}$/.test(value);
const key = value => typeof value === 'string' && /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,99}$/.test(value);
function parse(version) {
  const match = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-(alpha|beta|rc)\.(0|[1-9]\d*))?$/.exec(version || '');
  check(match, 'Invalid semantic version in versioning state');
  const parts = match.slice(1, 4).map(Number), build = Number(match[5] || 0);
  check([...parts, build].every(Number.isSafeInteger), 'Version numbers exceed safe integer range');
  return {parts, label: match[4], build};
}
function compare(a, b) {
  const x = parse(a), y = parse(b);
  for (let i = 0; i < 3; i++) if (x.parts[i] !== y.parts[i]) return x.parts[i] - y.parts[i];
  check(x.label === y.label, 'Cannot compare different environment version labels');
  return x.build - y.build;
}
function bump(current, type, label) {
  const value = parse(current), parts = value.parts;
  check(['BUILD', 'PATCH', 'MINOR', 'MAJOR'].includes(type), 'Invalid version bump');
  let build = value.build + 1;
  if (type !== 'BUILD') {
    const index = {MAJOR: 0, MINOR: 1, PATCH: 2}[type];
    parts[index]++;
    for (let i = index + 1; i < 3; i++) parts[i] = 0;
    build = 0; // Preserve the existing uvisa-versioning bump rules.
  }
  return parts.join('.') + '-' + label + '.' + build;
}
function buildType(commits) {
  let best = 'BUILD';
  const order = ['BUILD', 'PATCH', 'MINOR', 'MAJOR'];
  for (const commit of commits) {
    const message = commit.message || '';
    if (message.includes('[skip ci]')) continue;
    const first = message.trim().split('\n')[0].replace(/^Merged PR \d+:\s*/i, '');
    const match = /^([a-z]+)(?:\([^)]*\))?(!)?:\s*/i.exec(first);
    if (!match) continue;
    const level = match[2] || /^BREAKING[ -]CHANGE\s*:/m.test(message) ? 'MAJOR' :
      match[1].toLowerCase() === 'feat' ? 'MINOR' :
      ['fix', 'hotfix', 'perf', 'revert'].includes(match[1].toLowerCase()) ? 'PATCH' : 'BUILD';
    if (order.indexOf(level) > order.indexOf(best)) best = level;
  }
  return best;
}
function settings(config, input) {
  const v = config.versioning;
  check(v?.enabled && ['backend', 'frontend'].includes(config.scope), 'Versioning is not enabled for this scope');
  check(['dev', 'test', 'preprod'].includes(v.environment), 'Unknown release environment');
  check(/^[A-Za-z0-9_-]+(?:\/[A-Za-z0-9_-]+)*$/.test(v.directory), 'Unsafe versioning directory');
  check(/^[A-Za-z0-9_./-]+$/.test(v.revision) && !v.revision.startsWith('-') && !v.revision.includes('..'), 'Unsafe versioning branch');
  check(parse(v.initialVersion).label === undefined, 'initialVersion must be MAJOR.MINOR.PATCH');
  check(['AUTO', 'BUILD', 'PATCH', 'MINOR', 'MAJOR'].includes(v.bump), 'Invalid configured bump');
  check(sha(input.sourceCommit) && key(input.runId) && key(input.runName), 'Invalid run identity or source commit');
  check(key(input.buildEnvironment), 'Invalid build environment');
  check(input.sourceUrl === config.sourceUrl, 'Versioning requires the configured source repository');
  check(input.imageTag === '' || input.imageTag === undefined, 'Manual image tags are disabled when automatic versioning is enabled');
  check(Array.isArray(input.selected) && input.selected.length && new Set(input.selected).size === input.selected.length, 'Invalid versioning selection');
  input.selected.forEach(name => check(key(name) && config.catalog.some(s => s.name === name), 'Unknown selected service'));
  return {...v, label: {dev: 'alpha', test: 'beta', preprod: 'rc'}[v.environment],
    statePath: v.directory + '/state.yaml',
    runPath: v.directory + '/runs/' + v.environment + '/' + config.scope + '-' + input.runId + '.yaml'};
}
function identity(record, input, config) {
  check(record.schemaVersion === 1 && record.runId === input.runId && record.scope === config.scope &&
    record.runName === input.runName && record.sourceRevision === input.sourceRevision && record.buildEnvironment === input.buildEnvironment &&
    record.sourceCommit === input.sourceCommit && record.sourceUrl === input.sourceUrl &&
    JSON.stringify(record.selected) === JSON.stringify(input.selected), 'Existing reservation belongs to different build inputs');
}
async function execute(store, config, input, action) {
  input = {...input, buildEnvironment: input.buildEnvironment ?? config.env ?? 'dev'};
  const v = settings(config, input);
  check(['reserve', 'complete'].includes(action), 'Invalid versioning action');
  for (let attempt = 0; attempt < 6; attempt++) {
    const head = await store.head();
    const oldState = await store.read(v.statePath, head);
    const state = oldState || {schemaVersion: 1, counters: {}, services: {}, products: {}};
    check(state.schemaVersion === 1 && state.counters && state.services && state.products, 'Incompatible versioning state; refusing to overwrite');
    let record = await store.read(v.runPath, head);
    const changes = {};
    const now = new Date().toISOString();
    const envKey = v.environment;
    state.counters[envKey] ||= {};
    state.services[envKey] ||= {};
    const existingProduct = await store.read(v.directory + '/product/' + envKey + '.yaml', head);
    if (existingProduct) check(existingProduct.schemaVersion === 1 && existingProduct.environment === envKey &&
      existingProduct.components && typeof existingProduct.components === 'object', 'Existing product record needs reviewed migration');
    if (existingProduct?.version && !state.products[envKey]) {
      check(existingProduct.schemaVersion === 1 && existingProduct.environment === envKey &&
        existingProduct.components && typeof existingProduct.components === 'object', 'Existing product record needs reviewed migration');
      parse(existingProduct.version);
      state.products[envKey] = existingProduct.version;
      for (const [name, service] of Object.entries(existingProduct.components)) {
        check(/^(backend|frontend)\/[A-Za-z0-9_-]+$/.test(name), 'Invalid existing component key');
        parse(service.version);
        state.services[envKey][name] ||= service;
        state.counters[envKey][name] ||= service.version;
      }
    }
    if (record) identity(record, input, config);
    if (action === 'reserve') {
      if (record) return record;
      // Verify pinned source exists even on the first run, without building HEAD.
      await store.sourceCommit(input.sourceUrl, input.sourceCommit);
      record = {schemaVersion: 1, runId: input.runId, runName: input.runName, scope: config.scope,
        environment: envKey, sourceUrl: input.sourceUrl, sourceCommit: input.sourceCommit,
        sourceRevision: input.sourceRevision, buildEnvironment: input.buildEnvironment,
        selected: input.selected, status: 'reserved', createdAt: now, versions: {}, commits: {}};
      for (const name of input.selected) {
        const serviceKey = config.scope + '/' + name;
        if (!state.services[envKey][serviceKey]) {
          const existing = await store.read(v.directory + '/environments/' + envKey + '/' + name + '.yaml', head);
          if (existing) {
            check(existing.schemaVersion === 1 && existing.service === name && existing.scope === config.scope &&
              existing.environment === envKey && sha(existing.commitId), 'Existing service record needs reviewed migration: ' + name);
            parse(existing.version);
            state.services[envKey][serviceKey] = existing;
            state.counters[envKey][serviceKey] ||= existing.version;
          }
        }
        const previous = state.counters[envKey][serviceKey];
        const successful = state.services[envKey][serviceKey];
        const commits = v.bump === 'AUTO' && successful?.commitId && successful.commitId !== input.sourceCommit ?
          await store.sourceChanges(input.sourceUrl, input.sourceCommit, successful.commitId,
            config.catalog.find(s => s.name === name).paths || []) : [];
        const type = v.bump === 'AUTO' ? buildType(commits) : v.bump;
        let version = successful ? bump(successful.version, type, v.label) : v.initialVersion + '-' + v.label + '.1';
        if (previous && compare(version, previous) <= 0) version = bump(previous, 'BUILD', v.label);
        state.counters[envKey][serviceKey] = version;
        record.versions[name] = {version, buildtype: previous ? type : 'INITIAL'};
        record.commits[name] = commits;
      }
      for (const environment of ['dev', 'test', 'preprod']) {
        const path = v.directory + '/environments/' + environment + '/environment.yaml';
        if (!await store.read(path, head)) changes[path] = {schemaVersion: 1, environment,
          initializedAt: now, status: 'initialized', note: 'Repository metadata only; not proof of deployment'};
        const productPath = v.directory + '/product/' + environment + '.yaml';
        if (!await store.read(productPath, head)) changes[productPath] = {schemaVersion: 1,
          environment, status: 'initialized', version: null, components: {}};
      }
    } else {
      check(record, 'No reserved version exists for this PipelineRun');
      const release = input.release;
      check(release?.schemaVersion === 1 && release.succeeded === true && release.sourceCommit === input.sourceCommit &&
        JSON.stringify(release.selected) === JSON.stringify(input.selected) &&
        release.failed?.length === 0 && release.notStarted?.length === 0 && sha(input.gitopsCommit), 'Incomplete build or GitOps outcome');
      check(Object.keys(release.images || {}).length === input.selected.length, 'Unexpected image count');
      for (const name of input.selected) {
        const image = release.images[name], version = record.versions[name].version;
        const repository = config.imageRepository + '/' + name;
        check(image?.tag === version && image.repository === repository && /^sha256:[a-f0-9]{64}$/.test(image.digest) &&
          image.image === repository + '@' + image.digest, 'Published artifact differs from reservation: ' + name);
      }
      if (record.status === 'gitops-updated') {
        check(record.gitopsCommit === input.gitopsCommit && JSON.stringify(record.images) === JSON.stringify(release.images), 'Completed reservation has different artifacts');
        if (v.createTags) await store.tag(v.environment + '/' + record.productVersion, v.runPath);
        return record;
      }
      const lastProduct = state.products[envKey];
      const priorities = ['BUILD', 'PATCH', 'MINOR', 'MAJOR'];
      const productBump = input.selected.reduce((best, name) => {
        const type = record.versions[name].buildtype;
        return priorities.indexOf(type) > priorities.indexOf(best) ? type : best;
      }, 'BUILD');
      const productVersion = lastProduct ? bump(lastProduct, productBump, v.label) : v.initialVersion + '-' + v.label + '.1';
      state.products[envKey] = productVersion;
      for (const name of input.selected) {
        const serviceKey = config.scope + '/' + name;
        const previous = state.services[envKey][serviceKey];
        check(!previous || compare(record.versions[name].version, previous.version) > 0, 'A newer version already completed: ' + name);
        const service = {schemaVersion: 1, service: name, ownerRepo: config.sourceUrl, scope: config.scope,
          environment: envKey, buildEnvironment: input.buildEnvironment,
          version: record.versions[name].version, productVersion,
          commitId: input.sourceCommit, imageRef: release.images[name].repository + ':' + release.images[name].tag,
          imageDigest: release.images[name].digest, buildtype: record.versions[name].buildtype,
          lastBuiltAt: now, lastRunId: input.runId, pipelineRun: input.runName, gitopsCommit: input.gitopsCommit,
          status: 'gitops-updated', archived: false, commits: record.commits[name]};
        state.services[envKey][serviceKey] = service;
        changes[v.directory + '/environments/' + envKey + '/' + name + '.yaml'] = service;
      }
      Object.assign(record, {status: 'gitops-updated', completedAt: now, gitopsCommit: input.gitopsCommit,
        productVersion, images: release.images});
      changes[v.directory + '/product/' + envKey + '.yaml'] = {schemaVersion: 1, environment: envKey,
        version: productVersion, status: 'gitops-updated', lastRunId: input.runId,
        updatedAt: now, components: state.services[envKey]};
      const rows = input.selected.map(name => '| ' + name + ' | ' + record.versions[name].version + ' | ' + release.images[name].digest + ' |');
      changes[v.directory + '/releaseNotes/' + envKey + '/' + config.scope + '-' + input.runId + '.md'] =
        '# ' + productVersion + '\n\nEnvironment: ' + envKey + '\n\nScope: ' + config.scope +
        '\n\nStatus: GitOps updated; deployment health has not been established by this record.\n\n' +
        'Source commit: `' + input.sourceCommit + '`\n\nGitOps commit: `' + input.gitopsCommit +
        '`\n\n| Service | Version | Image digest |\n| --- | --- | --- |\n' + rows.join('\n') + '\n';
    }
    changes[v.statePath] = state;
    changes[v.runPath] = record;
    if (await store.commit(head, changes, action + ' ' + config.scope + ' versions [skip ci]')) {
      if (action === 'complete' && v.createTags) await store.tag(v.environment + '/' + record.productVersion, v.runPath);
      return record;
    }
  }
  throw new Error('Concurrent version updates exceeded retry limit; no build should reuse an uncommitted reservation');
}

function repoApi(repository) {
  const url = new URL(repository);
  check(url.protocol === 'https:' && !url.username && !url.password && !url.search && !url.hash, 'Expected credential-free HTTPS repository URL');
  const match = /^(.*)\/_git\/([^/]+)$/.exec(url.pathname);
  check(match, 'Expected Azure DevOps Git URL');
  return {origin: url.origin, path: match[1] + '/_apis/git/repositories/' + match[2]};
}
function credential(repository, contents) {
  const target = new URL(repository);
  for (const line of contents.split(/\r?\n/).filter(Boolean)) {
    let entry;
    try { entry = new URL(line); } catch (_) { continue; }
    if (entry.origin === target.origin && target.pathname.startsWith(entry.pathname.replace(/\/$/, '') + '/') && entry.password) {
      return Buffer.from(decodeURIComponent(entry.username) + ':' + decodeURIComponent(entry.password)).toString('base64');
    }
  }
  throw new Error('No matching Azure credentials in existing Git Secret');
}
function azureStore(config, fs, https, yaml, credentials) {
  const v = config.versioning, versions = new Map();
  repoApi(v.repository);
  async function request(repository, method, endpoint, query = {}, body) {
    const repo = repoApi(repository);
    const url = new URL(repo.origin + repo.path + endpoint);
    for (const [key, value] of Object.entries({...query, 'api-version': v.apiVersion || '6.0'})) url.searchParams.set(key, String(value));
    const auth = credential(repository, credentials);
    return new Promise((resolve, reject) => {
      const req = https.request(url, {method, rejectUnauthorized: true, headers: {
        Authorization: 'Basic ' + auth, Accept: 'application/json', 'Content-Type': 'application/json'
      }}, response => {
        response.setEncoding?.('utf8');
        let data = '';
        response.on('data', chunk => { data += chunk; if (data.length > 8 * 1024 * 1024) req.destroy(new Error('Azure response too large')); });
        response.on('end', () => {
          if (response.statusCode < 200 || response.statusCode >= 300) {
            const error = new Error('Azure Git API ' + method + ' ' + endpoint + ' failed: HTTP ' + response.statusCode);
            error.status = response.statusCode; reject(error); return;
          }
          try { resolve(JSON.parse(data)); } catch (_) { reject(new Error('Azure Git API returned non-JSON response')); }
        });
      });
      req.setTimeout(60000, () => req.destroy(new Error('Azure Git API timeout')));
      req.on('error', reject);
      req.end(body ? JSON.stringify(body) : undefined);
    });
  }
  return {
    async head() {
      const refs = await request(v.repository, 'GET', '/refs', {filter: 'heads/' + v.revision});
      const ref = refs.value.find(r => r.name === 'refs/heads/' + v.revision);
      check(ref && sha(ref.objectId), 'Versioning branch does not exist; create/review ocp before running');
      return ref.objectId;
    },
    async read(path, head) {
      try {
        const item = await request(v.repository, 'GET', '/items', {path: '/' + path, includeContent: true,
          'versionDescriptor.version': head, 'versionDescriptor.versionType': 'commit'});
        check(typeof item.content === 'string', 'Versioning file has no content');
        versions.set(head + ':' + path, true);
        if (path.endsWith('.md')) return item.content;
        const document = yaml.load(item.content, {schema: yaml.JSON_SCHEMA, maxDepth: 100});
        check(document && typeof document === 'object' && !Array.isArray(document), 'Empty or invalid versioning document; refusing to overwrite');
        return document;
      } catch (error) { if (error.status === 404) { versions.set(head + ':' + path, false); return null; } throw error; }
    },
    async commit(head, changes, comment) {
      const payload = {refUpdates: [{name: 'refs/heads/' + v.revision, oldObjectId: head}], commits: [{comment, changes: []}]};
      for (const [path, document] of Object.entries(changes)) {
        if (!versions.has(head + ':' + path)) await this.read(path, head);
        const content = typeof document === 'string' ? document : yaml.dump(document, {schema: yaml.JSON_SCHEMA, noRefs: true, lineWidth: -1});
        check(Buffer.byteLength(content) < 1024 * 1024, 'Versioning document exceeds 1 MiB; archive old state before continuing');
        payload.commits[0].changes.push({changeType: versions.get(head + ':' + path) ? 'edit' : 'add',
          item: {path: '/' + path}, newContent: {content, contentType: 'rawtext'}});
      }
      try { await request(v.repository, 'POST', '/pushes', {}, payload); return true; }
      catch (error) {
        // Only retry actual branch movement. Authentication/policy failures fail closed.
        if ([400, 409, 412].includes(error.status) && await this.head() !== head) return false;
        throw error;
      }
    },
    async sourceCommit(repository, commit) { await request(repository, 'GET', '/commits/' + commit); },
    async tag(name, path) {
      const head = await this.head();
      const history = await request(v.repository, 'GET', '/commits', {
        'searchCriteria.itemVersion.version': head, 'searchCriteria.itemVersion.versionType': 'commit',
        'searchCriteria.itemPath': '/' + path, 'searchCriteria.$top': 1
      });
      const target = history.value[0]?.commitId;
      check(sha(target), 'Cannot resolve completed version-record commit for Git tag');
      const tagName = 'refs/tags/' + name;
      const existing = await request(v.repository, 'GET', '/refs', {filter: 'tags/' + name});
      const found = existing.value.find(ref => ref.name === tagName);
      if (found) { check(found.objectId === target, 'Existing release tag points elsewhere; refusing to overwrite'); return; }
      const result = await request(v.repository, 'POST', '/refs', {}, [{name: tagName,
        oldObjectId: '0'.repeat(40), newObjectId: target}]);
      check(result.value?.[0]?.success === true, 'Creating versioning Git tag failed; check Create tag permission and retry finalization');
    },
    async sourceChanges(repository, commit, previous, paths) {
      check(sha(previous), 'Invalid successful source baseline');
      // Cache ranges and changed paths across service baselines in this batch.
      const cacheKey = repository + ':' + previous + ':' + commit;
      let commits = versions.get(cacheKey);
      if (!commits) {
        commits = [];
        for (let skip = 0; ; skip += 100) {
          check(skip < 10000, 'Too many commits since baseline; choose an explicit bump after review');
          const page = await request(repository, 'GET', '/commits', {
            'searchCriteria.itemVersion.version': commit, 'searchCriteria.itemVersion.versionType': 'commit',
            'searchCriteria.compareVersion.version': previous, 'searchCriteria.compareVersion.versionType': 'commit',
            'searchCriteria.$top': 100, 'searchCriteria.$skip': skip
          });
          for (const c of page.value) {
            let full = c;
            if (c.commentTruncated) full = await request(repository, 'GET', '/commits/' + c.commitId);
            commits.push({id: c.commitId, message: full.comment || ''});
          }
          if (page.value.length < 100) break;
        }
        versions.set(cacheKey, commits);
      }
      const relevant = [];
      const knownPaths = config.catalog.flatMap(s => s.paths || []);
      const matches = (file, prefix) => file === prefix.replace(/\/$/, '') || file.startsWith(prefix.endsWith('/') ? prefix : prefix + '/');
      for (const c of commits) {
        const changedKey = repository + ':changed:' + c.id;
        let files = versions.get(changedKey);
        if (!files) {
          files = [];
          for (let skip = 0; ; skip += 100) {
            check(skip < 100000, 'Commit diff is too large for automatic bump selection');
            const page = await request(repository, 'GET', '/commits/' + c.id + '/changes', {'$top': 100, '$skip': skip});
            check(Array.isArray(page.changes), 'Azure commit changes response is incomplete');
            files.push(...page.changes.flatMap(change => [change.item?.path, change.originalPath].filter(Boolean).map(p => p.replace(/^\//, ''))));
            if (page.changes.length < 100) break;
          }
          versions.set(changedKey, files);
        }
        if (!paths.length || !files.length || files.some(file => paths.some(p => matches(file, p)) || !knownPaths.some(p => matches(file, p)))) relevant.push(c);
      }
      return relevant;
    }
  };
}
module.exports = {parse, compare, bump, buildType, settings, execute, repoApi, credential, azureStore};
if (require.main === module) {
  (async () => {
    const fs = require('node:fs'), yaml = require('/config/js-yaml.js');
    const config = JSON.parse(fs.readFileSync('/config/config.json', 'utf8'));
    const release = process.env.RELEASE_JSON ? JSON.parse(process.env.RELEASE_JSON) : undefined;
    const input = {sourceCommit: process.env.SOURCE_COMMIT, sourceUrl: process.env.SOURCE_URL,
      sourceRevision: process.env.SOURCE_REVISION, buildEnvironment: process.env.BUILD_ENV, imageTag: process.env.IMAGE_TAG,
      runId: process.env.RUN_ID, runName: process.env.RUN_NAME,
      selected: process.env.SERVICES.split(','), release, gitopsCommit: process.env.GITOPS_COMMIT};
    const store = azureStore(config, fs, require('node:https'), yaml,
      fs.readFileSync(process.env.CREDENTIALS_PATH + '/.git-credentials', 'utf8'));
    const record = await execute(store, config, input, process.env.ACTION);
    if (process.env.ACTION === 'reserve') {
      const tags = Object.fromEntries(record.selected.map(name => [name, record.versions[name].version]));
      for (const [name, tag] of Object.entries(tags)) fs.writeFileSync('/tekton/results/tag-' + name, tag);
      fs.writeFileSync('/tekton/results/tags-json', JSON.stringify(tags));
    } else fs.writeFileSync('/tekton/results/product-version', record.productVersion);
    console.log('Versioning ' + process.env.ACTION + ': ' + record.environment + '/' + record.scope + ', run ' + record.runName);
    for (const name of record.selected) console.log(name + ': ' + record.versions[name].version);
  })().catch(error => { console.error(error.message); process.exitCode = 1; });
}
