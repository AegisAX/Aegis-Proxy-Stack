#!/usr/bin/env bash
# Run the real candidate proxy with private IPC, loopback, and no agent.
set -euo pipefail
image=${1:?usage: waf-cold-start.sh sha256:IMAGE_ID}
[[ $image =~ ^sha256:[0-9a-f]{64}$ ]]
docker run --rm -i --pull never --network none --ipc private --entrypoint bash "$image" -se <<'CONTAINER'
set -euo pipefail
work=$(mktemp -d)
cd "$work"
mkdir -p /var/log/nginx /var/cache/nginx /ext/appsec /run/nginx
cat >/ext/appsec/local_policy.yaml <<'POLICY'
policies:
  default: {mode: inactive}
  specific-rules:
    - {host: prevent.test, mode: prevent-learn}
    - {host: detect.test, mode: detect-learn}
POLICY
node /app/aegis-waf-scope.cjs startup
chmod 755 "$work"
cat > origin.cjs <<'JS'
const http = require('node:http');
const fs = require('node:fs');
http.createServer((req, res) => {
  fs.appendFileSync('seen', req.url + '\n');
  req.resume();
  req.on('end', () => res.end('fixture-origin'));
}).listen(18082, '127.0.0.1');
JS
cat > nginx.conf <<'NGINX'
load_module /usr/lib/nginx/modules/libngx_module.so;
user nobody nogroup;
worker_processes 1;
pid nginx.pid;
error_log stderr warn;
events { worker_connections 32; }
http {
    cp_worker_processes 1;
    include /run/nginx/aegis-waf-scope.conf;
    access_log off;
    server {
        listen 127.0.0.1:18081;
        server_name prevent.test;
        location / { proxy_pass http://127.0.0.1:18082; }
    }
    server {
        listen 127.0.0.1:18081;
        server_name detect.test;
        cp-nano-nginx-attachment on;
        location / { proxy_pass http://127.0.0.1:18082; }
    }
    server {
        listen 127.0.0.1:18081;
        server_name disabled.test;
        cp-nano-nginx-attachment off;
        location / { proxy_pass http://127.0.0.1:18082; }
    }
}
NGINX
node origin.cjs &
nginx -t -p "$PWD" -c nginx.conf
nginx -p "$PWD" -c nginx.conf
curl -fsS --retry 10 --retry-connrefused --retry-delay 1 http://127.0.0.1:18082/ready >/dev/null
for method in GET POST; do
    for mode in prevent detect disabled; do
        path="/$mode-$method"
        options=()
        if [[ $method == POST ]]; then options=(--data-binary fixture); fi
        code=$(curl -sS --max-time 8 -H "Host: $mode.test" "${options[@]}" -o response -w '%{http_code}' "http://127.0.0.1:18081$path")
        if [[ $mode == prevent ]]; then
            [[ $code == 503 ]]
            [[ $(grep -Fxc "$path" seen || [[ $? == 1 ]]) == 0 ]]
        else
            [[ $code == 200 && $(cat response) == fixture-origin && $(grep -Fxc "$path" seen) == 1 ]]
        fi
        host=$mode; visits=1
        if [[ $mode == disabled ]]; then host=off; fi
        if [[ $mode == prevent ]]; then visits=0; fi
        jq -nc --arg host "$host" --arg method "$method" --argjson status "$code" --argjson visits "$visits" \
            '{host:$host,method:$method,path:"/health-probe",status:$status,visits:$visits}' >>rows.jsonl
    done
done
jq -sc '{scenario:"cold",rows:.}' rows.jsonl
CONTAINER
