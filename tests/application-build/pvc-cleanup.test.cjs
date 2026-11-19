'use strict';
const assert = require('node:assert/strict');
const {cleanup} = require('../../pipelines/chart/files/pvc-cleanup');
function claim(name, overrides = {}) {
  return {metadata: {name, uid: name + '-uid', resourceVersion: '4',
    labels: {pipeline: 'backend-build-fanout'},
    ownerReferences: [{apiVersion: 'tekton.dev/v1', kind: 'PipelineRun', controller: true,
      name: 'backend-build-fanout-' + name, uid: name + '-owner'}], ...overrides}};
}
module.exports = (async () => {
  const claims = ['success', 'failed', 'running', 'mounted', 'uid-changed', 'missing', 'conflict'].map(n => claim(n));
  claims.push(claim('foreign', {labels: {pipeline: 'other'}}), claim('orphan', {ownerReferences: []}),
    claim('terminating', {deletionTimestamp: '2026-11-19T00:00:00Z'}));
  claims.push(claim('frontend', {labels: {pipeline: 'frontend-build-fanout'}, ownerReferences: [{
    apiVersion: 'tekton.dev/v1beta1', kind: 'PipelineRun', controller: true,
    name: 'frontend-build-fanout-frontend', uid: 'frontend-owner'
  }]}));
  const calls = [];
  const api = async (method, path, body) => {
    calls.push({method, path, body});
    const url = new URL(path, 'https://kubernetes');
    const name = url.pathname.split('/').at(-1);
    if (method === 'DELETE') {
      assert.deepEqual(body.preconditions, {uid: name + '-uid', resourceVersion: '4'});
      assert.equal(body.kind, 'DeleteOptions');
      assert(!JSON.stringify(body).includes('finalizers'));
      if (name === 'conflict') throw Object.assign(new Error('changed'), {status: 409});
      return {};
    }
    if (url.pathname.endsWith('/persistentvolumeclaims')) {
      assert(url.searchParams.get('labelSelector').includes('backend-build-fanout'));
      return url.searchParams.has('continue') ? {metadata: {}, items: claims.slice(3)} :
        {metadata: {continue: 'page 2'}, items: claims.slice(0, 3)};
    }
    if (url.pathname.includes('/persistentvolumeclaims/')) return claims.find(c => c.metadata.name === name);
    if (url.pathname.endsWith('/pods')) return {metadata: {}, items: [
      {status: {phase: 'Running'}, spec: {volumes: [{persistentVolumeClaim: {claimName: 'mounted'}}]}},
      {status: {phase: 'Succeeded'}, spec: {volumes: [{persistentVolumeClaim: {claimName: 'success'}}]}}
    ]};
    if (url.pathname.includes('/pipelineruns/')) {
      const id = name.replace(/^(backend|frontend)-build-fanout-/, '');
      if (id === 'missing') throw Object.assign(new Error('absent'), {status: 404});
      return {metadata: {uid: id === 'uid-changed' ? 'replaced-owner' : id + '-owner'}, status: {
        ...(id === 'running' ? {} : {completionTime: '2026-11-19T00:00:00Z'}),
        conditions: [{type: 'Succeeded', status: id === 'running' ? 'Unknown' : id === 'failed' ? 'False' : 'True'}]
      }};
    }
    throw new Error('Unexpected request: ' + path);
  };
  await cleanup(api, 'devops', true, () => {});
  assert.equal(calls.filter(c => c.method === 'DELETE').length, 0, 'Dry run must not delete');
  calls.length = 0;
  await cleanup(api, 'devops', false, () => {});
  assert.deepEqual(calls.filter(c => c.method === 'DELETE').map(c => c.path.split('/').at(-1)),
    ['success', 'failed', 'conflict', 'frontend']);
  await assert.rejects(cleanup(async () => { throw Object.assign(new Error('forbidden'), {status: 403}); },
    'devops', false, () => {}), /forbidden/);
  console.log('PASS: PVC cleanup pagination, dry run, completed owners, active-pod protection, UID/version preconditions and API errors');
})();
