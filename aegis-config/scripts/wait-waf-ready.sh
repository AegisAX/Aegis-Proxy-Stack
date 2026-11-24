#!/bin/sh
# Run inside the candidate NPM container before admitting an updated stack.
set -eu
policy=/ext/appsec/local_policy.yaml
socket=/run/nginx/aegis-scope.sock
scope=$(cd /app && node -e '
const fs = require("node:fs"), yaml = require("js-yaml");
const policy = yaml.load(fs.readFileSync(process.argv[1], "utf8"));
process.stdout.write(require("./aegis-waf-scope.cjs").compile(policy, true));
' "$policy")
if ! printf '%s\n' "$scope" | grep -Eq '^    [^ ]+ 1;$'; then
    echo 'WAF readiness: no preventive hosts in the installed policy'
    exit 0
fi
workers=$(nginx -T 2>/dev/null | awk '$1=="worker_processes" {gsub(/;$/,"",$2); print $2}')
if [ "$workers" = auto ]; then workers=$(getconf _NPROCESSORS_ONLN); fi
case "$workers" in ""|*[!0-9]*|0) echo 'Cannot determine the configured NGINX worker count' >&2; exit 1;; esac
revision() {
    digest=$(sha256sum "$policy") || return 1
    active=$(curl -fsS --max-time 2 --unix-socket "$socket" http://localhost/revision) || return 1
    [ "$active" = "${digest%% *}-active" ]
}
connected_workers() {
    master=$(cat /run/nginx/nginx.pid) || return 1
    before=$(cat "/proc/$master/task/$master/children") || return 1
    count=0
    channels=''
    for pid in $before; do
        # An old worker may be finishing the very API request awaiting this check.
        # Only workers accepting new connections count towards the live generation.
        title=$(tr -d '\000' <"/proc/$pid/cmdline") || return 1
        [ "$title" = 'nginx: worker process' ] || continue
        channel=$(awk '
            NF==6 && $6 ~ /^\/dev\/shm\/__cp_nano_(tx|rx)_shared_memory_[0-9]+__$/ {
                id=$6; sub(/^.*_memory_/,"",id)
                if ($6 ~ /_tx_/) tx[id]++; else rx[id]++
            }
            END {for (id in tx) if (tx[id]==1 && rx[id]==1) {pair=id; n++}
                 if (n!=1) exit 1; print pair}
        ' "/proc/$pid/maps") || return 1
        case " $channels " in *" $channel "*) return 1;; esac
        channels="$channels $channel"
        count=$((count+1))
    done
    [ "$workers" -eq "$count" ] && [ "$before" = "$(cat "/proc/$master/task/$master/children")" ]
}
burst=$workers
if [ "$burst" -gt 16 ]; then burst=16; fi
end=$(($(date +%s)+120))
while [ "$(date +%s)" -lt "$end" ]; do
    if revision && connected_workers && revision; then
        printf 'WAF ready: active policy and %s connected NGINX workers\n' "$workers"
        exit 0
    fi
    # The attachment opens worker IPC lazily. Warm it using only the local management API.
    i=0
    while [ "$i" -lt "$burst" ]; do
        curl --max-time 2 -fsS http://127.0.0.1:81/api/ >/dev/null 2>&1 &
        i=$((i+1))
    done
    wait
    sleep 1
done
echo 'Timed out waiting for the active WAF policy and all NGINX worker connections' >&2
exit 1
