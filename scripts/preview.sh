#!/bin/zsh
set -euo pipefail

task_root="${0:A:h:h}"
task_temp="$(mktemp -d "${TMPDIR:-/tmp}/vpn-gpt-preview.XXXXXX")"
trap 'rm -rf "$task_temp"' EXIT

task_output="${1:-$task_root/build/previews}"
mkdir -p "$task_output"
task_sdk="$(xcrun --show-sdk-path)"
xcrun swiftc \
  -swift-version 5 -parse-as-library -sdk "$task_sdk" -target arm64-apple-macos14.0 \
  -framework AppKit -framework SwiftUI -framework Network \
  -framework UserNotifications -framework ServiceManagement \
  "$task_root/Sources/Models.swift" \
  "$task_root/Sources/Theme.swift" \
  "$task_root/Sources/MihomoClient.swift" \
  "$task_root/Sources/UnixSocketTransport.swift" \
  "$task_root/Sources/AppModel.swift" \
  "$task_root/Sources/Views.swift" \
  "$task_root/Sources/PreferencesView.swift" \
  "$task_root/Sources/MenuBarIndicator.swift" \
  "$task_root/scripts/preview.swift" \
  -o "$task_temp/panel-preview"

"$task_temp/panel-preview" "$task_output" "$task_root/build/previews"
