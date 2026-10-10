#!/usr/bin/env bash
# Prints the SDK key: the SHA-256 of every input of the SDK build. Release
# tags use the first 16 hex digits. A change to an input gives a new key and
# a new release; a published release never changes.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
{
  sha256sum build.sh install_build_deps.sh key.sh sources.env patches/*.patch
  sha256sum ../../.github/workflows/wpe_sdk.yml
} | LC_ALL=C sort -k2 | sha256sum | cut -d' ' -f1
