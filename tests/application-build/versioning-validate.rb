require 'yaml'
require 'json'
require 'open3'
Dir.chdir(File.expand_path('../..', __dir__))
out, err, status = Open3.capture3('helm', 'template', 'release-pipeline', 'pipelines/chart', '-n', 'devops', '-f', 'customer-transfer/application-build/values.yaml')
raise err unless status.success?
docs = YAML.load_stream(out).compact
File.write('/tmp/mofa-versioning-fixture.json', JSON.generate(docs))
tasks = docs.select { |d| d['kind'] == 'Task' }.to_h { |d| [d['metadata']['name'], d['spec']] }
%w[backend frontend].each do |scope|
  pipeline = docs.find { |d| d['kind'] == 'Pipeline' && d['metadata']['name'] == "application-#{scope}-build-fanout" }['spec']
  names = pipeline['tasks'].map { |t| t['name'] }
  raise 'Missing version reservation/finalization' unless names.include?('reserve-versions') && names.last == 'record-versions'
  raise 'Finalize before GitOps' unless pipeline['tasks'].last['runAfter'] == ['update-gitops']
  pipeline.to_json.scan(/\$\(tasks\.([^.]+)\.results\.([^)]+)\)/).each do |producer, name|
    task = pipeline['tasks'].find { |t| t['name'] == producer }
    raise "Missing result #{producer}/#{name}" unless task && tasks[task['taskRef']['name']]['results'].any? { |r| r['name'] == name }
  end
  definitions = tasks.fetch("#{scope}-version-reserve")
  raise 'Use string results for installed API compatibility' unless definitions['results'].all? { |r| !r['type'] || r['type'] == 'string' }
  example = definitions['results'].to_h { |r| [r['name'], r['name'] == 'tags-json' ? JSON.generate(definitions['results'].reject { |v| v['name'] == 'tags-json' }.to_h { |v| [v['name'].delete_prefix('tag-'), '1.0.0-rc.1'] }) : '1.0.0-rc.1'] }
  raise 'Version Task results exceed safe termination-message budget' if JSON.generate(example.map { |name, value| {name: name, value: value} }).bytesize > 3500
end
puts 'PASS: versioned task/result references, ordering, string-result compatibility, bounded results and Helm fixtures'
