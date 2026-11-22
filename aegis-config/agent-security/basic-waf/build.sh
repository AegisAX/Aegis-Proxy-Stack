#!/usr/bin/env bash
# Run on Linux/amd64 with Docker, git, trusted GPG keys, dpkg-deb and binutils.
set -euo pipefail
[[ $# == 5 ]] || { echo 'Usage: build.sh OPENAPPSEC_GIT BOOST_REGEX_GIT APK_DIR NINJA_DEB NEW_OUTPUT_DIR' >&2; exit 2; }
recipe=$(cd -- "$(dirname -- "$0")" && pwd -P)
waf=$(realpath -- "$1"); boost=$(realpath -- "$2"); apks=$(realpath -- "$3"); deb=$(realpath -- "$4")
out=$(realpath -m -- "$5"); [[ ! -e $out ]] || { echo 'Choose a new output directory.' >&2; exit 2; }
umask 077; mkdir -- "$out"; mkdir -- "$out/source" "$out/work" "$out/ninja"
source_commit=f562a28d37f25a0a60221517f4f44f50ff940e50
merge=b8e58068ffbad37a9da9a2c5e4decbeeb3361fed
verify_commit() {
    local log=$out/$(basename "$2").signature
    git -C "$1" -c gpg.program=gpg verify-commit --raw "$2" > "$log" 2>&1
    grep -Eq '^\[GNUPG:\] VALIDSIG 968479A1AFF927E37D1A566BB5690EEEBB952194 ' "$log"
}
verify_commit "$waf" "$source_commit"; verify_commit "$boost" "$merge"
[[ $(git -C "$waf" rev-parse "$source_commit^{tree}") == e8bcdd6b286c6318e1553e3a2a8b44faaed5c803 ]]
[[ $(git -C "$boost" rev-parse "$merge^1") == 237e69caf65906d0313c9b852541b07fa84a99c1 ]]
git -C "$waf" archive "$source_commit" | tar -x -C "$out/source"
git -C "$boost" -c core.abbrev=7 diff "$merge^1" "$merge" -- include/boost/regex > "$out/regex.patch"
check_sha() { printf '%s  %s\n' "$1" "$2" | sha256sum -c - >/dev/null; }
check_sha ba098c1ddca4af893b26a5ecf2b692730c1f753ff9d5ec05223ce445a9930568 "$out/regex.patch"
check_sha 6a17f76a0f75586f1292f6c61a9b07fd0dec963baf6a102b17673f601c6b323a "$deb"
check_sha 6ed517a1257ca04e1385ad56cd95feff3fa7f29c05c14f672f4419c6350767d6 "$recipe/APK.SHA256"
dpkg-deb -x "$deb" "$out/ninja"; ninja=$out/ninja/usr/bin/ninja
[[ $("$ninja" --version) == 1.11.1 ]]
image=sha256:e50d940e9d2c4d81e5b3506b2ed87bfc7e91267b36ff016eb4b4cb21c39a3331
[[ $(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image") == linux/amd64 ]]
docker run --rm --pull never --network none --cpus 1 --memory 3g --pids-limit 160 \
    --security-opt no-new-privileges --env OWNER_UID="$(id -u)" --env OWNER_GID="$(id -g)" \
    -v "$out/work:/work" -v "$out/source:/src:ro" -v "$apks:/apks:ro" \
    -v "$recipe:/recipe:ro" -v "$out/regex.patch:/patch:ro" "$image" sh /recipe/build-inner.sh
python3 "$recipe/verify-deps.py" "$ninja" "$out/work/obj" "$out/dependency-receipt.json"
