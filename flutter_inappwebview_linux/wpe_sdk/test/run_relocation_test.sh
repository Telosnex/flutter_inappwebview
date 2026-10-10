#!/usr/bin/env bash
# Extracts an SDK archive to a new temporary directory, builds
# relocation_test.c against it, and runs it. The helper paths must be inside
# the temporary directory.
#
#   run_relocation_test.sh <wpe-sdk-*.tar.zst>
set -euo pipefail
archive="$(realpath "$1")"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
dir="$(mktemp -d /tmp/wpe-sdk-relocated.XXXXXX)"
trap 'rm -rf "$dir"' EXIT
zstd -dc "$archive" | tar -x -C "$dir"
sdk="$dir/wpe-sdk"
export PKG_CONFIG_PATH="$sdk/lib/pkgconfig"
include_dir="$(realpath "$(pkg-config --variable=includedir wpe-webkit-2.0)")"
[ "$include_dir" = "$sdk/include" ] || {
  echo "pkg-config does not point into the extracted SDK:" >&2
  echo "$include_dir" >&2
  exit 1
}
# shellcheck disable=SC2046
cc "$here/relocation_test.c" -o "$dir/relocation_test" \
  $(pkg-config --cflags --libs wpe-webkit-2.0 wpe-platform-headless-2.0) \
  -Wl,-rpath,"$sdk/lib"
output="$("$dir/relocation_test")"
echo "$output"
grep -q '^PASS$' <<< "$output"
helpers="$(grep '^Helper: ' <<< "$output" | cut -d' ' -f2-)"
[ -n "$helpers" ] || { echo "No helper process found." >&2; exit 1; }
# Every WebKit helper must come from the extracted SDK. bwrap and
# xdg-dbus-proxy are host programs of the sandbox.
for process in WPEWebProcess WPENetworkProcess; do
  grep -qx "$sdk/libexec/wpe-webkit-2.0/$process" <<< "$helpers" || {
    echo "$process did not start from the extracted SDK." >&2
    exit 1
  }
done
while IFS= read -r helper; do
  case "$helper" in
    "$sdk"/libexec/wpe-webkit-2.0/*|/usr/bin/bwrap|/usr/bin/xdg-dbus-proxy) ;;
    *) echo "Unexpected helper: $helper" >&2; exit 1 ;;
  esac
done <<< "$helpers"
echo "Relocation test passed: $sdk"
