#!/bin/sh
set -eu
umask 022
cd /apks
sha256sum -c /recipe/APK.SHA256 >/dev/null
# Only install the exact filename list that was hashed. The offline image's official Alpine
# keyring independently checks every APK signature.
set -- $(awk '{print "/apks/" $2}' /recipe/APK.SHA256)
test "$#" = 139
apk verify "$@" >/dev/null
apk add --no-network --repositories-file /dev/null "$@" >/dev/null
cd /usr/include
patch --fuzz=0 -p2 </patch
sha256sum -c /recipe/headers.sha256
addgroup -g "$OWNER_GID" trial
adduser -D -u "$OWNER_UID" -G trial trial
exec su trial -s /bin/sh -c '
set -eu
cd /work
export CPLUS_INCLUDE_PATH=/work/obj/external:/work/obj/external/graphqlparser:/src/external/graphqlparser
cmake -S /src -B /work/obj -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_CXX_FLAGS_RELEASE="-O2 -DNDEBUG" -DCMAKE_C_FLAGS_RELEASE="-O2 -DNDEBUG" \
  -DCMAKE_EXPORT_COMPILE_COMMANDS=ON -DCMAKE_INSTALL_PREFIX=/work/prefix
nice -n 15 cmake --build /work/obj --target shmem_ipc nginx_attachment_util graphqlparser --parallel 1
echo "8a75ef81570d31b67d894986696e67224b7538696993a267ea26583119db4cb9  /work/obj/external/graphqlparser/Ast.h" | sha256sum -c -
echo "952399efebb3eff5e46034bd0172007055feb4f79da7c86d1ef9f335f2f13f52  /work/obj/external/graphqlparser/AstVisitor.h" | sha256sum -c -
nice -n 15 ninja -C /work/obj -j1 components/security_apps/waap/waap_clib/CMakeFiles/waap_clib.dir/ParserGql.cc.o
# The upstream public version generator embeds the wall clock. Restore the original build
# timestamp for this exact artifact and verify the complete generated header before linking.
ninja -C /work/obj core/version/version_vars.h
header=/work/obj/core/version/version_vars.h
sed -i -E "s@^(static const char \\*timestamp = )\"[^\"]+\";@\\1\"2026-11-21T01:58:45+0000\";@" "$header"
echo "060cbe732d259c118b25294b06e514820d3aaf888b93baeb84f963a42ccde87a  $header" | sha256sum -c -
nice -n 15 cmake --build /work/obj --target cp-nano-http-transaction-handler --parallel 1
cmake --install /work/obj/nodes/http_transaction_handler --prefix /work/installed
elf=/work/installed/http_transaction_handler_service/bin/cp-nano-http-transaction-handler
test -x "$elf" && test ! -L "$elf"
readelf -W -d "$elf" > /work/installed-dynamic.txt
if grep -Eq "RPATH|RUNPATH" /work/installed-dynamic.txt; then exit 1; fi
case ${WAF_BUILD_VARIANT:-baseline} in
    baseline) handler_sha=a4d07f54fe3c3f5c553aad98550e9980ebe57b7f1213bf3f2b9e40f111e323c2;;
    inspection-loop) handler_sha=e73af6d7dba3066ceee789edcbef65d5ebb17a824b724c9ec50886a051331053;;
    *) echo "Unknown WAF build variant" >&2; exit 2;;
esac
echo "$handler_sha  $elf" | sha256sum -c -
export LD_LIBRARY_PATH=/work/obj/core:/work/obj/core/compression:/work/obj/core/shmem_ipc:/work/obj/attachments/nginx/nginx_attachment_util:/work/obj/external/graphqlparser
timeout 12 "$elf" --version > /work/version.txt 2>&1
grep -q "Version:" /work/version.txt
'
