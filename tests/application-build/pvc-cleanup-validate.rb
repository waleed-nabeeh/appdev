require 'yaml'
require 'open3'
Dir.chdir(File.expand_path('../..', __dir__))
def render(*flags)
  out, err, status = Open3.capture3('helm', 'template', 'release-pipeline', 'pipelines/chart', '-n', 'devops',
    '-f', 'customer-transfer/application-build/values.yaml', *flags)
  raise err unless status.success?
  YAML.load_stream(out).compact
end
docs = render
name = 'application-build-pvc-cleanup'
job = docs.find { |d| d['kind'] == 'CronJob' && d.dig('metadata', 'name') == name }
raise 'Missing Friday schedule/timezone' unless job.dig('spec', 'schedule') == '0 3 * * 5' && job.dig('spec', 'timeZone') == 'Asia/Riyadh'
raise 'Overlap not prevented' unless job.dig('spec', 'concurrencyPolicy') == 'Forbid'
pod = job.dig('spec', 'jobTemplate', 'spec', 'template', 'spec')
raise 'Wrong service account' unless pod['serviceAccountName'] == name
raise 'Missing registry authentication' unless pod['imagePullSecrets'].include?({'name' => 'registry-auth'})
raise 'Wrong approved image' unless pod['containers'][0]['image'].end_with?('/devops/nodejs-24:ubi9')
role = docs.find { |d| d['kind'] == 'Role' && d.dig('metadata', 'name') == name }
writes = role['rules'].select { |r| (r['verbs'] & %w[create update patch delete deletecollection *]).any? }
raise 'Excess write permissions' unless writes.size == 1 && writes[0]['resources'] == ['persistentvolumeclaims'] && writes[0]['verbs'].sort == %w[delete get list]
raise 'Unexpected cluster RBAC' if docs.any? { |d| %w[ClusterRole ClusterRoleBinding].include?(d['kind']) && d.dig('metadata', 'name') == name }
disabled = render('--set', 'pvcCleanup.enabled=false')
raise 'Resources remain when disabled' if disabled.any? { |d| d.dig('metadata', 'name') == name }
raise 'Cleanup changes existing manifests' unless docs.reject { |d| d.dig('metadata', 'name') == name } == disabled
puts 'PASS: cleanup schedule, namespace RBAC, approved image/pull Secret, disabled mode and unchanged existing manifests'
