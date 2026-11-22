#!/usr/bin/env bash
# Build local research images from pre-fetched exact inputs in a fresh directory.
set -euo pipefail
umask 077
if [[ $# != 3 || ( $1 != modern && $1 != bookworm ) ]]; then
    echo "Usage: $0 modern|bookworm INPUT_DIRECTORY NEW_WORK_DIRECTORY" >&2
    exit 2
fi
mode=$1
inputs=$(realpath "$2")
mkdir -m 700 -- "$3"
work=$(realpath "$3")
recipe=$(cd -- "$(dirname -- "$0")" && pwd)
engine=sha256:58da2f5a21c96723e2bcf7379604bdae063e1bc112da8a89697424a29340991a
upstream=jc21/nginx-proxy-manager@sha256:ddccef5311d962ce733bc3439f9efdc11f167888804e60c5912f8a37ecdc5d52
source_revision=89c43f564422a78bd0732046b636cbcd5e566b03
nonce=$(basename "$(mktemp -d "$work/tags.XXXXXXXX")" | tr '[:upper:]' '[:lower:]')
tags="aegis-npm-research:$nonce"
verify() {
    [[ $(docker image inspect --format '{{.Id}}' "$1") == "$2" ]] || { echo "Local image ID mismatch" >&2; exit 1; }
}
node_tree() {
    local supplied=$1 lock=$2 dest=$3
    mkdir -p "$dest" "$work/cache-$lock"
    cp "$recipe/locks/$lock" "$dest/package-lock.json"
    python3 - "$dest" <<'PYTHON'
import json, sys
from pathlib import Path
root=Path(sys.argv[1]); lock=json.loads((root/'package-lock.json').read_bytes())
package={'name':lock['name'],'private':True,'dependencies':lock['packages']['']['dependencies']}
(root/'package.json').write_text(json.dumps(package)+'\n')
PYTHON
    cp -a "$supplied/npm-cache/." "$work/cache-$lock/"
    # npm ci verifies registry tarball integrity from the committed lockfile before extraction.
    docker run --rm --pull never --network none --user "$(id -u):$(id -g)" -e HOME=/tmp \
        -v "$work/cache-$lock:/cache" -v "$dest:/locked" -w /locked --entrypoint npm "$upstream" \
        ci --offline --cache=/cache --ignore-scripts --no-audit --no-fund

}
copy_certifi() {
    local dst=$1
    mkdir -p "$dst"
    cp "$inputs/certifi-2026.11.20-py3-none-any.whl" "$dst/"
    (cd "$dst" && printf '%s  %s\n' 7422df25243767b9877031a2248cb14d09ddac9beee846f4cef3d5c9191d488f certifi-2026.11.20-py3-none-any.whl >SHA256SUMS && sha256sum -c SHA256SUMS)
}
verify "$upstream" sha256:6b906b29aee05da90feb85cd2bb1e4473df2d6b4498fd8a237f2716138e2c9f5
verify "$engine" "$engine"
if [[ $mode == bookworm ]]; then
    mkdir "$work/base" "$work/tar"
    mkdir "$work/base/debs"
    while read -r hash file; do
        [[ $hash =~ ^[0-9a-f]{64}$ && $file =~ ^\./[a-zA-Z0-9.+_~%:-]+\.deb$ ]]
        cp -- "$inputs/debs/$file" "$work/base/debs/"
    done <"$recipe/locks/bookworm-debs.sha256"
    cp "$recipe/locks/bookworm-debs.sha256" "$work/base/debs/SHA256SUMS"
    (cd "$work/base/debs" && sha256sum -c SHA256SUMS >/dev/null)
    node_tree "$inputs/bookworm-node" bookworm-node.json "$work/base/node"
    cp "$inputs/cert-prune" "$work/base/cert-prune"
    (cd "$work/base" && echo 'e4fde772da7b3bff2447a2901bd7b34186989431561d7772e03576691923404f  cert-prune' | sha256sum -c -)
    copy_certifi "$work/base/python"
    docker tag "$engine" "${tags}-engine"
    cp "$recipe/Dockerfile.bookworm" "$work/base/Dockerfile"
    docker build --network none --build-arg "PARENT_IMAGE=${tags}-engine" --iidfile "$work/base/image.id" -t "${tags}-compat" "$work/base"
    verify "${tags}-compat" "$(cat "$work/base/image.id")"
    cp "$recipe/Dockerfile.tar" "$work/tar/Dockerfile"
    cp "$recipe/verify-tar.cjs" "$work/tar/"
    docker build --network none --build-arg "PARENT_IMAGE=${tags}-compat" --iidfile "$work/final-image.id" -t "${tags}-final" "$work/tar"
    exit 0
fi
mkdir -p "$work/source" "$work/base/backend/internal" "$work/final/python"
git -C "$inputs/npm-source" archive "$source_revision" | tar -xf - -C "$work/source"
git -C "$work/source" apply --no-index --check "$recipe/npm-2.17.1.patch"
git -C "$work/source" apply --no-index "$recipe/npm-2.17.1.patch"
for file in setup.js internal/proxy-host.js internal/aegis-waf.js internal/certificate.js schema/paths/nginx/proxy-hosts/post.json schema/paths/nginx/proxy-hosts/hostID/put.json; do
    install -D -m 644 "$work/source/backend/$file" "$work/base/backend/$file"
done
mkdir -p "$work/base/modules/usrlib" "$work/base/modules/notices"
container=$(docker create --pull never --network none --entrypoint /bin/true "$engine")
trap 'docker rm -v "$container" >/dev/null' EXIT
docker cp "$container:/usr/lib/nginx/modules/libngx_module.so" "$work/base/modules/"
for lib in compression_utils nginx_attachment_util shmem_ipc; do docker cp "$container:/usr/lib/libosrc_$lib.so" "$work/base/modules/usrlib/"; done
docker cp "$container:/app/templates/local-policy-open-appsec-enabled-for-proxy-host.yaml" "$work/base/template.yaml"
cp -a "$inputs/attachment-notices/." "$work/base/modules/notices/"
(cd "$work/base" && sha256sum -c "$recipe/locks/attachment.sha256")
node_tree "$inputs/trixie-node" trixie-node.json "$work/base/node"
node_tree "$inputs/trixie-tools" trixie-tools.json "$work/final/node"
copy_certifi "$work/base/python"
# Yarn requires a writable working cache even when a pre-populated cache is mounted as seed.
cp -a "$inputs/frontend-yarn-cache" "$work/frontend-yarn-cache"
docker run --rm --pull never --network none --user "$(id -u):$(id -g)" --cpus 1 --memory 3200m -e HOME=/tmp -e YARN_CACHE_FOLDER=/cache -v "$work/frontend-yarn-cache:/cache" -v "$work/source/frontend:/source" -w /source --entrypoint sh "$upstream" -ec 'yarn install --offline --frozen-lockfile --non-interactive --ignore-scripts --production=false && NODE_ENV=production yarn locale-compile && NODE_ENV=production yarn build'
cp -a "$work/source/frontend/dist" "$work/base/frontend"
cp -a "$work/source/frontend/dist" "$work/final/frontend"
cp "$recipe/Dockerfile.2.17.1" "$work/base/Dockerfile"
docker build --network none --iidfile "$work/base/image.id" -t "${tags}-modern" "$work/base"
verify "${tags}-modern" "$(cat "$work/base/image.id")"
cp "$inputs/pip-26.3-py3-none-any.whl" "$inputs/setuptools-80.10.2-py3-none-any.whl" "$work/final/python/"
python3 "$recipe/repack-pip.py" "$work/final/python"
cp "$work/source/backend/internal/aegis-waf.js" "$work/final/"
cp "$recipe/materialize.cjs" "$work/final/"
cp "$recipe/Dockerfile.tools" "$work/final/Dockerfile"
docker build --network none --build-arg "PARENT_IMAGE=${tags}-modern" --iidfile "$work/final-image.id" -t "${tags}-final" "$work/final"
