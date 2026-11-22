#!/bin/bash
set -euo pipefail

usage() {
    cat <<'HELP'
Usage: ./update.sh [--security] [--dry-run] [--manifest FILE] [--maintenance]
       ./update.sh --recover-stack

  Run without options for the interactive menu.

  --security  Select the security update channel.
  --dry-run   Inspect the current deployment without applying an update.
  --manifest  Verify a release manifest before planning or applying it.
  --maintenance  Confirm ingress and administrative writes are paused for a stack release.
  --recover-stack  Resume or roll back an interrupted stack release.
  --help      Show this help.
HELP
}

channel=feature
dry_run=false
interactive=false
manifest=
maintenance=false
recover_stack=false
release_repo=AegisAX/Aegis-Proxy-Stack
if (( $# == 0 )); then
    interactive=true
    if [[ ! -t 0 ]]; then
        printf 'The interactive menu requires a terminal. Use --dry-run for scripted checks.\n' >&2
        exit 2
    fi
fi

while (( $# )); do
    case "$1" in
        --security) channel=security ;;
        --dry-run) dry_run=true ;;
        --maintenance) maintenance=true ;;
        --recover-stack) recover_stack=true ;;
        --manifest)
            if [[ $# -lt 2 || ! -f $2 ]]; then
                printf '%s\n' '--manifest requires an existing file.' >&2
                exit 2
            fi
            manifest=$(realpath -- "$2")
            shift
            ;;
        --help|-h) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

toolkit_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
base_dir=${AEGIS_INSTALL_ROOT:-$toolkit_dir}
export AEGIS_INSTALL_ROOT="$base_dir"
cd -- "$base_dir"

if [[ ! -f docker-compose.yml || ! -f .env ]]; then
    printf 'An installed deployment requires docker-compose.yml and .env in %s.\n' "$base_dir" >&2
    exit 1
fi

compose_file="$base_dir/docker-compose.yml"
state_dir="$base_dir/.aegis-update"
override="$state_dir/images.json"
pending="$state_dir/pending.json"
backup_pending="$state_dir/backup-pending.json"
stack_backup="$toolkit_dir/aegis-config/scripts/stack-backup.py"
stack_update="$toolkit_dir/aegis-config/scripts/stack-update.py"
stack_pending="$state_dir/stack-pending.json"
log_override="$base_dir/docker-compose.override.yml"
legacy_compose="$toolkit_dir/aegis-config/releases/compose-v0.4.1.yml"
# A bridge release can use the known old model after matching every live Compose hash.
if [[ -f $legacy_compose && -f $stack_update ]] && command -v python3 >/dev/null; then
    if [[ -e $stack_pending ]]; then
        : # Recovery uses the models saved by the interrupted transaction.
    elif ! AEGIS_COMPOSE_FILE="$compose_file" python3 -B "$stack_update" check >/dev/null 2>&1 &&
         AEGIS_COMPOSE_FILE="$legacy_compose" python3 -B "$stack_update" check >/dev/null 2>&1; then
        compose_file=$legacy_compose
    fi
fi
export AEGIS_COMPOSE_FILE="$compose_file"
compose=(docker compose --project-directory "$base_dir" --env-file "$base_dir/.env" -f "$compose_file")
if [[ -f $log_override ]]; then
    compose+=(-f "$log_override")
fi
if [[ -f $override ]]; then
    compose+=(-f "$override")
fi
if [[ $recover_stack == true ]]; then
    [[ -e $stack_pending && $dry_run == false && -z $manifest && $maintenance == false ]] || exit 2
    exec python3 -B "$stack_update" recover
fi
if [[ $interactive == true && -e $stack_pending ]]; then
    printf '\n  AEGIS 배포 관리자\n  중단된 스택 전환이 있습니다.\n'
    read -r -p '  [r] 스택 전환 복구    [0] 종료 › ' choice || exit 0
    if [[ $choice == [rR] ]]; then exec python3 -B "$stack_update" recover; fi
    exit 0
fi
installed_version=unknown
if [[ -s VERSION ]]; then
    installed_version=$(<VERSION)
fi
revision=$(git rev-parse --verify HEAD 2>/dev/null || printf 'unknown')
if command -v jq >/dev/null && [[ -f $state_dir/release.json && ! -L $state_dir/release.json ]]; then
    if active_release=$(jq -er 'select((.version | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and
            (.origin_commit | test("^[a-f0-9]{40}$"))) | [.version,.origin_commit] | @tsv' "$state_dir/release.json"); then
        IFS=$'\t' read -r installed_version revision <<< "$active_release"
    fi
fi

if [[ $interactive != true ]]; then
    printf 'Update channel: %s\n' "$channel"
    printf 'Installed version: %s\nCheckout commit: %s\n' "$installed_version" "$revision"
fi
"${compose[@]}" config --quiet
container_ids=$("${compose[@]}" ps --all --quiet)
if [[ -z $container_ids ]]; then
    printf 'No existing containers found for this deployment.\n' >&2
    exit 1
fi

mapfile -t container_id_list <<< "$container_ids"
inspect_format='{{index .Config.Labels "com.docker.compose.service"}}  {{.State.Status}}  {{.Config.Image}}  {{.Image}}'
if [[ $interactive == true ]]; then
    inspect_format+='  {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}  {{.Name}}'
fi
inventory=$(docker inspect --type container --format "$inspect_format" "${container_id_list[@]}")
if [[ $interactive != true ]]; then
    printf '\nService / container state / configured image / actual image ID\n%s\n' "$inventory"
fi

image_audits() {
    local service state ref id health container result
    printf '\n  실행 이미지 취약점 · 패키지별 발견 건수 / KEV 고유 CVE 수\n'
    while read -r service state ref id health container; do
        [[ $state == running ]] || continue
        if ! result=$(python3 "$toolkit_dir/aegis-config/scripts/image-audit.py" "${1:-show}" "$id" 2>/dev/null); then
            result='취약점 검사 결과를 읽을 수 없음'
        fi
        printf '  %-19s %s\n' "${container#/}" "$result"
    done <<< "$audit_inventory"
    if ! command -v "${AEGIS_TRIVY_BIN:-trivy}" >/dev/null; then
        printf '  저장된 검사 기록을 표시합니다. 이 호스트에서 재검사하려면 Trivy가 필요합니다.\n'
    fi
}

audit_inventory=$inventory
if [[ $interactive != true && $channel == security && $dry_run == true && -f $toolkit_dir/aegis-config/scripts/image-audit.py ]]; then
    audit_inventory=$(docker inspect --type container --format "$inspect_format  -  {{.Name}}" "${container_id_list[@]}")
    image_audits
fi

# Emit one GitHub release array per page. Keep failed authenticated output out of
# the public fallback, including a partial response from an interrupted second page.
release_pages() (
    local repo=$1 per_page=${2:-100} pages work page=1
    if command -v gh >/dev/null &&
        pages=$(timeout 12s gh api --hostname github.com --paginate "repos/$repo/releases?per_page=$per_page" 2>/dev/null) &&
        jq -es 'length > 0 and all(.[]; type == "array")' <<< "$pages" >/dev/null; then
        printf '%s\n' "$pages"
        return 0
    fi

    command -v curl >/dev/null || return 1
    work=$(mktemp -d) || return 1
    trap 'rm -f -- "$work/headers" "$work/page"; rmdir -- "$work"' EXIT
    while true; do
        curl --disable --fail --silent --show-error --connect-timeout 3 --max-time 12 \
            --proto '=https' -H 'Accept: application/vnd.github+json' \
            --dump-header "$work/headers" --output "$work/page" \
            "https://api.github.com/repos/$repo/releases?per_page=$per_page&page=$page" || return 1
        jq -ces 'if length == 1 and (.[0] | type) == "array" then .[0]
                 else error("Invalid GitHub releases response") end' "$work/page" || return 1
        if ! grep -Eiq '^link:.*;[[:space:]]*rel="next"' "$work/headers"; then return 0; fi
        page=$((page + 1))
    done
)

download_release_manifest() {
    timeout 12s gh release download --repo "$release_repo" --pattern "$2" --output "$3" -- "$1"
}

verify_release_attestation() {
    timeout 25s gh attestation verify "$1" \
        --repo "$release_repo" \
        --signer-workflow AegisAX/Aegis-Proxy-Stack/.github/workflows/release.yml \
        --source-ref refs/heads/main \
        --deny-self-hosted-runners
}

manifest_changes() {
    local changes service from_id target
    changes=$(jq -r '.images | to_entries[] | [.key, .value.from_id, .value.target] | @tsv' "$1") || return 1
    while IFS=$'\t' read -r service from_id target; do
        if ! awk -v service="$service" -v id="$from_id" '
            $1 == service { count++; if ($2 == "running" && $4 == id) matches++ }
            END { exit !(count == 1 && matches == 1) }
            ' <<< "$inventory"; then
            printf 'Existing container does not match manifest for service %s.\n' "$service" >&2
            return 1
        fi
    done <<< "$changes"
    printf '%s\n' "$changes"
}

verified_menu_releases() (
    local candidates=$1 work file channel tag asset scope
    work=$(mktemp -d) || return 1
    file="$work/manifest.json"
    trap 'rm -f -- "$file"; rmdir -- "$work"' EXIT
    while IFS=$'\t' read -r channel tag; do
        asset="aegis-$channel-$installed_version-$revision.json"
        rm -f -- "$file"
        if ! GH_PROMPT_DISABLED=1 download_release_manifest "$tag" "$asset" "$file" >/dev/null 2>&1 ||
           ! jq -es --arg channel "$channel" --arg version "$installed_version" --arg revision "$revision" \
               -f "$toolkit_dir/aegis-config/scripts/release-manifest.jq" "$file" >/dev/null 2>&1 ||
           ! jq -e --arg tag "$tag" '.release == $tag' "$file" >/dev/null 2>&1 ||
           ! manifest_changes "$file" >/dev/null 2>&1 ||
           ! GH_PROMPT_DISABLED=1 verify_release_attestation "$file" >/dev/null 2>&1; then
            continue
        fi
        scope=single
        if jq -e '.strategy == "stack-v1"' "$file" >/dev/null; then
            [[ -f $stack_update ]] && python3 -B "$stack_update" plan "$file" >/dev/null 2>&1 || continue
            scope=stack
            if jq -e '.images["log-rotator"] | .from_id != .target_id' "$file" >/dev/null; then
                scope=stack-log
            fi
        fi
        printf '%s\t%s\t%s\n' "$channel" "$tag" "$scope"
    done <<< "$candidates"
)

application_supported() {
    "${compose[@]}" config --format json | jq -e --arg service "$1" '
    (.services | keys) as $keys |
    ($keys | length) == 1 and ($service == "" or $keys == [$service]) and
    ((.networks // {}) | to_entries | all(.key == "default" and .value.external != true)) and
    (.services[$keys[0]] |
      ((.volumes // []) | length == 0) and
      ((.ports // []) | length == 0) and
      ((.configs // []) | length == 0) and
      ((.secrets // []) | length == 0) and
      ((.devices // []) | length == 0) and
      (.network_mode == null) and (.ipc == null) and (.pid == null) and
      (.privileged != true) and (.healthcheck.disable != true) and
      (.healthcheck.test[0] == "CMD" or .healthcheck.test[0] == "CMD-SHELL"))
    ' >/dev/null
}

secure_local_credentials() {
    local file metadata mode owner links
    local -a files=(.env .env.bak)

    if [[ -d backups && ! -L backups ]]; then
        files+=(backups/*/.env backups/*/.env.bak)
    fi

    for file in "${files[@]}"; do
        if [[ $file == backups/* && ( -L backups || -L ${file%/*} ) ]]; then
            continue
        fi
        [[ -e $file || -L $file ]] || continue
        if [[ -L $file || ! -f $file ]] ||
           ! metadata=$(stat -c '%a %u %h' -- "$file"); then
            printf '  비밀 설정 권한 수동 확인 필요  %q\n' "$file" >&2
            continue
        fi
        read -r mode owner links <<< "$metadata"
        if (( (8#$mode & 077) == 0 )); then
            continue
        fi
        if [[ $owner != "$EUID" || $links != 1 || -L $file ]]; then
            printf '  비밀 설정 권한 수동 확인 필요  %q\n' "$file" >&2
        elif chmod go-rwx -- "$file"; then
            printf '  비밀 설정 보호 적용  %q · 그룹·기타 권한 제거\n' "$file"
        else
            printf '  비밀 설정 권한 변경 실패  %q\n' "$file" >&2
        fi
    done
}

log_patch_prerequisites() {
    if [[ -e $stack_pending || -L $stack_pending ]]; then
        printf '스택 전환 복구 필요\n'
        return 1
    fi
    if [[ -e $backup_pending || -L $backup_pending ]]; then
        printf '스택 백업의 서비스 복구 필요\n'
        return 1
    fi
    if [[ ( -e $pending || -L $pending ) ]] && ! log_recovery_pending; then
        printf '이전 업데이트의 복구 기록이 남아 있습니다.\n'
        return 1
    fi
    if ! command -v jq >/dev/null; then
        printf '  로그 이미지 검증에는 jq가 필요합니다.\n'
        return 1
    fi
    if [[ -f $override ]] && jq -e '.services["log-rotator"] | type == "object" and has("image")' "$override" >/dev/null; then
        printf '  릴리스 오버라이드가 log 이미지를 지정하고 있어 기존 설정을 보존합니다.\n'
        return 1
    fi
    if [[ -e $log_override || -L $log_override ]]; then
        if [[ -L $log_override ]] ||
           ! jq -e '."x-aegis-local-patch" == "log-rotator" and
              (keys == ["services","x-aegis-local-patch"]) and
              (.services | keys == ["log-rotator"])' "$log_override" >/dev/null 2>&1; then
            printf '  기존 Compose 오버라이드가 있어 자동 교체를 중단합니다.\n'
            return 1
        fi
    fi

}

log_patch_config_source() {
    local source owner mode
    source=$("${compose[@]}" config --format json | jq -er '
        [.services["log-rotator"].volumes[]? |
         select(.target == "/etc/logrotate.conf")] |
        select(length == 1 and .[0].type == "bind") | .[0].source |
        select(type == "string" and startswith("/") and (test("[[:cntrl:]]") | not))') || return 1
    [[ -f $source && -r $source && ! -L $source ]] || return 1
    read -r owner mode < <(stat -c '%u %a' -- "$source") || return 1
    [[ $owner == 0 || $owner == "$EUID" ]] || return 1
    (( (8#$mode & 022) == 0 )) || return 1
    printf '%s\n' "$source"
}

inspect_log_patch() {
    local current image_id version upgrades config_file config_hash baked_hash managed_image
    log_patch_available=false
    log_patch_state=UNKNOWN
    if ! log_patch_status=$(log_patch_prerequisites); then
        return 0
    fi
    if log_recovery_pending; then
        log_patch_available=true
        log_patch_state=READY
        log_patch_status='중단된 log 전환 · 이전 이미지 및 실행 설정 복구 가능'
        return 0
    fi
    if ! current=$("${compose[@]}" ps --quiet log-rotator) ||
       [[ -z $current || $current == *$'\n'* ]]; then
        log_patch_status='실행 중인 log 컨테이너를 확인할 수 없습니다.'
        return 0
    fi
    if ! version=$(docker exec "$current" cat /etc/alpine-release 2>/dev/null); then
        log_patch_status='현재 Alpine 버전을 확인할 수 없습니다.'
        return 0
    fi
    case "$version" in
        3.19.*) ;;
        3.22.*)
            if [[ ! -f $log_override ]] ||
               ! managed_image=$(jq -er '.services["log-rotator"].image' "$log_override") ||
               ! image_id=$(docker inspect --type container --format '{{.Image}}' "$current") ||
               [[ $managed_image != "aegis-log-rotator:local-${image_id#sha256:}" ]]; then
                log_patch_status="Alpine $version · 관리 중인 로그 이미지인지 확인할 수 없습니다."
                return 0
            fi
            ;;
        *)
            log_patch_status="Alpine $version · 자동 업데이트 지원 범위 밖"
            return 0
            ;;
    esac
    if ! config_file=$(log_patch_config_source) || ! config_hash=$(sha256sum < "$config_file"); then
        log_patch_status="Alpine $version · 호스트 순환 설정의 경로·소유자·권한을 확인하세요."
        return 0
    fi
    config_hash=${config_hash%% *}
    if [[ $version == 3.19.* ]]; then
        log_patch_available=true
        log_patch_state=READY
        log_patch_status="Alpine $version → 3.22"
        return 0
    fi
    if ! baked_hash=$(timeout 5s docker exec "$current" sh -ec '
        if [ -x /usr/local/sbin/aegis-check-logrotate ] &&
           [ -f /usr/local/etc/aegis/logrotate.conf ]; then
            sha256sum < /usr/local/etc/aegis/logrotate.conf
        else
            printf "missing\n"
        fi' 2>/dev/null); then
        log_patch_status="Alpine $version · 실행 중인 순환 설정을 확인할 수 없습니다."
        return 0
    fi
    baked_hash=${baked_hash%% *}
    if [[ $baked_hash == missing ]]; then
        log_patch_status="Alpine $version · 로그 순환 설정 복구 가능"
    elif [[ ! $baked_hash =~ ^[0-9a-f]{64}$ ]]; then
        log_patch_status="Alpine $version · 실행 중인 순환 설정의 해시를 확인할 수 없습니다."
        return 0
    elif [[ $baked_hash != "$config_hash" ]]; then
        log_patch_status="Alpine $version · 변경된 순환 설정 적용 가능"
    elif ! timeout 8s docker exec "$current" /usr/local/sbin/aegis-check-logrotate --health >/dev/null 2>&1; then
        log_patch_status="Alpine $version · 로그 순환 점검 실패, 복구 가능"
    elif upgrades=$(docker run --rm --pull never --cap-drop ALL \
            --security-opt no-new-privileges --entrypoint sh "$image_id" -ec '
                apk --timeout 5 update >/dev/null
                apk version -l "<" | awk "NR > 1 && /</ {print}"
            ' 2>/dev/null); then
        if [[ -z $upgrades ]]; then
            log_patch_state=CHECKED
            log_patch_status="Alpine $version · NPM·WAF 회전 규칙 정상"
            return 0
        fi
        log_patch_status="Alpine $version · 갱신 가능한 패키지 있음"
    else
        log_patch_status="Alpine $version · 패키지 저장소 조회 실패"
        return 0
    fi
    log_patch_available=true
    log_patch_state=READY
}

installed_app_version() {
    local service=$1 container=$2
    case "$service" in
        npm) timeout 4s docker exec "$container" node -p 'require("/app/package.json").version' ;;
        agent)
            timeout 4s docker exec "$container" open-appsec-ctl --status |
                awk '/^Version:/ && !found {print $2; found=1} END {exit !found}'
            ;;
        db)
            timeout 4s docker exec "$container" mariadbd --version |
                awk '/ Ver / {split($3, version, "-MariaDB"); print version[1]; found=1} END {exit !found}'
            ;;
        log-rotator)
            timeout 4s docker exec "$container" logrotate --version |
                awk '$1 == "logrotate" && !found {print $2; found=1} END {exit !found}'
            ;;
    esac
}

print_image_status() {
    local color label
    case "$2" in
        READY)   color=$good;      label='적용 가능' ;;
        RELEASE) color=$good;      label='스택 릴리스에 포함' ;;
        REVIEW)  color=$attention; label='검증 필요' ;;
        TESTING) color=$accent;    label='검증 중' ;;
        OBSERVED) color=$good;     label='격리 검증 완료' ;;
        CURRENT) color=$muted;     label='공급자 이미지 변경 없음' ;;
        CHECKED) color=$muted;     label='패키지 업데이트 없음' ;;
        *)       color=$attention; label='확인 불가' ;;
    esac
    printf '  %-19s %s%s%s' "$1" "$color" "$label" "$reset"
    if [[ -n $3 ]]; then printf ' · %s' "$3"; fi
    printf '\n'
}

print_agent_review() {
    local container=$1 current=$2 upstream=$3 npm_id record result line
    local displayed=false
    local -a lines
    npm_id=$(awk '$1=="npm" && $2=="running" {print $4}' <<< "$inventory")
    for record in "$state_dir/agent-observation.json" "$state_dir/agent-geo-cache-observation.json"; do
        [[ -r $record ]] || continue
        result=$(python3 -IB "$toolkit_dir/aegis-config/scripts/agent-review.py" "$record" \
            "$current" "$npm_id" "$upstream" 2>/dev/null) || continue
        mapfile -t lines <<< "$result"
        print_image_status "$container" "${lines[0]}" "${lines[1]}"
        for line in "${lines[@]:2}"; do printf '  %-19s %s\n' '' "$line"; done
        displayed=true
        container=
    done
    [[ $displayed == true ]]
}

inspect_vendor_image() {
    local service=$1 ref=$2 container local_id local_digests remote
    read -r container local_id <<< "$(awk -v service="$service" '
        $1 == service {sub(/^\//, "", $6); print $6, ($2 == "running" ? $4 : ""); exit}
    ' <<< "$inventory")"
    [[ -n $container ]] || return 0
    if [[ ! $local_id =~ ^sha256:[a-f0-9]{64}$ ]] ||
       ! local_digests=$(docker image inspect --format '{{json .RepoDigests}}' "$local_id"); then
        print_image_status "$container" UNKNOWN "실행 이미지 미확인"
        return
    fi
    if ! remote=$(timeout 8s docker buildx imagetools inspect "$ref" \
        --format '{{json .Manifest}}' 2>/dev/null |
        jq -er '.digest | select(test("^sha256:[a-f0-9]{64}$"))'); then
        if [[ $service == agent ]] && print_agent_review "$container" "$local_id" -; then return 0; fi
        print_image_status "$container" UNKNOWN "공급자 조회 실패"
        return
    fi
    if [[ $service == agent ]] && print_agent_review "$container" "$local_id" "$remote"; then return 0; fi
    if jq -e --arg ref "${ref%:*}@$remote" '(. // []) | index($ref) != null' <<< "$local_digests" >/dev/null; then
        print_image_status "$container" CURRENT ""
    elif jq -e --arg repo "${ref%:*}@" '(. // []) | any(startswith($repo))' <<< "$local_digests" >/dev/null; then
        print_image_status "$container" REVIEW "공급자 새 이미지 ${remote:7:12}"
    else
        print_image_status "$container" UNKNOWN "실행 이미지의 공급자 다이제스트 미확인"
    fi
}

log_recovery_pending() {
    [[ -f $pending && ! -L $pending ]] && jq -e '
      .kind=="aegis-log-switch-1" and (.target|test("^sha256:[a-f0-9]{64}$")) and
      (.previous.image|test("^sha256:[a-f0-9]{64}$")) and
      (.old_override==null or (.old_override|type)=="string")' "$pending" >/dev/null 2>&1
}

log_runtime_config() {
    docker inspect --type container "$1" | jq -ec '.[0] | {
      image:.Image,entrypoint:.Config.Entrypoint,command:.Config.Cmd,health:.Config.Healthcheck}'
}

log_override_unchanged() {
    local snapshot=$1
    if [[ -f $snapshot ]]; then
        [[ -f $log_override && ! -L $log_override ]] && cmp -s -- "$snapshot" "$log_override"
    else
        [[ ! -e $log_override && ! -L $log_override ]]
    fi
}

log_restore() {
    local work=$1 service=log-rotator previous current old target project
    log_recovery_pending || return 1
    previous=$(jq -ec .previous "$pending") || return 1
    target=$(jq -er .target "$pending") || return 1
    old=$(jq -er .image <<< "$previous") || return 1
    local before_hash active_hash= candidate_hash=
    if [[ -f $log_override ]]; then
        [[ ! -L $log_override ]] && cp -- "$log_override" "$work/recovery-override" || return 1
        active_hash=$(sha256sum < "$work/recovery-override") || return 1
        before_hash=$(jq -jr '.old_override // ""' "$pending" | sha256sum) || return 1
        candidate_hash=$(bash "$toolkit_dir/aegis-config/logrotate/prepare.sh" --override "aegis-log-rotator:local-${target#sha256:}" | sha256sum) || return 1
        [[ $active_hash == "$before_hash" || $active_hash == "$candidate_hash" ]] || return 1
    else
        jq -e '.old_override==null' "$pending" >/dev/null || return 1
    fi
    [[ $(docker image inspect --format '{{.Id}}' "$old") == "$old" ]] || return 1
    current=$("${compose[@]}" ps --all -q "$service") || return 1
    [[ $current != *$'\n'* ]] || return 1
    if [[ -n $current ]]; then
        local actual
        actual=$(docker inspect --type container --format '{{.Image}}' "$current") || return 1
        [[ $actual == "$old" || $actual == "$target" ]] || return 1
    fi
    # Materialize only this service's resolved resources. Starting from one complete model lets
    # an old container with no healthcheck inherit its original image's exact default.
    "${compose[@]}" config --format json | jq -e --argjson prev "$previous" '
      . as $project | .services["log-rotator"] as $service |
      def selected($obj;$keys): ($obj // {} | with_entries(select(.key as $k | $keys|index($k))));
      def hc($h): {test:$h.Test} + (if $h.Interval then {interval:(($h.Interval|tostring)+"ns")} else {} end) +
        (if $h.Timeout then {timeout:(($h.Timeout|tostring)+"ns")} else {} end) +
        (if $h.Retries then {retries:$h.Retries} else {} end) +
        (if $h.StartPeriod then {start_period:(($h.StartPeriod|tostring)+"ns")} else {} end) +
        (if $h.StartInterval then {start_interval:(($h.StartInterval|tostring)+"ns")} else {} end);
      {name:$project.name,services:{"log-rotator":($service | del(.build,.depends_on,.healthcheck,.entrypoint,.command) |
          .image=$prev.image | .pull_policy="never" |
          if $prev.command!=null then .command=$prev.command else . end |
          if $prev.entrypoint!=null then .entrypoint=$prev.entrypoint else . end |
          if $prev.health!=null then .healthcheck=hc($prev.health) else . end)},
        networks:selected($project.networks;(($service.networks // {})|keys)),
        volumes:selected($project.volumes;[$service.volumes[]?|select(.type=="volume").source]),
        configs:selected($project.configs;[$service.configs[]?.source]),
        secrets:selected($project.secrets;[$service.secrets[]?.source])} |
      walk(if type=="string" then gsub("\\$";"$$") else . end)' > "$work/rollback.json" || return 1
    project=$(jq -er .name "$work/rollback.json") || return 1
    docker compose --project-directory "$base_dir" -p "$project" -f "$work/rollback.json" up -d --no-deps --pull never --wait --wait-timeout 90 "$service" || return 1
    current=$(docker compose -p "$project" -f "$work/rollback.json" ps --quiet "$service") || return 1
    [[ -n $current ]] && jq -en --argjson actual "$(log_runtime_config "$current")" --argjson prev "$previous" '$actual==$prev' >/dev/null || return 1
    # The override is committed only after a healthy switch. A crash after that rename can
    # leave a candidate override in place; restore the exact original bytes in that case.
    log_override_unchanged "$work/recovery-override" && log_patch_prerequisites || return 1
    if [[ -f $work/recovery-override && $active_hash == "$candidate_hash" ]]; then
        if jq -e '.old_override==null' "$pending" >/dev/null; then
            rm -- "$log_override" || return 1
        else
            jq -jr .old_override "$pending" > "$work/original.json" && mv -- "$work/original.json" "$log_override" || return 1
        fi
    fi
    rm -- "$pending"
}

patch_log_rotator() (
    set -euo pipefail
    local service=log-rotator script="$toolkit_dir/aegis-config/logrotate/prepare.sh" work current previous candidate target config before selected confirm reference
    log_patch_prerequisites || exit 1
    [[ ! -L $state_dir ]] || exit 1
    install -d -m 700 -- "$state_dir"
    exec {lock_fd}>"$state_dir/lock"
    flock -n "$lock_fd" || { printf '  다른 업데이트가 진행 중입니다.\n' >&2; exit 1; }
    log_patch_prerequisites || exit 1
    work=$(mktemp -d "$state_dir/log-patch.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    umask 077
    if log_recovery_pending; then
        read -r -p '  이전 log 이미지와 실행 설정을 복구할까요? (y/N) › ' confirm || exit 0
        [[ $confirm == [yY] ]] || exit 0
        log_restore "$work" && { printf '  log 복구 완료.\n'; exit 0; }
        printf '  복구 실패. 기록을 보존합니다.\n' >&2; exit 1
    fi
    if [[ -f $log_override ]]; then cp -- "$log_override" "$work/prior-override"; fi
    current=$("${compose[@]}" ps --quiet "$service")
    [[ -n $current && $current != *$'\n'* ]] || { printf '  실행 중인 log 컨테이너 한 개가 필요합니다.\n' >&2; exit 1; }
    previous=$(log_runtime_config "$current")
    reference=$("${compose[@]}" config --format json | jq -er '.services["log-rotator"].image')
    [[ $(docker image inspect --format '{{.Id}}' "$reference") == "$(jq -r .image <<< "$previous")" ]] || { printf '  Compose와 실행 이미지가 달라 복구 대상을 확인할 수 없습니다.\n' >&2; exit 1; }
    config=$(log_patch_config_source) || { printf '  로그 설정 경로와 권한을 확인하세요.\n' >&2; exit 1; }
    before=$(sha256sum < "$config")
    candidate=$(bash "$script" "$config")
    [[ $candidate =~ ^aegis-log-rotator:local-([a-f0-9]{64})$ ]] || exit 1
    target="sha256:${BASH_REMATCH[1]}"
    printf '  현재  %s\n  검증 후보  %s\n' "$(jq -r .image <<< "$previous")" "$target"
    read -r -p '  검증한 이미지로 log 컨테이너만 재시작할까요? (y/N) › ' confirm || exit 0
    [[ $confirm == [yY] ]] || exit 0
    if ! log_override_unchanged "$work/prior-override" || ! log_patch_prerequisites; then
        printf '  확인 중 Compose 오버라이드가 변경되어 log 전환을 중단합니다.\n' >&2
        exit 1
    fi
    selected=$(log_patch_config_source) || exit 1
    [[ $config == "$selected" && $(sha256sum < "$selected") == "$before" &&
       $("${compose[@]}" ps --quiet "$service") == "$current" && $(docker image inspect --format '{{.Id}}' "$candidate") == "$target" ]] || exit 1
    bash "$script" --override "$candidate" > "$work/override.json"
    # Match the persistent order: base, managed log fragment, then release images.
    local -a candidate_compose=(docker compose --project-directory "$base_dir" --env-file "$base_dir/.env" -f "$compose_file" -f "$work/override.json")
    if [[ -f $override ]]; then candidate_compose+=(-f "$override"); fi
    "${candidate_compose[@]}" config --format json | jq -e --arg image "$candidate" '.services["log-rotator"].image==$image' >/dev/null
    if [[ -f $work/prior-override ]]; then
        jq -n --arg target "$target" --argjson prev "$previous" --rawfile old "$work/prior-override" '{kind:"aegis-log-switch-1",previous:$prev,target:$target,old_override:$old}' > "$work/pending.json"
    else
        jq -n --arg target "$target" --argjson prev "$previous" '{kind:"aegis-log-switch-1",previous:$prev,target:$target,old_override:null}' > "$work/pending.json"
    fi
    mv -- "$work/pending.json" "$pending"
    if "${candidate_compose[@]}" up -d --no-deps --pull never --wait --wait-timeout 90 "$service" &&
       current=$("${compose[@]}" ps --quiet "$service") &&
       [[ $(docker inspect --type container --format '{{.Image}}' "$current") == "$target" ]] &&
       docker exec "$current" /usr/local/sbin/aegis-check-logrotate --health &&
       [[ $(docker exec "$current" sha256sum /usr/local/etc/aegis/logrotate.conf | cut -d ' ' -f1) == "${before%% *}" ]]; then
        if ! log_override_unchanged "$work/prior-override" || ! log_patch_prerequisites; then
            printf '  전환 중 Compose 오버라이드가 변경되었습니다. 변경된 파일과 복구 기록을 보존합니다.\n' >&2
            exit 1
        fi
        if [[ -f $work/prior-override ]]; then
            mv -- "$work/override.json" "$log_override"
        else
            ln -- "$work/override.json" "$log_override" || { printf '  새 오버라이드와 복구 기록을 보존합니다.\n' >&2; exit 1; }
        fi
        rm -- "$pending"
        printf '  log 보안 업데이트 완료 · 스케줄러와 NPM·WAF 회전 규칙 정상.\n'; exit 0
    fi
    printf '  적용 실패. 이전 log 이미지와 실행 설정을 복구합니다.\n' >&2
    if log_restore "$work"; then printf '  이전 log 복구 완료.\n' >&2; else printf '  복구 실패. 기록을 보존합니다: %s\n' "$pending" >&2; fi
    exit 1
)

if [[ $interactive == true ]]; then
    accent= muted= good= attention= reset=
    if [[ -t 1 && ${TERM:-dumb} != dumb && ! -v NO_COLOR ]]; then
        accent=$'\e[1;36m'
        muted=$'\e[2m'
        good=$'\e[32m'
        attention=$'\e[33m'
        reset=$'\e[0m'
    fi
    rule='──────────────────────────────────────────────────────────────────'
    printf '\n  %sAEGIS%s 배포 관리자\n' "$accent" "$reset"
    printf '  %s%s · Git %.12s%s\n' "$muted" "$installed_version" "$revision" "$reset"
    printf '  %s%s%s\n\n' "$muted" "$rule" "$reset"
    printf '  %s실행 중인 서비스%s\n' "$accent" "$reset"
    printf '  %s%-19s %-19s %-18s %s%s\n' "$muted" CONTAINER APPLICATION VERSION STATUS "$reset"
    while read -r name state _ _ health container; do
        container=${container#/}
        case "$name" in
            npm) app='NGINX Proxy Manager' ;;
            agent) app='open-appsec' ;;
            db) app=MariaDB ;;
            log-rotator) app=logrotate ;;
            *) app='—' ;;
        esac
        version='n/a'
        if [[ $state == running ]] &&
           detected_version=$(installed_app_version "$name" "$container" 2>/dev/null) &&
           [[ $detected_version =~ ^[0-9][a-zA-Z0-9.+_-]*$ ]]; then
            version=$detected_version
        fi
        service_state=$state
        state_color=$attention
        if [[ $state == running ]]; then
            service_state=$health
            case "$health" in
                none) service_state=running; state_color=$good ;;
                healthy) state_color=$good ;;
            esac
        fi
        printf '  %-19s %-19s %-18s %s%s%s\n' \
            "$container" "$app" "$version" "$state_color" "$service_state" "$reset"
    done <<< "$inventory"

    release_delivery='계획 확인만 가능'
    if ! command -v jq >/dev/null; then
        release_delivery='릴리스 조회 도구 필요 (jq)'
        dry_run=true
    elif [[ -e $pending || -e $backup_pending ]]; then
        release_delivery='복구 기록 확인 필요'
        dry_run=true
    elif { application_supported "" && awk 'END { exit !(NR == 1 && $2 == "running") }' <<< "$inventory"; } ||
         { [[ -f $stack_update ]] && python3 -B "$stack_update" check >/dev/null 2>&1; }; then
        if command -v gh >/dev/null; then
            release_delivery='서명 검증 후 적용 가능'
        else
            release_delivery='릴리스 조회 가능 · 서명 검증에 gh 필요'
            dry_run=true
        fi
    else
        dry_run=true
    fi

    feature_tags=()
    security_tags=()
    stack_release_tag=
    stack_log_release_tag=
    release_status='조회할 수 없음'
    if ! command -v jq >/dev/null; then
        release_status='jq 필요'
    elif [[ -e $pending || -e $backup_pending ]]; then
        release_status='복구 완료 후 확인 가능'
    elif ! command -v gh >/dev/null; then
        release_status='릴리스 검증에 gh 필요'
    elif [[ ! $installed_version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ||
            ! $revision =~ ^[a-f0-9]{40}$ ]]; then
        release_status='설치 버전 또는 Git 커밋 미확인'
    elif release_tags=$(release_pages "$release_repo" |
        jq -rs --arg suffix "$installed_version-$revision.json" '
            def compatible($asset):
                map(select(any(.assets[]; .name == $asset))) | sort_by(.published_at) | reverse | map(.tag_name);
            [ .[][] | select(.draft == false and .prerelease == false and
                             (.tag_name | test("^[a-zA-Z0-9][a-zA-Z0-9._-]{0,79}$"))) ] |
            {feature: compatible("aegis-feature-" + $suffix),
             security: compatible("aegis-security-" + $suffix)}
        '); then
        candidates=$(jq -r 'to_entries[] | .key as $channel | .value[] | [$channel, .] | @tsv' <<< "$release_tags")
        release_status='호환 릴리스 없음'
        if [[ -n $candidates ]]; then
            release_status='검증된 호환 릴리스 없음'
            while IFS=$'\t' read -r listed_channel listed_tag listed_scope; do
                case "$listed_channel" in
                    feature) feature_tags+=("$listed_tag") ;;
                    security) security_tags+=("$listed_tag") ;;
                esac
                if [[ $dry_run == false && $listed_scope == stack* ]]; then
                    if [[ -z $stack_release_tag ]]; then stack_release_tag=$listed_tag; fi
                    if [[ $listed_scope == stack-log && -z $stack_log_release_tag ]]; then
                        stack_log_release_tag=$listed_tag
                    fi
                fi
            done < <(verified_menu_releases "$candidates")
        fi
    else
        release_status='GitHub 조회 실패'
    fi
    printf '\n  %s이미지 업데이트%s\n' "$accent" "$reset"
    if [[ -n $stack_log_release_tag ]]; then
        log_patch_available=false
        log_patch_state=RELEASE
        log_patch_status=$stack_log_release_tag
    else
        inspect_log_patch
    fi
    printf '  %s%-19s %s%s\n' "$muted" CONTAINER '업데이트 확인 결과' "$reset"
    log_container=$(awk '$1 == "log-rotator" {sub(/^\//, "", $6); print $6; exit}' <<< "$inventory")
    if command -v jq >/dev/null &&
       awk '$1 == "npm" || $1 == "agent" || $1 == "db" { found=1 } END {exit !found}' <<< "$inventory"; then
        cat <(inspect_vendor_image agent ghcr.io/openappsec/agent:latest) \
            <(inspect_vendor_image db jc21/mariadb-aria:latest) \
            <(if [[ -n $log_container ]]; then print_image_status "$log_container" "$log_patch_state" "$log_patch_status"; fi) \
            <(inspect_vendor_image npm ghcr.io/openappsec/nginx-proxy-manager-attachment:latest)
    elif [[ -n $log_container ]]; then
        print_image_status "$log_container" "$log_patch_state" "$log_patch_status"
    fi

    npm_container=$(awk '$1 == "npm" && $2 == "running" {sub(/^\//, "", $6); print $6; exit}' <<< "$inventory")
    if [[ -n $npm_container ]]; then
        if engine=$(timeout 4s docker exec "$npm_container" nginx -v 2>&1 |
            awk '/^nginx version:/ {
                version=$3
                if ($4 ~ /^\(aegis-nginx-core-[0-9.]+\)$/) version=version " " $4
                print version; found=1
            } END {exit !found}'); then
            if [[ $engine == openresty/1.27.1.2 ]]; then
                printf '  %-19s 엔진 %s · NGINX 2026-11-18 보안 수정 포함 여부 미확인\n' '' "$engine"
            else
                printf '  %-19s 엔진 %s · 보안 패치 이력은 릴리스에서 확인\n' '' "$engine"
            fi
        else
            printf '  %-19s NGINX 엔진 버전 확인 불가\n' ''
        fi
    fi

    image_audits
    printf '\n  %sGitHub 릴리스%s %s· %s%s\n' "$accent" "$reset" "$muted" "$release_delivery" "$reset"
    if (( ${#feature_tags[@]} )); then
        printf '  기능  %s개 · 최신 %s\n' "${#feature_tags[@]}" "${feature_tags[0]}"
    else printf '  기능  %s\n' "$release_status"; fi
    if (( ${#security_tags[@]} )); then
        printf '  보안  %s개 · 최신 %s\n' "${#security_tags[@]}" "${security_tags[0]}"
    else printf '  보안  %s\n' "$release_status"; fi

    secure_local_credentials
    stack_backup_action=
    if [[ -f $stack_backup ]] && command -v python3 >/dev/null; then
        if [[ -e $backup_pending ]]; then
            stack_backup_action=resume
        elif [[ -z $stack_release_tag && ! -e $pending ]] && python3 "$stack_backup" check >/dev/null 2>&1; then
            stack_backup_action=backup
        fi
    fi
    if command -v "${AEGIS_TRIVY_BIN:-trivy}" >/dev/null && command -v python3 >/dev/null; then
        mapfile -t audit_ids < <(awk '$2 == "running" {print $4}' <<< "$audit_inventory" | sort -u)
        if (( ${#audit_ids[@]} )); then
            python3 "$toolkit_dir/aegis-config/scripts/image-audit.py" auto "${audit_ids[@]}" ||
                printf '  실행 이미지 자동 검사 시작 실패\n' >&2
        fi
    fi

    while true; do
        printf '\n  %s작업 선택%s\n' "$accent" "$reset"
        if (( ${#feature_tags[@]} )); then printf '  [1] 기능 릴리스 선택\n'; fi
        if (( ${#security_tags[@]} )); then printf '  [2] 보안 릴리스 선택\n'; fi
        if [[ $log_patch_available == true ]]; then
            if log_recovery_pending; then
                printf '  [4] %s 중단된 업데이트 복구\n' "$log_container"
            else
                printf '  [4] %s 보안 업데이트\n' "$log_container"
            fi
        fi
        case "$stack_backup_action" in
            backup) printf '  [b] 백업 파일 생성 · 서비스 일시 중단\n' ;;
            resume) printf '  [b] 중단된 백업 후 서비스 재시작\n' ;;
        esac
        if command -v "${AEGIS_TRIVY_BIN:-trivy}" >/dev/null && command -v python3 >/dev/null; then
            printf '  [s] 실행 이미지 취약점 재검사\n'
        fi
        printf '  [i] 이미지 상세    [0] 종료\n\n'
        read -r -p '  선택 › ' choice || exit 0
        case "$choice" in
            1|2)
                channel=feature
                eligible=("${feature_tags[@]}")
                if [[ $choice == 2 ]]; then
                    channel=security
                    eligible=("${security_tags[@]}")
                fi
                if (( ! ${#eligible[@]} )); then
                    printf '  선택한 채널에는 검증할 릴리스가 없습니다.\n'
                    continue
                fi
                if ! command -v gh >/dev/null; then
                    printf '  서명 검증에는 GitHub CLI(gh)가 필요합니다.\n' >&2
                    continue
                fi
                printf '\n  배포할 릴리스\n'
                for index in "${!eligible[@]}"; do
                    printf '  [%d] %s\n' "$((index+1))" "${eligible[index]}"
                done
                read -r -p '  릴리스 번호 · [0] 뒤로 › ' selected || exit 0
                [[ $selected == 0 ]] && continue
                if [[ ! $selected =~ ^[1-9][0-9]{0,5}$ ]] || (( selected > ${#eligible[@]} )); then
                    printf '  표시된 릴리스 번호를 선택하세요.\n'
                    continue
                fi
                release_tag=${eligible[selected-1]}
                asset="aegis-$channel-$installed_version-$revision.json"
                temp_dir=$(mktemp -d)
                trap 'rm -f -- "$temp_dir/manifest.json" "$temp_dir/next.json" "$temp_dir/previous.json" "$temp_dir/pending.json"; rmdir -- "$temp_dir"' EXIT
                manifest="$temp_dir/manifest.json"
                if ! download_release_manifest "$release_tag" "$asset" "$manifest"; then
                    printf '  릴리스 매니페스트를 내려받지 못했습니다.\n' >&2
                    exit 1
                fi
                printf '  릴리스 %s를 찾았습니다. 서명과 호환성을 확인합니다.\n' "$release_tag"
                break
                ;;
            4)
                if [[ $log_patch_available == true ]]; then
                    patch_log_rotator
                    exit $?
                fi
                if [[ -n $stack_log_release_tag ]]; then
                    printf '  로그는 스택 릴리스 %s에서 업데이트합니다.\n' "$stack_log_release_tag"
                else
                    printf '  적용할 log 업데이트가 없습니다.\n'
                fi
                ;;
            b|B)
                case "$stack_backup_action" in
                    backup)
                        printf '  NPM·DB·WAF·log를 중지한 뒤 백업하고 다시 시작합니다.\n'
                        read -r -p '  서비스 중단이 가능한 시간인가요? (y/N) › ' confirm || exit 0
                        ;;
                    resume)
                        read -r -p '  백업 전 컨테이너를 다시 시작할까요? (y/N) › ' confirm || exit 0
                        ;;
                    *)
                        if [[ -n $stack_release_tag ]]; then
                            printf '  스택 릴리스 %s 적용 중에 백업을 자동으로 생성합니다.\n' "$stack_release_tag"
                        else
                            printf '  현재 스택의 백업 작업을 시작할 수 없습니다.\n'
                        fi
                        continue ;;
                esac
                [[ $confirm == [yY] ]] || continue
                python3 "$stack_backup" "$stack_backup_action"
                exit $?
                ;;
            s|S)
                if command -v "${AEGIS_TRIVY_BIN:-trivy}" >/dev/null && command -v python3 >/dev/null; then
                    mapfile -t ids < <(awk '$2 == "running" {print $4}' <<< "$audit_inventory" | sort -u)
                    if (( ${#ids[@]} )); then
                        python3 "$toolkit_dir/aegis-config/scripts/image-audit.py" scan "${ids[@]}" ||
                            printf '  일부 재검사 실패 · 각 결과의 DB 시각을 확인하세요.\n' >&2
                        image_audits
                    fi
                fi
                ;;
            i|I)
                image_audits detail
                printf '\n  %s이미지 상세%s\n' "$accent" "$reset"
                while read -r _ _ image_ref image_id _ container; do
                    printf '  %s\n    %s\n    %s\n' "${container#/}" "$image_ref" "$image_id"
                done <<< "$inventory"
                ;;
            0) exit 0 ;;
            *) printf '  표시된 메뉴 번호를 선택하세요.\n' ;;
        esac
    done
fi

if [[ -n $manifest ]]; then
    # Verify and parse the same private snapshot.
    if [[ $interactive == true ]]; then
        snapshot=$manifest
    else
        temp_dir=$(mktemp -d)
        trap 'rm -f -- "$temp_dir/manifest.json" "$temp_dir/next.json" "$temp_dir/previous.json" "$temp_dir/pending.json"; rmdir -- "$temp_dir"' EXIT
        snapshot="$temp_dir/manifest.json"
        cp -- "$manifest" "$snapshot"
    fi

    verify_release_attestation "$snapshot"

    if ! jq -es --arg channel "$channel" --arg version "$installed_version" \
        --arg revision "$revision" -f "$toolkit_dir/aegis-config/scripts/release-manifest.jq" "$snapshot" >/dev/null; then
        printf 'Release manifest is invalid or does not match this checkout.\n' >&2
        exit 1
    fi
    if [[ $interactive == true ]] && ! jq -e --arg tag "$release_tag" '.release == $tag' "$snapshot" >/dev/null; then
        printf '선택한 GitHub 태그와 서명된 릴리스 이름이 다릅니다.\n' >&2
        exit 1
    fi

    changes=$(manifest_changes "$snapshot")

    jq -r '"\nVerified release: \(.release)",
        "Resolved CVEs: \(.resolved_cves | join(", "))"' "$snapshot"
    printf 'Service\tCurrent image ID\tTarget image\n%s\n' "$changes"
    if jq -e '.strategy == "stack-v1"' "$snapshot" >/dev/null; then
        python3 -B "$stack_update" plan "$snapshot"
    fi
else
    printf '\nNo %s release manifest supplied.\n' "$channel"
fi

if [[ $dry_run == true ]]; then
    exit 0
fi

if [[ -n $manifest ]] && jq -e '.strategy == "stack-v1"' "$snapshot" >/dev/null; then
    if [[ $interactive == true ]]; then
        printf '  새 쓰기가 들어오지 않도록 외부 트래픽과 관리 작업을 일시 중지하세요.\n'
        read -r -p '  쓰기 중지 및 서비스 중단을 확인하고 적용할까요? (y/N) › ' confirm || exit 0
        [[ $confirm == [yY] ]] || exit 0
    elif [[ $maintenance != true ]]; then
        printf 'Stack deployment requires --maintenance after pausing ingress and administrative writes.\n' >&2
        exit 2
    fi
    python3 -B "$stack_update" apply "$snapshot"
    exit $?
fi

if [[ -z $manifest || $changes == *$'\n'* ]]; then
    printf 'Application requires a verified manifest for one service.\n' >&2
    exit 1
fi
IFS=$'\t' read -r service from_id target <<< "$changes"

if ! application_supported "$service"; then
    printf 'Application supports only isolated single-service deployments with a healthcheck.\n' >&2
    exit 1
fi

if [[ $interactive == true ]]; then
    read -r -p '위 변경을 적용하시겠습니까? (y/N) ' confirm || exit 0
    [[ $confirm == [yY] ]] || exit 0
fi

install -d -m 700 -- "$state_dir"
exec {lock_fd}>"$state_dir/lock"
flock -n "$lock_fd" || { printf 'Another update is running.\n' >&2; exit 1; }

if [[ -e $pending ]]; then
    printf 'An unfinished transaction exists at %s.\n' "$pending" >&2
    exit 1
fi
if [[ -e $backup_pending || -L $backup_pending ]]; then
    printf 'Restore the services from the interrupted stack backup before updating.\n' >&2
    exit 1
fi
if [[ -e $stack_pending || -L $stack_pending ]]; then
    printf 'Restore the interrupted stack release before updating.\n' >&2
    exit 1
fi
current_id=$("${compose[@]}" ps --quiet "$service")
read -r current_image previous_ref <<< "$(docker inspect --type container --format '{{.Image}} {{.Config.Image}}' "$current_id")"
[[ $(docker image inspect --format '{{.Id}}' "$previous_ref") == "$from_id" ]] ||
    { printf 'The previous image reference no longer points to the running image.\n' >&2; exit 1; }
[[ $current_image == "$from_id" ]] || { printf 'The running image changed during planning.\n' >&2; exit 1; }

docker image pull "$target"
target_id=$(docker image inspect --format '{{.Id}}' "$target")
if [[ $target_id == "$from_id" ]]; then
    printf 'The target image is already running.\n'
    exit 0
fi

next="$temp_dir/next.json"
previous="$temp_dir/previous.json"
jq -n --arg service "$service" --arg image "$target" '{services:{($service):{image:$image}}}' > "$next"
jq -n --arg service "$service" --arg image "$previous_ref" '{services:{($service):{image:$image}}}' > "$previous"
jq -n --arg service "$service" --arg previous "$from_id" --arg target "$target" \
    '{service:$service,previous:$previous,target:$target}' > "$temp_dir/pending.json"
install -m 600 -- "$temp_dir/pending.json" "$state_dir/pending.new"
mv -- "$state_dir/pending.new" "$pending"

if "${compose[@]}" -f "$next" up -d --no-deps --pull never --wait --wait-timeout 30 "$service" &&
   current_id=$("${compose[@]}" ps --quiet "$service") &&
   [[ $(docker inspect --type container --format '{{.Image}}' "$current_id") == "$target_id" ]]; then
    install -m 600 -- "$next" "$state_dir/images.new"
    mv -- "$state_dir/images.new" "$override"
    rm -- "$pending"
    printf 'Update applied: %s\n' "$target"
    exit 0
fi

printf 'Update failed. Restoring the previous image.\n' >&2
if "${compose[@]}" -f "$previous" up -d --no-deps --pull never --wait --wait-timeout 30 "$service" &&
   current_id=$("${compose[@]}" ps --quiet "$service") &&
   [[ $(docker inspect --type container --format '{{.Image}}' "$current_id") == "$from_id" ]]; then
    rm -- "$pending"
    printf 'Previous image restored.\n' >&2
else
    printf 'Rollback failed. Recovery record retained at %s.\n' "$pending" >&2
fi
exit 1
