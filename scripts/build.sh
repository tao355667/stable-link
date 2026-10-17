#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="稳连.app"
APP_PATH="$BUILD_DIR/$APP_NAME"
LEGACY_APP_PATH="$BUILD_DIR/AI网络助手.app"
mkdir -p "$BUILD_DIR"
STAGING_DIR="$(mktemp -d "$BUILD_DIR/.build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
STAGED_APP="$STAGING_DIR/$APP_NAME"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"

if [ "$(uname -m)" != arm64 ]; then
    echo "此构建脚本面向这台 Apple Silicon Mac（arm64）。" >&2
    exit 1
fi

SWIFTC="$(xcrun --find swiftc)"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SOURCES=("$PROJECT_DIR"/Sources/*.swift)
if [ ! -f "${SOURCES[0]}" ]; then
    echo "没有找到 Sources/*.swift。" >&2
    exit 1
fi

echo "正在构建稳连…"
"$SWIFTC" -swift-version 5 -parse-as-library -O \
    -sdk "$SDK_PATH" -target arm64-apple-macos14.0 \
    -module-name VPNGPT \
    -framework AppKit -framework SwiftUI -framework Network \
    -framework UserNotifications -framework ServiceManagement \
    "${SOURCES[@]}" -o "$STAGED_APP/Contents/MacOS/VPNGPT"

cp "$PROJECT_DIR/Resources/Info.plist" "$STAGED_APP/Contents/Info.plist"
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
"$SWIFTC" -swift-version 5 -O -sdk "$SDK_PATH" -target arm64-apple-macos14.0 \
    "$PROJECT_DIR/Resources/icon.swift" \
    -framework AppKit -o "$STAGING_DIR/icon-generator"
"$STAGING_DIR/icon-generator" "$STAGING_DIR/AppIcon.iconset"
/usr/bin/iconutil -c icns "$STAGING_DIR/AppIcon.iconset" \
    -o "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp "$PROJECT_DIR/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE"
cp "$PROJECT_DIR/THIRD_PARTY_NOTICES.md" "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo"

# A failed compile or signature leaves the previous runnable app untouched.
/usr/bin/codesign --force --sign - --identifier com.xct.vpn-gpt \
    --timestamp=none "$STAGED_APP"
/usr/bin/codesign --verify --deep --strict "$STAGED_APP"

# macOS renamex_np(RENAME_SWAP) atomically exchanges two complete bundles.
# The old bundle remains in STAGING_DIR until the EXIT cleanup runs.
cat > "$STAGING_DIR/bundle-tool.swift" <<'SWIFT'
import AppKit
import Darwin

let manager = FileManager.default
func fail(_ message: String) -> Never {
    fputs("\(message)\n", stderr)
    exit(1)
}
func itemExists(_ path: String) -> Bool {
    var attributes = stat()
    return lstat(path, &attributes) == 0
}
func validateBundle(_ path: String) {
    let expectedTypes: [(String, FileAttributeType)] = [
        ("", .typeDirectory), ("Contents", .typeDirectory),
        ("Contents/MacOS", .typeDirectory),
        ("Contents/Info.plist", .typeRegular),
        ("Contents/MacOS/VPNGPT", .typeRegular)
    ]
    for (relative, expectedType) in expectedTypes {
        let item = relative.isEmpty ? path : URL(fileURLWithPath: path).appendingPathComponent(relative).path
        guard let attributes = try? manager.attributesOfItem(atPath: item),
              attributes[.type] as? FileAttributeType == expectedType else {
            fail("拒绝替换未识别的应用或符号链接：\(path)")
        }
    }
    guard manager.isExecutableFile(atPath: URL(fileURLWithPath: path).appendingPathComponent("Contents/MacOS/VPNGPT").path),
          let data = try? Data(contentsOf: URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")),
          let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
          info["CFBundleIdentifier"] as? String == "com.xct.vpn-gpt",
          info["CFBundleExecutable"] as? String == "VPNGPT" else {
        fail("拒绝替换未识别的应用或符号链接：\(path)")
    }
}
func processExists(_ pid: pid_t) -> Bool {
    if Darwin.kill(pid, 0) == 0 { return true }
    return errno != ESRCH
}
func stopBundles(_ bundlePaths: [String]) {
    // Validate every existing path before terminating any process. lstat also
    // finds dangling symlinks so they cannot bypass bundle validation.
    for path in bundlePaths where itemExists(path) { validateBundle(path) }
    let paths = Set(bundlePaths.map {
        URL(fileURLWithPath: $0).appendingPathComponent("Contents/MacOS/VPNGPT").standardizedFileURL.resolvingSymlinksInPath().path
    })
    let running = NSRunningApplication.runningApplications(withBundleIdentifier: "com.xct.vpn-gpt").filter {
        guard let executable = $0.executableURL else { return false }
        return paths.contains(executable.standardizedFileURL.resolvingSymlinksInPath().path)
    }
    for app in running {
        let pid = app.processIdentifier
        _ = app.terminate()
        let deadline = Date().addingTimeInterval(3)
        while processExists(pid) && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if processExists(pid) { _ = app.forceTerminate() }
        let forceDeadline = Date().addingTimeInterval(2)
        while processExists(pid) && Date() < forceDeadline { Thread.sleep(forTimeInterval: 0.1) }
        if processExists(pid) { fail("无法结束稳连（PID \(pid)），保留原安装。") }
    }
}
let arguments = Array(CommandLine.arguments.dropFirst())
guard let mode = arguments.first else { fail("bundle-tool: expected mode and bundle paths") }
if mode == "stop" {
    guard arguments.count >= 2 else { fail("bundle-tool: expected bundle paths") }
    stopBundles(Array(arguments.dropFirst()))
} else if mode == "replace" || mode == "retire" {
    guard arguments.count == 3 else { fail("bundle-tool: expected mode source destination") }
    let source = arguments[1]
    let destination = arguments[2]
    validateBundle(source)
    guard URL(fileURLWithPath: source).standardizedFileURL.resolvingSymlinksInPath() !=
            URL(fileURLWithPath: destination).standardizedFileURL.resolvingSymlinksInPath() else {
        fail("拒绝对同一个应用执行替换或归档。")
    }
    if mode == "replace" {
        let status: Int32
        if itemExists(destination) {
            validateBundle(destination)
            status = renamex_np(source, destination, UInt32(RENAME_SWAP))
        } else {
            status = rename(source, destination)
        }
        if status != 0 { fail("应用替换失败：\(String(cString: strerror(errno)))") }
    } else if itemExists(destination) {
        // Only retire the legacy bundle after the signed replacement exists.
        validateBundle(destination)
        stopBundles([destination])
        do {
            var trashedURL: NSURL?
            try manager.trashItem(at: URL(fileURLWithPath: destination), resultingItemURL: &trashedURL)
            print("旧版应用已移至废纸篓，可恢复：\(destination)")
        } catch {
            fail("新版已就绪，但旧版归档失败，保留旧版：\(error.localizedDescription)")
        }
    }
} else { fail("bundle-tool: unsupported mode") }
SWIFT
"$SWIFTC" -swift-version 5 -O -sdk "$SDK_PATH" -target arm64-apple-macos14.0 \
    "$STAGING_DIR/bundle-tool.swift" \
    -framework AppKit -o "$STAGING_DIR/bundle-tool"

"$STAGING_DIR/bundle-tool" stop "$STAGED_APP" "$APP_PATH" "$LEGACY_APP_PATH"
"$STAGING_DIR/bundle-tool" replace "$STAGED_APP" "$APP_PATH"
mv -f "$STAGING_DIR/bundle-tool" "$BUILD_DIR/.bundle-tool"
"$BUILD_DIR/.bundle-tool" retire "$APP_PATH" "$LEGACY_APP_PATH"
echo "构建完成：$APP_PATH"
