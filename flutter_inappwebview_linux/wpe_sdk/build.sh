#!/usr/bin/env bash
# Builds the relocatable WPE WebKit SDK that flutter_inappwebview_linux uses.
#
#   build.sh <output-directory>
#
# Output: wpe-sdk-<target>.tar.zst and wpe-sdk-<target>.json, where <target>
# is <os>-<os version>-<arch>, for example ubuntu-24.04-x64. The archive has
# one top-level directory, wpe-sdk/. The SDK runs from any directory:
#  - patches/0001 makes WebKit find its helper processes, injected bundle,
#    locale data, and sandbox paths relative to libWPEWebKit-2.0.so.
#  - Every ELF file has a RUNPATH relative to $ORIGIN.
#
# Environment:
#   WPE_SDK_JOBS   Parallel jobs. Default: nproc, at most one per 3 GiB of
#                  memory. A WebKit compile job can use 2-3 GiB.
#   WPE_SDK_WORK   Build directory. Default: $PWD/.wpe-sdk-work.
#   WPE_SDK_PREFIX Build-time install prefix. Default: /opt/wpe-sdk. Must be
#                  writable. The prefix is in the binaries; the relocation
#                  patch replaces it at run time.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${1:?usage: build.sh <output-directory>}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
# shellcheck source=flutter_inappwebview_linux/wpe_sdk/sources.env
source "$here/sources.env"

memory_jobs=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / (3 * 1024 * 1024) ))
default_jobs=$(nproc)
if [ "$memory_jobs" -lt "$default_jobs" ]; then default_jobs=$memory_jobs; fi
if [ "$default_jobs" -lt 1 ]; then default_jobs=1; fi
jobs="${WPE_SDK_JOBS:-$default_jobs}"
work="${WPE_SDK_WORK:-$PWD/.wpe-sdk-work}"
prefix="${WPE_SDK_PREFIX:-/opt/wpe-sdk}"

# shellcheck source=/dev/null
. /etc/os-release
case "$(uname -m)" in
  x86_64) arch=x64 ;;
  aarch64) arch=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac
target="$ID-$VERSION_ID-$arch"
archive="$out/wpe-sdk-$target.tar.zst"

download() {
  local url="$1" file="$2" sha256="$3"
  if [ ! -f "$file" ] || ! echo "$sha256  $file" | sha256sum -c --quiet - 2>/dev/null; then
    curl -fsSL --retry 3 -o "$file.tmp" "$url"
    mv "$file.tmp" "$file"
  fi
  echo "$sha256  $file" | sha256sum -c --quiet -
}

source_dir() {
  local name="$1" url="$2" sha256="$3"
  local file="$work/src/$name.tar.xz" dir="$work/src/$name"
  download "$url" "$file" "$sha256"
  rm -rf "$dir"
  mkdir -p "$dir"
  tar -xf "$file" -C "$dir" --strip-components=1
  echo "$dir"
}

mkdir -p "$work/src"
mkdir -p "$prefix"
find "$prefix" -mindepth 1 -delete
export PKG_CONFIG_PATH="$prefix/lib/pkgconfig"
export CMAKE_PREFIX_PATH="$prefix"
export LD_LIBRARY_PATH="$prefix/lib"

libwpe="$(source_dir "libwpe-$LIBWPE_VERSION" \
  "https://wpewebkit.org/releases/libwpe-$LIBWPE_VERSION.tar.xz" "$LIBWPE_SHA256")"
cmake -S "$libwpe" -B "$libwpe/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix" \
  -DCMAKE_INSTALL_LIBDIR=lib
ninja -C "$libwpe/build" -j"$jobs" install

fdo="$(source_dir "wpebackend-fdo-$WPEBACKEND_FDO_VERSION" \
  "https://wpewebkit.org/releases/wpebackend-fdo-$WPEBACKEND_FDO_VERSION.tar.xz" \
  "$WPEBACKEND_FDO_SHA256")"
meson setup "$fdo/build" "$fdo" --prefix="$prefix" --libdir=lib \
  --buildtype=release
ninja -C "$fdo/build" -j"$jobs" install

webkit="$(source_dir "wpewebkit-$WPEWEBKIT_VERSION" \
  "https://wpewebkit.org/releases/wpewebkit-$WPEWEBKIT_VERSION.tar.xz" \
  "$WPEWEBKIT_SHA256")"
for patch in "$here"/patches/*.patch; do
  patch -d "$webkit" -p1 --forward --quiet < "$patch"
done
cmake -S "$webkit" -B "$webkit/build" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$prefix" \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_INSTALL_LIBEXECDIR=libexec \
  -DPORT=WPE \
  -DENABLE_WPE_PLATFORM=ON \
  -DENABLE_WPE_PLATFORM_DRM=ON \
  -DENABLE_WPE_PLATFORM_HEADLESS=ON \
  -DENABLE_WPE_PLATFORM_WAYLAND=ON \
  -DENABLE_BUBBLEWRAP_SANDBOX=ON \
  -DENABLE_MINIBROWSER=OFF \
  -DENABLE_DOCUMENTATION=OFF \
  -DENABLE_INTROSPECTION=OFF \
  -DENABLE_WEBDRIVER=OFF \
  -DENABLE_SPEECH_SYNTHESIS=OFF \
  -DENABLE_GAMEPAD=OFF \
  -DENABLE_JOURNALD_LOG=OFF \
  -DENABLE_WPE_QT_API=OFF \
  -DUSE_JPEGXL=OFF \
  -DUSE_AVIF=OFF \
  -DUSE_WOFF2=OFF \
  -DUSE_LCMS=OFF \
  -DUSE_ATK=OFF \
  -DUSE_LIBBACKTRACE=OFF \
  -DUSE_SYSPROF_CAPTURE=OFF \
  -DUSE_GSTREAMER_WEBRTC=OFF
ninja -C "$webkit/build" -j"$jobs" install

# RUNPATHs relative to $ORIGIN, so the SDK loads its own libraries from any
# directory.
while IFS= read -r -d '' file; do
  if file -b "$file" | grep -q '^ELF'; then
    dir="$(dirname "$file")"
    rel="$(realpath --relative-to="$dir" "$prefix/lib")"
    if [ "$rel" = . ]; then rpath="\$ORIGIN"; else rpath="\$ORIGIN/$rel"; fi
    patchelf --set-rpath "$rpath" "$file"
  fi
done < <(find "$prefix" -type f \( -path "$prefix/lib/*" -o -path "$prefix/libexec/*" \) -print0)

# pkg-config files relative to their own location.
for pc in "$prefix"/lib/pkgconfig/*.pc; do
  sed -i "s|$prefix|\${pcfiledir}/../..|g" "$pc"
done

# Licenses.
mkdir -p "$prefix/share/licenses"
cp "$libwpe/COPYING" "$prefix/share/licenses/libwpe.txt"
cp "$fdo/COPYING" "$prefix/share/licenses/wpebackend-fdo.txt"
for license in "$webkit"/Source/WebCore/LICENSE-LGPL-2 "$webkit"/Source/WebCore/LICENSE-LGPL-2.1 "$webkit"/Source/WebCore/LICENSE-APPLE; do
  cp "$license" "$prefix/share/licenses/wpewebkit-$(basename "$license").txt"
done

# Check: the library loads, reports the pinned version, and finds its
# helpers relative to its own location.
probe="$work/probe"
mkdir -p "$probe"
cat > "$probe/probe.c" <<'C'
#include <stdio.h>
#include <wpe/webkit.h>
int main(void) {
  printf("%u.%u.%u\n", webkit_get_major_version(), webkit_get_minor_version(),
         webkit_get_micro_version());
  return 0;
}
C
# shellcheck disable=SC2046
cc "$probe/probe.c" $(pkg-config --cflags --libs wpe-webkit-2.0) -o "$probe/probe"
version="$("$probe/probe")"
[ "$version" = "$WPEWEBKIT_VERSION" ] || {
  echo "Version mismatch: built $version, pinned $WPEWEBKIT_VERSION" >&2
  exit 1
}
for helper in WPEWebProcess WPENetworkProcess; do
  test -x "$prefix/libexec/wpe-webkit-2.0/$helper"
done

# Archive with fixed metadata, so the same files give the same bytes.
stage="$work/stage"
rm -rf "$stage"
mkdir -p "$stage"
cp -a "$prefix" "$stage/wpe-sdk"
tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
  -C "$stage" -cf - wpe-sdk | zstd -19 -T0 -q -o "$archive" -f

sha256="$(sha256sum "$archive" | cut -d' ' -f1)"
cat > "$out/wpe-sdk-$target.json" <<JSON
{
  "target": "$target",
  "archive": "$(basename "$archive")",
  "sha256": "$sha256",
  "bytes": $(stat -c %s "$archive"),
  "buildPrefix": "$prefix",
  "libwpe": "$LIBWPE_VERSION",
  "wpebackendFdo": "$WPEBACKEND_FDO_VERSION",
  "wpewebkit": "$WPEWEBKIT_VERSION",
  "compiler": "$(cc --version | head -1)",
  "glibc": "$(ldd --version | head -1 | awk '{print $NF}')"
}
JSON
cat "$out/wpe-sdk-$target.json"
