#!/bin/sh
# Report the version loaded by the orchestrator. Its control listener stays on loopback.
set -u
policy=/ext/appsec/local_policy.yaml
receipt=/ext/appsec/.aegis-active-policy
status=/etc/cp/conf/orchestration_status.json
last_requested=
retry_at=0
while :; do
    if [ -r "$policy" ] && [ -r "$status" ]; then
        hash=$(busybox sha256sum "$policy") || { sleep 2; continue; }
        hash=${hash%% *}
        active=$(busybox awk -F'"' '$2 == "Policy version" { print $4 }' "$status")
        if [ "$active" = "$hash" ]; then
            # Only this helper writes the receipt. A fresh heartbeat also covers helper restarts.
            current=$(cat "$receipt" 2>/dev/null || :)
            if [ "$current" = "$hash" ] && [ ! -L "$receipt" ]; then
                busybox touch -h "$receipt"
            else
                tmp=$(busybox mktemp /ext/appsec/.aegis-active.XXXXXX) || { sleep 2; continue; }
                if printf '%s\n' "$hash" >"$tmp" && chmod 644 "$tmp"; then busybox mv -fT "$tmp" "$receipt"; fi
                rm -f "$tmp"
            fi
        else
            rm -f "$receipt"
            now=$(date +%s)
            if [ "$last_requested" != "$hash" ] || [ "$now" -ge "$retry_at" ]; then
                for port in 7777 7778; do
                    curl --noproxy '*' -fsS --max-time 3 -o /dev/null -H 'Content-Type: application/json' \
                        -d '{"policy_path":"/ext/appsec/local_policy.yaml"}' "http://127.0.0.1:$port/set-apply-policy" 2>/dev/null && break
                done
                last_requested=$hash
                retry_at=$((now+15))
            fi
        fi
    fi
    sleep 2
done
