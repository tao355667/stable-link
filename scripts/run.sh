#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
SHOULD_OPEN=1
if [ "${1:-}" = --no-open ]; then
    SHOULD_OPEN=0
elif [ "$#" -gt 0 ]; then
    echo "用法：$0 [--no-open]" >&2
    exit 1
fi
if [ "$#" -gt 1 ]; then
    echo "用法：$0 [--no-open]" >&2
    exit 1
fi

"$PROJECT_DIR/scripts/build.sh"
SOURCE_APP="$PROJECT_DIR/build/稳连.app"
LEGACY_SOURCE_APP="$PROJECT_DIR/build/AI网络助手.app"
INSTALL_DIR="$HOME/Applications"
INSTALL_APP="$INSTALL_DIR/稳连.app"
LEGACY_INSTALL_APP="$INSTALL_DIR/AI网络助手.app"
mkdir -p "$INSTALL_DIR"
STAGING_DIR="$(mktemp -d "$INSTALL_DIR/.vpn-gpt-install.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/稳连.app"
/usr/bin/ditto "$SOURCE_APP" "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

# Only this project's new/legacy builds and exact installed apps can be stopped.
# No command-line substring matching and no broad pkill operation.
"$PROJECT_DIR/build/.bundle-tool" stop "$SOURCE_APP" "$INSTALL_APP" "$LEGACY_SOURCE_APP" "$LEGACY_INSTALL_APP"
"$PROJECT_DIR/build/.bundle-tool" replace "$STAGED_APP" "$INSTALL_APP"
/usr/bin/codesign --verify --deep --strict "$INSTALL_APP"
# A failed build, verification or install leaves the legacy installation intact.
"$PROJECT_DIR/build/.bundle-tool" retire "$INSTALL_APP" "$LEGACY_INSTALL_APP"
echo "已安装：$INSTALL_APP"
if [ "$SHOULD_OPEN" -eq 1 ]; then
    /usr/bin/open "$INSTALL_APP"
fi
