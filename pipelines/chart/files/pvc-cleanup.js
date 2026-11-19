'use strict';

const selector = 'pipeline in (backend-build-fanout,frontend-build-fanout)';
async function cleanup(api, namespace, dryRun = false, log = console.log) {
  const base = '/api/v1/namespaces/' + encodeURIComponent(namespace);
  async function list(path) {
    const items = [];
    let cursor = '';
    do {
      const page = await api('GET', path + (path.includes('?') ? '&' : '?') +
        'limit=200' + (cursor ? '&continue=' + encodeURIComponent(cursor) : ''));
      items.push(...page.items);
      cursor = page.metadata?.continue || '';
    } while (cursor);
    return items;
  }
  async function get(path) {
    try { return await api('GET', path); }
    catch (e) { if (e.status === 404) return null; throw e; }
  }
  let deleted = 0;
  const claims = await list(base + '/persistentvolumeclaims?labelSelector=' + encodeURIComponent(selector));
  for (const candidate of claims) {
    const path = base + '/persistentvolumeclaims/' + encodeURIComponent(candidate.metadata.name);
    const claim = await get(path);
    if (!claim || claim.metadata.deletionTimestamp) continue;
    const scope = claim.metadata.labels?.pipeline;
    if (!['backend-build-fanout', 'frontend-build-fanout'].includes(scope)) continue;
    const owner = claim.metadata.ownerReferences?.find(o =>
      o.kind === 'PipelineRun' && /^tekton\.dev\/v1(beta1)?$/.test(o.apiVersion) && o.controller === true);
    if (!owner || !owner.name.startsWith(scope + '-')) {
      log('SKIP ' + claim.metadata.name + ': no matching build PipelineRun owner'); continue;
    }
    const run = await get('/apis/tekton.dev/v1/namespaces/' + encodeURIComponent(namespace) +
      '/pipelineruns/' + encodeURIComponent(owner.name));
    if (!run || run.metadata.uid !== owner.uid || !run.status?.completionTime ||
        !run.status.conditions?.some(c => c.type === 'Succeeded' && ['True', 'False'].includes(c.status))) {
      log('SKIP ' + claim.metadata.name + ': owner absent, changed or unfinished'); continue;
    }
    const pods = await list(base + '/pods');
    if (pods.some(p => !['Succeeded', 'Failed'].includes(p.status?.phase) &&
        p.spec?.volumes?.some(v => v.persistentVolumeClaim?.claimName === claim.metadata.name))) {
      log('SKIP ' + claim.metadata.name + ': referenced by an active pod'); continue;
    }
    if (dryRun) { log('WOULD DELETE ' + claim.metadata.name); continue; }
    try {
      await api('DELETE', path, {apiVersion: 'v1', kind: 'DeleteOptions', preconditions: {
        uid: claim.metadata.uid, resourceVersion: claim.metadata.resourceVersion
      }});
      deleted++;
      log('DELETE REQUESTED ' + claim.metadata.name);
    } catch (e) {
      if (![404, 409].includes(e.status)) throw e;
      log('SKIP ' + claim.metadata.name + ': disappeared or changed during cleanup');
    }
  }
  log('Completed: ' + deleted + ' PVC deletion requests; dryRun=' + dryRun);
}
module.exports = {cleanup};
if (require.main === module) {
  const {kubeClient} = require('./backend-dispatch.js');
  cleanup(kubeClient(require('node:fs'), require('node:https')), process.env.NAMESPACE,
    process.env.DRY_RUN === 'true').catch(error => { console.error(error.message); process.exitCode = 1; });
}
