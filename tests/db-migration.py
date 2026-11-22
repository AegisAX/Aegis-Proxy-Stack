"""Exercise a MariaDB migration using a new NPM installation and private Docker volumes."""

import argparse
import hashlib
import json
import os
import re
import secrets
import subprocess
import time
from pathlib import Path


API = """
import json, sys, urllib.error, urllib.request
opts = json.load(sys.stdin)
def request(method, path, data=None, token=None, expected_absent=False):
    body = None if data is None else json.dumps(data).encode()
    headers = {'Content-Type': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    req = urllib.request.Request('http://127.0.0.1:81/api' + path, body, headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=12) as reply:
            output = reply.read()
            return json.loads(output) if output else None
    except urllib.error.HTTPError as error:
        if expected_absent and error.code == 404:
            return None
        print('api_status', method, path, error.code, file=sys.stderr)
        if path.startswith('/nginx/proxy-hosts'):
            try:
                print('proxy_error', json.loads(error.read())['error']['message'][:250], file=sys.stderr)
            except (ValueError, KeyError, TypeError):
                pass
        raise SystemExit(1)
token = request('POST', '/tokens', {'identity': opts['email'], 'secret': opts['password']})['token']
hosts = '/nginx/proxy-hosts'
domain = 'proxy.db-trial.example'
record = {'domain_names': [domain], 'forward_scheme': 'http', 'forward_host': '127.0.0.1',
          'forward_port': opts['next_port'], 'advanced_config': '', 'locations': [],
          'meta': {}, 'use_openappsec': False, 'certificate_id': 0, 'access_list_id': 0}
if opts['id'] is None:
    saved = request('POST', hosts, record, token)
else:
    target = hosts + '/' + str(opts['id'])
    previous = request('GET', target, token=token)
    assert previous['domain_names'] == [domain] and previous['forward_port'] == opts['previous_port']
    saved = request('PUT', target, record, token)
current = request('GET', hosts + '/' + str(saved['id']), token=token)
assert current['forward_port'] == opts['next_port'] and current['domain_names'] == [domain]
scratch = dict(record, domain_names=['disposable.db-trial.example'])
created = request('POST', hosts, scratch, token)
scratch_path = hosts + '/' + str(created['id'])
assert request('GET', scratch_path, token=token)['domain_names'] == scratch['domain_names']
scratch['forward_port'] += 1
request('PUT', scratch_path, scratch, token)
assert request('GET', scratch_path, token=token)['forward_port'] == scratch['forward_port']
request('DELETE', scratch_path, token=token)
assert request('GET', scratch_path, token=token, expected_absent=True) is None
print(json.dumps({'id': current['id'], 'forward_port': current['forward_port']}))
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('baseline', 'candidate', 'npm'):
        parser.add_argument('--' + name, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--policy-template', type=Path, default=Path(__file__).resolve().parents[1]
                        / 'aegis-config/policy/local_policy.yaml.template')
    args = parser.parse_args()
    if args.output.exists() or not all(re.fullmatch('sha256:[0-9a-f]{64}', value)
                                       for value in (args.baseline, args.candidate, args.npm)):
        parser.error('use immutable local image IDs and a new output file')
    os.umask(0o077)
    project = 'aegis-db-qa-' + secrets.token_hex(8)
    label = 'org.aegis.db-qa=' + project
    db = project + '-db'
    npm = project + '-npm'
    policy = args.policy_template.read_bytes()
    volumes = {role: project + '-' + role for role in ('previous', 'new', 'rollback', 'app', 'certs', 'policy')}
    report = dict(project=project, baseline=args.baseline, candidate=args.candidate, npm=args.npm,
                  network_internal=True, published_ports=[], stages=[], phase='starting')
    app_password, root_password, web_password = [secrets.token_hex(24) for _ in range(3)]
    email = 'qa@database.example'

    def docker(*argv, data=None, env=None, check=True, timeout=60):
        result = subprocess.run(['docker', *argv], input=data, capture_output=True,
                                env={**os.environ, **(env or {})}, timeout=timeout)
        if check and result.returncode:
            # Docker logs and command output can contain database or bootstrap credentials.
            raise RuntimeError('Docker operation failed: ' + ' '.join(argv[:2]))
        return result

    def scoped_objects(kind):
        command = {'container': ['ps', '-aq'], 'volume': ['volume', 'ls', '-q'],
                   'network': ['network', 'ls', '-q']}[kind]
        return docker(*command, '--filter', 'label=' + label).stdout.decode().splitlines()

    def stop(name):
        docker('stop', '--time', '25', name)
        docker('rm', '-v', name)

    def sql(user, password, command, *, check=True):
        return docker('exec', '-i', '-e', 'MYSQL_PWD', db, 'mariadb', '--protocol=tcp',
                      '-h127.0.0.1', '-N', '-B', '-u', user, '-e', command,
                      env={'MYSQL_PWD': password}, check=check)

    def wait_for(test, stage):
        until = time.monotonic() + 95
        while time.monotonic() < until:
            if test():
                return
            time.sleep(1)
        raise RuntimeError(stage + ' readiness timeout')

    def start_db(image, volume, root):
        settings = dict(MYSQL_DATABASE='npm', MYSQL_USER='npm',
                        MYSQL_PASSWORD=app_password, MYSQL_ROOT_PASSWORD=root)
        environment = [arg for key in settings for arg in ('-e', key)]
        docker('run', '-d', '--name', db, '--label', label, '--network', project,
               '--network-alias', 'db', '--mount', 'type=volume,source=' + volume + ',target=/var/lib/mysql',
               '--log-driver', 'none', *environment, image, env=settings)
        wait_for(lambda: sql('root', root, 'SELECT 1', check=False).stdout.strip() == b'1'
                 and sql('npm', app_password, 'SELECT 1', check=False).stdout.strip() == b'1', 'DB')

    def start_npm(initial):
        settings = dict(DB_MYSQL_HOST='db', DB_MYSQL_PORT='3306', DB_MYSQL_USER='npm',
                        DB_MYSQL_PASSWORD=app_password, DB_MYSQL_NAME='npm', DISABLE_IPV6='true',
                        INITIAL_ADMIN_EMAIL=email if initial else 'unused@database.example',
                        INITIAL_ADMIN_PASSWORD=web_password if initial else secrets.token_hex(24))
        environment = [arg for key in settings for arg in ('-e', key)]
        docker('run', '-d', '--name', npm, '--label', label, '--network', project,
               '--mount', 'type=volume,source=' + volumes['app'] + ',target=/data',
               '--mount', 'type=volume,source=' + volumes['certs'] + ',target=/etc/letsencrypt',
               '--mount', 'type=volume,source=' + volumes['policy'] + ',target=/ext/appsec',
               '--log-driver', 'none', *environment, args.npm, env=settings)
        if initial:
            docker('exec', '-i', npm, 'sh', '-c', 'cat > /ext/appsec/local_policy.yaml', data=policy)
        wait_for(lambda: docker('exec', npm, 'curl', '-fsS', '--max-time', '3',
                                'http://127.0.0.1:81/api/', check=False).returncode == 0, 'NPM')

    def api(record, port):
        opts = dict(email=email, password=web_password, id=record.get('id'),
                    previous_port=record.get('forward_port'), next_port=port)
        result = docker('exec', '-i', npm, 'python3', '-c', API, data=json.dumps(opts).encode(), check=False)
        if result.returncode:
            message = result.stderr.decode(errors='replace')
            detail = [line for line in message.splitlines() if line.startswith(('api_status ', 'proxy_error '))]
            raise RuntimeError('NPM API check failed: ' + ' '.join(detail))
        return json.loads(result.stdout)

    def client(program, *options, data=None):
        return docker('run', '--rm', '-i', '--label', label, '--network', project,
                      '--entrypoint', program, '-e', 'MYSQL_PWD', args.candidate,
                      '-hdb', '-unpm', *options, 'npm', env={'MYSQL_PWD': app_password},
                      data=data, timeout=120).stdout

    def snapshot():
        # All NPM writers are stopped. Per-table locking also covers legacy Aria tables.
        return client('mariadb-dump', '--lock-tables', '--hex-blob', '--order-by-primary',
                      '--skip-comments', '--skip-dump-date', '--no-autocommit=0')

    def content_hash():
        data = client('mariadb-dump', '--lock-tables', '--hex-blob', '--order-by-primary',
                      '--skip-comments', '--skip-dump-date', '--no-create-info')
        return hashlib.sha256(data).hexdigest()

    if any(scoped_objects(k) for k in ('container', 'volume', 'network')):
        raise RuntimeError('existing QA label collision')
    try:
        for im in (args.baseline, args.candidate, args.npm):
            if docker('image', 'inspect', '--format', '{{.Id}}', im).stdout.decode().strip() != im:
                raise RuntimeError('image ID mismatch')
        docker('network', 'create', '--internal', '--label', label, project)
        for volume in volumes.values():
            if docker('volume', 'inspect', volume, check=False).returncode == 0:
                raise RuntimeError('volume name collision')
            docker('volume', 'create', '--label', label, volume)
        record = {}
        backup = expected = None
        for phase, image, data_role, root, port in [
            ('baseline', args.baseline, 'previous', app_password, 8101),
            ('candidate', args.candidate, 'new', root_password, 8102),
            ('rollback', args.baseline, 'rollback', app_password, 8103),
        ]:
            report['phase'] = phase
            start_db(image, volumes[data_role], root)
            if backup is not None:
                client('mariadb', data=backup)
                if content_hash() != expected:
                    raise RuntimeError('restored SQL data differs at ' + phase)
            if phase == 'candidate':
                docker('exec', db, 'healthcheck.sh', '--connect', '--innodb_initialized')
                if sql('root', app_password, 'SELECT 1', check=False).returncode == 0:
                    raise RuntimeError('application credential authenticated as root')
                if sql('npm', app_password, 'SELECT * FROM mysql.global_priv LIMIT 0', check=False).returncode == 0:
                    raise RuntimeError('application account can read server account table')
            version = sql('root', root, 'SELECT VERSION()').stdout.decode().strip()
            start_npm(phase == 'baseline')
            record = api(record, port)
            stop(npm)
            tables = int(sql('npm', app_password, "SELECT COUNT(*) FROM information_schema.tables "
                              "WHERE table_schema='npm'").stdout)
            if tables < 10:
                raise RuntimeError('NPM did not initialize its schema')
            backup = snapshot()
            expected = content_hash()
            report['stages'].append(dict(phase=phase, server_version=version, npm_tables=tables, datadir=data_role,
                                         authenticated_and_wrote_proxy=True, disposable_proxy_crud=True,
                                         official_healthcheck=phase == 'candidate', proxy=record,
                                         sql_dump_sha256=hashlib.sha256(backup).hexdigest(),
                                         sql_dump_bytes=len(backup), restored_data_verified=phase != 'baseline'))
            stop(db)
        report['phase'] = 'passed'
    finally:
        for kind in ('container', 'volume', 'network'):
            owned = scoped_objects(kind)
            if owned:
                command = ['rm', '-f', '-v'] if kind == 'container' else [kind, 'rm']
                docker(*command, *owned)
        report['cleanup_verified'] = not any(scoped_objects(k) for k in ('container', 'volume', 'network'))
        args.output.write_text(json.dumps(report, indent=2) + '\n')


if __name__ == '__main__':
    main()
