#!/bin/zsh
set -euo pipefail

task_root="${0:A:h:h}"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/vpn-gpt-resource-policy-tests.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT

xcrun swiftc \
  -swift-version 5 \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -framework AppKit -framework SwiftUI -framework Network \
  -framework UserNotifications -framework ServiceManagement \
  "$task_root/Sources/Models.swift" \
  "$task_root/Sources/MihomoClient.swift" \
  "$task_root/Sources/UnixSocketTransport.swift" \
  "$task_root/Sources/AppModel.swift" \
  "$task_root/Tests/ResourcePolicyTests.swift" \
  -o "$task_temp/resource-policy-tests"

"$task_temp/resource-policy-tests"
