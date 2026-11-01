#!/usr/bin/env ruby
require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
Dir.chdir(File.expand_path('../..', __dir__))
def check(ok, message)
  raise message unless ok
end
def run(*cmd)
  out, err, status = Open3.capture3(*cmd)
  check(status.success?, "#{cmd.first}: #{err}")
  out
end
command = %w[helm template release-pipeline pipelines/chart -n devops -f customer-transfer/application-build/values.yaml]
docs = YAML.load_stream(run(*command)).compact
%w[backend frontend].each do |scope|
  find = ->(kind, name) { docs.find { |d| d['kind'] == kind && d['metadata']['name'] == name } || raise("Missing #{kind}/#{name}") }
  pipeline = find.call('Pipeline', "application-#{scope}-promotion")['spec']
  phases = %w[read-release-manifest get-approved-artifacts verify-image update-gitops]
  definitions = phases.to_h { |phase| [phase, find.call('Task', "#{scope}-promotion-#{phase}")['spec']] }
  config = JSON.parse(find.call('ConfigMap', "#{scope}-promotion-code")['data']['promotion.json'])
  check(config['catalog'].size == (scope == 'backend' ? 14 : 3), 'Promotion catalog must match current build allowlist')
  check(config['sourceFile'] == "app-chart/#{scope}.yaml", 'Wrong preprod source')
  check(config['targets'].map { |t| t['file'] } == ["app-chart/prod-#{scope}.yaml", "app-chart/dr-#{scope}.yaml"], 'Wrong target files')
  check(config['targets'].all? { |t| t['applicationPrefix'] == config['sourcePrefix'] }, 'Current test must preserve application names')
  check(pipeline['params'].find { |p| p['name'] == 'services' }['default'] == config['catalog'].map { |s| s['name'] }.join(','), 'Missing UI defaults')
  check(pipeline.fetch('workspaces', []).empty?, 'No manual workspace inputs for promotion')
  check(pipeline['tasks'].map { |t| t['name'] } == phases, 'Design stages must be separate graph Tasks')
  phases.each_cons(2) { |a,b| check(pipeline['tasks'].find { |t| t['name'] == b }['runAfter'] == [a], 'Verification must block later Tasks') }
  verifier = definitions.fetch('verify-image')
  check(verifier.to_json.include?('$repository@$digest') && !pipeline.to_json.include?('argocd-sync'), 'Verify the resolved digest; no automatic Argo sync')
  check(verifier['steps'].find { |s| s['name'] == 'verify-images' }['env'].any? { |e| e['name'] == 'HOME' && e['value'] == '/tmp/promotion-rhtas-home' }, 'Verifier needs its own writable HOME')
  check(definitions.fetch('read-release-manifest').to_json.include?('git show') && definitions.fetch('update-gitops').to_json.include?('Concurrent change'), 'Pin approved source and reject intervening file changes')
  pipeline['tasks'].each do |t|
    task = definitions.fetch(t['name'])
    check(t.dig('taskRef', 'name') == "#{scope}-promotion-#{t['name']}", 'Wrong promotion Task')
    check(t['params'].all? { |p| task['params'].any? { |declared| declared['name'] == p['name'] } }, 'Unknown Task parameter')
    check(task['params'].reject { |p| p.key?('default') }.all? { |p| t['params'].any? { |v| v['name'] == p['name'] } }, 'Missing artifact input')
    check(task.fetch('workspaces', []).empty? && task['volumes'].none? { |v| v['persistentVolumeClaim'] }, 'Promotion must use no PVC')
    check(!t['onError'] && task['steps'].none? { |s| s['onError'] }, 'Failure must block all target updates')
    task.to_json.scan(/\$\(params\.([^)]+)\)/).flatten.each { |p| check(task['params'].any? { |v| v['name'] == p }, 'Unknown Task param reference') }
    task['steps'].each do |step|
      next unless step['script']
      Dir.mktmpdir do |tmp|
        script = File.join(tmp, 'script')
        File.write(script, step['script'])
        run('bash', '-n', script)
      end
    end
  end
  pipeline.to_json.scan(/\$\(tasks\.([^.]+)\.results\.([^)]+)\)/).each do |producer, result|
    check(definitions.fetch(producer).fetch('results').any? { |r| r['name'] == result }, 'Invalid Task result data flow')
  end
  update = definitions.fetch('update-gitops')
  check(update['steps'].map { |s| s['name'] } == %w[read-preproduction plan-promotion recheck-tags update-gitops push-production-and-dr], 'Recheck tags before writing targets')
  check(pipeline['tasks'].last['params'].any? { |p| p['name'] == 'verified-digests' && p['value'] == '$(tasks.verify-image.results.digests)' }, 'Only verified artifact results may update GitOps')
end
disabled = YAML.load_stream(run('helm', 'template', 'release-pipeline', 'pipelines/chart')).compact
check(disabled.none? { |d| d['metadata']['name'].include?('-promotion-read-release-manifest') }, 'New promotion must default off outside customer values')
Dir.mktmpdir do |tmp|
  FileUtils.mkdir_p(File.join(tmp, 'work'))
  FileUtils.mkdir_p(File.join(tmp, 'credentials/registry'))
  File.write(File.join(tmp, 'credentials/registry/config.json'), '{}')
  FileUtils.mkdir_p(File.join(tmp, 'bin'))
  File.write(File.join(tmp, 'bin/skopeo'), "#!/bin/sh\nprintf '%s\\n' \"$TEST_DIGEST\"\n")
  File.chmod(0755, File.join(tmp, 'bin/skopeo'))
  File.write(File.join(tmp, 'work/images.tsv'), "acl-service\tquay.example/devops/acl-service\tapproved-tag\n")
  script = File.join(tmp, 'resolve.sh')
  File.write(script, File.read('pipelines/chart/files/promotion-resolve.sh').gsub('/work', File.join(tmp, 'work')).gsub('/credentials', File.join(tmp, 'credentials')))
  env = {'PATH' => File.join(tmp, 'bin') + ':' + ENV.fetch('PATH'), 'MODE' => 'resolve', 'TEST_DIGEST' => 'sha256:' + 'a' * 64}
  _, err, status = Open3.capture3(env, 'sh', script)
  check(status.success?, err)
  _, err, status = Open3.capture3(env.merge('MODE' => 'recheck'), 'sh', script)
  check(status.success?, err)
  _, _, status = Open3.capture3(env.merge('MODE' => 'recheck', 'TEST_DIGEST' => 'sha256:' + 'b' * 64), 'sh', script)
  check(!status.success?, 'A tag changed after verification must block promotion')
  _, _, status = Open3.capture3(env.merge('TEST_DIGEST' => 'invalid'), 'sh', script)
  check(!status.success?, 'Invalid registry digest must block promotion')
end
puts 'Passed promotion Helm references, defaults, same-name targets, no-PVC flow, shell syntax and tag-race rejection'
Dir.mktmpdir do |tmp|
  remote = File.join(tmp, 'remote.git')
  seed = File.join(tmp, 'seed')
  run('git', 'init', '--bare', remote)
  run('git', 'init', '-b', 'dev', seed)
  run('git', '-C', seed, 'config', 'user.name', 'Test')
  run('git', '-C', seed, 'config', 'user.email', 'test@example.invalid')
  files = %w[backend.yaml prod-backend.yaml dr-backend.yaml frontend.yaml prod-frontend.yaml dr-frontend.yaml]
  files.each { |f| File.write(File.join(seed, f), f + '-old') }
  run('git', '-C', seed, 'add', '.')
  run('git', '-C', seed, 'commit', '-m', 'seed')
  run('git', '-C', seed, 'remote', 'add', 'origin', remote)
  run('git', '-C', seed, 'push', '-u', 'origin', 'dev')
  base = run('git', '-C', seed, 'rev-parse', 'HEAD').strip
  %w[back front stale noop].each do |name|
    run('git', 'clone', '-b', 'dev', remote, File.join(tmp, name))
  end
  push = lambda do |name, scope|
    work = File.join(tmp, 'work-' + name)
    FileUtils.mkdir_p(work)
    FileUtils.mkdir_p(File.join(work, 'results'))
    File.write(File.join(work, 'source-commit'), base)
    File.write(File.join(work, 'targets.txt'), "prod-#{scope}.yaml\ndr-#{scope}.yaml\n")
    File.write(File.join(work, 'watched.txt'), "#{scope}.yaml\nprod-#{scope}.yaml\ndr-#{scope}.yaml\n")
    script = File.join(work, 'push.sh')
    code = File.read('pipelines/chart/files/promotion-push.sh').gsub('/work/repo', File.join(tmp, name))
      .gsub('/work/', work + '/').gsub('/tekton/results/', File.join(work, 'results') + '/')
    File.write(script, code)
    _, err, result = Open3.capture3({'SCOPE' => scope, 'GITOPS_BRANCH' => 'dev'}, 'sh', script)
    [result.success?, err]
  end
  %w[prod-frontend.yaml dr-frontend.yaml].each { |f| File.write(File.join(tmp, 'front', f), 'frontend-new') }
  success, error = push.call('front', 'frontend')
  check(success, error)
  %w[prod-backend.yaml dr-backend.yaml].each { |f| File.write(File.join(tmp, 'back', f), 'backend-new') }
  success, error = push.call('back', 'backend')
  check(success, error)
  %w[prod-frontend.yaml dr-frontend.yaml].each { |f| check(run('git', '--git-dir', remote, 'show', 'dev:' + f) == 'frontend-new', 'Lost concurrent frontend promotion') }
  %w[prod-backend.yaml dr-backend.yaml].each { |f| check(run('git', '--git-dir', remote, 'show', 'dev:' + f) == 'backend-new', 'Both backend target files must be committed') }
  check(run('git', '--git-dir', remote, 'diff-tree', '--no-commit-id', '--name-only', '-r', 'dev').lines.map(&:strip).sort == %w[dr-backend.yaml prod-backend.yaml], 'Promotion must commit both target files together')
  %w[prod-backend.yaml dr-backend.yaml].each { |f| File.write(File.join(tmp, 'stale', f), 'stale-backend') }
  success, = push.call('stale', 'backend')
  check(!success, 'Concurrent changes to target files must fail closed')
  success, = push.call('noop', 'backend')
  check(!success, 'A stale no-change promotion must not claim current targets match')
  check(run('git', '--git-dir', remote, 'show', 'dev:backend.yaml') == 'backend.yaml-old', 'Source was modified')
  # Pin an older approved source while retaining the latest target definitions.
  run('git', '-C', seed, 'pull', '--ff-only', 'origin', 'dev')
  File.write(File.join(seed, 'backend.yaml'), 'newer-preproduction-source')
  run('git', '-C', seed, 'commit', '-am', 'new preproduction source')
  run('git', '-C', seed, 'push', 'origin', 'dev')
  work = File.join(tmp, 'read-work')
  credentials = File.join(tmp, 'read-credentials')
  results = File.join(tmp, 'read-results')
  [work, credentials, results].each { |d| FileUtils.mkdir_p(d) }
  definition = docs.find { |d| d['kind'] == 'Task' && d['metadata']['name'] == 'backend-promotion-read-release-manifest' }
  source_step = definition['spec']['steps'].find { |s| s['name'] == 'read-preproduction' }['script']
  source_step = source_step.gsub('/work', work).gsub('/credentials/git', credentials).gsub('/tekton/results', results)
  filename = File.join(tmp, 'read-source.sh')
  File.write(filename, source_step)
  env = {'HOME' => File.join(tmp, 'read-home'), 'GITOPS_URL' => remote, 'GITOPS_BRANCH' => 'dev', 'SOURCE_FILE' => 'backend.yaml', 'APPROVED_COMMIT' => base, 'EMIT_SOURCE_RESULTS' => 'true'}
  _, err, status = Open3.capture3(env, 'sh', filename)
  check(status.success?, err)
  check(File.read(File.join(work, 'approved-source.yaml')) == 'backend.yaml-old', 'Promotion must read the pinned source revision')
  check(File.read(File.join(work, 'repo/backend.yaml')) == 'newer-preproduction-source' && File.read(File.join(work, 'repo/prod-backend.yaml')) == 'backend-new', 'Historical source must not reset current target state')
  check(File.read(File.join(results, 'source-commit')) == base && File.read(File.join(results, 'base-commit')).size == 40, 'Read Task must emit the pinned source and current base for the update Task')
  update_work = File.join(tmp, 'update-work')
  FileUtils.mkdir_p(update_work)
  File.write(filename, source_step.gsub(work, update_work))
  _, error, status = Open3.capture3(env.merge('HOME' => File.join(tmp, 'update-home'),
    'EXPECTED_BASE' => base, 'PROD_FILE' => 'prod-backend.yaml', 'DR_FILE' => 'dr-backend.yaml'), 'sh', filename)
  check(!status.success? && error.include?('Concurrent change'), 'Fresh update Task must reject source/target changes since the read Task')
end
puts 'Passed real local Git promotion: paired target commit, parallel scope merge, approved source pinning and stale target/no-op rejection'
