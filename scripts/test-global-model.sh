#!/bin/zsh
set -euo pipefail

task_root="${0:A:h:h}"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/vpn-gpt-global-model-tests.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="$(xcrun --sdk macosx --show-sdk-path)"

xcrun swiftc \
  -swift-version 5 \
  -sdk "$task_sdk" \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -framework AppKit -framework SwiftUI -framework Network \
  -framework UserNotifications -framework ServiceManagement \
  "$task_root/Sources/Models.swift" \
  "$task_root/Sources/MihomoClient.swift" \
  "$task_root/Sources/UnixSocketTransport.swift" \
  "$task_root/Sources/AppModel.swift" \
  "$task_root/Tests/GlobalScanModelTests.swift" \
  -o "$task_temp/global-model-tests"

"$task_temp/global-model-tests"
