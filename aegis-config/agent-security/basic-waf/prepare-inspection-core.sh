#!/usr/bin/env bash
set -euo pipefail
[[ $# == 2 || $# == 3 ]] || { echo 'Usage: prepare-inspection-core.sh BUILD_WORK NEW_OUTPUT [inspection-loop|scoped-verdict]' >&2; exit 2; }
work=$(realpath -- "$1")
output=$(realpath -m -- "$2")
[[ ! -e $output && ! -L $output ]] || { echo 'Choose a new output directory.' >&2; exit 2; }
[[ $(patchelf --version) == 'patchelf 0.18.0' ]] || { echo 'Use patchelf 0.18.0.' >&2; exit 2; }
handler=cp-nano-http-transaction-handler
library=libaegis_waf_core.so
case ${3:-inspection-loop} in
    inspection-loop)
        input_hash=e73af6d7dba3066ceee789edcbef65d5ebb17a824b724c9ec50886a051331053
        output_hash=82b44a033eb99713e054001cd9656f36181b538ead321c1cb8e92afdf6093a58 ;;
    scoped-verdict)
        input_hash=37075f553667020e107f6caf9f3edf1c31884a5acc8c54e151abe61391365a87
        output_hash=5f3ce9ecdd2ca373d6dff95c5dab350385d6af8e35b144ba6bdee3a233712ebf ;;
    *) echo 'Unknown WAF build variant' >&2; exit 2 ;;
esac
umask 077
temp=$(mktemp -d -- "$(dirname -- "$output")/.waf-core.XXXXXXXX")
trap 'rm -rf -- "$temp"' EXIT
cp -- "$work/installed/http_transaction_handler_service/bin/$handler" "$temp/$handler"
cp -- "$work/obj/core/libngen_core.so" "$temp/$library"
(
    cd -- "$temp"
    echo "$input_hash  $handler" | sha256sum -c -
    echo "8b71c69d368abcf0cc183a7fc0f7305641c0e1c1a13c298df8615b2c1df44aa0  $library" | sha256sum -c -
    patchelf --remove-rpath "$library"
    patchelf --set-soname "$library" "$library"
    patchelf --replace-needed libngen_core.so "$library" "$handler"
    echo "$output_hash  $handler" | sha256sum -c -
    echo "ed48ffa38660dba539fc742ba1871a7f6040ff0ecf405592898591a21167d21b  $library" | sha256sum -c -
)
mv -nT -- "$temp" "$output"
[[ ! -d $temp ]] || { echo 'Output already exists.' >&2; exit 1; }
trap - EXIT
