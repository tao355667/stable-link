import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications

@main
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    private var subscription: AnyCancellable?
    private var statusUpdateScheduled = false
    private var displayedToolTip: String?
    private var displayedAccessibilityLabel: String?
    private var indicatorImages: [String: NSImage] = [:]
    private var displayedIndicator: String?
    private static let showName = Notification.Name("com.xct.vpn-gpt.show-panel")

    static func main() {
        if CommandLine.arguments.contains("--diagnose") {
            Task.detached {
                do {
                    let client = MihomoClient()
                    let snapshot = try await client.snapshot()
                    let report = try await client.check(snapshot: snapshot, group: "ChatGPT") { _ in }
                    let encoder = JSONEncoder()
                    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.dateEncodingStrategy = .iso8601
                    let data = try encoder.encode(report)
                    FileHandle.standardOutput.write(data)
                    FileHandle.standardOutput.write(Data("\n".utf8))
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
                    exit(1)
                }
            }
            dispatchMain()
        }
        let app = NSApplication.shared
        let identifier = Bundle.main.bundleIdentifier ?? "com.xct.vpn-gpt"
        if NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            DistributedNotificationCenter.default().postNotificationName(showName, object: nil,
                                                                          userInfo: nil, deliverImmediately: true)
            return
        }
        let delegate = ApplicationDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        UNUserNotificationCenter.current().delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.title = ""
        statusItem.button?.imagePosition = .imageOnly
        statusItem.button?.imageScaling = .scaleProportionallyDown
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = true
        popover.contentSize = NSSize(width: 400, height: 480)
        popover.contentViewController = NSHostingController(rootView: PanelView(model: model) { [weak self] in
            self?.showSettings()
        })
        subscription = model.objectWillChange.sink { [weak self] _ in
            self?.scheduleStatusItemUpdate()
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showPanel),
                                                            name: Self.showName, object: nil)
        updateStatusItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            if CommandLine.arguments.contains("--show-settings") { self?.showSettings() }
            else { self?.showPanel() }
        }
    }

    private func scheduleStatusItemUpdate() {
        // Several @Published properties often change together. Read their final
        // values once on the next run loop rather than enqueueing one draw each.
        guard !statusUpdateScheduled else { return }
        statusUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.statusUpdateScheduled = false
            self.updateStatusItem()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        let state = model.status.rawValue
        if displayedIndicator != state {
            if indicatorImages[state] == nil { indicatorImages[state] = MenuBarIndicator.image(for: model.status) }
            button.image = indicatorImages[state]
            displayedIndicator = state
        }
        let toolTip = "稳连 · " + model.statusReason
        let accessibilityLabel = "稳连，" + model.status.title
        if displayedToolTip != toolTip {
            button.toolTip = toolTip
            displayedToolTip = toolTip
        }
        if displayedAccessibilityLabel != accessibilityLabel {
            button.setAccessibilityLabel(accessibilityLabel)
            displayedAccessibilityLabel = accessibilityLabel
        }
    }

    @objc private func togglePanel() {
        if popover.isShown { popover.performClose(nil) }
        else { showPanel() }
    }

    @objc private func showPanel() {
        guard let button = statusItem.button else { return }
        model.synchronizeSelection()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverWillShow(_ notification: Notification) {
        model.setPanelVisible(true)
    }

    func popoverDidClose(_ notification: Notification) {
        model.setPanelVisible(false)
    }

    private func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let controller = NSHostingController(rootView: PreferencesView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "稳连设置"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 550, height: 680))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async { self.showPanel() }
        completionHandler()
    }
}
