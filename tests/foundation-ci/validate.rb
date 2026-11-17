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

def render(*extra)
  out, err, status = Open3.capture3('helm', 'template', 'release-pipeline', './pipelines/chart', '-n', 'devops',
    '-f', 'customer-transfer/application-build/values.yaml', *extra)
  check(status.success?, err)
  YAML.load_stream(out).compact
end

docs = render
index = docs.to_h { |d| [[d['kind'], d['metadata']['name']], d] }
spec = index.fetch(['Pipeline', 'application-foundation-ci'])['spec']
tasks = spec['tasks'].to_h { |t| [t['name'], t] }
check(tasks.keys == %w[clone validate-chart package-chart publish-chart], 'Wrong task flow')
tasks.keys.each_cons(2) { |a, b| check(tasks[b]['runAfter'] == [a], 'Broken dependency') }
definitions = tasks.transform_values { |t| t['taskSpec'] || index.fetch(['Task', t['taskRef']['name']])['spec'] }
tasks.each do |name, task|
  check(!task.key?('onError') && !task.key?('when'), 'Stages must remain blocking')
  definition = definitions[name]
  inputs = task.fetch('params', []).map { |p| p['name'] }
  check((inputs - definition.fetch('params', []).map { |p| p['name'] }).empty?, 'Unknown task input')
  definition.fetch('params', []).reject { |p| p.key?('default') }.each { |p| check(inputs.include?(p['name']), 'Missing task input') }
  definition.fetch('workspaces', []).reject { |w| w['optional'] }.each do |w|
    check(task.fetch('workspaces', []).any? { |b| b['name'] == w['name'] && spec['workspaces'].any? { |p| p['name'] == b['workspace'] } }, 'Missing workspace')
  end
end
spec.to_json.scan(/\$\(tasks\.([^.]+)\.results\.([^)]+)\)/).each do |producer, result|
  check(definitions.fetch(producer).fetch('results', []).any? { |r| r['name'] == result }, 'Invalid result reference')
end
check(!spec.to_json.include?('pipeline-proxy'), 'Must not depend on proxy')
render('--set', 'foundationCi.enabled=false').each do |d|
  check(index[[d['kind'], d['metadata']['name']]] == d, 'Changed an existing resource')
end
run = YAML.safe_load(index.fetch(['ConfigMap', 'foundation-ci-run-template'])['data']['pipelinerun.yaml'])
check(run.dig('spec', 'pipelineRef', 'name') == 'application-foundation-ci', 'Wrong run template')
helm_bin = ENV.fetch('HELM_TEST_BINARY', Open3.capture2('which', 'helm')[0].strip)
Dir.mktmpdir('foundation-ci') do |dir|
  source = File.join(dir, 'source')
  chart = File.join(source, 'app-chart', '1.0.0')
  FileUtils.mkdir_p(File.join(chart, 'templates'))
  File.write(File.join(chart, 'Chart.yaml'), "apiVersion: v2\nname: app-chart\nversion: 1.0.0\nappVersion: original\ndependencies:\n- name: access-control\n  version: 1.0.0\n  repository: file://charts/access-control\n")
  FileUtils.mkdir_p(File.join(chart, 'charts', 'access-control'))
  File.write(File.join(chart, 'charts', 'access-control', 'Chart.yaml'), "apiVersion: v2\nname: access-control\nversion: 1.0.0\n")
  File.write(File.join(chart, 'values.yaml'), "message: default\n")
  File.write(File.join(chart, 'templates', 'config.yaml'), "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: {{ .Release.Name }}\ndata:\n  version: {{ .Chart.Version | quote }}\n  message: {{ .Values.message | quote }}\n")
  File.write(File.join(source, 'validation.yaml'), "message: override\n")
  results = File.join(dir, 'results')
  FileUtils.mkdir_p(results)
  prepare = lambda do |script|
    script = script.gsub('$(workspaces.source.path)', dir).gsub('$(workspaces.registry-auth.path)', File.join(dir, 'auth'))
    script.gsub(/\$\(results\.([^.]+)\.path\)/) { File.join(results, Regexp.last_match(1)) }
  end
  bin = File.join(dir, 'bin')
  FileUtils.mkdir_p(bin)
  FileUtils.ln_s(helm_bin, File.join(bin, 'helm'))
  environment = {'PATH' => "#{bin}:#{ENV['PATH']}", 'CHART_PATH' => 'app-chart/1.0.0', 'CHART_VERSION' => '1.0.1-test.1', 'VALUES_FILE' => 'validation.yaml', 'RENDER_NAMESPACE' => 'devops'}
  validation = prepare.call(definitions['validate-chart']['steps'].last['script'])
  out, err, status = Open3.capture3(environment, 'sh', '-c', validation)
  check(status.success?, out + err)
  check(File.read(File.join(results, 'chart-name')) == 'app-chart', 'Wrong chart name')
  check(YAML.load_file(File.join(chart, 'Chart.yaml'))['version'] == '1.0.0', 'Source chart changed')
  check(File.read(File.join(dir, 'chart-ci', 'rendered.yaml')).include?('override'), 'Validation values ignored')
  out, err, status = Open3.capture3(environment, 'sh', '-c', prepare.call(definitions['package-chart']['steps'][0]['script']))
  check(status.success?, out + err)
  package = File.join(dir, 'chart-ci', 'dist', 'app-chart-1.0.1-test.1.tgz')
  out, err, status = Open3.capture3(helm_bin, 'show', 'chart', package)
  check(status.success?, err)
  metadata = YAML.safe_load(out)
  check(metadata['version'] == '1.0.1-test.1' && metadata['appVersion'] == 'original', 'Wrong packaged metadata')
  [{'CHART_PATH' => '../escape'}, {'CHART_VERSION' => '1.0'}, {'CHART_VERSION' => '1.0.0;id'}, {'VALUES_FILE' => '/tmp/values'}].each do |invalid|
    _, _, status = Open3.capture3(environment.merge(invalid), 'sh', '-c', validation)
    check(!status.success?, 'Unsafe input accepted')
  end
  # Publication is mocked: validate credential use, destination, logs and fail-closed behavior.
  FileUtils.mkdir_p(File.join(dir, 'auth'))
  File.write(File.join(dir, 'auth', '.dockerconfigjson'), '{}')
  FileUtils.rm(File.join(bin, 'helm'))
  File.write(File.join(bin, 'helm'), <<~'SH')
    #!/bin/sh
    set -eu
    test "$1" = push
    test -s "$2"
    test "$3" = oci://quay.example/devops
    test -s "$HELM_REGISTRY_CONFIG"
    test "${FAIL_PUSH:-0}" != 1
    printf 'Pushed: quay.example/devops/app-chart:1.0.1-test.1\nDigest: sha256:%064d\n' 0
  SH
  FileUtils.chmod(0755, File.join(bin, 'helm'))
  publish = prepare.call(definitions['publish-chart']['steps'][0]['script']).gsub('/tmp/chart-push.log', File.join(dir, 'push.log'))
  environment.merge!('CHART_NAME' => 'app-chart', 'OCI_REGISTRY' => 'oci://quay.example/devops')
  out, err, status = Open3.capture3(environment, 'sh', '-c', publish)
  check(status.success? && out.include?('Published chart: oci://quay.example/devops/app-chart:1.0.1-test.1'), out + err)
  FileUtils.rm(File.join(results, 'chart-reference'))
  out, _, status = Open3.capture3(environment.merge('FAIL_PUSH' => '1'), 'sh', '-c', publish)
  check(!status.success? && !File.exist?(File.join(results, 'chart-reference')) && !out.include?('completed successfully'), 'Failed push reported success')
end
puts 'PASS: task wiring, unchanged existing resources, actual lint/render/package/versioning, input validation and mocked OCI publication'
