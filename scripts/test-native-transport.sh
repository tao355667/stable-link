#!/bin/zsh
set -euo pipefail

task_root="${0:A:h:h}"
# AF_UNIX paths are short on macOS; TMPDIR may already exceed the path limit.
task_temp="$(mktemp -d /tmp/vg-native.XXXXXX)"
trap 'rm -rf "$task_temp"' EXIT
task_sdk="$(xcrun --show-sdk-path)"

xcrun swiftc \
  -swift-version 5 \
  -sdk "$task_sdk" \
  -target arm64-apple-macos14.0 \
  -parse-as-library \
  -framework Network \
  "$task_root/Sources/Models.swift" \
  "$task_root/Sources/MihomoClient.swift" \
  "$task_root/Sources/UnixSocketTransport.swift" \
  "$task_root/Tests/NativeTransportTests.swift" \
  -o "$task_temp/native-transport-tests"

"$task_temp/native-transport-tests" "$task_temp"
