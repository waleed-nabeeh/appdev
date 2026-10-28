'use strict';

const services = ['admin-portal', 'applicant-portal', 'operational-portal'];

function updateRelease(previous, env) {
  if (previous.schemaVersion !== 1 || !previous.images || typeof previous.images !== 'object' || Array.isArray(previous.images)) {
    throw new Error('Expected frontend release schemaVersion 1 with an images object');
  }
  if (!/^[0-9a-f]{40}$/.test(env.SOURCE_COMMIT)) throw new Error('Invalid full source commit');
  if (!/^[a-z0-9][a-z0-9.-]*(?::[0-9]+)?\/[a-z0-9/_-]+$/.test(env.IMAGE_REPOSITORY)) {
    throw new Error('Invalid image repository');
  }
  const tag = env.SOURCE_COMMIT.slice(0, 8);
  if (previous.imageTag === tag && previous.sourceCommit !== env.SOURCE_COMMIT) {
    throw new Error('Eight-character SHA collision; refusing to replace the previous release');
  }
  const images = {};
  for (const service of services) {
    const digest = env[service.toUpperCase().replaceAll('-', '_') + '_DIGEST'];
    if (!/^sha256:[0-9a-f]{64}$/.test(digest || '')) throw new Error('Invalid digest for ' + service);
    images[service] = {repository: env.IMAGE_REPOSITORY + '/' + service, tag, digest};
  }
  return {...previous, sourceCommit: env.SOURCE_COMMIT, imageTag: tag,
    buildEnvironment: 'dev', pipelineRun: env.RUN_NAME, images};
}

module.exports = {updateRelease};

if (require.main === module) {
  const fs = require('node:fs');
  const path = require('node:path');
  const root = '/work/repo';
  const file = path.resolve(root, process.env.RELEASE_FILE);
  if (!file.startsWith(root + '/') || fs.realpathSync(file) !== file) {
    throw new Error('Release file must be a regular path inside the GitOps checkout');
  }
  if (process.env.GITOPS_FORMAT === 'yaml') {
    const yaml = require('/config/js-yaml.js');
    const {updateCore} = require('/config/backend-gitops-update.js');
    const release = updateRelease({schemaVersion: 1, images: {}}, process.env);
    const record = {schemaVersion: 1, succeeded: true, selected: services, failed: [], notStarted: [], sourceCommit: release.sourceCommit,
      images: Object.fromEntries(services.map(name => [name, {...release.images[name], image: release.images[name].repository + '@' + release.images[name].digest}]))};
    const previous = yaml.load(fs.readFileSync(file, 'utf8'), {schema: yaml.JSON_SCHEMA, maxDepth: 100});
    const updated = updateCore(previous, record, {catalog: services.map(name => ({name})), imageRepository: process.env.IMAGE_REPOSITORY,
      applicationNamePrefix: process.env.APPLICATION_NAME_PREFIX, applicationNameSuffix: process.env.APPLICATION_NAME_SUFFIX}, release.sourceCommit);
    if (JSON.stringify(updated) !== JSON.stringify(previous)) fs.writeFileSync(file, yaml.dump(updated, {schema: yaml.JSON_SCHEMA, noRefs: true, lineWidth: -1, quotingType: '"'}));
  } else {
    const previous = JSON.parse(fs.readFileSync(file, 'utf8'));
    const release = updateRelease(previous, process.env);
    fs.writeFileSync(file, JSON.stringify(release, null, 2) + '\n');
  }
}
