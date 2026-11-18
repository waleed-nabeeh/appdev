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
render('--set', 'remoteBuild.enabled=false').each do |doc|
  check(index[[doc['kind'], doc['metadata']['name']]] == doc, 'Existing resources changed before DMZ activation')
end
task = index.fetch(['Task', 'build-image-dmz'])['spec']
legacy = index.fetch(['Task', 'build-image'])['spec']
%w[results workspaces].each { |field| check(task[field] == legacy[field], "Task contract changed: #{field}") }
check(task['params'].reject { |p| p['name'] == 'diagnostic-base-image' } == legacy['params'], 'Legacy build params must be preserved')
check(task['params'].find { |p| p['name'] == 'diagnostic-base-image' }['default'] == '', 'Diagnostics must be opt-in for normal application builds')
check(!task.to_json.include?('capabilities'), 'Remote build must not require privileges')
check(task['steps'][0]['env'].none? { |e| e.key?('valueFrom') }, 'Proxy values must be transferred as files, not injected into Hub environment')
check(task['volumes'].any? { |v| v.dig('secret', 'secretName') == 'pipeline-proxy' }, 'Reuse existing proxy Secret')
check(task['steps'][0]['image'].end_with?('/devops/alpine-git:2026-10-07'), 'Reuse approved Git/SSH image')
%w[backend frontend].each do |scope|
  pipeline = index.fetch(['Pipeline', "application-#{scope}-dmz-test"])['spec']
  check(pipeline['tasks'].map { |t| t['name'] } == %w[clone build], 'Smoke test must not deploy')
  diagnostic = pipeline['params'].find { |p| p['name'] == 'diagnostic-base-image' }['default']
  check(scope == 'frontend' ? diagnostic.include?('/devops/nodejs-24:') : diagnostic == '', 'Enable Node diagnostics only for frontend smoke test')
  check(pipeline['tasks'].last.dig('taskRef', 'name') == 'build-image-dmz', 'Smoke test must build remotely')
  run = YAML.safe_load(index.fetch(['ConfigMap', "#{scope}-dmz-test-run-template"])['data']['pipelinerun.yaml'])
  check(run.dig('spec', 'pipelineRef', 'name') == "application-#{scope}-dmz-test", 'Wrong run template')
end
active = render('--set', 'remoteBuild.useForApplicationBuilds=true')
%w[backend frontend].each do |scope|
  pipeline = active.find { |d| d['kind'] == 'Pipeline' && d['metadata']['name'] == "application-#{scope}-build-fanout" }
  builds = pipeline['spec']['tasks'].select { |t| t['name'].start_with?('build-') }
  check(!builds.empty? && builds.all? { |t| t.dig('taskRef', 'name') == 'build-image-dmz' }, 'Every selected service must route to DMZ')
  original = index.fetch(['Pipeline', pipeline['metadata']['name']])
  expected = Marshal.load(Marshal.dump(original))
  expected['spec']['tasks'].select { |t| t['name'].start_with?('build-') }.each { |t| t['taskRef']['name'] = 'build-image-dmz' }
  check(pipeline == expected, 'DMZ activation changed unrelated stages, source, workspaces or image results')
end
puts 'PASS: default resources unchanged, frontend/backend smoke pipelines, remote task contract, and selected-service opt-in wiring'
