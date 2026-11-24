#!/bin/bash
set -euo pipefail

# v0.4.1 fetches only update.sh and invokes it with --no-self-update.
if [[ ${1:-} == --no-self-update ]]; then shift; fi
install_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
toolkit_tag=v0.5.0
toolkit_digest=8fa2088a49a1f5f45fd8447bdcae88f3f0c7c25fa60713457b494f12bfa86f0a
toolkit_manifest=aegis-config/releases/toolkit.sha256

verified() {
    local directory=$1 recorded
    [[ -f $directory/$toolkit_manifest ]] || return 1
    recorded=$(sha256sum < "$directory/$toolkit_manifest") || return 1
    [[ ${recorded%% *} == "$toolkit_digest" ]] &&
        (cd -- "$directory" && sha256sum --check --status "$toolkit_manifest")
}

toolkit=$install_root
if ! verified "$toolkit"; then
    state="$install_root/.aegis-update"
    umask 077
    mkdir -p -- "$state"
    [[ -O $state && -d $state && ! -L $state ]] || {
        printf '업데이트 상태 디렉터리의 소유권을 확인하세요.\n' >&2
        exit 1
    }
    chmod go-rwx -- "$state"
    toolkit="$state/toolkit-$toolkit_digest"
    if ! verified "$toolkit"; then
        if [[ -e $toolkit || -L $toolkit ]]; then
            printf '보관한 배포 도구의 무결성이 일치하지 않습니다.\n' >&2
            exit 1
        fi
        build=$(mktemp -d "$state/toolkit-fetch.XXXXXXXX")
        trap 'rm -rf -- "$build"' EXIT
        git init -q "$build/source"
        git -c credential.interactive=never -C "$build/source" fetch -q --no-tags --depth=1 \
            https://github.com/AegisAX/Aegis-Proxy-Stack.git "refs/tags/$toolkit_tag"
        assets="$build/assets"
        mkdir -p -- "$assets/${toolkit_manifest%/*}"
        git -C "$build/source" show "FETCH_HEAD:$toolkit_manifest" > "$assets/$toolkit_manifest"
        actual=$(sha256sum < "$assets/$toolkit_manifest")
        [[ ${actual%% *} == "$toolkit_digest" ]]
        while IFS= read -r row; do
            path=${row:66}
            [[ $path =~ ^aegis-config/[A-Za-z0-9._/-]+$ && $path != *..* ]]
            mkdir -p -- "$assets/${path%/*}"
            git -C "$build/source" show "FETCH_HEAD:$path" > "$assets/$path"
        done < "$assets/$toolkit_manifest"
        verified "$assets"
        if ! mv -T --no-clobber -- "$assets" "$toolkit"; then
            verified "$toolkit"
        fi
        verified "$toolkit"
        rm -rf -- "$build"
        trap - EXIT
    fi
fi

export AEGIS_INSTALL_ROOT="$install_root"
exec bash "$toolkit/aegis-config/scripts/update-manager.sh" "$@"
