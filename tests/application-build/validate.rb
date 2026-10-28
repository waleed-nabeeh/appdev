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
runs = YAML.load_stream(File.read('customer-transfer/application-build/dispatches.yaml')).compact
check(runs.size == 2, 'Expected two dispatcher TaskRun examples')
%w[backend frontend].each do |scope|
  front = scope == 'frontend'
  config = JSON.parse(get.call('ConfigMap', scope + '-dispatch-config')['data']['config.json'])
  check(config['scope'] == scope && config['catalog'].size == (front ? 3 : 14), 'Incorrect allowed catalog')
  check(config['fanoutPipeline'] == "application-#{scope}-build-fanout" && config['npmAuth'] == front, 'Incorrect build scope/workspaces')
  check(config['workspaceSize'] == '3Gi', 'Incorrect storage settings')
  check(config['applicationNamePrefix'] == 'pre-' && config['applicationNameSuffix'] == '', 'GitOps must target pre- application names')
  gitops_apps = YAML.load_file("customer-transfer/backend-gitops/#{scope}-preproduction.yaml").fetch('argocd-applications').fetch('applications')
  config['catalog'].each do |service|
    image = gitops_apps.fetch('pre-' + service['name']).fetch('overrideValues').fetch('image')
    check(image['repository'] == config['imageRepository'] + '/' + service['name'], 'Preproduction image repository mismatch')
  end
  check(documents.none? { |d| d['kind'] == 'Pipeline' && d.dig('metadata', 'name') == "application-#{scope}-dispatch" }, 'No parent dispatcher PipelineRun')
  check(documents.none? { |d| d['kind'] == 'Pipeline' && d.dig('metadata', 'name') == "application-#{scope}-service-build" }, 'No per-service child PipelineRuns')
  fanout = get.call('Pipeline', config['fanoutPipeline'])['spec']
  defaults = fanout['params'].to_h { |p| [p['name'], p['default']] }
  check(defaults['source-url'] == config['sourceUrl'] && defaults['env'] == 'dev', 'Missing Pipeline source-url/env defaults')
  check(defaults['services'] == config['catalog'].map { |s| s['name'] }.join(','), 'Missing Pipeline services default')
  check(!defaults.key?('build-args'), 'Expose env instead of a build argument parameter')
  check(fanout['tasks'].last['name'] == 'update-gitops' && !fanout['tasks'].last.key?('when'), 'GitOps must be in the main fanout')
  config['catalog'].each do |service|
    name = service['name']
    lane = ['resolve-source'] + %w[clone test build scan gate sign].map { |stage| "#{stage}-#{name}" }
    lane.each_cons(2) { |a, b| check(fanout['tasks'].find { |t| t['name'] == b }['runAfter'] == [a], 'Broken working lane') }
    unit = fanout['tasks'].find { |t| t['name'] == 'test-' + name }
    check(unit['taskRef']['name'] == (front ? 'frontend-unit-test' : 'unit-test'), 'Incorrect test Task')
    check((unit['onError'] == 'continue') == front, 'Frontend-only test concession')
    build = fanout['tasks'].find { |t| t['name'] == 'build-' + name }
    args = build['params'].find { |p| p['name'] == 'build-args' }['value']
    check(args == [front ? 'BUILD_ENVIRONMENT=$(params.env)' : 'CERT_KEYWORD=$(params.env)'], 'env must control build arguments')
    clone = fanout['tasks'].find { |t| t['name'] == 'clone-' + name }
    check(clone['params'].find { |p| p['name'] == 'url' }['value'] == '$(params.source-url)', 'Clone must consume source-url')
  end
  check(fanout['tasks'].none? { |t| t['name'].start_with?('verify-') }, 'Verify belongs to promotion')
  direct_run = YAML.load_file("customer-transfer/application-build/#{scope}-pipelinerun.yaml")
  entry_name = "application-#{scope}-build"
  entry = get.call('Pipeline', entry_name)['spec']
  check(direct_run['kind'] == 'PipelineRun' && direct_run.dig('spec', 'pipelineRef', 'name') == entry_name, 'Manual file must start the scope entry Pipeline')
  check(direct_run['spec']['params'].map { |p| p['name'] } == ['services'], 'Manual PipelineRun must supply only the service list')
  check(direct_run['spec'].fetch('workspaces', []).empty? && entry.fetch('workspaces', []).empty?, 'UI start must require no workspace inputs')
  entry_defaults = entry['params'].to_h { |p| [p['name'], p['default']] }
  check(direct_run['spec']['params'][0]['value'] == entry_defaults['services'], 'Manual service list must match its console default')
  %w[services source-url source-revision env source-commit].each { |p| check(entry_defaults[p] == defaults[p], 'Console defaults must match fanout defaults') }
  check(entry['tasks'].size == 1 && entry['tasks'][0].dig('taskRef', 'name') == scope + '-build-dispatch', 'UI entry must use the shared dispatcher')
  check(entry['results'].any? { |r| r['name'] == 'build-pipeline-run' }, 'UI must expose the actual build run name')
  updater = tasks.fetch(scope + '-gitops-update')
  env = updater['stepTemplate']['env'].to_h { |e| [e['name'], e['value']] }
  check(env['VALUES_FILE'] == "app-chart/#{scope}.yaml" && env['GITOPS_BRANCH'] == 'dev', 'Incorrect GitOps target')
  check(env['GITOPS_URL'].end_with?('/RedHat_HelmCharts'), 'Incorrect accessible GitOps repo')
  launcher = tasks.fetch(scope + '-build-dispatch')
  check(launcher['steps'].last['script'].include?('function makeFanoutRun'), 'Missing selected-only builder')
  manual_names = config['catalog'].map { |s| s['name'] }
  check(launcher['params'].find { |p| p['name'] == 'services' }['default'] == manual_names.join(','), 'Manual chart default must list every enabled service')
  check(launcher['params'].find { |p| p['name'] == 'source-url' }['default'] == defaults['source-url'], 'Launcher source-url default drift')
  check(launcher['params'].find { |p| p['name'] == 'env' }['default'] == defaults['env'], 'Launcher env default drift')
  check(launcher['workspaces'].find { |w| w['name'] == 'git-credentials' }['optional'], 'Dispatcher credentials must be optional workspace input')
  check(launcher['volumes'].any? { |v| v.dig('secret', 'secretName') == 'git-credentials' }, 'Dispatcher must mount configured credentials internally')
  run = runs.find { |r| r.dig('spec', 'taskRef', 'name') == scope + '-build-dispatch' }
  check(run && run['kind'] == 'TaskRun' && run['spec']['serviceAccountName'] == scope + '-dispatcher', 'Incorrect launcher example')
  check(run['spec']['params'].find { |p| p['name'] == 'services' }['value'].split(',') == manual_names, 'Manual example must list every enabled service')
  check(run['spec']['params'].find { |p| p['name'] == 'source-url' }['value'] == defaults['source-url'], 'Manual source-url drift')
  check(run['spec']['params'].find { |p| p['name'] == 'env' }['value'] == 'dev', 'Manual env must default dev')
  check(run['spec']['workspaces'].none? { |w| w['volumeClaimTemplate'] }, 'Launcher must allocate no PVC')
  run['spec']['params'].each { |p| check(launcher['params'].any? { |v| v['name'] == p['name'] }, 'Unknown sample run parameter') }
  listener = get.call('EventListener', scope + '-pr')
  check(listener.to_json.include?('lastMergeTargetCommit') && !listener.to_json.include?('compareSecret'), 'PR diff inputs and requested auth mode')
  template = get.call('TriggerTemplate', scope + '-azure-pr')
  triggered = template['spec']['resourcetemplates'][0]['spec']
  check(template['spec']['resourcetemplates'][0]['kind'] == 'PipelineRun' && triggered['pipelineRef']['name'] == entry_name, 'PR must use same UI entry Pipeline as manual')
  check(triggered['params'].find { |p| p['name'] == 'selection-mode' }['value'] == 'diff', 'PR must select from diff')
  check(triggered['params'].find { |p| p['name'] == 'source-url' }['value'] == defaults['source-url'], 'PR source-url default drift')
  check(triggered['params'].find { |p| p['name'] == 'env' }['value'] == 'dev', 'PR env default drift')
  route = get.call('Route', scope + '-pr-webhook')['spec']
  check(route['to']['name'] == 'el-' + scope + '-pr' && route['tls']['termination'] == 'edge', 'Route must reach correct listener')
  role = get.call('Role', scope + '-dispatcher')['rules']
  check(role.any? { |r| r['resources'] == ['pipelineruns'] && r['verbs'].sort == %w[create get] }, 'Launcher must have only get/create run permissions')
  binding = get.call('RoleBinding', scope + '-dispatcher')
  check(binding['subjects'].any? { |s| s['kind'] == 'ServiceAccount' && s['name'] == 'pipeline' && s['namespace'] == 'devops' }, 'Console pipeline account needs launch permissions')
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
  # A pinned commit exercises the real resolver without contacting a Git server.
  credentials = File.join(tmp, 'credentials')
  Dir.mkdir(credentials)
  resolver = tasks.fetch('backend-build-resolve')['steps'][0]['script']
  commit_file = File.join(tmp, 'commit')
  tag_file = File.join(tmp, 'tag')
  resolver = resolver.gsub('$(workspaces.git-credentials.path)', credentials)
                     .gsub('$(results.commit.path)', commit_file)
                     .gsub('$(results.tag.path)', tag_file)
  script = File.join(tmp, 'resolver.sh')
  File.write(script, resolver)
  source_sha = '12345678' + 'a' * 32
  environment = {'HOME' => File.join(tmp, 'git-home'), 'SOURCE_URL' => 'https://git.example/team/backend',
                 'BUILD_ENV' => 'dev', 'REVISION' => 'test', 'COMMIT' => source_sha,
                 'SERVICES' => 'acl-service,core-service', 'EXPECTED_SERVICES' => 'acl-service,core-service'}
  _, err, result = Open3.capture3(environment, 'sh', script)
  check(result.success? && File.read(commit_file) == source_sha && File.read(tag_file) == '12345678', err)
  [{'BUILD_ENV' => 'dev$(id)'}, {'SOURCE_URL' => 'https://user:password@git.example/backend'},
   {'SERVICES' => 'acl-service'}].each do |invalid|
    _, _, result = Open3.capture3(environment.merge(invalid), 'sh', script)
    check(!result.success?, 'Unsafe input or changed graph selection must fail before building')
  end
  # The console entry supplies no workspace: credentials must use the internal mount.
  launch_work = File.join(tmp, 'launch-work')
  Dir.mkdir(launch_work)
  source_step = tasks.fetch('backend-build-dispatch')['steps'][0]['script']
  source_step = source_step.gsub('/credentials/git', credentials).gsub('/work', launch_work)
  launch_script = File.join(tmp, 'launch-source.sh')
  File.write(launch_script, source_step)
  _, err, result = Open3.capture3(environment.merge('HOME' => File.join(tmp, 'launch-home'),
    'CREDENTIALS_PATH' => '', 'MODE' => 'manual', 'TARGET_COMMIT' => ''), 'sh', launch_script)
  check(result.success? && File.read(File.join(launch_work, 'commit')) == source_sha, err)
end
[['frontendRelease.selectedServices', '["wrong-portal"]'], ['frontendRelease.selectedServices', '["admin-portal","admin-portal"]'], ['frontendRelease.dispatch.maxParallel', '0']].each do |key, value|
  _, _, result = Open3.capture3(*command, '--set-json', key + '=' + value)
  check(!result.success?, 'Invalid frontend dispatcher settings must fail rendering')
end
puts 'Passed single-values selected-only fanout templates, working stages, GitOps, CSV launcher, PR routing, RBAC and shell checks'
