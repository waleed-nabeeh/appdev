#!/usr/bin/env ruby
require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'

Dir.chdir(File.expand_path('../..', __dir__))
def check(ok, message)
  raise message unless ok
end
def render(*extra)
  command = ['helm', 'template', 'release-pipeline', 'pipelines/chart', '-n', 'devops',
             '-f', 'customer-transfer/devops-apply/values-devops.yaml', *extra]
  out, err, status = Open3.capture3(*command)
  raise err unless status.success?
  YAML.load_stream(out).compact
end
overlay = ['-f', 'customer-transfer/backend-build-fanout/values-backend.yaml']
catalog = JSON.parse(File.read('pipelines/chart/files/backend-services.json'))
check(catalog.size == 17, 'Expected 17 services')
check(catalog.map { |s| s['name'] }.uniq.size == 17, 'Duplicate service')
baseline = render
check(baseline.none? { |d| d.dig('metadata', 'name') == 'application-backend-build-fanout' }, 'Feature must default off')
all = render(*overlay)
# Ensure adding backend resources does not change existing pipeline/task definitions.
baseline.each do |old|
  current = all.find { |d| d['kind'] == old['kind'] && d.dig('metadata', 'name') == old.dig('metadata', 'name') }
  check(current == old, "Existing resource changed: #{old.dig('metadata', 'name')}")
end
def validate(documents, services)
  pipeline = documents.find { |d| d.dig('metadata', 'name') == 'application-backend-build-fanout' }
  tasks = pipeline['spec']['tasks']
  definitions = documents.select { |d| d['kind'] == 'Task' }.to_h { |d| [d['metadata']['name'], d['spec']] }
  check(tasks.size == 1 + services.size * 6, 'Wrong number of tasks')
  check(tasks.none? { |t| t['name'].match?(/verify|gitops|helm/) }, 'Build must not verify or deploy')
  services.each do |service|
    lane = ['resolve-source'] + %w[clone test build scan gate sign].map { |stage| "#{stage}-#{service['name']}" }
    lane.each_cons(2) { |a, b| check(tasks.find { |t| t['name'] == b }['runAfter'] == [a], "Broken edge #{a} -> #{b}") }
    build = tasks.find { |t| t['name'] == "build-#{service['name']}" }
    params = build['params'].to_h { |p| [p['name'], p['value']] }
    check(params['containerfile'] == service['containerfile'], 'Wrong Dockerfile')
    check(params['context'] == '.', 'Expected repository-root build context')
    check(params['build-args'] == ['CERT_KEYWORD=dev'], 'Wrong build arguments')
    clone = tasks.find { |t| t['name'] == "clone-#{service['name']}" }
    check(clone['params'].any? { |p| p['name'] == 'commit' && p['value'] == '$(tasks.resolve-source.results.commit)' }, 'Unpinned clone')
    check(!tasks.find { |t| t['name'] == "test-#{service['name']}" }.key?('onError'), 'Backend tests must block by default')
  end
  tasks.each do |task|
    definition = definitions.fetch(task['taskRef']['name'])
    params = task.fetch('params', []).map { |p| p['name'] }
    check((params - definition.fetch('params', []).map { |p| p['name'] }).empty?, 'Unknown Task parameter')
    definition.fetch('params', []).reject { |p| p.key?('default') }.each { |p| check(params.include?(p['name']), 'Required parameter missing') }
    definition.fetch('workspaces', []).reject { |w| w['optional'] }.each do |w|
      check(task.fetch('workspaces', []).any? { |b| b['name'] == w['name'] }, 'Required workspace missing')
    end
  end
  pipeline['spec'].to_json.scan(/\$\(tasks\.([^.]+)\.results\.([^)]+)\)/).each do |producer, result|
    task = tasks.find { |t| t['name'] == producer }
    check(!task.nil?, "Missing producer #{producer}")
    check(definitions.fetch(task['taskRef']['name']).fetch('results', []).any? { |r| r['name'] == result }, 'Missing Task result')
  end
  config = documents.find { |d| d.dig('metadata', 'name') == 'backend-build-run-template' }
  run = YAML.safe_load(config['data']['pipelinerun.yaml'])
  check(run.dig('spec', 'pipelineRef', 'name') == pipeline['metadata']['name'], 'Wrong PipelineRun reference')
  check(run.dig('spec', 'taskRunTemplate', 'serviceAccountName') == 'pipeline', 'Wrong service account')
  check(run['spec']['workspaces'].map { |w| w['name'] }.sort == pipeline['spec']['workspaces'].map { |w| w['name'] }.sort, 'Run workspace mismatch')
  pvcs = run['spec']['workspaces'].select { |w| w['volumeClaimTemplate'] }
  check(pvcs.size == services.size, 'Unselected services allocated PVCs')
  pvcs.each { |w| check(w.dig('volumeClaimTemplate', 'spec', 'resources', 'requests', 'storage') == '3Gi', 'Wrong PVC size') }
end
validate(all, catalog)
%w[acl-service authserver-service].each do |name|
  validate(render(*overlay, '--set', "backendBuild.selectedServices={#{name}}"), catalog.select { |s| s['name'] == name })
end
validate(render(*overlay, '--set', 'backendBuild.selectedServices={acl-service,payment-service}'), catalog.select { |s| %w[acl-service payment-service].include?(s['name']) })
%w[unknown-service acl-service,acl-service].each do |selection|
  failed = false
  begin
    render(*overlay, '--set', "backendBuild.selectedServices={#{selection}}")
  rescue RuntimeError
    failed = true
  end
  check(failed, 'Invalid service selection must fail')
end
Dir.mktmpdir do |tmp|
  resolver = all.find { |d| d['kind'] == 'Task' && d.dig('metadata', 'name') == 'backend-build-resolve' }
  File.write("#{tmp}/resolve.sh", resolver['spec']['steps'][0]['script'])
  _, err, status = Open3.capture3('sh', '-n', "#{tmp}/resolve.sh")
  check(status.success?, err)
end
if ARGV[0]
  catalog.each do |service|
    %w[project containerfile].each do |key|
      parts = service[key].split('/')
      dir = File.expand_path(ARGV[0])
      parts.each do |part|
        check(Dir.children(dir).include?(part), "Missing or wrong-case source path: #{service[key]}")
        dir = File.join(dir, part)
      end
    end
  end
end
puts 'Passed 17-service, one/two-service selection, dependency, result, workspace, isolation and shell checks'
