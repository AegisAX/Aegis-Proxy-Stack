#!/usr/bin/env bash
# Real Docker/Compose test. Each case uses its own project, synthetic log dirs and no published ports.
set -euo pipefail
base=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
work=$(mktemp -d); project="aegislogtest$(basename "$work" | tr -cd 'a-z0-9')"
export COMPOSE_PROJECT_NAME=$project
cleanup() {
    if [[ -f $work/docker-compose.yml ]]; then (cd "$work" && docker compose down --volumes --remove-orphans >/dev/null 2>&1) || true; fi
    rm -rf -- "$work"
}
trap cleanup EXIT
mkdir -p "$work/aegis-config/scripts" "$work/aegis-logs/"{npm,waf}
chmod 0755 "$work/aegis-logs/"{npm,waf}
cp -R -- "$base/aegis-config/logrotate" "$work/aegis-config/"
cp -- "$base/aegis-config/scripts/update-manager.sh" "$work/aegis-config/scripts/"
printf '%s\n' '#!/bin/bash' 'exec bash ./aegis-config/scripts/update-manager.sh "$@"' > "$work/update.sh"
cp -- "$base/aegis-config/scripts/image-audit.py" "$work/aegis-config/scripts/"
cd "$work"; touch .env; chmod 600 .env; chmod 644 aegis-config/logrotate/aegis-rotate.conf
config=$work/aegis-config/logrotate/aegis-rotate.conf
script=$work/aegis-config/logrotate/prepare.sh
# Keep the service's shipped command, health defaults and mounts. Replace the global container
# name, host clock and shared network with private fixture resources.
{ printf 'services:\n'; awk '/^  log-rotator:/{keep=1} keep&&/^  [a-z][^:]*:/{if($1!="log-rotator:") exit} keep&&!/container_name:|\/etc\/localtime:/{print}' "$base/docker-compose.yml"; printf 'networks:\n  aegis-network: {}\n'; } > docker-compose.yml
cp docker-compose.yml base.yaml
image() { docker inspect --format '{{.Image}}' "$(docker compose ps -q log-rotator)"; }
snapshot() { docker inspect "$(docker compose ps -q log-rotator)" | jq -c '.[0]|[.Image,.Config.Cmd,.Config.Entrypoint,.Config.Healthcheck]'; }
menu() { printf '4\ny\n' | timeout 240s script -q -e -c 'bash ./update.sh' /dev/null > "$1"; }
# Installation emits the exact managed override consumed by plain Compose.
selected=$(bash "$script" --install "$config" docker-compose.override.yml)
docker compose up -d --wait --wait-timeout 90 >/dev/null
[[ $(image) == "sha256:${selected##*local-}" && $(docker compose config --format json | jq -r '.services["log-rotator"].image') == "$selected" ]]
docker compose exec -T log-rotator /usr/local/sbin/aegis-check-logrotate --health
printf '%s\n' 'PASS fresh installation and plain docker compose up'
docker compose down --volumes; rm docker-compose.override.yml
# Existing user-authored overlays cannot be replaced by the installer.
printf 'services: {}\n' > docker-compose.override.yml
if bash "$script" --install "$config" docker-compose.override.yml; then exit 1; fi
grep -Fxq 'services: {}' docker-compose.override.yml; rm docker-compose.override.yml
# Existing unmodified installations continue to use the legacy entry point until selected.
docker compose up -d --wait --wait-timeout 90 >/dev/null
oldstate=$(snapshot); old=$(image); [[ $old != "sha256:${selected##*local-}" ]]

# While the confirmation prompt is open an operator can edit the managed override.
# Exercise the real menu and Docker without allowing any extra fixture service to start.
jq -n '{"x-aegis-local-patch":"log-rotator",services:{"log-rotator":{image:"alpine:3.19"}}}' >docker-compose.override.yml
jq '.services.audit_note = {image:"alpine:3.19",profiles:["never"]}' docker-compose.override.yml > edited.json
mkfifo "$work/menu-input"
exec {input}<>"$work/menu-input"
timeout 240s script -q -e -c 'bash ./update.sh' /dev/null <"$work/menu-input" > concurrent.log &
reader=$!
printf '4\n' >&"$input"
for ((waited=0; waited<1800; waited++)); do
    if grep -q '재시작할까요?' concurrent.log; then break; fi
    kill -0 "$reader" || { echo 'menu exited before the confirmation prompt' >&2; exit 1; }
    sleep 0.1
done
grep -q '재시작할까요?' concurrent.log || { echo 'missing confirmation prompt' >&2; exit 1; }
cp edited.json docker-compose.override.yml
printf 'y\n' >&"$input"
if wait "$reader"; then echo 'unexpected success after concurrent edit' >&2; exit 1; fi
exec {input}>&-
cmp -s edited.json docker-compose.override.yml
grep -q '오버라이드가 변경' concurrent.log
[[ $(snapshot) == "$oldstate" && ! -e .aegis-update/pending.json ]]
rm docker-compose.override.yml
printf '%s\n' 'PASS concurrent override edit survives confirmation and runtime remains untouched'

# The release override is applied last on every real startup.
mkdir -p .aegis-update
jq -n --arg im "$old" '{services:{"log-rotator":{image:$im}}}' > release.json
cp release.json .aegis-update/images.json
printf '4\n0\n' | timeout 60s script -q -e -c 'bash ./update.sh' /dev/null > release-conflict.log
grep -q '릴리스 오버라이드가 log 이미지를 지정' release-conflict.log
if grep -q '\[4\]' release-conflict.log; then echo 'conflicting log action was offered' >&2; exit 1; fi
cmp -s release.json .aegis-update/images.json
[[ $(snapshot) == "$oldstate" && ! -e docker-compose.override.yml && ! -e .aegis-update/pending.json ]]
rm .aegis-update/images.json
printf '%s\n' 'PASS release-pinned log is preserved and its conflicting local action is hidden'

# Inject a concurrent file write immediately after the real candidate health check succeeds.
mkdir late-edit-bin
real_docker=$(command -v docker)
cat > late-edit-bin/docker <<'HOOK'
#!/usr/bin/env bash
set -eu
if [[ ${1:-} == exec && ${3:-} == /usr/local/sbin/aegis-check-logrotate && ${4:-} == --health && -f .aegis-update/pending.json ]]; then
    "$REAL_DOCKER" "$@"
    cp edited.json docker-compose.override.yml
    exit 0
fi
exec "$REAL_DOCKER" "$@"
HOOK
chmod 700 late-edit-bin/docker
if REAL_DOCKER=$real_docker PATH="$work/late-edit-bin:$PATH" menu late-conflict.log; then
    echo 'unexpected success after health-time edit' >&2; exit 1
fi
cmp -s edited.json docker-compose.override.yml
grep -q '변경된 파일과 복구 기록을 보존' late-conflict.log
[[ -s .aegis-update/pending.json && $(image) != "$old" ]]
# The operator resolves their edit in this throwaway project, then explicitly resumes rollback.
rm docker-compose.override.yml
menu resolved.log
[[ $(snapshot) == "$oldstate" && ! -e .aegis-update/pending.json && ! -e docker-compose.override.yml ]]
printf '%s\n' 'PASS health-time edit and journal survive, then explicit rollback restores the original'
if [[ ${1:-} == --conflicts ]]; then exit 0; fi

menu success.log; grep -q 'log 보안 업데이트 완료' success.log
[[ $(image) == "sha256:${selected##*local-}" && ! -e .aegis-update/pending.json ]]
docker compose exec -T log-rotator /usr/local/sbin/aegis-check-logrotate --health
printf '%s\n' 'PASS interactive update of an existing legacy service'
# Power loss after the checked override rename but before the completed journal unlink.
jq -n --argjson previous "$oldstate" --arg target "$(image)" '{kind:"aegis-log-switch-1",target:$target,old_override:null,
  previous:{image:$previous[0],command:$previous[1],entrypoint:$previous[2],health:$previous[3]}}' > .aegis-update/pending.json
menu recovery.log; grep -q 'log 복구 완료' recovery.log
[[ $(snapshot) == "$oldstate" && ! -e docker-compose.override.yml && ! -e .aegis-update/pending.json ]]
printf '%s\n' 'PASS interrupted override commit recovers the original 3.19 image with no healthcheck'
docker compose down --volumes
# Recreate a real failure: this mount hides only the candidate baked config. The old process
# has its own command and explicit healthcheck, both different from the checkout after the edit.
python3 - <<'PY'
from pathlib import Path
p=Path('docker-compose.yml');s=p.read_text();s=s.replace('    restart: unless-stopped','    tmpfs: [/usr/local/etc/aegis]\n    healthcheck:\n      test: [CMD-SHELL, "pidof crond >/dev/null"]\n      interval: 2s\n      timeout: 2s\n      retries: 15\n    restart: unless-stopped');p.write_text(s)
PY
docker compose up -d --wait --wait-timeout 90 >/dev/null
before=$(snapshot)
sed -i 's/crond -f -l 8/crond -f -l 7/;s/retries: 15/retries: 10/' docker-compose.yml
if menu failure.log; then cat failure.log >&2; exit 1; fi
grep -q '이전 log 복구 완료' failure.log || { tail -20 failure.log >&2; exit 1; }
[[ $(snapshot) == "$before" && ! -e .aegis-update/pending.json && ! -e docker-compose.override.yml ]]
printf '%s\n' 'PASS real candidate health failure restores original image, command, entrypoint and healthcheck'
