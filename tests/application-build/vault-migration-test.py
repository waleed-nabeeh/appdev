"""Test migration with synthetic credentials and mocked oc/Vault, never real services."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / 'customer-transfer/application-build/migrate-secrets-to-vault.sh'
with tempfile.TemporaryDirectory(prefix='mofa-migrate-test-') as tmp:
    root = Path(tmp)
    binaries = root / 'bin'
    binaries.mkdir()
    output = root / 'output'
    output.mkdir()
    scratch = root / 'scratch'
    scratch.mkdir()
    fixtures = {
        'git-credentials': {'.git-credentials': 'https://fixture:synthetic-pat@azure.example\n'},
        'registry-auth': {'.dockerconfigjson': '{"auths":{"example":{"auth":"synthetic"}}}'},
        'npm-auth': {'NPM_TOKEN': 'synthetic-token'},
        'rhacs-auth': {'endpoint': 'central.example:443', 'token': 'synthetic-rhacs'},
        'pipeline-proxy': {'HTTP_PROXY': 'http://proxy:8080', 'HTTPS_PROXY': 'http://proxy:8080', 'NO_PROXY': 'azure.example'},
        'dmz-build-ssh': {'ssh-privatekey': '-----BEGIN FIXTURE-----\nsynthetic-key\n-----END FIXTURE-----\n', 'known_hosts': 'vm fixture\n'}
    }
    fixture_path = root / 'fixtures.json'
    fixture_path.write_text(json.dumps(fixtures))
    for name, source in {
        'oc': '''#!/usr/bin/env python3
import json, os, pathlib, sys
a=sys.argv[1:]
if a == ['whoami', '--show-server']:
 print(os.environ.get('MOCK_SERVER', 'https://api.hub-visa-ocp.mofa.gov.sa:6443')); sys.exit(0)
assert a[0:2] == ['-n','devops'] and a[2] == 'extract'
name=a[3].split('/')[1]
directory=pathlib.Path(a[4].split('=',1)[1])
assert directory.stat().st_mode & 0o777 == 0o700
for k,v in json.loads(pathlib.Path(os.environ['FIXTURES']).read_text())[name].items():
 (directory/k).write_text(v)
''',
        'vault': '''#!/usr/bin/env python3
import json, os, pathlib, sys
a=sys.argv[1:]
if a[:2] == ['read','-field=type']: print('kv'); sys.exit(0)
if a[:2] == ['read','-field=options']: print('map[version:'+os.environ.get('KV_VERSION','2')+']'); sys.exit(0)
assert a[:4] == ['kv','put','-mount=secret','-cas=0']
name=a[4].split('/')[-1]
dest=pathlib.Path(os.environ['OUTPUT'])/(name+'.json')
if dest.exists(): print('CAS mismatch',file=sys.stderr); sys.exit(2)
values={}
for arg in a[5:]:
 k,p=arg.split('=@',1)
 assert 'synthetic' not in arg
 f=pathlib.Path(p)
 assert f.stat().st_mode & 0o777 == 0o600
 values[k]=f.read_text()
dest.write_text(json.dumps(values))
print('created metadata only')
'''
    }.items():
        path = binaries / name
        path.write_text(source)
        path.chmod(0o755)
    env = dict(os.environ, PATH=str(binaries) + ':' + os.environ['PATH'], FIXTURES=str(fixture_path),
               OUTPUT=str(output), TMPDIR=str(scratch), VAULT_ADDR='https://vault.example')
    result = subprocess.run(['bash', str(SCRIPT)], env=env, text=True, capture_output=True)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert 'synthetic' not in result.stdout + result.stderr
    for name, values in fixtures.items():
        assert json.loads((output/(name+'.json')).read_text()) == values
    assert not list(scratch.glob('mofa-vault-migration.*')), 'Plaintext migration files remained'
    original = (output/'git-credentials.json').read_bytes()
    result = subprocess.run(['bash', str(SCRIPT), 'git-credentials'], env=env, text=True, capture_output=True)
    assert result.returncode != 0 and 'never overwritten' in result.stderr
    assert (output/'git-credentials.json').read_bytes() == original
    assert not list(scratch.glob('mofa-vault-migration.*')), 'Failure did not clean temporary credentials'
    for overrides, args in [({'KV_VERSION':'1'}, []), ({'MOCK_SERVER':'https://wrong.example'}, []), ({}, ['unrelated'])]:
        result = subprocess.run(['bash', str(SCRIPT), *args], env=dict(env, **overrides), text=True, capture_output=True)
        assert result.returncode != 0
        assert 'synthetic' not in result.stdout + result.stderr
    print('PASS: six raw Secret formats, hidden keys, private temporary files, cleanup, create-only CAS, cluster/KV checks and selection validation')
