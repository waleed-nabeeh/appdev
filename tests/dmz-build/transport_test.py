#!/usr/bin/env python3
"""Exercise real tar/shell transport with mocked SSH/Podman, never a live VM."""
import json
import os
from pathlib import Path
import subprocess
import tempfile

REPO = Path(__file__).resolve().parents[2]
CLIENT = (REPO / 'pipelines/chart/files/dmz-build-client.sh').read_text()
RUNNER = REPO / 'pipelines/chart/files/dmz-build-runner.sh'


def executable(path, text):
    path.write_text(text)
    path.chmod(0o755)


with tempfile.TemporaryDirectory(prefix='dmz-test-') as tmp:
    root = Path(tmp)
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    remote = root / 'remote'
    remote.mkdir()
    source = root / 'source'
    (source / 'shared').mkdir(parents=True)
    (source / 'shared/shared.csproj').write_text('shared project')
    (source / 'Dockerfile').write_text('FROM internal/base\nCOPY . .\n')
    (source / '.dockerignore').write_text('.git\n')
    (source / '.git').mkdir()
    (source / '.git/config').write_text('excluded')
    auth = root / 'auth'
    auth.mkdir()
    (auth / '.dockerconfigjson').write_text('{}')
    npm = root / 'npm'
    npm.mkdir()
    (npm / 'NPM_TOKEN').write_text('test-token-not-a-real-credential')
    ssh_auth = root / 'ssh'
    ssh_auth.mkdir()
    (ssh_auth / 'ssh-privatekey').write_text('mock-private-key')
    (ssh_auth / 'known_hosts').write_text('mock-host-key')
    executable(bin_dir / 'ssh-keygen', '#!/bin/sh\nexit 0\n')
    executable(bin_dir / 'ssh', '''#!/usr/bin/env python3
import os, subprocess, sys
assert ('StrictHostKeyChecking=yes' in sys.argv or 'StrictHostKeyChecking=accept-new' in sys.argv)
assert 'BatchMode=yes' in sys.argv
assert 'IdentitiesOnly=yes' in sys.argv
sys.exit(subprocess.run(['bash', '-c', sys.argv[-1]], cwd=os.environ['MOCK_REMOTE']).returncode)
''')
    # Python flock uses actual OS locks on the inherited descriptors, like util-linux flock.
    executable(bin_dir / 'flock', '''#!/usr/bin/env python3
import fcntl, sys
mode = sys.argv[1]
flags = {'-x': fcntl.LOCK_EX, '-n': fcntl.LOCK_EX | fcntl.LOCK_NB, '-u': fcntl.LOCK_UN}[mode]
try:
    fcntl.flock(int(sys.argv[2]), flags)
except BlockingIOError:
    sys.exit(1)
''')
    executable(bin_dir / 'realpath', '''#!/usr/bin/env python3
import pathlib, sys
print(pathlib.Path(sys.argv[-1]).resolve(strict=True))
''')
    executable(bin_dir / 'podman', '''#!/usr/bin/env python3
import fcntl, json, os, pathlib, sys, time
args = sys.argv[1:]
if args == ['--version']:
    print('podman mock'); sys.exit(0)
if args[0] == 'create':
    assert '--pull=never' in args and '--network=none' in args
    print('diagnostic-container'); sys.exit(0)
if args[0] == 'rm':
    assert args[1] == 'diagnostic-container'; sys.exit(0)
if args[0] == 'export':
    import io, tarfile
    with tarfile.open(fileobj=sys.stdout.buffer, mode='w|') as archive:
        for path in ['etc/passwd', 'usr/bin/bash', 'usr/lib64/ld-linux-x86-64.so.2']:
            entry=tarfile.TarInfo(path); entry.size=1
            archive.addfile(entry,io.BytesIO(b'x'))
    sys.exit(0)
if args[0] == 'info':
    print('true'); sys.exit(0)
if args[:2] == ['image', 'inspect']:
    print('sha256:fixture linux/amd64'); sys.exit(0)
if args[0] == 'run':
    assert '--pull=never' in args and '--network=none' in args
    assert args[args.index('--entrypoint')+1] == '/bin/sh'
    assert args[args.index('--user')+1] == '0:0'
    assert '--authfile' not in args and '--secret' not in args
    if os.environ.get('MOCK_DIAGNOSTIC_FAIL') == 'true':
        print('mock /bin/sh not found', file=sys.stderr); sys.exit(127)
    pathlib.Path(os.environ['DIAGNOSTIC_MARKER']).touch()
    print('uid=0 gid=0; node fixture; npm fixture'); sys.exit(0)
if args[:2] == ['image', 'rm']:

    sys.exit(0)
if args[0] in ('build', 'push'):
    if os.environ.get('EXPECT_PROXY') == 'true':
        assert os.environ['HTTP_PROXY'] == os.environ['http_proxy'] == 'http://fixture-user:fixture-pass@proxy.example:8080'
        assert os.environ['HTTPS_PROXY'] == os.environ['https_proxy'] == os.environ['HTTP_PROXY']
        assert os.environ['NO_PROXY'] == os.environ['no_proxy'] == 'localhost,quay.example,azure.example'
    else:
        assert not any(os.environ.get(k) for k in ['HTTP_PROXY','HTTPS_PROXY','http_proxy','https_proxy','ALL_PROXY','all_proxy'])
    assert '--tls-verify='+os.environ.get('EXPECT_TLS_VERIFY', 'true') in args
if args[0] == 'build':
    if os.environ.get('DIAGNOSTIC_BASE_IMAGE'):
        assert pathlib.Path(os.environ['DIAGNOSTIC_MARKER']).exists(), 'build started before base-image check'
    assert '--http-proxy=true' in args
    assert pathlib.Path('shared/shared.csproj').is_file(), 'full repository missing'
    assert pathlib.Path('.dockerignore').is_file()
    assert not pathlib.Path('.git').exists()
    credential = pathlib.Path(args[args.index('--authfile')+1])
    assert credential.is_file() and not credential.is_relative_to(pathlib.Path.cwd())
    expected = os.environ.get('EXPECT_NPM') == 'true'
    assert ('--secret' in args) == expected
    assert '--build-arg' in args and 'BUILD_ENVIRONMENT=dev with space' in args
    if os.environ.get('MOCK_FAIL') == 'build': sys.exit(14)
    if os.environ.get('TRACK'):
        track = pathlib.Path(os.environ['TRACK'])
        with track.open('r+') as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            d=json.load(f); d['active']+=1; d['max']=max(d['max'],d['active'])
            f.seek(0); json.dump(d,f); f.truncate()
        time.sleep(0.4)
        with track.open('r+') as f:
            fcntl.flock(f, fcntl.LOCK_EX)
            d=json.load(f); d['active']-=1; f.seek(0); json.dump(d,f); f.truncate()
    sys.exit(0)
if args[0] == 'push':
    if os.environ.get('MOCK_FAIL') == 'push': sys.exit(15)
    pathlib.Path(args[args.index('--digestfile')+1]).write_text('sha256:' + 'a'*64)
    sys.exit(0)
sys.exit(2)
''')
    proxy = root / 'proxy'
    proxy.mkdir()
    for key, value in {'HTTP_PROXY':'http://fixture-user:fixture-pass@proxy.example:8080',
                       'HTTPS_PROXY':'http://fixture-user:fixture-pass@proxy.example:8080',
                       'NO_PROXY':'localhost,quay.example,azure.example'}.items():
        (proxy/key).write_text(value+'\r\n')
    script = CLIENT.replace('/dmz-proxy', str(proxy)).replace('/ssh-auth', str(ssh_auth)).replace('/opt/dmz-build/runner.sh', str(RUNNER))
    client_path = root / 'client.sh'
    client_path.write_text(script)
    env = dict(os.environ, PATH=str(bin_dir)+':'+os.environ['PATH'], MOCK_REMOTE=str(remote),
               DMZ_HOST='172.28.50.40', DMZ_USER='appdevpipeline', DMZ_PORT='22',
               DMZ_ROOT='tekton-builds', DMZ_MAX_BUILDS='4', DMZ_WAIT_SECONDS='30',
               SOURCE_DIR=str(source), REGISTRY_AUTH=str(auth), NPM_AUTH=str(npm),
               BUILD_IMAGE='quay.example/devops/acl-service:dmz-test-1',
               BUILD_CONTEXT='.', CONTAINERFILE='Dockerfile')
    for label, use_npm, failure in [('frontend', 'true', ''), ('backend', 'false', ''),
                                     ('build-fail', 'true', 'build'), ('push-fail', 'true', 'push')]:
        case = root / label
        case.mkdir()
        run_env = dict(env, JOB_ID=label, NPM_AUTH_BOUND=use_npm, EXPECT_NPM=use_npm,
                       MOCK_FAIL=failure, RESULT_DIGEST=str(case/'digest'), RESULT_IMAGE=str(case/'image'))
        result = subprocess.run(['bash', str(client_path), 'BUILD_ENVIRONMENT=dev with space'],
                                env=run_env, text=True, capture_output=True)
        assert (result.returncode == 0) == (not failure), (label, result.stdout, result.stderr)
        assert not (remote/'tekton-builds/jobs'/label).exists(), 'remote workspace/credentials not cleaned'
        if not failure:
            assert (case/'digest').read_text() == 'sha256:'+'a'*64
            assert (case/'image').read_text() == env['BUILD_IMAGE']+'@sha256:'+'a'*64
        else:
            assert not (case/'digest').exists(), 'failed build returned successful results'
        print('PASS:', label, 'full context, secret isolation, result handling and cleanup')
    for fail in [False, True]:
        case = root / ('diagnostic-fail' if fail else 'diagnostic-pass')
        case.mkdir()
        result = subprocess.run(['bash', str(client_path), 'BUILD_ENVIRONMENT=dev with space'],
             env=dict(env, JOB_ID=case.name, NPM_AUTH_BOUND='false', EXPECT_NPM='false',
                      DIAGNOSTIC_BASE_IMAGE='quay.example/devops/node:fixture',
                      MOCK_DIAGNOSTIC_FAIL=str(fail).lower(), DIAGNOSTIC_MARKER=str(case/'checked'),
                      RESULT_DIGEST=str(case/'digest'), RESULT_IMAGE=str(case/'image')),
             text=True, capture_output=True)
        assert (result.returncode == 0) == (not fail), (result.stdout, result.stderr)
        if fail:
            assert 'BASE IMAGE CHECK FAILED' in result.stderr
            assert 'usr/bin/bash' in result.stdout and 'Filesystem entry count:' in result.stdout
            assert not (case/'digest').exists() and not (case/'checked').exists()
        else:
            assert 'BASE IMAGE CHECK PASSED' in result.stdout and (case/'digest').exists()
        assert not (remote/'tekton-builds/jobs'/case.name).exists()
    print('PASS: in-pipeline base-image check precedes build, uses no pull/network/secrets, and blocks build on failure')
    case = root / 'proxy-enabled'
    case.mkdir()
    result = subprocess.run(['bash', str(client_path), 'BUILD_ENVIRONMENT=dev with space'],
              env=dict(env, JOB_ID=case.name, NPM_AUTH_BOUND='false', EXPECT_NPM='false',
                       DMZ_PROXY_ENABLED='true', EXPECT_PROXY='true', RESULT_DIGEST=str(case/'digest'),
                       RESULT_IMAGE=str(case/'image')), text=True, capture_output=True)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert 'fixture-pass' not in result.stdout+result.stderr
    assert not (remote/'tekton-builds/jobs'/case.name).exists()
    print('PASS: secret proxy values forwarded to VM build/push, normalized, not evaluated/logged and cleaned')
    # Two additional jobs queue behind the same four globally shared locks.
    track = root / 'concurrency.json'
    track.write_text('{"active":0,"max":0}')
    processes = []
    for number in range(6):
        case = root / ('parallel-'+str(number))
        case.mkdir()
        run_env = dict(env, JOB_ID=case.name, NPM_AUTH_BOUND='false', EXPECT_NPM='false',
                       TRACK=str(track), RESULT_DIGEST=str(case/'digest'), RESULT_IMAGE=str(case/'image'))
        processes.append(subprocess.Popen(['bash', str(client_path), 'BUILD_ENVIRONMENT=dev with space'],
                         env=run_env, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE))
    for process in processes:
        stdout, stderr = process.communicate(timeout=40)
        assert process.returncode == 0, (stdout, stderr)
    stats = json.loads(track.read_text())
    assert stats['active'] == 0 and 1 < stats['max'] <= 4, stats
    print('PASS: six simultaneous jobs respect the shared four-build limit:', stats)
    case = root / 'increase-limit'
    case.mkdir()
    result = subprocess.run(['bash', str(client_path), 'BUILD_ENVIRONMENT=dev with space'],
              env=dict(env, JOB_ID=case.name, DMZ_MAX_BUILDS='14', NPM_AUTH_BOUND='false',
                       EXPECT_NPM='false', RESULT_DIGEST=str(case/'digest'), RESULT_IMAGE=str(case/'image')),
              text=True, capture_output=True)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert (remote/'tekton-builds/slots/max-builds').read_text() == '14'
    assert 'Increased shared DMZ build limit from 4 to 14.' in result.stdout
    case = root / 'stale-limit'
    case.mkdir()
    result = subprocess.run(['bash', str(client_path)],
              env=dict(env, JOB_ID=case.name, NPM_AUTH_BOUND='false', EXPECT_NPM='false',
                       RESULT_DIGEST=str(case/'digest'), RESULT_IMAGE=str(case/'image')),
              text=True, capture_output=True)
    assert result.returncode != 0 and 'VM build limit is higher' in result.stderr
    assert (remote/'tekton-builds/slots/max-builds').read_text() == '14'
    env['DMZ_MAX_BUILDS'] = '14'
    print('PASS: pipeline automatically raises stored limit to 14 and stale runs cannot lower it')
    (ssh_auth/'known_hosts').unlink()
    result = subprocess.run(['bash', str(client_path)], env=dict(env, JOB_ID='missing-host',
                            NPM_AUTH_BOUND='false'), text=True, capture_output=True)
    assert result.returncode != 0 and 'known_hosts' in result.stderr
    print('PASS: missing verified host key fails closed before source/credential transfer')

    case = root / 'private-key-only'
    case.mkdir()
    result = subprocess.run(['bash', str(client_path), 'BUILD_ENVIRONMENT=dev with space'],
                            env=dict(env, JOB_ID=case.name, NPM_AUTH_BOUND='false', EXPECT_NPM='false',
                                     DMZ_HOST_KEY_POLICY='accept-new', DMZ_TLS_VERIFY='false', EXPECT_TLS_VERIFY='false', RESULT_DIGEST=str(case/'digest'),
                                     RESULT_IMAGE=str(case/'image')), text=True, capture_output=True)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert (case/'digest').read_text() == 'sha256:'+'a'*64
    print('PASS: private-key-only test mode with TLS disabled on both Podman build and push')

# Use real ssh-keygen to validate the normalization, without exposing key material.
with tempfile.TemporaryDirectory(prefix='dmz-key-format-') as tmp:
    root = Path(tmp)
    original = root/'original'
    subprocess.run(['ssh-keygen', '-q', '-t', 'rsa', '-b', '2048', '-N', '', '-f', str(original)],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    content = original.read_bytes()
    for name, raw in [('lf', content), ('no-final-newline', content.rstrip(b'\n')),
                      ('crlf', content.replace(b'\n', b'\r\n'))]:
        source = root/(name+'.key')
        normalized = root/(name+'.normalized')
        source.write_bytes(raw)
        with normalized.open('wb') as target:
            subprocess.run(['awk', '{sub(/\\r$/, ""); print}', str(source)], stdout=target, check=True)
        normalized.chmod(0o600)
        result = subprocess.run(['ssh-keygen', '-y', '-P', '', '-f', str(normalized)],
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        assert result.returncode == 0, name
    print('PASS: real SSH key parsing after LF, CRLF and missing-final-newline normalization')
