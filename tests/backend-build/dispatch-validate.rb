#!/usr/bin/env ruby
require_relative 'validate'
require 'fileutils'

overlay = ['-f', 'customer-transfer/backend-build-fanout/values-backend.yaml']
enabled = render(*overlay)
disabled = render(*overlay, '--set', 'backendBuild.dispatch.enabled=false')
disabled.each do |old|
  check(enabled.find { |d| d['kind'] == old['kind'] && d['metadata']['name'] == old['metadata']['name'] } == old,
        "Dispatcher changed existing resource #{old['metadata']['name']}")
end
config = enabled.find { |d| d['kind'] == 'ConfigMap' && d['metadata']['name'] == 'backend-dispatch-config' }
settings = JSON.parse(config['data']['config.json'])
check(settings['catalog'].size == 14 && settings['workspaceSize'] == '3Gi' && settings['maxParallel'] == 3, 'Dispatcher settings')
definitions = enabled.select { |d| d['kind'] == 'Task' }.to_h { |d| [d['metadata']['name'], d['spec']] }
%w[application-backend-dispatch application-backend-service-build].each do |name|
  spec = enabled.find { |d| d['kind'] == 'Pipeline' && d['metadata']['name'] == name }['spec']
  tasks = spec['tasks']
  tasks.each do |task|
    definition = definitions.fetch(task['taskRef']['name'])
    params = task.fetch('params', []).map { |p| p['name'] }
    check((params - definition.fetch('params', []).map { |p| p['name'] }).empty?, 'Unknown Task param')
    definition.fetch('params', []).reject { |p| p.key?('default') }.each { |p| check(params.include?(p['name']), 'Required param missing') }
    check(task.fetch('runAfter', []).all? { |n| tasks.any? { |t| t['name'] == n } }, 'Missing dependency')
    definition.fetch('workspaces', []).reject { |w| w['optional'] }.each do |w|
      check(task.fetch('workspaces', []).any? { |b| b['name'] == w['name'] && spec['workspaces'].any? { |s| s['name'] == b['workspace'] } }, 'Workspace binding missing')
    end
  end
  spec.to_json.scan(/\$\(tasks\.([^.]+)\.results\.([^)]+)\)/).each do |producer, result|
    task = tasks.find { |t| t['name'] == producer }
    check(task && definitions.fetch(task['taskRef']['name']).fetch('results', []).any? { |r| r['name'] == result }, 'Missing result producer')
  end
  check(tasks.none? { |t| t['name'].match?(/verify|gitops/) }, 'Build must not promote')
end
run = YAML.safe_load(File.read('customer-transfer/backend-build-fanout/pipelinerun-dispatch.yaml'))
check(run['spec']['workspaces'].none? { |w| w['volumeClaimTemplate'] }, 'Parent must not allocate PVCs')
check(run['spec']['taskRunTemplate']['serviceAccountName'] == 'backend-dispatcher', 'Parent SA')
check(enabled.none? { |d| d['metadata']['name'] == 'backend-pr-webhook' }, 'Triggers must default off')
triggered = render(*overlay, '--set', 'backendBuild.dispatch.triggers.enabled=true')
listener = triggered.find { |d| d['kind'] == 'EventListener' && d['metadata']['name'] == 'backend-pr' }
check(listener.to_json.include?('compareSecret') && listener.to_json.include?('lastMergeTargetCommit'), 'Authenticated pinned PR')
route = triggered.find { |d| d['kind'] == 'Route' && d['metadata']['name'] == 'backend-pr-webhook' }
check(route['spec']['tls']['termination'] == 'edge', 'HTTPS route')
_, err, status = Open3.capture3('sh', '-n', 'pipelines/chart/files/backend-select-source.sh')
check(status.success?, err)
Dir.mktmpdir do |tmp|
  repo = File.join(tmp, 'source')
  credentials = File.join(tmp, 'credentials')
  FileUtils.mkdir_p([repo, credentials])
  git = lambda do |*args|
    out, error, result = Open3.capture3('git', '-C', repo, *args)
    check(result.success?, error)
    out.strip
  end
  git.call('init', '-b', 'test')
  git.call('config', 'user.email', 'test@example.invalid')
  git.call('config', 'user.name', 'Dispatcher Test')
  File.write(File.join(repo, 'base.txt'), 'base')
  git.call('add', '.')
  git.call('commit', '-m', 'base')
  base = git.call('rev-parse', 'HEAD')
  FileUtils.mkdir_p(File.join(repo, 'services/acl/Api'))
  File.write(File.join(repo, 'services/acl/Api/controller.cs'), 'test')
  git.call('add', '.')
  git.call('commit', '-m', 'service change')
  head = git.call('rev-parse', 'HEAD')
  %w[manual diff].each do |mode|
    work = File.join(tmp, mode)
    FileUtils.mkdir_p(work)
    script = File.join(work, 'source.sh')
    File.write(script, File.read('pipelines/chart/files/backend-select-source.sh').gsub('/work', work))
    env = {'HOME' => File.join(work, 'home'), 'CREDENTIALS_PATH' => credentials, 'MODE' => mode,
           'REVISION' => 'test', 'COMMIT' => mode == 'manual' ? '' : head, 'TARGET_COMMIT' => base, 'SOURCE_URL' => repo}
    _, error, result = Open3.capture3(env, 'sh', script)
    check(result.success?, error)
    check(File.read(File.join(work, 'commit')) == head, 'Resolved wrong source SHA')
    if mode == 'diff'
      check(File.binread(File.join(work, 'changed')) == "services/acl/Api/controller.cs\0", 'Wrong merge-base diff')
    end
  end
end
puts 'Passed dispatcher isolation, allowlist, Task references, workspaces, manual run and optional trigger rendering'
puts 'Passed real local Git branch resolution and merge-base diff checks'
