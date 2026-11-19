require 'yaml'
require 'open3'
Dir.chdir(File.expand_path('../..', __dir__))
def render(*args)
  out, err, status = Open3.capture3('helm', 'template', 'release-pipeline', 'pipelines/chart', '-n', 'devops',
    '-f', 'customer-transfer/application-build/values.yaml', *args)
  raise err unless status.success?
  YAML.load_stream(out).compact
end
docs = render
secrets = docs.select { |d| d['kind'] == 'ExternalSecret' }
expected = %w[git-credentials registry-auth npm-auth rhacs-auth pipeline-proxy dmz-build-ssh]
raise 'Wrong Secret mapping set' unless secrets.map { |d| d.dig('spec', 'target', 'name') }.sort == expected.sort
secrets.each do |doc|
  spec = doc['spec']; name = spec.dig('target', 'name')
  raise 'Wrong resource namespace/name/API' unless doc.dig('metadata', 'namespace') == 'devops' && doc.dig('metadata', 'name') == 'pipeline-vault-' + name && doc['apiVersion'] == 'external-secrets.io/v1'
  expected_target = {'name' => name, 'creationPolicy' => 'Merge', 'deletionPolicy' => 'Retain',
    'template' => {'metadata' => {'labels' => {'customer.mofa.gov.sa/credential-source' => 'vault'}}}}
  raise 'Unsafe target lifecycle or metadata propagation' unless spec['target'] == expected_target
  raise 'Store changed' unless spec['secretStoreRef'] == {'name' => 'vault-backend', 'kind' => 'SecretStore'}
  raise 'Wrong Vault path or decoding' unless spec['dataFrom'] == [{'extract' => {'key' => 'devops/pipelines/' + name, 'decodingStrategy' => 'None'}}]
end
raise 'Chart must not create credential Secrets or replace Vault authentication' if docs.any? { |d| %w[Secret SecretStore ClusterSecretStore].include?(d['kind']) }
disabled = render('--set', 'externalSecrets.enabled=false')
raise 'Disabling sync changed pipeline resources' unless docs.reject { |d| d['kind'] == 'ExternalSecret' } == disabled
raise 'Unsupported older served API selection' unless render('--set', 'externalSecrets.apiVersion=external-secrets.io/v1beta1').select { |d| d['kind'] == 'ExternalSecret' }.all? { |d| d['apiVersion'] == 'external-secrets.io/v1beta1' }
one = render('--set-json', 'externalSecrets.secrets=[{"name":"git-credentials","remoteKey":"devops/pipelines/git-credentials"}]')
raise 'Staged single-secret migration failed' unless one.count { |d| d['kind'] == 'ExternalSecret' } == 1
out, err, status = Open3.capture3('helm', 'template', 'test', 'pipelines/chart')
raise err unless status.success?
raise 'Feature must default off' if YAML.load_stream(out).compact.any? { |d| d['kind'] == 'ExternalSecret' }
puts 'PASS: six existing Secret mappings, Merge/Retain, raw data, namespace/store reuse, API selection, staged migration and unchanged pipelines'
