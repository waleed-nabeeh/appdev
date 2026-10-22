'use strict';

const {updateRelease} = require('../../pipelines/chart/files/frontend-release-update.js');
let checks = 0;
function assert(condition, message) {
  if (!condition) throw new Error(message);
  checks++;
}
function rejects(action, message) {
  let failed = false;
  try { action(); } catch (_) { failed = true; }
  assert(failed, message);
}
const original = {schemaVersion: 1, images: {}, sourceCommit: '', imageTag: '', preserved: 'keep'};
const env = {
  SOURCE_COMMIT: 'abcdef01' + '2'.repeat(32),
  IMAGE_REPOSITORY: 'registry.example:8443/devops',
  RUN_NAME: 'frontend-release-test-123',
  ADMIN_PORTAL_DIGEST: 'sha256:' + 'a'.repeat(64),
  APPLICANT_PORTAL_DIGEST: 'sha256:' + 'b'.repeat(64),
  OPERATIONAL_PORTAL_DIGEST: 'sha256:' + 'c'.repeat(64)
};
const result = updateRelease(original, env);
assert(result.imageTag === 'abcdef01', 'Tag must be eight characters without a prefix');
assert(result.sourceCommit === env.SOURCE_COMMIT, 'Full SHA must be retained');
assert(result.buildEnvironment === 'dev', 'Build environment must stay dev');
assert(result.preserved === 'keep', 'Unrelated release metadata must survive');
assert(Object.keys(result.images).length === 3, 'All three services must be included');
assert(result.images['applicant-portal'].digest === env.APPLICANT_PORTAL_DIGEST, 'Digest must not be dropped');
assert(Object.keys(original.images).length === 0, 'Input must not be mutated');
rejects(() => updateRelease(original, {...env, SOURCE_COMMIT: 'abcdef01'}), 'Short SHA is not valid source identity');
rejects(() => updateRelease(original, {...env, OPERATIONAL_PORTAL_DIGEST: 'latest'}), 'Bad third digest must reject entire release');
rejects(() => updateRelease({...original, schemaVersion: 2}, env), 'Unknown schema must be rejected');
rejects(() => updateRelease({...original, images: []}, env), 'Array is not an image map');
rejects(() => updateRelease(original, {...env, IMAGE_REPOSITORY: '../outside'}), 'Invalid repository must be rejected');
rejects(() => updateRelease({...original, imageTag: 'abcdef01', sourceCommit: 'abcdef01' + '0'.repeat(32)}, env), 'SHA collision must be rejected');
assert(updateRelease(result, env).imageTag === 'abcdef01', 'Same-commit rerun is supported');
console.log('Passed ' + checks + ' release-update checks');
