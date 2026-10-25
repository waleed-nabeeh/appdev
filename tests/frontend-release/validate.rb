#!/usr/bin/env ruby
require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

ROOT = File.expand_path('../..', __dir__)
Dir.chdir(ROOT)
def run(*args)
  out, err, status = Open3.capture3(*args)
  raise "#{args.join(' ')} failed: #{err}\n#{out}" unless status.success?
  out
end
def docs(text)
  YAML.load_stream(text).compact
end
def check(condition, message)
  raise message unless condition
end

base = ['helm', 'template', 'release-pipeline', 'pipelines/chart', '-n', 'devops',
        '-f', 'customer-transfer/devops-apply/values-devops.yaml']
default = docs(run(*base))
check(!default.any? { |d| d.dig('metadata', 'name') == 'application-frontend-release-test' }, 'Release must default off')
test_release = docs(run(*base, '-f', 'customer-transfer/frontend-release-test/values-release.yaml'))
test_pipeline = test_release.find { |d| d.dig('metadata', 'name') == 'application-frontend-release-test' }
test_tasks = test_pipeline['spec']['tasks']
check(test_tasks.count { |t| t['name'].start_with?('scan-', 'gate-') } == 6, 'Customer release must include three ACS scan/gate pairs')
legacy = test_release.find { |d| d.dig('metadata', 'name') == 'application-frontend-three-service-validation' }['spec']['tasks']
%w[admin-portal applicant-portal operational-portal].each do |service|
  lane = ['resolve-source'] + %w[clone test build scan gate sign verify].map { |stage| "#{stage}-#{service}" }
  lane.each_cons(2) do |before, after|
    check(test_tasks.find { |t| t['name'] == after }['runAfter'] == [before], "Broken test lane #{after}")
  end
  %w[test build sign verify].each do |stage|
    old = legacy.find { |t| t['name'] == "#{stage}-#{service}" }
    new_task = test_tasks.find { |t| t['name'] == old['name'] }
    check(new_task['taskRef'] == old['taskRef'], "Task drift for #{old['name']}")
    check(new_task['workspaces'] == old['workspaces'], "Workspace drift for #{old['name']}")
    check(new_task['onError'] == old['onError'], "Error handling drift for #{old['name']}")
    old_params = old['params'].reject { |p| stage == 'build' && p['name'] == 'image' }
    new_params = new_task['params'].reject { |p| stage == 'build' && p['name'] == 'image' }
    check(new_params.to_json == old_params.to_json.gsub('$(params.build-environment)', 'dev'), "Parameter drift for #{old['name']}")
  end
end
release = docs(run(*base, '-f', 'customer-transfer/frontend-release-test/values-release.yaml', '--set', 'frontendRelease.scanEnabled=true'))
tasks = release.select { |d| d['kind'] == 'Task' }.to_h { |d| [d['metadata']['name'], d['spec']] }
pipeline = release.find { |d| d.dig('metadata', 'name') == 'application-frontend-release-test' }
check(!pipeline.nil?, 'Missing release Pipeline')
ptasks = pipeline['spec']['tasks']
names = ptasks.map { |t| t['name'] }
check(names.uniq == names, 'Duplicate pipeline task')
ptasks.each do |t|
  spec = tasks.fetch(t['taskRef']['name'])
  provided = (t['params'] || []).map { |p| p['name'] }
  declared = (spec['params'] || []).map { |p| p['name'] }
  check((provided - declared).empty?, "Unknown parameters in #{t['name']}")
  (spec['params'] || []).reject { |p| p.key?('default') }.each do |p|
    check(provided.include?(p['name']), "Missing parameter #{p['name']} in #{t['name']}")
  end
  (t['runAfter'] || []).each { |name| check(names.include?(name), "Missing runAfter #{name}") }
  t.to_json.scan(/\$\(tasks\.([^.]+)\.results\.([^)]+)\)/).each do |producer, result|
    producer_task = ptasks.find { |p| p['name'] == producer }
    check(!producer_task.nil?, "Missing producer #{producer}")
    results = tasks.fetch(producer_task['taskRef']['name']).fetch('results', []).map { |r| r['name'] }
    check(results.include?(result), "Missing result #{producer}.#{result}")
  end
  workspaces = (t['workspaces'] || []).map { |w| w['name'] }
  (spec['workspaces'] || []).reject { |w| w['optional'] }.each do |w|
    check(workspaces.include?(w['name']), "Missing workspace #{w['name']} in #{t['name']}")
  end
end
services = %w[admin-portal applicant-portal operational-portal]
services.each do |service|
  lane = ['resolve-source'] + %w[clone test build scan gate sign verify].map { |stage| "#{stage}-#{service}" }
  lane.each_cons(2) do |before, after|
    check(ptasks.find { |t| t['name'] == after }['runAfter'] == [before], "Missing explicit lane edge #{before} -> #{after}")
  end
  build = ptasks.find { |t| t['name'] == "build-#{service}" }
  check(build['params'].find { |p| p['name'] == 'build-args' }['value'] == ['BUILD_ENVIRONMENT=dev'], 'Wrong build argument')
  check(names.include?("gate-#{service}"), 'Missing security gate')
  clone = ptasks.find { |t| t['name'] == "clone-#{service}" }
  check(clone['params'].find { |p| p['name'] == 'commit' }['value'] == '$(tasks.resolve-source.results.commit)', 'Clone is not pinned')
end
update = ptasks.find { |t| t['name'] == 'update-gitops' }
check(update['runAfter'].sort == services.map { |s| "verify-#{s}" }.sort, 'GitOps must wait for all verifications')
check(tasks['frontend-release-update']['workspaces'].map { |w| w['name'] } == ['git-credentials'], 'GitOps must not mount three source PVCs')
manual = YAML.load_file('customer-transfer/frontend-release-test/pipelinerun.yaml')
manual['spec']['workspaces'].select { |w| w['volumeClaimTemplate'] }.each do |workspace|
  check(workspace.dig('volumeClaimTemplate', 'spec', 'resources', 'requests', 'storage') == '3Gi', 'Release workspace must request 3Gi')
end
acl = YAML.load_file('customer-transfer/devops-apply/pipelinerun-acl.yaml')
acl['spec']['workspaces'].select { |w| w['volumeClaimTemplate'] }.each do |workspace|
  check(workspace.dig('volumeClaimTemplate', 'spec', 'resources', 'requests', 'storage') == '3Gi', 'ACL workspace must request 3Gi')
end
check(manual['spec']['pipelineRef']['name'] == pipeline['metadata']['name'], 'Wrong manual pipeline reference')
check(manual['spec']['workspaces'].map { |w| w['name'] }.sort == pipeline['spec']['workspaces'].map { |w| w['name'] }.sort, 'PipelineRun workspace mismatch')
variant = docs(run(*base, '-f', 'customer-transfer/frontend-release-test/values-release.yaml', '--set', 'frontendRelease.scanEnabled=false,frontendRelease.allowTestFailure=false'))
variant = variant.find { |d| d.dig('metadata', 'name') == pipeline['metadata']['name'] }
check(variant['spec']['tasks'].none? { |t| t['name'].start_with?('scan-', 'gate-') || t.key?('onError') }, 'Strict-test/no-scan variant incorrect')
services.each do |service|
  sign = variant['spec']['tasks'].find { |t| t['name'] == "sign-#{service}" }
  check(sign['runAfter'] == ["build-#{service}"], 'No-scan signing must explicitly follow build')
end

gitops = 'customer-transfer/frontend-release-test/gitops/tekton-frontend-test'
check(docs(run('helm', 'template', 'frontend-release-test-root', gitops, '-n', 'development')).empty?, 'Empty release must not create workloads')
Dir.mktmpdir('frontend-release-validation-') do |tmp|
  FileUtils.cp_r(gitops, "#{tmp}/gitops")
  image_map = services.to_h { |s| [s, {'repository' => "registry.example/devops/#{s}", 'tag' => 'abcdef01', 'digest' => 'sha256:' + 'a' * 64}] }
  File.write("#{tmp}/gitops/releases/frontend.json", JSON.generate({'schemaVersion' => 1, 'sourceCommit' => 'abcdef01' + 'b' * 32, 'pipelineRun' => 'test', 'images' => image_map}))
  apps = docs(run('helm', 'template', 'frontend-release-test-root', "#{tmp}/gitops", '-n', 'development'))
  check(apps.size == 3, 'Expected three Argo CD Applications')
  apps.each do |app|
    check(app.dig('metadata', 'namespace') == 'development', 'Wrong Argo namespace')
    check(app.dig('spec', 'destination', 'namespace') == 'frontend-tekton-test', 'Destination isolation lost')
    values = YAML.safe_load(app.dig('spec', 'source', 'helm', 'values'))
    File.write("#{tmp}/values.yaml", values.to_yaml)
    objects = docs(run('helm', 'template', app['metadata']['name'], 'apps/frontend/helm', '-f', "#{tmp}/values.yaml"))
    check(objects.map { |o| o['kind'] }.sort == %w[Deployment Route Service], 'Unexpected application resources')
    deployment = objects.find { |o| o['kind'] == 'Deployment' }
    check(deployment.dig('spec', 'template', 'spec', 'containers', 0, 'image') == values['image']['repository'] + '@' + values['image']['digest'], 'Deployment is not pinned to verified digest')
  end
  _, _, status = Open3.capture3('helm', 'template', 'bad', 'apps/frontend/helm', '--set', 'image.repository=registry.example/x,image.digest=latest')
  check(!status.success?, 'Chart accepted non-digest reference')
  release.select { |d| %w[frontend-release-resolve frontend-release-update].include?(d.dig('metadata', 'name')) }.each do |task|
    task['spec']['steps'].each do |step|
      next unless step['script'].start_with?('#!/bin/sh')
      File.write("#{tmp}/step.sh", step['script'])
      run('sh', '-n', "#{tmp}/step.sh")
    end
  end
end
puts 'Passed rendered Pipeline, Task, PipelineRun, GitOps, chart, and shell checks'
