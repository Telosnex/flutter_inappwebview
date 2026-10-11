#!/usr/bin/env bash
# Installs the packages that build.sh needs, as root. Supported bases:
# Ubuntu 24.04 and Debian 13 (trixie). The list is the Debian wpewebkit
# Build-Depends, without the features that build.sh turns off, plus the
# tools that build libwpe, WPEBackend-fdo, and the archive.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends \
  bubblewrap ca-certificates cmake curl file g++ gcc git gperf libdrm-dev \
  libegl-dev libenchant-2-dev libepoxy-dev libfontconfig-dev libfreetype-dev \
  libavif-dev libgbm-dev libgcrypt20-dev libgles-dev libglib2.0-dev \
  libgstreamer-plugins-bad1.0-dev libgstreamer-plugins-base1.0-dev \
  libgstreamer1.0-dev libharfbuzz-dev libhyphen-dev libicu-dev libinput-dev \
  libjpeg-dev libjxl-dev liblcms2-dev libopenjp2-7-dev libpng-dev libseccomp-dev libsoup-3.0-dev \
  libsqlite3-dev libsystemd-dev libtasn1-6-dev libudev-dev libwayland-dev \
  libwebp-dev libwoff-dev libxkbcommon-dev libxml2-utils libxslt1-dev meson ninja-build \
  patch patchelf perl pkg-config python3 ruby unifdef wayland-protocols \
  xdg-dbus-proxy xz-utils zstd
