#!/usr/bin/env ruby
require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'

def check(condition, message)
  raise message unless condition
end

def render(*extra)
  out, err, status = Open3.capture3('helm', 'template', 'release-pipeline', './pipelines/chart', '-n', 'devops',
                                  '-f', 'customer-transfer/application-build/values.yaml', *extra)
  check(status.success?, err)
  YAML.load_stream(out).compact
end

docs = render
index = docs.to_h { |d| [[d['kind'], d['metadata']['name']], d] }
spec = index.fetch(['Pipeline', 'application-keycloak-build'])['spec']
tasks = spec['tasks'].to_h { |t| [t['name'], t] }
definitions = tasks.transform_values { |t| t['taskSpec'] || index.fetch(['Task', t['taskRef']['name']])['spec'] }
order = %w[clone validate build-image scan-image security-gate push-image sign-image]
check(tasks.keys == order, 'Unexpected pipeline flow')
order.each_cons(2) { |before, after| check(tasks[after]['runAfter'] == [before], "Missing failure gate before #{after}") }
tasks.each do |name, task|
  check(!task.key?('when'), 'Security stages must not be skipped')
  if name == 'security-gate'
    check(task['onError'] == 'continue', 'Customer temporary advisory gate must continue on failure')
  else
    check(!task.key?('onError'), 'Only the security gate may ignore failure')
  end
  definition = definitions[name]
  supplied = task.fetch('params', []).map { |p| p['name'] }
  declared = definition.fetch('params', []).map { |p| p['name'] }
  check((supplied - declared).empty?, "Unknown parameter in #{name}")
  definition.fetch('params', []).reject { |p| p.key?('default') }.each do |p|
    check(supplied.include?(p['name']), "Missing parameter in #{name}")
  end
  bindings = task.fetch('workspaces', [])
  definition.fetch('workspaces', []).reject { |w| w['optional'] }.each do |w|
    check(bindings.any? { |b| b['name'] == w['name'] && spec['workspaces'].any? { |s| s['name'] == b['workspace'] } }, "Missing workspace in #{name}")
  end
end
spec.to_json.scan(/\$\(tasks\.([^.]+)\.results\.([^)]+)\)/).each do |producer, result|
  check(definitions.fetch(producer).fetch('results', []).any? { |r| r['name'] == result }, 'Invalid result reference')
end
strict = render('--set', 'keycloakBuild.allowSecurityGateFailure=false').find { |d| d['kind'] == 'Pipeline' && d['metadata']['name'] == 'application-keycloak-build' }
strict_gate = strict['spec']['tasks'].find { |t| t['name'] == 'security-gate' }
check(!strict_gate.key?('onError'), 'Strict policy enforcement must be restorable')
build = tasks['build-image']
check(build['params'].find { |p| p['name'] == 'image' }['value'].end_with?(':candidate-$(context.pipelineRun.uid)'), 'Candidate must be unique per run')
check(!definitions['build-image']['steps'][0].key?('env'), 'Build must not require proxy Secret')
%w[scan-image security-gate].each do |name|
  check(tasks[name]['params'][0]['value'].end_with?('@$(tasks.build-image.results.image-digest)'), 'Must scan/check by digest')
end
check(tasks['sign-image']['params'][0]['value'] == '$(tasks.push-image.results.image-url)', 'Must sign published digest')
run = YAML.safe_load(index.fetch(['ConfigMap', 'keycloak-build-run-template'])['data']['pipelinerun.yaml'])
check(run.dig('spec', 'pipelineRef', 'name') == 'application-keycloak-build', 'Run references wrong pipeline')
check(run.dig('spec', 'taskRunTemplate', 'serviceAccountName') == 'pipeline', 'Run service account')
render('--set', 'keycloakBuild.enabled=false').each do |doc|
  check(index[[doc['kind'], doc['metadata']['name']]] == doc, "Existing resource changed: #{doc['metadata']['name']}")
end

Dir.mktmpdir('keycloak-publish-test') do |dir|
  auth = File.join(dir, 'auth')
  FileUtils.mkdir_p(auth)
  File.write(File.join(auth, '.dockerconfigjson'), '{}')
  File.write(File.join(dir, 'skopeo'), <<~'SH')
    #!/usr/bin/env bash
    set -eu
    test "$1" = copy
    test "$2" = --authfile
    test "$4" = --preserve-digests
    test "$5" = --digestfile
    test "$7" = "docker://${IMAGE_REPOSITORY}@${SCANNED_DIGEST}"
    test "$8" = "docker://${IMAGE_REPOSITORY}:${IMAGE_TAG}"
    test -z "${HTTPS_PROXY:-}"
    test "${MOCK_FAIL:-0}" != 1
    printf '%s' "$MOCK_DIGEST" > "$6"
  SH
  FileUtils.chmod(0755, File.join(dir, 'skopeo'))
  # Exercise tag defaults/rejection and CRLF parsing without a Git server.
  File.write(File.join(dir, 'git'), "#!/bin/sh\nprintf '%s\\n' 12345678aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n")
  FileUtils.chmod(0755, File.join(dir, 'git'))
  %w[JDBC-driver/mssql-jdbc.jar SPI-jar-files/applicant-portal-keycloak-extension.jar SPI-jar-files/nafath-keycloak-extension.jar].each do |jar|
    file = File.join(dir, jar)
    FileUtils.mkdir_p(File.dirname(file))
    File.write(file, 'nonempty-test-fixture')
  end
  base = 'quay-registry-prod.apps.hub-visa-ocp.mofa.gov.sa/devops/keycloak-rhel9:26.6'
  File.binwrite(File.join(dir, 'Dockerfile'), "FROM #{base}\r\nENV KC_DB=mssql\r\n")
  validation = definitions['validate']['steps'][0]['script']
    .gsub('$(results.commit.path)', File.join(dir, 'commit'))
    .gsub('$(results.tag.path)', File.join(dir, 'tag'))
  validation_path = File.join(dir, 'validate.sh')
  File.write(validation_path, validation)
  validation_env = {'PATH' => "#{dir}:#{ENV['PATH']}", 'BASE_IMAGE' => base}
  {' ' => false, '' => true, '26.6-custom-1' => true, "good\n" => false,
   'candidate-other-run' => false, '-bad' => false, 'a' * 129 => false}.each do |tag, expected|
    _, err, status = Open3.capture3(validation_env.merge('IMAGE_TAG' => tag), 'sh', validation_path, chdir: dir)
    check(status.success? == expected, "Incorrect tag validation: #{tag.inspect}: #{err}")
    check(File.read(File.join(dir, 'tag')) == (tag.empty? ? '12345678' : tag), 'Wrong resolved tag') if expected
  end
  script = definitions['push-image']['steps'][0]['script']
  script = script.gsub('$(workspaces.registry-auth.path)', auth)
                 .gsub('$(results.image-digest.path)', File.join(dir, 'digest'))
                 .gsub('$(results.image-url.path)', File.join(dir, 'url'))
                 .gsub('/tmp/published-digest', File.join(dir, 'published'))
  script_path = File.join(dir, 'publish.sh')
  File.write(script_path, script)
  digest = "sha256:#{'a' * 64}"
  env = {'PATH' => "#{dir}:#{ENV['PATH']}", 'IMAGE_REPOSITORY' => 'quay.example/devops/keycloak-custom',
         'IMAGE_TAG' => '26.6-custom-1', 'SCANNED_DIGEST' => digest, 'MOCK_DIGEST' => digest, 'HTTPS_PROXY' => 'must-be-unset'}
  _, err, status = Open3.capture3(env, 'bash', script_path)
  check(status.success?, err)
  check(File.read(File.join(dir, 'url')) == "#{env['IMAGE_REPOSITORY']}@#{digest}", 'Wrong published reference')
  [{'MOCK_DIGEST' => "sha256:#{'b' * 64}"}, {'MOCK_FAIL' => '1'}].each do |failure|
    FileUtils.rm_f(File.join(dir, 'url'))
    _, _, status = Open3.capture3(env.merge(failure), 'bash', script_path)
    check(!status.success? && !File.exist?(File.join(dir, 'url')), 'Publication failure must stop results/signing')
  end
  definitions.values.each do |definition|
    definition.fetch('steps', []).each do |step|
      next unless step['script']
      file = File.join(dir, 'syntax.sh')
      File.write(file, step['script'])
      _, err, status = Open3.capture3('bash', '-n', file)
      check(status.success?, err)
    end
  end
end
puts 'PASS: gated task graph, digest references, credentials/workspaces, unchanged existing resources, publication success/failure and shell syntax'
