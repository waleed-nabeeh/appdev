#!/usr/bin/env ruby
require_relative 'validate'
require 'base64'
overlay = ['-f', 'customer-transfer/backend-build-fanout/values-backend.yaml']
before = render(*overlay)
after = render(*overlay, '-f', 'customer-transfer/backend-gitops/values-gitops.yaml')
before.each do |old|
  next if old['kind'] == 'Pipeline' && %w[application-backend-dispatch application-backend-build-fanout].include?(old['metadata']['name'])
  next if old['kind'] == 'ConfigMap' && old['metadata']['name'] == 'backend-build-run-template'
  check(after.find { |d| d['kind'] == old['kind'] && d['metadata']['name'] == old['metadata']['name'] } == old, 'Unrelated resource changed')
end
pipeline = after.find { |d| d['kind'] == 'Pipeline' && d['metadata']['name'] == 'application-backend-dispatch' }
tasks = pipeline['spec']['tasks']
definitions = after.select { |d| d['kind'] == 'Task' }.to_h { |d| [d['metadata']['name'], d['spec']] }
expected_repo = 'https://azuredevops.mofa.gov.sa/MOFA/UnifiedVisaPlatform/_git/RedHat_HelmCharts'
%w[backend-gitops-update frontend-release-update].each do |name|
  env = definitions.fetch(name)['stepTemplate']['env'].to_h { |e| [e['name'], e['value']] }
  check(env['GITOPS_URL'] == expected_repo && env['GITOPS_BRANCH'] == 'dev', 'Wrong accessible Git update destination')
  file = name.start_with?('backend') ? env['VALUES_FILE'] : env['RELEASE_FILE']
  check(file == (name.start_with?('backend') ? 'app-chart/backend.yaml' : 'app-chart/frontend.yaml'), 'Wrong Git values file')
end
check(tasks.none? { |t| t['name'] == 'gitops-base' }, 'Dispatcher must not start a separate base check')
check(!tasks.find { |t| t['name'] == 'update-gitops' }.key?('when'), 'GitOps must be a normal final stage')
check(pipeline['spec']['params'].none? { |p| p['name'] == 'update-gitops' }, 'Dispatcher must not require a GitOps run switch')
check(tasks.find { |t| t['name'] == 'update-gitops' }['runAfter'] == ['dispatch'], 'Update must follow successful batch')
tasks.each do |task|
  definition = definitions.fetch(task['taskRef']['name'])
  params = task.fetch('params', []).map { |p| p['name'] }
  check((params - definition.fetch('params', []).map { |p| p['name'] }).empty?, 'Unknown Task param')
  definition.fetch('params', []).reject { |p| p.key?('default') }.each { |p| check(params.include?(p['name']), 'Missing Task param') }
end
pipeline.to_json.scan(/\$\(tasks\.([^.]+)\.results\.([^)]+)\)/).each do |name, result|
  task = tasks.find { |t| t['name'] == name }
  check(task && definitions[task['taskRef']['name']].fetch('results', []).any? { |r| r['name'] == result }, 'Missing result producer')
end
# Preserve all working build lanes; only add GitOps dependencies and tasks.
fanout_name = 'application-backend-build-fanout'
old_fanout = before.find { |d| d['kind'] == 'Pipeline' && d['metadata']['name'] == fanout_name }
fanout = after.find { |d| d['kind'] == 'Pipeline' && d['metadata']['name'] == fanout_name }
old_fanout['spec']['tasks'].each do |old|
  current = fanout['spec']['tasks'].find { |t| t['name'] == old['name'] }
  expected = Marshal.load(Marshal.dump(old))
  check(current == expected, "Working backend stage changed: #{old['name']}")
end
old_cm = before.find { |d| d['kind'] == 'ConfigMap' && d['metadata']['name'] == 'backend-build-run-template' }
new_cm = after.find { |d| d['kind'] == 'ConfigMap' && d['metadata']['name'] == 'backend-build-run-template' }
check(old_cm['data']['pipelinerun.yaml'] == new_cm['data']['pipelinerun.yaml'], 'Existing build-only run changed')
check(YAML.load_file('customer-transfer/backend-gitops/pipelinerun.yaml') == YAML.safe_load(new_cm['data']['gitops-pipelinerun.yaml']), 'Customer run drifted from Helm template')
[nil, 'acl-service', 'acl-service,core-service'].each do |selection|
  extra = selection ? ['--set', "backendBuild.selectedServices={#{selection}}"] : []
  documents = render(*overlay, '-f', 'customer-transfer/backend-gitops/values-gitops.yaml', *extra)
  p = documents.find { |d| d['kind'] == 'Pipeline' && d['metadata']['name'] == fanout_name }
  ptasks = p['spec']['tasks']
  update = ptasks.find { |t| t['name'] == 'update-gitops' }
  record = JSON.parse(update['params'].find { |v| v['name'] == 'release-json' }['value'])
  selected = ptasks.select { |t| t['name'].start_with?('build-') }.map { |t| t['name'].delete_prefix('build-') }
  check(record['selected'] == selected && record['images'].keys.sort == selected.sort, 'GitOps selected services mismatch')
  check(update['runAfter'].sort == selected.map { |s| 'sign-' + s }.sort, 'GitOps must wait for every sign task')
  check(record['succeeded'] && record['failed'].empty? && record['notStarted'].empty?, 'Wrong successful release record')
  check(record['sourceCommit'] == '$(tasks.resolve-source.results.commit)', 'Wrong source result')
  selected.each do |s|
    image = record['images'][s]
    check(image['tag'] == '$(tasks.resolve-source.results.tag)', 'Tag must come from source SHA')
    check(image['digest'] == "$(tasks.build-#{s}.results.image-digest)", 'Digest must come from build result')
    check(image['image'] == image['repository'] + '@' + image['digest'], 'Invalid digest reference')
  end
  check(p['spec']['params'].none? { |v| v['name'] == 'update-gitops' }, 'Fixed fanout must not require a GitOps run switch')
  check(ptasks.none? { |t| t['name'] == 'gitops-base' }, 'Fixed fanout must not start a separate base check')
  check(!update.key?('when'), 'GitOps must be a normal stage without a run guard')
  check(update['params'].none? { |v| v['name'] == 'expected-base' }, 'Fixed fanout must use the current GitOps branch at update time')
  ptasks.each do |t|
    definition = definitions.fetch(t['taskRef']['name'])
    provided = t.fetch('params', []).map { |v| v['name'] }
    check((provided - definition.fetch('params', []).map { |v| v['name'] }).empty?, 'Unknown fanout Task param')
    definition.fetch('params', []).reject { |v| v.key?('default') }.each { |v| check(provided.include?(v['name']), 'Missing required fanout param') }
    definition.fetch('workspaces', []).reject { |v| v['optional'] }.each { |v| check(t.fetch('workspaces', []).any? { |w| w['name'] == v['name'] }, 'Missing workspace binding') }
    t.fetch('runAfter', []).each { |dep| check(ptasks.any? { |other| other['name'] == dep }, 'Unknown dependency') }
  end
  p.to_json.scan(/\$\(tasks\.([^.]+)\.results\.([^)]+)\)/).each do |name, result|
    task = ptasks.find { |t| t['name'] == name }
    check(task && definitions[task['taskRef']['name']].fetch('results', []).any? { |v| v['name'] == result }, 'Missing fanout result producer')
  end
  cm = documents.find { |d| d['kind'] == 'ConfigMap' && d['metadata']['name'] == 'backend-build-run-template' }
  run = YAML.safe_load(cm['data']['gitops-pipelinerun.yaml'])
  check(run.dig('spec', 'pipelineRef', 'name') == fanout_name, 'GitOps test must use fixed fanout')
  check(run.dig('spec', 'taskRunTemplate', 'serviceAccountName') == 'pipeline', 'Use working pipeline service account')
  check(run['spec']['params'].none? { |v| v['name'] == 'update-gitops' }, 'Run must not need a GitOps switch')
  check(run['spec']['workspaces'].map { |w| w['name'] }.sort == p['spec']['workspaces'].map { |w| w['name'] }.sort, 'Subset run workspace mismatch')
  claims = run['spec']['workspaces'].select { |w| w['volumeClaimTemplate'] }
  check(claims.size == selected.size && claims.all? { |w| w.dig('volumeClaimTemplate', 'spec', 'resources', 'requests', 'storage') == '3Gi' }, 'Wrong subset PVC allocation')
  check(claims.all? { |w| w.dig('volumeClaimTemplate', 'metadata', 'labels', 'pipeline') == 'backend-build-fanout' }, 'Missing PVC identification label')
end
%w[backend-build-resolve backend-gitops-base].each do |name|
  definition = definitions.fetch(name)
  step = definition['steps'][0]
  check(step['env'].any? { |e| e['name'] == 'HOME' && e['value'] == '/work/home' }, 'Resolver HOME must be privately created')
  check(definition['volumes'].any? { |v| v['name'] == 'work' && v['emptyDir'] == {} }, 'Missing writable scratch volume')
  check(step['volumeMounts'].any? { |v| v['name'] == 'work' && v['mountPath'] == '/work' }, 'Missing HOME scratch mount')
end
%w[backend-gitops-update frontend-release-update].each do |name|
  clone = definitions.fetch(name)['steps'].find { |s| s['name'] == 'clone' }['script']
  check(clone.include?('chmod -R g+rwX /work/repo'), 'Node updater needs group write on checkout')
  check(!clone.include?('chmod -R g+rwX "$HOME"'), 'Credentials must remain private')
end
puts 'Passed final GitOps stage, unchanged build lanes, 14/1/2-service result wiring and permission regression checks'
Dir.mktmpdir do |tmp|
  definitions.select { |name, _| name.start_with?('backend-gitops-') }.each do |name, spec|
    spec['steps'].each do |step|
      next unless step['script'].start_with?('#!/bin/sh')
      script = File.join(tmp, name + '-' + step['name'])
      File.write(script, step['script'])
      _, err, result = Open3.capture3('sh', '-n', script)
      check(result.success?, err)
    end
  end
end
code = after.find { |d| d['kind'] == 'ConfigMap' && d['metadata']['name'] == 'gitops-yaml-code' }
check(Base64.decode64(code['binaryData']['js-yaml.js']) == File.binread('pipelines/chart/files/vendor/js-yaml.js'), 'Bundled parser changed during render')
check(code.to_json.bytesize < 1_000_000, 'ConfigMap too large')
front = after.find { |d| d['kind'] == 'Pipeline' && d['metadata']['name'] == 'application-frontend-release-test' }
check(front['spec']['tasks'].count { |t| t['name'].start_with?('scan-') } == 3, 'Frontend scans must be enabled')
check(front['spec']['tasks'].count { |t| t['name'].start_with?('gate-') } == 3, 'Frontend gates must be enabled')
check(front['spec']['tasks'].none? { |t| t['name'].start_with?('verify-') }, 'Verify deferred to promotion in new overlay')
reference = File.expand_path('../../../../wel/RedHat_argocd/development/apps/core-apps.yaml', __dir__)
if File.exist?(reference)
  expected = YAML.load_file(reference)
  all = expected['argocd-applications']['applications']
  all.each_value do |app|
    app['autoSync'] = false
    image = app['overrideValues']['image']
    image['repository'] = 'quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/' + image['repository'].split('/').last
    route = app['overrideValues']['route']
    route['host'] = route['host'].sub('apps.visa-ocp-test-dev.mofa.gov.sa', 'apps.pre-visa-ocp.mofa.gov.sa') if route && route['host']
  end
  names = JSON.parse(File.read('pipelines/chart/files/backend-services.json')).map { |s| s['name'] + '-dev' }
  {'backend' => names, 'frontend' => %w[admin-portal-dev applicant-portal-dev operational-portal-dev]}.each do |group, keys|
    expected['argocd-applications']['applications'] = all.select { |key, _| keys.include?(key) }
    check(YAML.load_file("customer-transfer/backend-gitops/#{group}.yaml") == expected, 'Unexpected reference configuration change')
  end
end
puts 'Passed GitOps opt-in, unchanged build resources, references, parser packaging and shell checks'
Dir.mktmpdir do |tmp|
  run = lambda do |*cmd|
    out, err, status = Open3.capture3(*cmd)
    check(status.success?, "#{cmd.join(' ')}: #{err}")
    out
  end
  remote = File.join(tmp, 'remote.git')
  seed = File.join(tmp, 'seed')
  run.call('git', 'init', '--bare', remote)
  run.call('git', 'init', '-b', 'pre-production', seed)
  %w[seed a b c d].each do |name|
    repo = File.join(tmp, name)
    run.call('git', 'clone', '-b', 'pre-production', remote, repo) unless name == 'seed'
    run.call('git', '-C', repo, 'config', 'user.name', 'Test')
    run.call('git', '-C', repo, 'config', 'user.email', 'test@example.invalid')
    if name == 'seed'
      File.write(File.join(repo, 'backend.yaml'), 'backend-old')
      File.write(File.join(repo, 'frontend.yaml'), 'frontend-old')
      run.call('git', '-C', repo, 'add', '.')
      run.call('git', '-C', repo, 'commit', '-m', 'seed')
      run.call('git', '-C', repo, 'remote', 'add', 'origin', remote)
      run.call('git', '-C', repo, 'push', '-u', 'origin', 'pre-production')
    end
  end
  b = File.join(tmp, 'b')
  File.write(File.join(b, 'frontend.yaml'), 'frontend-new')
  run.call('git', '-C', b, 'commit', '-am', 'frontend update')
  run.call('git', '-C', b, 'push')
  a = File.join(tmp, 'a')
  File.write(File.join(a, 'backend.yaml'), 'backend-new')
  script = File.join(tmp, 'push.sh')
  File.write(script, File.read('pipelines/chart/files/gitops-push.sh').sub('/work/repo', a))
  _, err, result = Open3.capture3({'VALUES_FILE' => 'backend.yaml', 'GITOPS_BRANCH' => 'pre-production'}, 'sh', script)
  check(result.success?, err)
  check(run.call('git', '--git-dir', remote, 'show', 'pre-production:frontend.yaml') == 'frontend-new', 'Lost parallel frontend commit')
  check(run.call('git', '--git-dir', remote, 'show', 'pre-production:backend.yaml') == 'backend-new', 'Backend commit missing')
  c = File.join(tmp, 'c')
  File.write(File.join(c, 'backend.yaml'), 'stale-backend')
  File.write(script, File.read('pipelines/chart/files/gitops-push.sh').sub('/work/repo', c))
  _, _, result = Open3.capture3({'VALUES_FILE' => 'backend.yaml', 'GITOPS_BRANCH' => 'pre-production'}, 'sh', script)
  check(!result.success?, 'Same-file concurrent update must fail')
  check(run.call('git', '--git-dir', remote, 'show', 'pre-production:backend.yaml') == 'backend-new', 'Same-file conflict overwrote newer release')
end
puts 'Passed real local Git push races: different files merge, same-file update rejected'
