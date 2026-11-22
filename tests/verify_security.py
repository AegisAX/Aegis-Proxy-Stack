"""Exercise verify_all.sh with a real NPM API, an agent CLI stub and a local HTTPS status fixture."""

import hashlib
import json
import os
import shutil
import ssl
import subprocess
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


DOCKER = """#!/bin/sh
set -eu
case "$*" in
    'compose ps agent') printf '%s\n' 'fixture-agent Up';;
    'compose exec agent open-appsec-ctl --status'|'compose exec -T agent open-appsec-ctl --status')
        printf '%s\n' 'fixture agent CLI'; test "$QA_MODE" != status-fails;;
    'compose exec -T agent open-appsec-ctl --apply-policy /ext/appsec/local_policy.yaml')
        printf '%s\n' apply >> "$QA_TRACE"
        test "$QA_MODE" != reload-fails;;
    'compose port npm 81'|'compose exec -T npm nginx -t') exec "$QA_DOCKER" "$@";;
    'ps --format '*) exec "$QA_DOCKER" "$@" --filter "label=com.docker.compose.project=$COMPOSE_PROJECT_NAME";;
    *) exit 76;;
esac
"""

CURL = """#!/bin/sh
set -eu
for value do
    case "$value" in
        https://verify.fixture.test/*)
            exec "$QA_CURL" --cacert "$QA_CA" --connect-to "verify.fixture.test:443:127.0.0.1:$QA_PORT" "$@";;
        "$QA_NPM/api/nginx/proxy-hosts"|"$QA_NPM/api/nginx/proxy-hosts/"*)
            for option do
                case "$option" in
                    POST|PUT|PATCH|DELETE|-d|--data*|-F|--form*)
                        printf '%s\n' 'proxy-write-attempt' >> "$QA_WRITES"; exit 75;;
                esac
            done
            case "$QA_MODE" in
                legacy-record) printf '%s\n' '[{"enabled":true,"domain_names":["test.aegis.local"],"forward_port":81,"forward_host":"localhost"}]'; exit 0;;
                malformed) printf '%s\n' '{}'; exit 0;;
            esac;;
    esac
done
exec "$QA_CURL" "$@"
"""


def verify(wd, project, env, email, password, address, api):
    tool_dir = wd / 'verify-tools'
    tool_dir.mkdir(mode=0o700)
    for name, body in [('docker', DOCKER), ('curl', CURL)]:
        target = tool_dir / name
        target.write_text(body)
        target.chmod(0o700)
    cert, key = tool_dir / 'cert.pem', tool_dir / 'key.pem'
    subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                    '-keyout', str(key), '-out', str(cert), '-subj', '/CN=verify.fixture.test',
                    '-addext', 'subjectAltName=DNS:verify.fixture.test'],
                   capture_output=True, check=True, timeout=15)
    trace = tool_dir / 'agent-calls'
    writes = tool_dir / 'proxy-write-attempts'
    writes.touch()
    requests = []

    class Response(BaseHTTPRequestHandler):
        def do_GET(self):
            requests.append(self.path)
            self.send_response({'/allow': 200, '/deny': 403, '/absent': 404}.get(self.path, 404))
            self.end_headers()

        def log_message(self, *_):
            pass

    def proxy_count():
        _, token = api(address, '/tokens', {'identity': email, 'secret': password})
        code, hosts = api(address, '/nginx/proxy-hosts', token=token['token'])
        if code != 200 or not isinstance(hosts, list):
            raise RuntimeError('failed to read real proxy host inventory')
        return len(hosts)

    if proxy_count() != 0:
        raise RuntimeError('verifier requires a fresh zero-host fixture')
    results = {}
    with ThreadingHTTPServer(('127.0.0.1', 0), Response) as server:
        tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        tls.load_cert_chain(cert, key)
        server.socket = tls.wrap_socket(server.socket, server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            for name, expected, applied, probes in (
                ('default', True, True, []), ('status-fails', False, False, []), ('reload-fails', False, True, []),
                ('legacy-record', False, False, []), ('malformed', False, False, []),
                ('invalid-paths', False, True, []), ('allow-deny', True, True, ['/allow', '/deny']),
                ('unexpected-status', False, True, ['/allow', '/absent']),
            ):
                trace.write_text('')
                requests.clear()
                test_env = {k: v for k, v in env.items() if not k.startswith('AEGIS_VERIFY_')}
                test_env.update(COMPOSE_PROJECT_NAME=project, MASTER_EMAIL=email, MASTER_PASSWORD=password,
                                QA_MODE=name, QA_PORT=str(server.server_port), QA_CA=str(cert), QA_TRACE=str(trace),
                                QA_WRITES=str(writes),
                                QA_NPM='http://' + address, QA_DOCKER=shutil.which('docker'), QA_CURL=shutil.which('curl'),
                                PATH=str(tool_dir) + os.pathsep + env['PATH'])
                if name in ('allow-deny', 'unexpected-status', 'invalid-paths'):
                    test_env.update(AEGIS_VERIFY_HOST='verify.fixture.test', AEGIS_VERIFY_ALLOW_PATH='/allow',
                                    AEGIS_VERIFY_DENY_PATH={'allow-deny': '/deny', 'unexpected-status': '/absent',
                                                            'invalid-paths': '/allow'}[name])
                proc = subprocess.run(['bash', 'verify_all.sh'], cwd=wd, env=test_env, input=b'',
                                      capture_output=True, timeout=40)
                output = proc.stdout + proc.stderr
                if ((proc.returncode == 0) != expected or (trace.read_text().splitlines() == ['apply']) != applied
                        or requests != probes or password.encode() in output or proxy_count() != 0 or writes.stat().st_size):
                    raise RuntimeError('verifier regression: ' + name + ', exit ' + str(proc.returncode))
                results[name] = dict(exit_code=proc.returncode, dry_agent_reload_called=applied,
                                     local_https_paths=list(requests), real_npm_hosts_after=0)
        finally:
            server.shutdown()
            thread.join(5)
    return dict(sha256=hashlib.sha256((wd / 'verify_all.sh').read_bytes()).hexdigest(), samples=results,
                real_npm_authentication_and_host_inventory=True, legacy_record_and_malformed_inventory_injected=True,
                agent_cli_simulated=True, https_codes_from_local_fixture=True)
