#!/usr/bin/env bash
# stdout is the content-addressed local image tag. Diagnostics go to stderr.
set -euo pipefail
assets=$(cd -- "$(dirname -- "$0")" && pwd -P)
mode=build
if [[ ${1:-} == --install ]]; then mode=install; shift; fi
if [[ ${1:-} == --override ]]; then
    [[ $# == 2 && $2 =~ ^aegis-log-rotator:local-[a-f0-9]{64}$ ]] || exit 2
    jq -n --arg image "$2" '{"x-aegis-local-patch":"log-rotator",services:{"log-rotator":{
      image:$image,pull_policy:"never",command:["crond","-f","-l","8"],
      healthcheck:{test:["CMD","/usr/local/sbin/aegis-check-logrotate","--health"],interval:"15s",timeout:"8s",retries:3}}}}'
    exit
fi
[[ ($mode == build && $# == 1) || ($mode == install && $# == 2) ]] || exit 2
config=$1
[[ -f $config && ! -L $config && -r $config ]] || { echo '로그 순환 설정을 읽을 수 없습니다.' >&2; exit 1; }
read -r owner mode_bits < <(stat -c '%u %a' -- "$config")
[[ $owner == "$EUID" || $owner == 0 ]] && (( (8#$mode_bits & 022) == 0 )) || { echo '로그 설정의 소유권·쓰기 권한을 확인하세요.' >&2; exit 1; }
if [[ $mode == install ]]; then
    destination=$2
    [[ ! -e $destination && ! -L $destination ]] || { echo '기존 Compose 오버라이드를 보존합니다. 기존 설치는 update.sh를 사용하세요.' >&2; exit 1; }
fi
work=$(mktemp -d); fragment=
trap 'rm -rf -- "$work"; if [[ -n $fragment ]]; then rm -f -- "$fragment"; fi' EXIT
install -m 0644 "$assets/Dockerfile" "$work/Dockerfile"
install -m 0755 "$assets/aegis-check-logrotate" "$work/aegis-check-logrotate"
install -m 0644 "$config" "$work/aegis-rotate.conf"
sha() { sha256sum < "$1" | cut -d ' ' -f1; }
digest=$(sha "$work/aegis-rotate.conf"); checker=$(sha "$work/aegis-check-logrotate")
# A previously validated image can be reused when the exact recipe and current repository packages agree.
known=sha256:5efaa4b35ab37b0d6d2e678f7c6881c7d44f5ea5ee4298839a5d91707d947ac4
id=
if [[ $digest == 119914b243b61e9aab44417cbef343734f0598ba19676f2fec61665972851744 &&
      $checker == 07949cc4a7348b6a84bd671c6d9df743527ae95bf8616621ff092cf6210be3b4 &&
      $(sha "$work/Dockerfile") == c6ec7ce0f5bbb88475a4be9ae37192c2dece0e6121d09f9aaae8b9790eaceab9 ]] &&
   docker image inspect "$known" >/dev/null 2>&1 &&
   timeout 35s docker run --rm --pull never --cap-drop ALL --security-opt no-new-privileges --entrypoint sh "$known" -ec '
       apk --timeout 8 update >/dev/null && pending=$(apk version -l "<") && ! printf "%s\n" "$pending" | grep -q " < "' >&2; then
    id=$known
else
    docker build --progress plain --pull --no-cache --iidfile "$work/image-id" "$work" >&2
    id=$(<"$work/image-id")
fi
[[ $id =~ ^sha256:[a-f0-9]{64}$ && $(docker image inspect --format '{{.Id}}' "$id") == "$id" ]]
run=(docker run --rm --pull never --network none --cap-drop ALL --security-opt no-new-privileges)
"${run[@]}" --entrypoint sh "$id" -ec '
    set -o pipefail
    case "$(cat /etc/alpine-release)" in 3.22.*) ;; *) exit 1;; esac
    printf "%s  %s\n%s  %s\n" "$1" /usr/local/etc/aegis/logrotate.conf "$2" /usr/local/sbin/aegis-check-logrotate | sha256sum -c -
    for requirement in musl=1.2.5-r13 musl-utils=1.2.5-r13 libssl3=3.5.9-r0 libcrypto3=3.5.9-r0 busybox=1.37.0-r20 logrotate=3.21.0-r1; do
        name=${requirement%=*}; floor=${requirement#*=}
        installed=$(awk -F: -v pkg="$name" '\''$1=="P" {matchpkg=($2==pkg)} $1=="V" && matchpkg {print $2}'\'' /lib/apk/db/installed)
        test -n "$installed" || exit 1
        case "$(apk version -t "$installed" "$floor")" in ">"|"=") ;; *) exit 1;; esac
    done
    ! command -v docker >/dev/null && ! apk info -e docker-cli >/dev/null || exit 1
' sh "$digest" "$checker" >&2
"${run[@]}" -i --entrypoint sh "$id" -s < "$assets/probe.sh" >&2
[[ $(sha "$config") == "$digest" ]] || { echo '검증 중 로그 설정이 변경되었습니다.' >&2; exit 1; }
tag="aegis-log-rotator:local-${id#sha256:}"
docker image tag "$id" "$tag"
if [[ $mode == install ]]; then
    fragment=$(mktemp "${destination}.XXXXXX")
    bash "$0" --override "$tag" > "$fragment"
    ln -- "$fragment" "$destination" || { echo '기존 Compose 오버라이드를 보존합니다.' >&2; exit 1; }
fi
printf '%s\n' "$tag"
