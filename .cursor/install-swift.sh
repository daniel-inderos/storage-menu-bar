#!/usr/bin/env bash
# Idempotent Cloud Agent setup for StorageBar.
#
# StorageBar is a macOS-only app: it links AppKit, IOKit, ServiceManagement and
# UserNotifications, and CI builds/tests it on macOS (.github/workflows/ci.yml,
# runs-on: macos-15). Cloud Agent VMs are Linux, so `swift build` / `swift test`
# cannot compile the app or its tests here. This script installs a real Swift
# toolchain anyway so the sources can be navigated and edited with compiler
# support, SwiftPM works, and cross-platform (Foundation-only) logic can be
# compiled/run. The manifest resolves cleanly (the package has no dependencies).
set -euo pipefail

SWIFT_VERSION="6.3.3"
SWIFTLY_ENV="$HOME/.local/share/swiftly/env.sh"

if ! command -v swift >/dev/null 2>&1 && [ ! -f "$SWIFTLY_ENV" ]; then
  echo "==> Installing Swift toolchain system dependencies"
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    binutils gnupg2 libcurl4-openssl-dev libedit-dev libncurses-dev \
    libpython3-dev libsqlite3-dev libxml2-dev libz3-dev tzdata

  echo "==> Installing swiftly and Swift ${SWIFT_VERSION}"
  tmp_dir="$(mktemp -d)"
  curl -fsSL "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz" \
    -o "${tmp_dir}/swiftly.tar.gz"
  tar zxf "${tmp_dir}/swiftly.tar.gz" -C "${tmp_dir}"
  "${tmp_dir}/swiftly" init --assume-yes --skip-install
  # shellcheck disable=SC1090
  . "$SWIFTLY_ENV"
  swiftly install "$SWIFT_VERSION" --assume-yes
  swiftly use "$SWIFT_VERSION"
fi

# shellcheck disable=SC1090
[ -f "$SWIFTLY_ENV" ] && . "$SWIFTLY_ENV"

echo "==> Swift toolchain"
swift --version

echo "==> Resolving package manifest"
swift package resolve

echo "==> StorageBar dev environment ready."
echo "    NOTE: 'swift build' / 'swift test' require macOS frameworks and only"
echo "    succeed on a macOS host (CI: runs-on macos-15)."
