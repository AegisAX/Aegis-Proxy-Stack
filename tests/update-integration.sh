#!/bin/bash
set -euo pipefail

repo_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
old_image=${1:?Usage: bash tests/update-integration.sh OLD_IMAGE TARGET_REPO@sha256:DIGEST}
target=${2:?Pass the replacement image by digest}
lab=$(mktemp -d /tmp/aegis-update-test.XXXXXX)
export COMPOSE_PROJECT_NAME="aegis-update-test-${lab##*.}"
COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME,,}
compose=(docker compose --project-directory "$lab" -f "$lab/docker-compose.yml")
cleanup() {
    "${compose[@]}" down --remove-orphans >/dev/null 2>&1 || true
    rm -rf -- "$lab"
}
trap cleanup EXIT

cp -- "$repo_dir/update.sh" "$lab/update.sh"
toolkit=aegis-config/releases/toolkit.sha256
install -D -m 644 "$repo_dir/$toolkit" "$lab/$toolkit"
while read -r _ file; do
    install -D -m 644 "$repo_dir/$file" "$lab/$file"
done < "$repo_dir/$toolkit"
cd -- "$lab"
touch .env
printf 'v0.4.1\n' > VERSION
git init -q
git -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m fixture
mkdir bin
# Isolate the verifier double to this process. Compose and Docker are real.
cat > bin/gh <<'MOCK'
#!/bin/bash
case "$1 $2" in
    'attestation verify') exit "${MOCK_VERIFY_STATUS:-0}" ;;
    'api --hostname')
        asset="aegis-security-v0.4.1-$FIXTURE_COMMIT.json"
        jq -n --arg asset "$asset" '[
            {tag_name:"v0.4.6",draft:false,prerelease:true,published_at:"2026-01-03",assets:[{name:$asset}]},
            {tag_name:"v0.4.5",draft:false,prerelease:false,published_at:"2026-01-02",assets:[{name:$asset}]},
            {tag_name:"v0.4.4",draft:false,prerelease:false,published_at:"2026-01-01",assets:[{name:$asset}]}]'
        ;;
    'release download')
        until [[ $1 == --output ]]; do shift; done
        [[ $4 == v0.4.4 ]] || exit 9
        jq --arg release "${MOCK_RELEASE_NAME:-$4}" '.release=$release' release.json > "$2"
        ;;
    *) exit 9 ;;
esac
MOCK
chmod +x bin/gh
export PATH="$lab/bin:$PATH"
export FIXTURE_COMMIT=$(git rev-parse HEAD)

old_id=$(docker image inspect --format '{{.Id}}' "$old_image")
docker image pull "$target"
target_id=$(docker image inspect --format '{{.Id}}' "$target")
[[ $old_id != "$target_id" ]]
jq -n --arg revision "$(git rev-parse HEAD)" --arg old "$old_id" --arg target "$target" '
    {schema_version:1, channel:"security", from_version:"v0.4.1", from_commit:$revision,
     release:"integration-fixture", resolved_cves:["CVE-2000-0000"],
     images:{probe:{from_id:$old,target:$target}}}
' > release.json

current_image() {
    docker inspect --type container --format '{{.Image}}' "$("${compose[@]}" ps -q probe)"
}

for scenario in failure success; do
    if [[ $scenario == failure ]]; then
        old_release=$(docker run --rm --network none "$old_image" cat /etc/alpine-release)
        check="grep -Fx ${old_release} /etc/alpine-release"
    else
        check='test -s /etc/alpine-release'
    fi
    jq -n --arg image "$old_image" --arg check "$check" '
      {services:{probe:{image:$image,command:["sleep","600"],stop_grace_period:"1s",
        healthcheck:{test:["CMD-SHELL",$check],interval:"1s",timeout:"1s",retries:2}}}}
    ' > docker-compose.yml
    "${compose[@]}" up -d --pull never --wait --wait-timeout 15
    bash update.sh --security --dry-run --manifest release.json
    [[ $(current_image) == "$old_id" ]]
    if MOCK_VERIFY_STATUS=1 bash update.sh --security --manifest release.json; then
        exit 1
    fi
    [[ $(current_image) == "$old_id" && ! -e .aegis-update/pending.json ]]

    mkdir -p .aegis-update
    touch .aegis-update/pending.json
    if bash update.sh --security --manifest release.json; then exit 1; fi
    [[ $(current_image) == "$old_id" ]]
    rm -- .aegis-update/pending.json

    touch .aegis-update/backup-pending.json
    if bash update.sh --security --manifest release.json; then exit 1; fi
    [[ $(current_image) == "$old_id" && -f .aegis-update/backup-pending.json ]]
    rm -- .aegis-update/backup-pending.json

    if [[ $scenario == failure ]]; then
        if bash update.sh --security --manifest release.json; then exit 1; fi
        [[ $(current_image) == "$old_id" && ! -e .aegis-update/pending.json ]]
    else
        printf '2\n2\nn\n' | timeout 40s script -qefc 'bash update.sh --no-self-update' /dev/null >menu.log
        grep -F 'Verified release: v0.4.4' menu.log
        if grep -F 'v0.4.6' menu.log; then exit 1; fi
        [[ $(current_image) == "$old_id" ]]
        if printf '2\n2\ny\n' | MOCK_RELEASE_NAME=v0.4.5 timeout 40s \
            script -qefc 'bash update.sh' /dev/null >wrong-tag.log; then exit 1; fi
        grep -F '선택한 GitHub 태그와 서명된 릴리스 이름이 다릅니다' wrong-tag.log
        [[ $(current_image) == "$old_id" ]]
        bash update.sh --security --manifest release.json
        [[ $(current_image) == "$target_id" && -s .aegis-update/images.json && ! -e .aegis-update/pending.json ]]
    fi
    "${compose[@]}" down
    printf 'Passed: %s\n' "$scenario"
done
