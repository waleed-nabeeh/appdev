#!/usr/bin/env ruby
require 'yaml'
require 'json'
require 'open3'
Dir.chdir(File.expand_path('../..', __dir__))
def check(ok, message)
  raise message unless ok
end
def render(*flags)
  out, err, status = Open3.capture3('helm', 'template', 'release-pipeline', './pipelines/chart', '-n', 'devops', '-f', 'customer-transfer/application-build/values.yaml', *flags)
  check(status.success?, err)
  YAML.load_stream(out).compact
end
docs = render
index = docs.to_h { |d| [[d['kind'], d['metadata']['name']], d] }
inactive = render('--set', 'remoteBuild.useForApplicationBuilds=false')
inactive_index = inactive.to_h { |d| [[d['kind'], d['metadata']['name']], d] }
render('--set', 'remoteBuild.enabled=false', '--set', 'remoteBuild.useForApplicationBuilds=false').each do |doc|
  check(inactive_index[[doc['kind'], doc['metadata']['name']]] == doc, 'Existing resources changed before DMZ activation')
end
task = index.fetch(['Task', 'build-image-dmz'])['spec']
check(task['steps'][0]['env'].find { |e| e['name'] == 'DMZ_MAX_BUILDS' }['value'] == '14', 'Customer VM concurrency must render as 14')
%w[0 -1 1.5 invalid].each do |limit|
  _, err, status = Open3.capture3('helm', 'template', 'release-pipeline', './pipelines/chart', '-f', 'customer-transfer/application-build/values.yaml', '--set', "remoteBuild.maxParallel=#{limit}")
  check(!status.success? && err.include?('remoteBuild.maxParallel must be a positive integer'), "Invalid concurrency accepted: #{limit}")
end
legacy = index.fetch(['Task', 'build-image'])['spec']
check(task['results'] == legacy['results'], 'Task results must be preserved')
check(task['workspaces'].reject { |w| w['name'] == 'nuget-auth' } == legacy['workspaces'], 'Legacy workspaces must be preserved')
check(task['workspaces'].include?({'name' => 'nuget-auth', 'optional' => true}), 'NuGet workspace must be optional')
check(task['params'].reject { |p| %w[diagnostic-base-image nuget-credential-url].include?(p['name']) } == legacy['params'], 'Legacy build params must be preserved')
check(task['params'].find { |p| p['name'] == 'diagnostic-base-image' }['default'] == '', 'Diagnostics must be opt-in for normal application builds')
check(!task.to_json.include?('capabilities'), 'Remote build must not require privileges')
check(task['steps'][0]['env'].none? { |e| e.key?('valueFrom') }, 'Proxy values must be transferred as files, not injected into Hub environment')
check(task['volumes'].any? { |v| v.dig('secret', 'secretName') == 'pipeline-proxy' }, 'Reuse existing proxy Secret')
check(task['steps'][0]['image'].end_with?('/devops/alpine-git:2026-10-07'), 'Reuse approved Git/SSH image')
%w[backend frontend].each do |scope|
  pipeline = index.fetch(['Pipeline', "application-#{scope}-dmz-test"])['spec']
  check(pipeline['tasks'].map { |t| t['name'] } == %w[clone build], 'Smoke test must not deploy')
  diagnostic = pipeline['params'].find { |p| p['name'] == 'diagnostic-base-image' }['default']
  check(diagnostic == '', 'Base-image diagnostics must be opt-in for both smoke tests')
  check(pipeline['tasks'].last.dig('taskRef', 'name') == 'build-image-dmz', 'Smoke test must build remotely')
  run = YAML.safe_load(index.fetch(['ConfigMap', "#{scope}-dmz-test-run-template"])['data']['pipelinerun.yaml'])
  check(run.dig('spec', 'pipelineRef', 'name') == "application-#{scope}-dmz-test", 'Wrong run template')
end
active = docs
%w[backend frontend].each do |scope|
  pipeline = active.find { |d| d['kind'] == 'Pipeline' && d['metadata']['name'] == "application-#{scope}-build-fanout" }
  builds = pipeline['spec']['tasks'].select { |t| t['name'].start_with?('build-') }
  check(!builds.empty? && builds.all? { |t| t.dig('taskRef', 'name') == 'build-image-dmz' }, 'Every selected service must route to DMZ')
  original = inactive_index.fetch(['Pipeline', pipeline['metadata']['name']])
  expected = Marshal.load(Marshal.dump(original))
  expected['spec']['tasks'].select { |t| t['name'].start_with?('build-') }.each do |t|
    t['taskRef']['name'] = 'build-image-dmz'
    if scope == 'backend'
      t['params'] << {'name' => 'nuget-credential-url', 'value' => 'https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_UnifiedVisaPlatform.Backend'}
      t['workspaces'] << {'name' => 'nuget-auth', 'workspace' => 'git-credentials'}
    end
  end
  expected['spec']['tasks'].each { |t| t['params']&.sort_by! { |p| p['name'] } }
  pipeline['spec']['tasks'].each { |t| t['params']&.sort_by! { |p| p['name'] } }
  check(pipeline == expected, 'DMZ activation changed unrelated stages, source, workspaces or image results')
end
puts 'PASS: customer full pipelines use DMZ, rollback preserves Hub stages, smoke pipelines and remote task contract remain valid'
