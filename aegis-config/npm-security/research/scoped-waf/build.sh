#!/usr/bin/env bash
# Prepare the research proxy from a reviewed fork and a pre-fetched attachment archive.
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: build.sh OPEN_APPSEC_NPM_GIT ATTACHMENT_ARCHIVE NEW_OUTPUT' >&2; exit 2; }
recipe=$(cd -- "$(dirname -- "$0")" && pwd -P)
fork=$(realpath -- "$1")
archive=$(realpath -- "$2")
umask 077
mkdir -m 700 -- "$3"
work=$(realpath -- "$3")
mkdir "$work/compiler" "$work/module" "$work/app"
fork_commit=5a3728fcc7a3853fe51522301db7eeda2cbab845
for file in Dockerfile.engine build-engine.sh build-attachment.sh; do
    git -C "$fork" show "$fork_commit:security/$file" >"$work/compiler/$file"
done
(cd "$work/compiler" && sha256sum -c - <<'LOCK'
db17fcd73c4d8cb56ce4ff62026de99d0fbfdd81a4c82324d0aeecf736ee349f  Dockerfile.engine
aa9aba70854d3d579f447446e1f5d1cc460a5662d0a37dd43279512f288c66d6  build-engine.sh
2b648363916bf41a95d77097077eedc79903853b88d0f475b93c3e0a7ba1ca84  build-attachment.sh
LOCK
)
cp "$archive" "$work/module/attachment-1ed86d4.tar.gz"
(cd "$work/module" && echo 'c3d0e0e46c9b632023d5a7235647bd8c2bb70ba16ff22229bec60ce4f1da9602  attachment-1ed86d4.tar.gz' | sha256sum -c -)
cp "$work/compiler/build-attachment.sh" "$recipe/../nginx-scoped-verdict.patch" "$recipe/Dockerfile.module" "$work/module/"
base=sha256:4011d192e11d14783ba86f6d1b0ef935495324731e903523390ea40a7e9972e0
[[ $(docker image inspect -f '{{.Id}}' "$base") == "$base" ]]
tag="aegis-waf-qa:$(cat /proc/sys/kernel/random/uuid)"
docker tag "$base" "$tag-base"
docker build --target engine -t "$tag-builder" -f "$work/compiler/Dockerfile.engine" "$work/compiler"
docker build --network none --build-arg BUILDER="$tag-builder" --build-arg NPM="$tag-base" \
    -f "$work/module/Dockerfile.module" -t "$tag-module" "$work/module"
mkdir -p "$work/app/backend/internal"
docker run --rm --pull never --network none --read-only --cap-drop ALL --entrypoint cat \
    "$base" /app/internal/aegis-waf.js > "$work/app/backend/internal/aegis-waf.js"
(cd "$work/app" && echo '0ac16be4f73a108540c0f42a7625bf0f245e9d37d9c995347c05f6412b16b564  backend/internal/aegis-waf.js' | sha256sum -c -)
git -C "$work/app" apply --no-index --check "$recipe/npm-policy-ack.patch"
git -C "$work/app" apply --no-index "$recipe/npm-policy-ack.patch"
cp "$recipe/../../../scripts/wait-waf-ready.sh" "$work/app/"
cp "$work/app/backend/internal/aegis-waf.js" "$recipe/waf-scope.cjs" "$work/app/"
docker build --network none --build-arg PARENT="$tag-module" -t "$tag-app" --iidfile "$work/scoped-app.id" \
    -f "$recipe/Dockerfile.runtime" "$work/app"
# Keep the Debian packages in the deployed image aligned with the reviewed inputs.
(cd "$recipe" && echo '43e9351500bf8037e8528c371767737b3e9dafa0913fe3760964268566508094  debian-security.sha256' | sha256sum -c -)
docker build --build-arg BASE="$tag-app" --iidfile "$work/image.id" - <"$recipe/Dockerfile.debian-security"
