'use strict';

function check(ok, message) { if (!ok) throw new Error(message); }
function sha(value) { return typeof value === 'string' && value.length === 40 && /^[0-9a-f]{40}$/.test(value); }
function branch(value) { return typeof value === 'string' && !/[\r\n]/.test(value) && /^[A-Za-z0-9_./-]+$/.test(value) && !value.startsWith('-'); }

function selectServices(input, catalog) {
  const names = catalog.map(s => s.name);
  check(typeof input === 'string' && input.trim(), 'Provide services as a comma-separated list or all');
  if (input.trim() === 'all') return names;
  const parts = input.split(',').map(s => s.trim());
  check(parts.every(Boolean), 'Empty service names are not allowed');
  const unique = [...new Set(parts)];
  unique.forEach(name => check(names.includes(name), 'Unknown or disabled service: ' + name));
  return unique;
}

function selectDiff(paths, catalog, fallback) {
  const all = catalog.map(s => s.name);
  if (fallback) return all;
  const selected = new Set();
  for (const path of paths) {
    if (!path) continue;
    // Only changes within an executable project's own directory are narrowly scoped.
    // Libraries/contracts, build metadata, shared code and unmapped paths affect all.
    if (/\.(csproj|props|targets|sln|slnx)$/i.test(path)) return all;
    const matches = catalog.filter(s => (s.paths || [s.containerfile.slice(0, -'Dockerfile'.length)]).some(prefix => path.startsWith(prefix)));
    if (matches.length !== 1) return all;
    selected.add(matches[0].name);
  }
  return all.filter(name => selected.has(name));
}

function serviceSettings(name, commit, revision, config) {
  const service = config.catalog.find(s => s.name === name);
  check(service, 'Unknown or disabled service: ' + name);
  check(sha(commit), 'A full source SHA is required');
  check(branch(revision), 'Invalid source branch');
  return {...service, commit, tag: commit.slice(0, 8), image: config.imageRepository + '/' + name + ':' + commit.slice(0, 8)};
}

function childName(uid, service, scope = 'backend') {
  return scope + '-' + uid.replaceAll('-', '').slice(0, 16) + '-' + service;
}

function makeChild(parent, service, commit, revision, config) {
  serviceSettings(service, commit, revision, config);
  return {
    apiVersion: 'tekton.dev/v1', kind: 'PipelineRun',
    metadata: {
      name: childName(parent.metadata.uid, service, config.scope), namespace: parent.metadata.namespace,
      labels: {'customer.mofa.gov.sa/batch': parent.metadata.name, 'customer.mofa.gov.sa/service': service},
      ownerReferences: [{apiVersion: 'tekton.dev/v1', kind: 'PipelineRun', name: parent.metadata.name, uid: parent.metadata.uid}]
    },
    spec: {
      pipelineRef: {name: config.childPipeline || 'application-backend-service-build'},
      taskRunTemplate: {serviceAccountName: config.buildServiceAccount},
      timeouts: {pipeline: config.childTimeout},
      params: [{name: 'service', value: service}, {name: 'source-commit', value: commit}, {name: 'source-revision', value: revision}],
      workspaces: [
        {name: 'source', volumeClaimTemplate: {
          metadata: {labels: {pipeline: (config.scope || 'backend') + '-dispatch', 'customer.mofa.gov.sa/batch': parent.metadata.name, 'customer.mofa.gov.sa/service': service}},
          spec: {accessModes: ['ReadWriteOnce'], resources: {requests: {storage: config.workspaceSize}}}
        }},
        {name: 'git-credentials', secret: {secretName: 'git-credentials'}},
        {name: 'registry-auth', secret: {secretName: 'registry-auth'}},
        ...(config.npmAuth ? [{name: 'npm-auth', secret: {secretName: 'npm-auth'}}] : [])
      ]
    }
  };
}

function state(run) {
  const condition = (run.status?.conditions || []).find(c => c.type === 'Succeeded');
  return condition?.status === 'True' ? 'succeeded' : condition?.status === 'False' ? 'failed' : 'running';
}

function releaseImage(run, service, commit, config) {
  check(state(run) === 'succeeded', 'Cannot approve an unsuccessful child');
  const results = Object.fromEntries((run.status?.results || []).map(r => [r.name, r.value]));
  check(results['source-commit'] === commit, 'Child source SHA mismatch');
  check(typeof results['image-digest'] === 'string' && results['image-digest'].length === 71 && /^sha256:[0-9a-f]{64}$/.test(results['image-digest']), 'Missing or invalid image digest');
  const repository = config.imageRepository + '/' + service;
  check(results['image-url'] === repository + ':' + commit.slice(0, 8) + '@' + results['image-digest'], 'Unexpected child image reference');
  return {repository, tag: commit.slice(0, 8), digest: results['image-digest'], image: repository + '@' + results['image-digest'], run: run.metadata.name};
}

async function dispatch({api, sleep, now, parent, config, selected, commit, revision}) {
  check(sha(commit) && branch(revision), 'Invalid source identity');
  check(Array.isArray(selected) && selected.length <= config.catalog.length, 'Invalid service selection');
  check(new Set(selected).size === selected.length, 'Duplicate services');
  selected.forEach(s => serviceSettings(s, commit, revision, config));
  check(Number.isInteger(config.maxParallel) && config.maxParallel > 0, 'Invalid maxParallel');
  check(Number.isInteger(config.timeoutSeconds) && config.timeoutSeconds > 0, 'Invalid timeoutSeconds');
  const prefix = '/apis/tekton.dev/v1/namespaces/' + parent.metadata.namespace + '/pipelineruns';
  const owner = parent.metadata.uid;
  const active = new Map();
  const done = new Map();
  const pending = [];
  const deadline = now() + config.timeoutSeconds * 1000;
  const read = async name => { try { return await api('GET', prefix + '/' + name); } catch (e) { if (e.status === 404) return null; throw e; } };
  const owned = (run, service) => {
    check(run.metadata.ownerReferences?.some(r => r.uid === owner), 'Child ownership mismatch');
    const p = Object.fromEntries(run.spec.params.map(x => [x.name, x.value]));
    check(p.service === service && p['source-commit'] === commit && p['source-revision'] === revision, 'Existing child parameters differ');
    check(run.spec.pipelineRef?.name === (config.childPipeline || 'application-backend-service-build'), 'Unexpected child pipeline');
  };
  // Deterministic names reuse already-created children after a dispatcher retry.
  for (const service of selected) {
    const existing = await read(childName(owner, service, config.scope));
    if (!existing) pending.push(service);
    else {
      owned(existing, service);
      (state(existing) === 'running' ? active : done).set(service, existing);
    }
  }
  let failure = [...done.values()].some(r => state(r) === 'failed');
  try {
    while (pending.length || active.size) {
      check(now() < deadline, 'Dispatcher timeout');
      const current = await read(parent.metadata.name);
      check(current && !current.metadata.deletionTimestamp && !current.spec.status && state(current) !== 'failed', 'Parent cancelled or deleted');
      while (!failure && pending.length && active.size < config.maxParallel) {
        const service = pending.shift();
        let child;
        try { child = await api('POST', prefix, makeChild(parent, service, commit, revision, config)); }
        catch (e) { if (e.status !== 409) throw e; child = await read(childName(owner, service, config.scope)); }
        check(child, 'Child creation was not confirmed');
        owned(child, service);
        active.set(service, child);
      }
      for (const [service, child] of active) {
        const currentChild = await read(child.metadata.name);
        check(currentChild, 'Child was deleted during the batch: ' + child.metadata.name);
        owned(currentChild, service);
        if (state(currentChild) !== 'running') {
          done.set(service, currentChild);
          active.delete(service);
          if (state(currentChild) === 'failed') failure = true;
        }
      }
      if (failure && !active.size) break;
      if (active.size || pending.length) await sleep(10000);
    }
  } catch (error) {
    for (const child of active.values()) {
      try { await api('PATCH', prefix + '/' + child.metadata.name, {spec: {status: 'Cancelled'}}); } catch (_) { /* Owner deletion and child timeouts remain fallback protection. */ }
    }
    throw error;
  }
  const record = {schemaVersion: 1, sourceCommit: commit, sourceRevision: revision, batch: parent.metadata.name,
    succeeded: !failure && done.size === selected.length, selected, images: {}, failed: [], notStarted: pending};
  for (const service of selected) {
    const run = done.get(service);
    if (!run) continue;
    if (state(run) === 'succeeded') record.images[service] = releaseImage(run, service, commit, config);
    else record.failed.push({service, run: run.metadata.name});
  }
  const name = (config.scope || 'backend') + '-result-' + owner.replaceAll('-', '').slice(0, 16);
  const cmPath = '/api/v1/namespaces/' + parent.metadata.namespace + '/configmaps';
  const cm = {apiVersion: 'v1', kind: 'ConfigMap', metadata: {name, namespace: parent.metadata.namespace,
    ownerReferences: [{apiVersion: 'tekton.dev/v1', kind: 'PipelineRun', name: parent.metadata.name, uid: owner}]},
    immutable: true, data: {'release.json': JSON.stringify(record, null, 2)}};
  try { await api('POST', cmPath, cm); }
  catch (e) {
    if (e.status !== 409) throw e;
    const previous = await api('GET', cmPath + '/' + name);
    check(previous.data?.['release.json'] === cm.data['release.json'] && previous.metadata.ownerReferences?.some(r => r.uid === owner), 'Existing batch record differs');
  }
  return {name, record};
}

function kubeClient(fs, https) {
  const base = '/var/run/secrets/kubernetes.io/serviceaccount/';
  return (method, path, body) => new Promise((resolve, reject) => {
    const data = body ? JSON.stringify(body) : undefined;
    const request = https.request({hostname: process.env.KUBERNETES_SERVICE_HOST,
      port: Number(process.env.KUBERNETES_SERVICE_PORT_HTTPS || 443), path, method,
      ca: fs.readFileSync(base + 'ca.crt'), rejectUnauthorized: true,
      headers: {Authorization: 'Bearer ' + fs.readFileSync(base + 'token', 'utf8').trim(),
        'Content-Type': method === 'PATCH' ? 'application/merge-patch+json' : 'application/json'}}, response => {
      let output = '';
      response.on('data', chunk => { output += chunk; });
      response.on('end', () => {
        if (response.statusCode < 200 || response.statusCode >= 300) {
          const error = new Error(method + ' Kubernetes API request failed: HTTP ' + response.statusCode);
          error.status = response.statusCode; reject(error); return;
        }
        try { resolve(JSON.parse(output)); } catch (e) { reject(e); }
      });
    });
    request.on('error', reject);
    request.setTimeout(30000, () => request.destroy(new Error('Kubernetes API timeout')));
    request.end(data);
  });
}

module.exports = {selectServices, selectDiff, serviceSettings, makeChild, state, releaseImage, dispatch, kubeClient};

if (require.main === module) {
  (async () => {
    const fs = require('node:fs');
    const config = JSON.parse(fs.readFileSync('/config/config.json', 'utf8'));
    if (process.env.ACTION === 'select') {
      const commit = fs.readFileSync('/work/commit', 'utf8');
      check(sha(commit), 'Invalid resolved SHA');
      const selected = process.env.MODE === 'manual' ? selectServices(process.env.SERVICES, config.catalog) :
        selectDiff(fs.readFileSync('/work/changed', 'utf8').split('\0'), config.catalog, fs.existsSync('/work/all-services'));
      fs.writeFileSync('/tekton/results/services', JSON.stringify(selected));
      fs.writeFileSync('/tekton/results/commit', commit);
      console.log('Selected services: ' + (selected.join(',') || '(none)'));
    } else if (process.env.ACTION === 'prepare') {
      const service = serviceSettings(process.env.SERVICE, process.env.COMMIT, process.env.REVISION, config);
      for (const key of ['project', 'containerfile', 'context', 'image', 'commit']) fs.writeFileSync('/tekton/results/' + key, service[key]);
    } else if (process.env.ACTION === 'dispatch') {
      const api = kubeClient(fs, require('node:https'));
      const parent = await api('GET', '/apis/tekton.dev/v1/namespaces/' + process.env.NAMESPACE + '/pipelineruns/' + process.env.PARENT);
      const result = await dispatch({api, sleep: ms => new Promise(r => setTimeout(r, ms)), now: Date.now,
        parent, config, selected: JSON.parse(process.env.SELECTED), commit: process.env.COMMIT, revision: process.env.REVISION});
      fs.writeFileSync('/tekton/results/release-record', result.name);
      console.log('Batch record: ' + result.name);
      check(result.record.succeeded, 'A child build failed; remaining queued services were not started. Inspect the batch record.');
    } else throw new Error('Unknown dispatcher action');
  })().catch(error => { console.error(error.message); process.exitCode = 1; });
}
