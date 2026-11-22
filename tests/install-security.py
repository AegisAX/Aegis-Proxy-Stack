"""Run the installer against two isolated, real NPM images using their bundled SQLite."""

import argparse
import hashlib
import json
import os
import re
import secrets
import shutil
import stat
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path


FILES = ('install.sh', 'verify_all.sh', 'docker-compose.yml', 'aegis-config/policy/local_policy.yaml.template',
         'aegis-config/scripts/package.json', 'aegis-config/scripts/package-lock.json',
         'aegis-config/scripts/policy_generator.js', 'aegis-config/db-security/Dockerfile',
         'aegis-config/db-security/prepare.sh')


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--clone', type=Path, required=True)
    parser.add_argument('--legacy', required=True)
    parser.add_argument('--modern', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--with-verifier', action='store_true', help='also exercise verifier branches on the real modern NPM API')
    args = parser.parse_args()
    args.source = args.source.resolve()
    args.output = args.output.resolve()
    os.umask(0o077)
    require(not args.output.exists(), 'choose a new output file')
    require(all(re.fullmatch(r'sha256:[0-9a-f]{64}', i) for i in (args.legacy, args.modern)),
            'provide immutable local NPM image IDs')
    report = dict(installer_sha256=hashlib.sha256((args.source / 'install.sh').read_bytes()).hexdigest(),
                  services_tested=['npm'], api_mock=False, docker_mock=False, log_preparation_tested=False,
                  samples={})
    env = {k: v for k, v in os.environ.items() if not k.startswith(('COMPOSE_', 'NPM_', 'DB_', 'AGENT_'))}
    env.update(TERM='xterm', npm_config_audit='false')

    with tempfile.TemporaryDirectory(prefix='installer-', dir=args.output.parent) as temp:
        scratch = Path(temp)

        def run(cwd, *command, data=None, timeout=120, check=True, project=None):
            proc = subprocess.run(command, cwd=cwd, input=data, capture_output=True, timeout=timeout,
                                  env={**env, **({'COMPOSE_PROJECT_NAME': project} if project else {})})
            if check and proc.returncode:
                raise RuntimeError(command[0] + ' exited ' + str(proc.returncode))
            return proc

        def clone(name):
            root = scratch / name
            run(scratch, 'git', 'clone', '--quiet', '--no-local', '--no-checkout', str(args.clone.resolve()), str(root))
            for filename in FILES:
                dest = root / filename
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(args.source / filename, dest)
            # Log image preparation is exercised independently. Preserve a real existing override.
            (root / 'docker-compose.override.yml').write_text('services: {}\n')
            return root

        def install(wd, project, email, password, start, check=True):
            data = ('\n'.join([email, password, password, 'y' if start else 'n', 'n']) + '\n').encode()
            proc = run(wd, 'bash', './install.sh', data=data, project=project, timeout=225, check=False)
            require(password.encode() not in proc.stdout + proc.stderr, 'installer echoed administrator password')
            if check and (proc.returncode or (start and b'Installation Complete.' not in proc.stdout)):
                messages = ('NPM API timed out', 'Could not create the first NPM administrator',
                            'Could not verify the NPM administrator account', 'Failed to verify new password',
                            'Complete first-user setup on a loopback listener')
                matched = next((m for m in messages if m.encode() in proc.stdout), 'exit ' + str(proc.returncode))
                raise RuntimeError('installer failed: ' + matched)
            return proc

        def api(address, path, data=None, method=None, token=None):
            payload = None if data is None else json.dumps(data).encode()
            headers = {'Content-Type': 'application/json'}
            if token:
                headers['Authorization'] = 'Bearer ' + token
            req = urllib.request.Request('http://' + address + '/api' + path, payload, headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=4) as resp:
                    return resp.status, json.load(resp)
            except urllib.error.HTTPError as e:
                return e.code, {}

        def login(address, email, password):
            code, body = api(address, '/tokens', {'identity': email, 'secret': password})
            return code == 200 and bool(body.get('token'))

        for mode in ('normal', 'unreadable'):
            wd = clone('missing-' + mode)
            db = wd / 'aegis-data/db'
            db.mkdir(parents=True)
            (db / 'sentinel').write_text('nonempty')
            if mode == 'unreadable':
                db.chmod(0)
            try:
                result = install(wd, 'aegis-missing-' + secrets.token_hex(8),
                                 'qa@fixture.example', secrets.token_hex(24), False, check=False)
                protected = result.returncode != 0 and not (wd / '.env').exists()
                report['missing_env_' + mode + '_denied'] = protected
            finally:
                db.chmod(0o700)

        previous = clone('previous-format')
        shared = secrets.token_hex(24)
        previous_env = previous / '.env'
        legacy_bytes = ('# retained comment\nAGENT_EMAIL=old@fixture.example\nDB_ROOT_PASSWORD=' + shared
                        + '\nNPM_DB_PASSWORD=' + shared + '\n\n').encode()
        previous_env.write_bytes(legacy_bytes)
        previous_env.chmod(0o640)
        legacy_data = previous / 'aegis-data/db'
        legacy_data.mkdir(parents=True)
        (legacy_data / 'sentinel').write_text('existing database fixture')
        install(previous, 'aegis-preexisting-' + secrets.token_hex(8),
                'qa@fixture.example', secrets.token_hex(24), False)
        require(previous_env.read_bytes() == legacy_bytes and stat.S_IMODE(previous_env.stat().st_mode) == 0o600,
                'previous-format credentials or file bytes changed')
        report['previous_format_credentials_and_comments_preserved'] = True

        for variant, image in [('legacy', args.legacy), ('modern', args.modern)]:
            wd = clone(variant)
            project = 'aegis-install-' + secrets.token_hex(8)
            email, password = 'qa@fixture.example', secrets.token_hex(24) + '!$"\\'
            compose = ['docker', 'compose', '-p', project, '-f', 'docker-compose.yml', '-f', 'docker-compose.override.yml']
            install(wd, project, email, password, False)
            env_file = wd / '.env'
            baseline = env_file.read_bytes()
            values = dict(line.split('=', 1) for line in baseline.decode().splitlines() if '=' in line)
            db_credentials = (values['DB_ROOT_PASSWORD'], values['NPM_DB_PASSWORD'])
            require(stat.S_IMODE(env_file.stat().st_mode) == 0o600 and
                    all(re.fullmatch('[0-9a-f]{64}', p) for p in db_credentials) and
                    len({password, *db_credentials}) == 3 and password.encode() not in baseline,
                    'generated credential isolation')
            original = json.loads(run(wd, *compose, 'config', '--format', 'json').stdout)
            admin = [p for p in original['services']['npm']['ports'] if p['target'] == 81]
            require(len(admin) == 1 and admin[0]['host_ip'] == values['NPM_ADMIN_BIND'] == '127.0.0.1',
                    'original compose admin endpoint')
            require(original['services']['db']['environment']['MYSQL_ROOT_PASSWORD'] == db_credentials[0]
                    and original['services']['npm']['environment']['DB_MYSQL_PASSWORD'] == db_credentials[1],
                    'original compose credential consumers')
            env_file.chmod(0o644)
            install(wd, project, email, password, False)
            require(env_file.read_bytes() == baseline and stat.S_IMODE(env_file.stat().st_mode) == 0o600,
                    'reinstall credential file preservation')
            # Isolate the actual NPM API with SQLite, unique volumes and one ephemeral loopback port.
            fixture = {'services': {'npm': {'image': image, 'pull_policy': 'never', 'ports': [
                {'target': 81, 'published': '0', 'host_ip': '${NPM_ADMIN_BIND:?}', 'protocol': 'tcp'}],
                'environment': {'DB_SQLITE_FILE': '/data/database.sqlite', 'DISABLE_IPV6': 'true',
                                'IP_RANGES_FETCH_ENABLED': 'false'},
                'volumes': ['app:/data', 'certs:/etc/letsencrypt'], 'logging': {'driver': 'none'}}},
                'networks': {'default': {'driver_opts': {'com.docker.network.bridge.enable_ip_masquerade': 'false'}}},
                'volumes': {'app': {}, 'certs': {}}}
            (wd / 'docker-compose.yml').write_text(json.dumps(fixture))
            def project_resources(kind):
                cli = {'container': ('ps', '-aq'), 'volume': ('volume', 'ls', '-q'),
                       'network': ('network', 'ls', '-q')}[kind]
                return run(wd, 'docker', *cli, '--filter', 'label=com.docker.compose.project=' + project).stdout.strip()
            require(not any(project_resources(k) for k in ('container', 'volume', 'network')), 'project collision')
            try:
                run(wd, *compose, 'up', '-d')
                cid = run(wd, *compose, 'ps', '-q', 'npm').stdout.decode().strip()
                require(run(wd, 'docker', 'inspect', '--format', '{{.Image}}', cid).stdout.decode().strip() == image,
                        'test image identity')
                address = run(wd, *compose, 'port', 'npm', '81').stdout.decode().strip()
                require(bool(re.fullmatch(r'127\.0\.0\.1:[1-9][0-9]*', address)), 'published loopback')
                deadline = time.monotonic() + 75
                while time.monotonic() < deadline:
                    try:
                        status, body = api(address, '/')
                        if status == 200 and body.get('status') == 'OK':
                            break
                    except (OSError, ValueError):
                        pass
                    time.sleep(1)
                else:
                    raise RuntimeError(variant + ' real NPM readiness timeout')
                start_state = body.get('setup', 'legacy')
                require(start_state == ('legacy' if variant == 'legacy' else False), 'unexpected NPM first-user state')
                install(wd, project, email, password, True)
                require(login(address, email, password), 'new administrator login')
                require(not login(address, 'admin@example.com', 'changeme'), 'factory credentials still accepted')
                require(env_file.read_bytes() == baseline, 'login flow changed .env')
                if variant == 'legacy':
                    # Re-create the exact persisted state after a password change and before the email update.
                    _, issued = api(address, '/tokens', {'identity': email, 'secret': password})
                    code, _ = api(address, '/users/1', {'name': 'Administrator', 'nickname': 'Admin',
                                                       'email': 'admin@example.com'}, 'PUT', issued['token'])
                    require(code == 200 and login(address, 'admin@example.com', password), 'interrupted state')
                    install(wd, project, email, password, True)
                    require(login(address, email, password), 'interrupted legacy account recovery')
                install(wd, project, email, password, True)
                bad = install(wd, project, email, secrets.token_hex(24), True, check=False)
                require(bad.returncode != 0 and login(address, email, password) and env_file.read_bytes() == baseline,
                        'failed reinstall changed credentials')
                report['samples'][variant] = dict(image=image, first_user_state=start_state, actual_login=True,
                    factory_credentials_denied=True, reinstall_login=True, wrong_admin_denied=True,
                    interrupted_legacy_account_recovered=variant == 'legacy',
                    new_env_mode='0600', original_compose_bound_to_loopback=True, db_passwords_distinct=True,
                    existing_env_byte_identical=True, real_loopback_published=True)
                if args.with_verifier and variant == 'modern':
                    from verify_security import verify
                    report['verifier'] = verify(wd, project, env, email, password, address, api)
            finally:
                run(wd, *compose, 'down', '-v', '--remove-orphans')
                require(not any(project_resources(k) for k in ('container', 'volume', 'network')), 'cleanup failed')
        report['phase'] = 'passed' if all(report['missing_env_' + m + '_denied'] for m in ('normal','unreadable')) else 'failed'
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        require(report['phase'] == 'passed', 'existing datadir guard failed')


if __name__ == '__main__':
    main()
