#!/usr/bin/env ruby
require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'

Dir.chdir(File.expand_path('../..', __dir__))
def check(ok, message)
  raise message unless ok
end
command = ['helm', 'template', 'release-pipeline', 'pipelines/chart', '-n', 'devops',
           '-f', 'customer-transfer/application-build/values.yaml']
output, error, status = Open3.capture3(*command)
check(status.success?, error)
documents = YAML.load_stream(output).compact
keys = documents.map { |d| [d['kind'], d.dig('metadata', 'namespace'), d.dig('metadata', 'name')] }
check(keys.uniq.size == keys.size, 'Duplicate resources in combined values render')
get = lambda do |kind, name|
  documents.find { |d| d['kind'] == kind && d.dig('metadata', 'name') == name } || raise("Missing #{kind}/#{name}")
end
tasks = documents.select { |d| d['kind'] == 'Task' }.to_h { |d| [d['metadata']['name'], d['spec']] }
documents.select { |d| d['kind'] == 'Pipeline' }.each do |pipeline|
  spec = pipeline['spec']
  spec.fetch('tasks', []).each do |task|
    definition = tasks.fetch(task.dig('taskRef', 'name'))
    supplied = task.fetch('params', []).map { |p| p['name'] }
    declared = definition.fetch('params', []).map { |p| p['name'] }
    check((supplied - declared).empty?, "Unknown param in #{task['name']}")
    definition.fetch('params', []).reject { |p| p.key?('default') }.each do |p|
      check(supplied.include?(p['name']), "Missing required parameter #{p['name']}")
    end
    definition.fetch('workspaces', []).reject { |w| w['optional'] }.each do |w|
      binding = task.fetch('workspaces', []).find { |b| b['name'] == w['name'] }
      check(binding && spec.fetch('workspaces', []).any? { |p| p['name'] == binding['workspace'] }, "Missing workspace #{w['name']}")
    end
    task.fetch('runAfter', []).each { |name| check(spec['tasks'].any? { |t| t['name'] == name }, 'Missing task dependency') }
  end
  spec.to_json.scan(/\$\(tasks\.([^.]+)\.results\.([^)]+)\)/).each do |producer, result|
    producer_task = spec['tasks'].find { |t| t['name'] == producer }
    check(producer_task && tasks.fetch(producer_task['taskRef']['name']).fetch('results', []).any? { |r| r['name'] == result }, 'Invalid task result reference')
  end
end
runs = YAML.load_stream(File.read('customer-transfer/application-build/pipelineruns.yaml')).compact
check(runs.size == 2, 'Expected two parent run examples')
%w[backend frontend].each do |scope|
  front = scope == 'frontend'
  config = JSON.parse(get.call('ConfigMap', scope + '-dispatch-config')['data']['config.json'])
  check(config['scope'] == scope && config['catalog'].size == (front ? 3 : 14), 'Incorrect allowed catalog')
  check(config['childPipeline'] == "application-#{scope}-service-build" && config['npmAuth'] == front, 'Incorrect child scope/workspaces')
  check(config['workspaceSize'] == '3Gi' && config['maxParallel'] == 3, 'Incorrect storage/concurrency settings')
  parent = get.call('Pipeline', "application-#{scope}-dispatch")['spec']
  check(parent['tasks'].map { |t| t['name'] } == %w[select dispatch update-gitops], 'Parent must select, dispatch, update GitOps')
  check(parent['params'].none? { |p| p['name'] == 'update-gitops' }, 'No GitOps run switch')
  check(parent['params'].find { |p| p['name'] == 'services' }['default'] == 'all', 'CSV input must have a usable default')
  check(parent['tasks'].last['runAfter'] == ['dispatch'] && !parent['tasks'].last.key?('when'), 'GitOps must follow successful dispatch')
  child = get.call('Pipeline', config['childPipeline'])['spec']
  check(child['tasks'].map { |t| t['name'] } == %w[settings clone test build scan gate sign], 'Child must preserve working build flow without verify')
  child['tasks'].each_cons(2) { |a, b| check(b['runAfter'] == [a['name']], 'Broken child stage ordering') }
  unit = child['tasks'].find { |t| t['name'] == 'test' }
  check(unit['taskRef']['name'] == (front ? 'frontend-unit-test' : 'unit-test'), 'Incorrect test Task')
  check((unit['onError'] == 'continue') == front, 'Frontend-only test concession')
  build = child['tasks'].find { |t| t['name'] == 'build' }
  args = build['params'].find { |p| p['name'] == 'build-args' }['value']
  check(args == [front ? 'BUILD_ENVIRONMENT=dev' : 'CERT_KEYWORD=dev'], 'Keep dev build arguments')
  updater = tasks.fetch(scope + '-gitops-update')
  env = updater['stepTemplate']['env'].to_h { |e| [e['name'], e['value']] }
  check(env['VALUES_FILE'] == "app-chart/#{scope}.yaml" && env['GITOPS_BRANCH'] == 'dev', 'Incorrect GitOps target')
  check(env['GITOPS_URL'].end_with?('/RedHat_HelmCharts'), 'Incorrect accessible GitOps repo')
  select = tasks.fetch(scope + '-dispatch-select')
  check(select['steps'].last['script'].include?('function selectServices'), 'Empty selector script')
  check(tasks.fetch(scope + '-dispatch-run')['steps'][0]['script'].include?('async function dispatch'), 'Empty dispatcher script')
  run = runs.find { |r| r.dig('spec', 'pipelineRef', 'name') == "application-#{scope}-dispatch" }
  check(run && run['spec']['taskRunTemplate']['serviceAccountName'] == scope + '-dispatcher', 'Incorrect example parent')
  check(run['spec']['workspaces'].none? { |w| w['volumeClaimTemplate'] }, 'Parent must allocate no PVC')
  run['spec']['params'].each { |p| check(parent['params'].any? { |v| v['name'] == p['name'] }, 'Unknown sample run parameter') }
  listener = get.call('EventListener', scope + '-pr')
  check(listener.to_json.include?('lastMergeTargetCommit') && !listener.to_json.include?('compareSecret'), 'PR diff inputs and requested auth mode')
  template = get.call('TriggerTemplate', scope + '-azure-pr')
  triggered = template['spec']['resourcetemplates'][0]['spec']
  check(triggered['pipelineRef']['name'] == "application-#{scope}-dispatch", 'PR must use same dispatcher as manual')
  check(triggered['params'].find { |p| p['name'] == 'selection-mode' }['value'] == 'diff', 'PR must select from diff')
  route = get.call('Route', scope + '-pr-webhook')['spec']
  check(route['to']['name'] == 'el-' + scope + '-pr' && route['tls']['termination'] == 'edge', 'Route must reach correct listener')
  role = get.call('Role', scope + '-dispatcher')['rules']
  check(role.any? { |r| r['resources'] == ['pipelineruns'] && r['verbs'].sort == %w[create get patch] }, 'Missing child run RBAC')
end
check(documents.none? { |d| d.dig('metadata', 'name') == 'frontend-pr-webhook-proxy' }, 'Legacy proxy must not shadow dispatcher route')
Dir.mktmpdir do |tmp|
  tasks.each do |name, spec|
    spec.fetch('steps', []).each_with_index do |step, i|
      next unless step.fetch('script', '').match?(/\A#!.*(?:sh|bash)/)
      file = File.join(tmp, "#{name}-#{i}.sh")
      File.write(file, step['script'])
      _, err, result = Open3.capture3('bash', '-n', file)
      check(result.success?, err)
    end
  end
end
[['frontendRelease.selectedServices', '["wrong-portal"]'], ['frontendRelease.selectedServices', '["admin-portal","admin-portal"]'], ['frontendRelease.dispatch.maxParallel', '0']].each do |key, value|
  _, _, result = Open3.capture3(*command, '--set-json', key + '=' + value)
  check(!result.success?, 'Invalid frontend dispatcher settings must fail rendering')
end
puts 'Passed single-values backend/frontend dispatcher, child stages, GitOps, CSV contract, run examples, triggers, RBAC and shell checks'
