#!/usr/bin/env bash
# Print the local tag to store in a new installation's .env.
set -euo pipefail
assets=$(cd -- "$(dirname -- "$0")" && pwd -P)
known=sha256:01ac69580137b28229fdbbc7586d8d2fa561c90a022954aa3dbb7c331d7ce39c
recipe=$(sha256sum < "$assets/Dockerfile")
expected_recipe=4db8115b10bf2489b63611b3580c244a034a39e0c65a83798a1ba0bec60cf0f5
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
if [[ ${recipe%% *} == "$expected_recipe" ]] && docker image inspect "$known" >/dev/null 2>&1; then
    id=$known
else
    docker build --pull --progress plain --iidfile "$work/id" "$assets" >&2
    id=$(<"$work/id")
fi
[[ $id =~ ^sha256:[0-9a-f]{64}$ && $(docker image inspect --format '{{.Id}}' "$id") == "$id" ]]
docker run --rm --pull never --network none --entrypoint sh "$id" -ec '
    mariadbd --version | grep -F "10.11.20-MariaDB"
    gosu --version | grep -F "1.19 (go1.27.4"
    test -z "$(ls -A /var/lib/mysql)"
    test "$(gosu nobody id -u)" != 0
' >&2
if [[ $id != "$known" ]]; then
    printf 'Fresh MariaDB build %s. Its vulnerability scan is available through update.sh.\n' "$id" >&2
fi
tag="aegis-mariadb:local-${id#sha256:}"
docker image tag "$id" "$tag"
printf '%s\n' "$tag"
