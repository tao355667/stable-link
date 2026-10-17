// Local, offline layout fixtures. No lifecycle observers, HTTP requests, real
// node switching, or writes to the user's application-support directory.
import AppKit
import SwiftUI

@main
struct PanelPreview {
    @MainActor static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            fatalError("Usage: panel-preview OUTPUT_DIRECTORY LEGACY_PREVIEW_DIRECTORY")
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        let manager = FileManager.default
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let legacyDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try manager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let store = manager.temporaryDirectory.appendingPathComponent("vpngpt-preview-" + UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: store) }
        let model = AppModel(autoStart: false, storageDirectory: store)
        model.settings.group = "节点选择"
        model.settings.notificationsEnabled = false
        model.notificationPermission = "未决定"
        model.launchAtLogin = false
        let names = ["日本 · 示例 02", "日本 · 示例 01", "新加坡 · 示例", "香港 · 示例", "美国 · 示例"]
        let nodes = names.map {
            NodeInventoryEntry(name: $0, kind: "Vless", groups: ["节点选择", "ChatGPT"], selectableGroups: ["节点选择"])
        }
        let now = Date()
        func result(_ name: String, _ latency: Int) -> NodeResult {
            NodeResult(name: name, resolvedNode: name,
                       samples: [ProbeSample(latencyMS: latency, error: nil), ProbeSample(latencyMS: latency + 20, error: nil)],
                       testedAt: now)
        }
        var current = result(names[0], 158)
        current.samples.append(ProbeSample(latencyMS: 168, error: nil))
        model.snapshot = ControllerSnapshot(socketPath: "/preview-fixture.sock", version: "示例版本", proxyPort: 7897, mode: "rule",
            groups: [ProxyGroup(name: "节点选择", kind: "Selector", selected: names[0], members: names),
                     ProxyGroup(name: "ChatGPT", kind: "Selector", selected: names[2], members: names)],
            resolvedNodes: ["节点选择": names[0], "ChatGPT": names[2]], inventory: nodes)
        model.report = CheckReport(checkedAt: now, group: "节点选择", selection: names[0], current: current,
            path: PathObservation(exitIP: "203.0.113.5", httpStatus: 200, reachable: true, error: nil))
        model.status = .healthy
        model.globalScan = GlobalScanReport(startedAt: now, finishedAt: now, groupCount: 2, inventory: nodes,
            results: nodes.enumerated().map { index, node in
                GlobalNodeResult(node: node, rounds: [result(node.name, 130 + index * 65), result(node.name, 150 + index * 65)])
            }, completedRounds: 2, scope: .currentGroup, groupName: "节点选择")

        // Render native Menu and ScrollView through AppKit. ImageRenderer alone
        // leaves those platform-backed controls blank. This window stays hidden.
        func render(_ view: NSView, size: NSSize, filename: String, legacyName: String? = nil) throws {
            let bounds = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = view
            view.frame = bounds
            view.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                fatalError("Unable to create the offline preview bitmap")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else {
                fatalError("Unable to encode the offline preview")
            }
            let url = outputDirectory.appendingPathComponent(filename)
            try png.write(to: url)
            print(url.path)
            if let legacyName {
                try png.write(to: legacyDirectory.appendingPathComponent(legacyName))
            }
            window.close()
        }
        func renderPanel(_ filename: String, legacyName: String) throws {
            let view = NSHostingView(rootView: PanelView(model: model, openSettings: {}).environment(\.colorScheme, .light))
            try render(view, size: NSSize(width: 400, height: 480), filename: filename, legacyName: legacyName)
        }
        try renderPanel("overview.png", legacyName: "home-fixture.png")

        // Fixture for a controller-confirmed selection while verification is
        // running: the new name is visible, old measurements are absent, the
        // recovery control is present but unavailable until verification ends.
        model.snapshot?.groups[0].selected = names[1]
        model.snapshot?.resolvedNodes["节点选择"] = names[1]
        model.report = nil
        model.status = .checking
        model.isSwitching = true
        model.switchingTarget = names[1]
        model.progress = "切换已确认，正在复检…"
        model.switchReceipt = SwitchReceipt(group: "节点选择", previousSelection: names[0], newSelection: names[1], switchedAt: now)
        try renderPanel("switching.png", legacyName: "switching-fixture.png")

        // Preferences are the actual product view. No controls are activated;
        // in particular, this does not request notification permission or login.
        model.snapshot?.groups[0].selected = names[0]
        model.snapshot?.resolvedNodes["节点选择"] = names[0]
        model.report = CheckReport(checkedAt: now, group: "节点选择", selection: names[0], current: current,
            path: PathObservation(exitIP: "203.0.113.5", httpStatus: 200, reachable: true, error: nil))
        model.status = .healthy
        model.isSwitching = false
        model.switchingTarget = nil
        model.switchReceipt = nil
        let preferences = NSHostingView(rootView: PreferencesView(model: model).environment(\.colorScheme, .light))
        try render(preferences, size: NSSize(width: 550, height: 680), filename: "settings.png")

        // This explanatory legend renders the same 17-point AppKit images as
        // the menu bar, under both system appearances. It is not a desktop shot.
        try render(IndicatorLegendView(), size: NSSize(width: 820, height: 260), filename: "menu-bar-states.png")
    }
}

private final class IndicatorLegendView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.953, green: 0.953, blue: 0.965, alpha: 1).setFill()
        bounds.fill()
        label("菜单栏状态图标", rect: NSRect(x: 24, y: 17, width: 772, height: 27),
              font: .systemFont(ofSize: 18, weight: .semibold), color: .black)
        label("颜色与形状同时表达状态，无需展开面板。", rect: NSRect(x: 24, y: 46, width: 772, height: 20),
              font: .systemFont(ofSize: 12), color: .darkGray)
        let states: [HealthStatus] = [.healthy, .degraded, .unreachable, .checking, .disconnected, .error, .stale, .unknown]
        for (row, name) in [NSAppearance.Name.aqua, .darkAqua].enumerated() {
            let y = CGFloat(78 + row * 86)
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
                let background = row == 0 ? NSColor.white : NSColor(srgbRed: 0.15, green: 0.15, blue: 0.17, alpha: 1)
                background.setFill()
                NSBezierPath(roundedRect: NSRect(x: 20, y: y, width: 780, height: 76), xRadius: 11, yRadius: 11).fill()
                label(row == 0 ? "浅色菜单栏" : "深色菜单栏", rect: NSRect(x: 34, y: y + 29, width: 103, height: 20),
                      font: .systemFont(ofSize: 12, weight: .medium), color: .labelColor)
                for (index, state) in states.enumerated() {
                    let x = CGFloat(147 + index * 80)
                    MenuBarIndicator.image(for: state)?.draw(in: NSRect(x: x + 31.5, y: y + 15, width: 17, height: 17))
                    label(state.title, rect: NSRect(x: x, y: y + 43, width: 80, height: 19),
                          font: .systemFont(ofSize: 11), color: .secondaryLabelColor, centered: true)
                }
            }
        }
    }

    private func label(_ text: String, rect: NSRect, font: NSFont, color: NSColor, centered: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centered ? .center : .left
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            .draw(in: rect)
    }
}
