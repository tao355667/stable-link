import AppKit
import Combine
import Foundation
import Network
import ServiceManagement
import UserNotifications

private struct ExitObservation: Codable {
    var date: Date
    var ip: String
    var path: String
}

private struct SavedState: Codable {
    var report: CheckReport?
    var events: [EventEntry]
    var observations: [ExitObservation]
    var notifiedLevel: Int
    var switchReceipt: SwitchReceipt?
    var globalScan: GlobalScanReport?
    var globalScanSocket: String?
    var globalScanInvalidated: Bool?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var settings = AppSettings()
    @Published var snapshot: ControllerSnapshot?
    @Published var report: CheckReport?
    @Published var status: HealthStatus = .unknown
    @Published var isChecking = false
    @Published var isScanning = false
    @Published var isSwitching = false
    @Published var switchingTarget: String?
    @Published var progress = "准备连接 Clash Verge"
    @Published var errorText: String?
    @Published var notice: String?
    @Published var lastAttemptAt: Date?
    @Published var events: [EventEntry] = []
    @Published var switchReceipt: SwitchReceipt?
    @Published var launchAtLogin = false
    @Published var notificationPermission = "未决定"
    @Published var globalScan: GlobalScanReport? {
        didSet { rebuildScanCaches() }
    }
    @Published private var globalScanInvalidated = false

    private let client: MihomoClient
    private let storageDirectory: URL
    private var operation: Task<Void, Never>?
    private var operationID = UUID()
    private var followup: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var timer: Timer?
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    private var localOffline = false
    private var sleeping = false
    private var pathSignature: String?
    private var observations: [ExitObservation] = []
    private var notifiedLevel = 0
    private var problemKey = ""
    private var problemCount = 0
    private var committedSettings = AppSettings()
    private var networkRevision = 0
    private var pendingLifecycleRefresh = false
    private var initialGlobalScanPending = false
    private var globalScanSocket: String?
    private var selectionTimer: Timer?
    private var selectionTask: Task<Void, Never>?
    private var selectionEpoch = 0
    private var pendingSelectionCheck = false
    private var previousCandidateRows: [GlobalNodeResult] = []
    private var previousCandidateKey = ""
    private var stableResultCache: [GlobalNodeResult] = []
    private var stableResultByName: [String: GlobalNodeResult] = [:]
    private var resultByName: [String: GlobalNodeResult] = [:]
    private var isPanelVisible = false
    private var lastPanelRefreshAt = Date.distantPast
    private var lastProgressSaveAt = Date.distantPast

    static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory,
                                                           in: .userDomainMask)[0]
        .appendingPathComponent("VPNGPT", isDirectory: true)

    var candidates: [NodeResult] {
        guard globalScan != nil else { return report?.candidates ?? [] }
        return stableResultCache.filter { currentGroup?.members.contains($0.node.name) == true }.map(\.summary)
    }
    var globalInventory: [NodeInventoryEntry] {
        if let snapshot { return scopeInventory(in: snapshot) }
        guard let globalScan, scanMatchesScope(globalScan) else { return [] }
        return globalScan.inventory
    }
    var globalResults: [GlobalNodeResult] { globalScan?.results ?? [] }
    var stableNodes: [GlobalNodeResult] {
        guard globalScanFresh else { return [] }
        return stableResultCache.filter { Date().timeIntervalSince($0.summary.testedAt) < 900 }
    }
    /// The home screen offers only nodes that this group can actually select.
    /// Keep the rows visible while an operation is busy; the buttons disable.
    var switchableStableNodes: [GlobalNodeResult] {
        guard let group = currentGroup, group.canSelect else { return [] }
        let selected = Set([group.selected, snapshot?.resolvedNodes[group.name] ?? group.selected])
        let rows = candidateListRechecking ? previousCandidateRows : stableNodes
        return rows.filter {
            group.members.contains($0.node.name) && !selected.contains($0.node.name)
        }
    }
    var candidateListRechecking: Bool {
        isScanning && !globalScanFresh && previousCandidateKey == candidateKey && !previousCandidateRows.isEmpty
    }
    private var candidateKey: String {
        (snapshot?.socketPath ?? "") + "|" + settings.group + "|" + settings.scanScope.rawValue
    }
    var globalScanFresh: Bool {
        guard !localOffline, !sleeping, !globalScanInvalidated, let finished = globalScan?.finishedAt,
              let globalScan, scanMatchesScope(globalScan), globalScan.completedRounds == 2 else { return false }
        return Date().timeIntervalSince(finished) < 900
    }
    func canUseGlobalNode(_ name: String) -> Bool {
        guard !isBusy, !localOffline, !sleeping, globalScanFresh, currentGroup?.canSelect == true,
              currentGroup?.members.contains(name) == true,
              currentGroup?.selected != name,
              let result = stableResultByName[name] else { return false }
        return Date().timeIntervalSince(result.summary.testedAt) < 900
    }
    var currentGroup: ProxyGroup? { snapshot?.group(named: settings.group) }
    func scanResult(named name: String) -> GlobalNodeResult? { resultByName[name] }
    var isBusy: Bool { isChecking || isScanning || isSwitching }
    var canUndo: Bool {
        hasUndoSelection && !isBusy
    }
    var hasUndoSelection: Bool {
        guard let receipt = switchReceipt, let group = currentGroup else { return false }
        return receipt.group == settings.group && group.selected == receipt.newSelection &&
            group.members.contains(receipt.previousSelection)
    }

    var statusReason: String {
        if let errorText { return errorText }
        if sleeping { return "Mac 正在休眠，唤醒后会重新检测。" }
        if localOffline { return "本地网络已断开，连接恢复后会自动复查。" }
        if status == .stale { return "最近的结果已过期，重新检测后再判断当前连接。" }
        if status == .checking { return progress }
        guard let report else { return "连接 Clash Verge 并选择策略组，即可开始检测。" }
        switch status {
        case .healthy:
            return "节点探测和当前代理访问均通过。登录、对话与 Codex 任务尚未验证。"
        case .degraded:
            if !report.path.reachable {
                return report.current.passes ? "节点探测通过，但当前代理访问未通过。请检查分流规则或尝试其他节点。" :
                    "节点探测和当前代理访问均出现异常。可以扫描节点，或打开 Clash Verge 检查连接。"
            }
            return "节点探测有失败，当前访问路径仍可达；稍后会自动复查。"
        case .unreachable:
            return "复测后仍未能访问目标。可以扫描节点，或打开 Clash Verge 检查连接。"
        default: return "查看检测时间和各项结果，了解本次检测覆盖的范围。"
        }
    }

    var ipObservationSummary: String {
        guard let report, let socket = snapshot?.socketPath else { return "尚无出口观测，样本不足。" }
        let key = socket + ":" + String(snapshot?.proxyPort ?? 0)
        let recent = observations.filter { $0.path == key && $0.date > Date().addingTimeInterval(-86400) }
        guard report.path.exitIP != nil else { return "本次未取得出口 IP，稳定性未知。" }
        let unique = Set(recent.map(\.ip)).count
        if recent.count < 2 { return "已采样 1 次，样本不足以判断稳定性。" }
        return "近 24 小时采样 \(recent.count) 次，观察到 \(unique) 个出口；仅反映采样时刻。"
    }

    init(autoStart: Bool = true, client: MihomoClient = MihomoClient(),
         storageDirectory: URL? = nil) {
        self.client = client
        self.storageDirectory = storageDirectory ?? Self.supportDirectory
        load()
        committedSettings = settings
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if report != nil { status = .stale }
        guard autoStart else { return }
        initialGlobalScanPending = !globalScanFresh
        installLifecycleObservers()
        Task { await updateNotificationPermission() }
        refresh()
    }

    func refresh() {
        guard !isBusy, !sleeping else { return }
        followup?.cancel()
        if localOffline {
            status = .error
            errorText = "本地网络已断开。连接恢复后会自动检测。"
            return
        }
        let id = beginOperation()
        isChecking = true
        status = .checking
        progress = "正在连接 Clash Verge…"
        operation = Task { [self] in
            do {
                let epoch = selectionEpoch
                let fetched = try await client.snapshot(socketOverride: settings.socketOverride)
                let fresh = reconcileSnapshot(fetched, startedAt: epoch)
                try Task.checkCancellation()
                guard operationID == id else { return }
                acceptSnapshot(fresh)
                let group = validGroup(in: fresh)
                guard !group.isEmpty else { throw LocalFailure.message("没有找到可检测的策略组。请先在 Clash Verge 中载入配置。") }
                if group != settings.group {
                    settings.group = group
                    committedSettings = settings
                    persistSettings()
                    notice = "已为你选择策略组「\(group)」，可在设置中更改。"
                }
                let checked = try await client.check(snapshot: fresh, group: group) { [weak self] text in
                    await self?.setProgress(text, id: id)
                }
                try Task.checkCancellation()
                guard operationID == id else { return }
                apply(checked, snapshot: fresh)
                finishOperation(id)
            } catch {
                handle(error, id: id)
            }
        }
    }

    func scanCandidates() {
        guard !isBusy else { return }
        guard !localOffline, !sleeping else {
            notice = "网络恢复后可以扫描节点。"
            return
        }
        initialGlobalScanPending = false
        if globalScanFresh {
            previousCandidateRows = switchableStableNodes
            previousCandidateKey = candidateKey
        }
        let id = beginOperation()
        isScanning = true
        globalScanInvalidated = true
        let scope = settings.scanScope
        let group = settings.group
        progress = scope == .currentGroup ? "正在读取当前代理组…" : "正在读取所有代理组…"
        operation = Task { [self] in
            do {
                let epoch = selectionEpoch
                let fetched = try await client.snapshot(socketOverride: settings.socketOverride)
                let fresh = reconcileSnapshot(fetched, startedAt: epoch)
                try Task.checkCancellation()
                guard operationID == id else { return }
                acceptSnapshot(fresh)
                globalScanSocket = fresh.socketPath
                globalScan = GlobalScanReport(startedAt: Date(), groupCount: scope == .currentGroup ? 1 : fresh.groups.count,
                    inventory: scopeInventory(in: fresh), results: [], completedRounds: 0,
                    scope: scope, groupName: scope == .currentGroup ? group : nil)
                let progressHandler: @Sendable (String) async -> Void = { [weak self] text in
                    await self?.setProgress(text, id: id)
                }
                let partialHandler: @Sendable (GlobalScanReport) async -> Void = { [weak self] partial in
                    await self?.setGlobalPartial(partial, id: id)
                }
                let results: GlobalScanReport
                if scope == .currentGroup {
                    results = try await client.scanCurrentGroup(snapshot: fresh, group: group,
                        progress: progressHandler, partial: partialHandler)
                } else {
                    results = try await client.scanAll(snapshot: fresh, progress: progressHandler, partial: partialHandler)
                }
                try Task.checkCancellation()
                guard operationID == id else { return }
                globalScan = results
                globalScanInvalidated = false
                let finalEpoch = selectionEpoch
                if let finalSnapshot = try? await client.snapshot(socketOverride: fresh.socketPath) {
                    try Task.checkCancellation()
                    guard operationID == id else { return }
                    let latest = reconcileSnapshot(finalSnapshot, startedAt: finalEpoch)
                    acceptSnapshot(latest)
                    validateGlobalScan(against: latest)
                    if let report, latest.group(named: report.group)?.selected != report.selection ||
                        latest.resolvedNodes[report.group] != report.current.resolvedNode {
                        self.report = nil
                        status = .stale
                    }
                } else {
                    globalScanInvalidated = true
                }
                let invalidCount = results.inventory.count - results.results.count
                let scopeText = scope == .currentGroup ? "当前代理组「\(group)」" : "\(results.groupCount) 个代理组"
                notice = "已扫描\(scopeText)的 \(results.inventory.count) 个去重节点，\(stableNodes.count) 个本轮稳定。" +
                    (invalidCount > 0 ? "\(invalidCount) 个节点在扫描期间发生变化，未计入稳定结果。" : "") +
                    (globalScanFresh ? "" : "配置或连接已变化，请重新扫描确认。")
                appendEvent("节点扫描完成", "\(scope.title) · \(results.inventory.count) 个节点 · \(stableNodes.count) 个本轮稳定")
                persistState()
                finishOperation(id)
            } catch { handle(error, id: id) }
        }
    }

    func setScanScope(_ scope: ScanScope) {
        guard !isSwitching, scope != settings.scanScope else { return }
        if isBusy { cancelOperation() }
        settings.scanScope = scope
        committedSettings = settings
        persistSettings()
        globalScan = nil
        globalScanInvalidated = true
        initialGlobalScanPending = false
        scanCandidates()
    }

    func setMonitoredGroup(_ name: String) {
        guard !isSwitching, name != settings.group,
              snapshot?.group(named: name) != nil else { return }
        if isBusy { cancelOperation() }
        settings.group = name
        committedSettings = settings
        persistSettings()
        selectionEpoch += 1
        report = nil
        switchReceipt = nil
        status = .stale
        errorText = nil
        pendingSelectionCheck = false
        problemCount = 0
        problemKey = ""
        notifiedLevel = 0
        if settings.scanScope == .currentGroup {
            globalScan = nil
            globalScanInvalidated = true
        }
        initialGlobalScanPending = !globalScanFresh
        persistState()
        refresh()
    }

    /// Polling the controller is independent from slow network probes. It keeps
    /// the displayed logical selection and resolved leaf current during scans.
    func synchronizeSelection() {
        guard selectionTask == nil, !sleeping, !isSwitching else { return }
        if snapshot == nil {
            if !isBusy { refresh() }
            return
        }
        selectionTask = Task { [weak self] in
            await self?.pollSelectionNow()
            self?.selectionTask = nil
        }
    }

    /// Fast while the panel is in use, quiet while it is closed. Opening the
    /// panel still requests an immediate selection check.
    func setPanelVisible(_ visible: Bool) {
        guard visible != isPanelVisible else { return }
        isPanelVisible = visible
        configureSelectionTimer()
        guard visible else { return }
        objectWillChange.send()
        synchronizeSelection()
        if !globalScanFresh {
            initialGlobalScanPending = true
            if !isBusy, snapshot != nil {
                initialGlobalScanPending = false
                scanCandidates()
            }
        }
    }

    func pollSelectionNow() async {
        guard !sleeping, !isSwitching, let base = snapshot else { return }
        let epoch = selectionEpoch
        let group = settings.group
        do {
            let latest = try await client.selectionSnapshot(snapshot: base)
            try Task.checkCancellation()
            guard epoch == selectionEpoch, !isSwitching, group == settings.group,
                  snapshot?.socketPath == base.socketPath else { return }
            let previous = base.group(named: group)
            let current = latest.group(named: group)
            let oldLeaf = base.resolvedNodes[group]
            let newLeaf = latest.resolvedNodes[group]
            let changed = previous?.selected != current?.selected || oldLeaf != newLeaf
            acceptSnapshot(latest)
            guard changed else { return }
            let wasChecking = isChecking
            // A current-scope scan may be probing a nested group's old leaf.
            let scopeChanged = settings.scanScope == .currentGroup &&
                Set(scopeInventory(in: base).map(\.name)) != Set(scopeInventory(in: latest).map(\.name))
            if wasChecking || (isScanning && scopeChanged) { cancelOperation() }
            report = nil
            status = .stale
            errorText = nil
            if switchReceipt?.newSelection != current?.selected { switchReceipt = nil }
            problemCount = 0
            problemKey = ""
            notifiedLevel = 0
            notice = "已同步 Clash 的节点选择，正在确认新节点。"
            appendEvent("Clash 节点已更新", "\(group)：\(oldLeaf ?? previous?.selected ?? "未知") → \(newLeaf ?? current?.selected ?? "未发现")")
            pendingSelectionCheck = true
            persistState()
            if !isBusy { scheduleSelectionCheck() }
        } catch is CancellationError {
            return
        } catch {
            // Do not replace an active probe's error handling with a stale poll.
            guard epoch == selectionEpoch, !isBusy else { return }
            globalScanInvalidated = true
            report = nil
            status = .disconnected
            errorText = error.localizedDescription
        }
    }

    func switchTo(_ target: String) {
        performSwitch(target, undo: false)
    }

    func undoSwitch() {
        guard canUndo, let receipt = switchReceipt else { return }
        performSwitch(receipt.previousSelection, undo: true)
    }

    private func performSwitch(_ target: String, undo: Bool) {
        guard !isBusy, let snapshot, let group = currentGroup, group.canSelect else { return }
        guard target != group.selected, group.members.contains(target) else {
            notice = "该节点已不在当前策略组中，请重新检测。"
            return
        }
        if !undo {
            if globalScan != nil && !canUseGlobalNode(target) {
                notice = "请重新扫描节点，并选择本轮稳定且属于此策略组的节点。"
                return
            }
            guard let candidate = candidates.first(where: { $0.name == target }),
                  candidate.successes == candidate.samples.count,
                  Date().timeIntervalSince(candidate.testedAt) < (globalScan == nil ? 300 : 900) else {
                notice = "请先扫描节点，并选择本轮稳定的节点。"
                return
            }
        }
        let previous = group.selected
        let selectedGroup = settings.group
        let expectedResolved = undo ? nil : candidates.first(where: { $0.name == target })?.resolvedNode
        let revision = networkRevision
        let id = beginOperation()
        isSwitching = true
        switchingTarget = target
        status = .checking
        progress = undo ? "正在恢复原节点…" : "正在切换所选策略组…"
        operation = Task { [self] in
            var didCommit = false
            do {
                if !undo, let expected = stableResultByName[target] {
                    let latest = try await client.snapshot(socketOverride: snapshot.socketPath)
                    guard latest.inventory.first(where: { $0.name == target }) == expected.node else {
                        globalScanInvalidated = true
                        throw LocalFailure.message("该节点的配置或所属策略组已变化，请重新扫描。")
                    }
                    guard networkRevision == revision, !localOffline, !sleeping, globalScanFresh else {
                        throw LocalFailure.message("预检期间网络状态已变化，未执行切换。请重新扫描确认。")
                    }
                }
                try await client.select(snapshot: snapshot, group: selectedGroup,
                                        target: target, expectedSelection: previous,
                                        expectedResolvedNode: expectedResolved)
                didCommit = true
                selectionEpoch += 1
                report = nil
                // The controller has confirmed the write. Keep recovery available even
                // if the next full snapshot or probe fails.
                if let index = self.snapshot?.groups.firstIndex(where: { $0.name == selectedGroup }) {
                    self.snapshot?.groups[index].selected = target
                    self.snapshot?.resolvedNodes[selectedGroup] = snapshot.resolvedNodes[target] ?? target
                }
                switchReceipt = undo ? nil : SwitchReceipt(group: selectedGroup,
                    previousSelection: previous, newSelection: target, switchedAt: Date())
                appendEvent(undo ? "恢复原节点" : "手动切换节点", "\(selectedGroup)：\(previous) → \(target)")
                progress = "切换已确认，正在复检…"
                let fresh = try await client.snapshot(socketOverride: snapshot.socketPath)
                acceptSnapshot(fresh)
                let checked = try await client.check(snapshot: fresh, group: selectedGroup) { [weak self] text in
                    await self?.setProgress(text, id: id)
                }
                guard operationID == id else { return }
                if networkRevision == revision && !sleeping && !localOffline {
                    apply(checked, snapshot: fresh)
                    notice = undo ? "已恢复原节点并完成复检。" :
                        (status == .healthy ? "已切换并通过网络复检。需要时可恢复原节点。" : "已切换，复检仍有异常，可恢复原节点。")
                } else {
                    status = .stale
                    pendingLifecycleRefresh = true
                    notice = "节点选择已更新；检测期间网络发生变化，连接恢复后会重新复查。"
                }
                finishOperation(id)
            } catch {
                if didCommit {
                    notice = undo ? "原节点已恢复，复检未完成。请重新检测。" : "节点已切换，复检未完成。请重新检测，或使用恢复原节点。"
                } else if case ClientError.writeUncertain = error {
                    // A cancelled/failed write can still reach the controller. Reconcile before
                    // offering recovery; never blindly issue another write.
                    if let actual = try? await client.snapshot(socketOverride: snapshot.socketPath) {
                        acceptSnapshot(actual)
                        if actual.group(named: selectedGroup)?.selected == target {
                            switchReceipt = undo ? nil : SwitchReceipt(group: selectedGroup,
                                previousSelection: previous, newSelection: target, switchedAt: Date())
                            notice = "控制器已选中目标节点，复检未完成。可重新检测或恢复原节点。"
                        }
                    }
                }
                handle(error, id: id)
            }
        }
    }

    func cancelOperation() {
        // Writes are intentionally not cancellable halfway through a switch transaction.
        guard !isSwitching else { return }
        let cancelledScan = isScanning
        followup?.cancel()
        debounce?.cancel()
        operation?.cancel()
        operationID = UUID()
        operation = nil
        isChecking = false
        isScanning = false
        if cancelledScan {
            globalScanInvalidated = true
            status = report.map(HealthStatus.evaluate) ?? .unknown
        } else { status = report == nil ? .unknown : .stale }
        lastAttemptAt = Date()
        progress = "检测已取消"
        notice = cancelledScan ? "节点扫描已停止，未完成的结果不会计入稳定节点。" : "检测已取消，保留上一次结果。"
        if cancelledScan { persistState() }
    }

    func saveSettings() {
        guard !isBusy else {
            settings = committedSettings
            notice = "当前操作结束后再保存设置。"
            return
        }
        settings.intervalMinutes = min(30, max(1, settings.intervalMinutes))
        settings.socketOverride = settings.socketOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        if !settings.socketOverride.isEmpty && !settings.socketOverride.hasPrefix("/") {
            settings = committedSettings
            errorText = "接口路径需要使用以 / 开头的本机绝对路径。"
            return
        }
        let changedSocket = settings.socketOverride != committedSettings.socketOverride
        let changedScope = settings.scanScope != committedSettings.scanScope
        let changedGroup = settings.group != committedSettings.group
        let changedRoute = settings.group != committedSettings.group || changedSocket
        committedSettings = settings
        persistSettings()
        if changedRoute {
            report = nil
            switchReceipt = nil
            problemCount = 0
            problemKey = ""
            notifiedLevel = 0
        }
        if changedSocket || changedScope || (changedGroup && settings.scanScope == .currentGroup) {
            globalScan = nil
            globalScanInvalidated = true
            initialGlobalScanPending = true
        }
        if changedSocket { globalScanSocket = nil }
        notice = "设置已保存。"
        refresh()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            notice = SMAppService.mainApp.status == .requiresApproval ? "请在系统设置的登录项中允许稳连。" : "开机启动设置已更新。"
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            errorText = "无法修改开机启动：\(error.localizedDescription)"
        }
    }

    func requestNotifications() {
        if notificationPermission == "已拒绝" {
            notice = "请打开系统设置 → 通知 → 稳连，开启“允许通知”。"
            return
        }
        Task {
            do {
                let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                if allowed {
                    settings.notificationsEnabled = true
                    committedSettings = settings
                    persistSettings()
                } else {
                    notice = "通知未获允许。可以在系统设置 → 通知中开启稳连。"
                }
            } catch { notice = "暂时无法申请通知权限：\(error.localizedDescription)" }
            await updateNotificationPermission()
        }
    }

    func openClash() {
        let url = URL(fileURLWithPath: "/Applications/Clash Verge.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, _ in }
    }

    func copyDiagnostics() {
        var lines = ["稳连 0.1.0", "时间：\(Date().formatted())", "状态：\(status.title)",
                     "原因：\(statusReason)", "策略组：\(settings.group)"]
        if let snapshot {
            lines.append("mihomo：\(snapshot.version)，模式：\(snapshot.mode)")
            lines.append("控制接口：本机 Unix socket")
        }
        if let report {
            lines.append("检测时间：\(report.checkedAt.formatted())")
            lines.append("当前选择：\(report.selection)")
            lines.append("节点探测：\(report.current.successes)/\(report.current.samples.count)")
            lines.append("中位延迟：\(report.current.medianMS.map { String($0) + "ms" } ?? "未知")")
            lines.append("当前路径 HTTP：\(report.path.httpStatus.map(String.init) ?? "未知")；出口IP已隐藏")
            lines.append("范围：未验证账号、对话生成、Codex任务和节点出口归属")
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        notice = "诊断已复制，出口 IP 和本机接口路径已隐藏。"
    }

    private func validGroup(in snapshot: ControllerSnapshot) -> String {
        if snapshot.group(named: settings.group) != nil { return settings.group }
        for preferred in ["节点选择", "ChatGPT", "OpenAI", "AI"] {
            if snapshot.group(named: preferred) != nil { return preferred }
        }
        return snapshot.groups.first(where: \.canSelect)?.name ?? snapshot.groups.first?.name ?? ""
    }

    private func beginOperation() -> UUID {
        followup?.cancel()
        operationID = UUID()
        errorText = nil
        notice = nil
        return operationID
    }

    private func setProgress(_ text: String, id: UUID) {
        guard operationID == id else { return }
        progress = text
    }

    private func setGlobalPartial(_ partial: GlobalScanReport, id: UUID) {
        guard operationID == id, isScanning else { return }
        globalScan = partial
        if Date().timeIntervalSince(lastProgressSaveAt) >= 15 {
            lastProgressSaveAt = Date()
            persistState()
        }
    }

    private func rebuildScanCaches() {
        stableResultCache = globalScan?.stableResults ?? []
        stableResultByName = Dictionary(uniqueKeysWithValues: stableResultCache.map { ($0.node.name, $0) })
        resultByName = Dictionary(uniqueKeysWithValues: (globalScan?.results ?? []).map { ($0.node.name, $0) })
    }

    private func scanMatchesScope(_ scan: GlobalScanReport) -> Bool {
        guard (scan.scope ?? .allGroups) == settings.scanScope else { return false }
        return settings.scanScope == .allGroups || scan.groupName == settings.group
    }

    private func scopeInventory(in snapshot: ControllerSnapshot) -> [NodeInventoryEntry] {
        guard settings.scanScope == .currentGroup else { return snapshot.inventory }
        guard let group = snapshot.group(named: settings.group) else { return [] }
        let all = Dictionary(uniqueKeysWithValues: snapshot.inventory.map { ($0.name, $0) })
        let names = Set((group.members + [group.selected]).compactMap { name -> String? in
            if all[name] != nil { return name }
            guard let resolved = snapshot.resolvedNodes[name], all[resolved] != nil else { return nil }
            return resolved
        })
        return snapshot.inventory.filter { names.contains($0.name) }
    }

    private func reconcileSnapshot(_ fetched: ControllerSnapshot, startedAt epoch: Int) -> ControllerSnapshot {
        guard selectionEpoch != epoch, let snapshot, snapshot.socketPath == fetched.socketPath else { return fetched }
        var current = fetched
        current.groups = snapshot.groups
        current.resolvedNodes = snapshot.resolvedNodes
        current.inventory = snapshot.inventory
        return current
    }

    private func acceptSnapshot(_ fresh: ControllerSnapshot) {
        guard snapshot != fresh else { return }
        selectionEpoch += 1
        snapshot = fresh
        validateGlobalScan(against: fresh)
    }

    private func scheduleSelectionCheck() {
        guard pendingSelectionCheck, !isBusy, !sleeping, !localOffline else { return }
        pendingSelectionCheck = false
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func validateGlobalScan(against snapshot: ControllerSnapshot) {
        guard let globalScan else { return }
        guard globalScanSocket == snapshot.socketPath, scanMatchesScope(globalScan) else {
            globalScanInvalidated = true
            return
        }
        let entries = Dictionary(uniqueKeysWithValues: snapshot.inventory.map { ($0.name, $0) })
        let expected = Set(scopeInventory(in: snapshot).map(\.name))
        if Set(globalScan.inventory.map(\.name)) != expected ||
            globalScan.results.contains(where: { entries[$0.node.name] != $0.node }) {
            globalScanInvalidated = true
        }
    }

    private func finishOperation(_ id: UUID) {
        guard operationID == id else { return }
        isChecking = false
        isScanning = false
        isSwitching = false
        switchingTarget = nil
        operation = nil
        progress = ""
        if pendingLifecycleRefresh && !sleeping && !localOffline {
            pendingLifecycleRefresh = false
            scheduleNetworkRefresh("网络已更新，正在重新确认连接。")
        } else if pendingSelectionCheck && !sleeping && !localOffline {
            scheduleSelectionCheck()
        } else if initialGlobalScanPending && isPanelVisible && snapshot != nil && report != nil && !sleeping && !localOffline {
            initialGlobalScanPending = false
            Task { @MainActor [weak self] in self?.scanCandidates() }
        }
    }

    private func handle(_ error: Error, id: UUID) {
        guard operationID == id else { return }
        if error is CancellationError {
            status = report == nil ? .unknown : .stale
        } else if sleeping || localOffline {
            status = sleeping ? .stale : .error
            errorText = sleeping ? nil : "本地网络已断开，连接恢复后会自动复查。"
            lastAttemptAt = Date()
        } else {
            errorText = error.localizedDescription
            status = snapshot == nil ? .disconnected : .error
            lastAttemptAt = Date()
            appendEvent("检测未完成", error.localizedDescription)
            persistState()
        }
        finishOperation(id)
    }

    private func apply(_ checked: CheckReport, snapshot: ControllerSnapshot) {
        let old = report
        acceptSnapshot(snapshot)
        self.report = checked
        lastAttemptAt = Date()
        status = HealthStatus.evaluate(checked)
        errorText = nil
        if let ip = checked.path.exitIP {
            observations.append(ExitObservation(date: checked.checkedAt, ip: ip,
                path: snapshot.socketPath + ":" + String(snapshot.proxyPort)))
        }
        observations = Array(observations.filter { $0.date > Date().addingTimeInterval(-86400) }.suffix(2000))
        if old == nil || HealthStatus.evaluate(old!) != status || old?.selection != checked.selection {
            appendEvent(status.title, "\(checked.group) · \(checked.selection) · \(checked.current.successes)/\(checked.current.samples.count) 次探测成功")
        }
        evaluateNotification(checked)
        persistState()
    }

    private func evaluateNotification(_ report: CheckReport) {
        let key = report.group + "\n" + report.selection
        if status == .healthy {
            if notifiedLevel > 0 && settings.notifyOnRecovery {
                notify("连接已恢复", "\(report.group) 的网络复检已通过。")
            }
            notifiedLevel = 0
            problemCount = 0
            problemKey = key
            return
        }
        guard status == .degraded || status == .unreachable else { return }
        if problemKey == key { problemCount += 1 }
        else { problemKey = key; problemCount = 1; notifiedLevel = 0 }
        let level = status == .unreachable ? 2 : 1
        if (level == 2 || problemCount >= 2) && level > notifiedLevel {
            notify(status.title, "\(report.group)：\(report.selection)。打开稳连查看结果和候选。")
            notifiedLevel = level
        }
        if problemCount == 1 {
            followup = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    private func notify(_ title: String, _ body: String) {
        guard settings.notificationsEnabled, notificationPermission == "已允许" else { return }
        let content = UNMutableNotificationContent()
        content.title = "稳连：" + title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "vpn-gpt-health", content: content, trigger: nil))
    }

    private func updateNotificationPermission() async {
        let result = await UNUserNotificationCenter.current().notificationSettings()
        switch result.authorizationStatus {
        case .authorized, .provisional, .ephemeral: notificationPermission = "已允许"
        case .denied: notificationPermission = "已拒绝"
        case .notDetermined: notificationPermission = "未决定"
        @unknown default: notificationPermission = "不可用"
        }
    }

    private func installLifecycleObservers() {
        let scheduled = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(scheduled, forMode: .common)
        timer = scheduled
        scheduled.tolerance = 3
        configureSelectionTimer()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = true
                self.selectionTask?.cancel()
                self.selectionTimer?.invalidate()
                self.globalScanInvalidated = true
                self.networkRevision += 1
                self.pendingLifecycleRefresh = true
                self.followup?.cancel()
                self.cancelOperation()
                self.status = .stale
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.sleeping = false
                self.configureSelectionTimer()
                self.scheduleNetworkRefresh("Mac 已唤醒，正在重新确认连接。")
            }
        })
        monitor.pathUpdateHandler = { [weak self] path in
            let signature = String(describing: path.status) + path.availableInterfaces
                .filter { path.usesInterfaceType($0.type) }.map(\.name).sorted().joined(separator: ",")
            Task { @MainActor in
                guard let self else { return }
                let changed = self.pathSignature != nil && self.pathSignature != signature
                self.pathSignature = signature
                self.localOffline = path.status != .satisfied
                if self.localOffline {
                    self.globalScanInvalidated = true
                    self.networkRevision += 1
                    self.pendingLifecycleRefresh = true
                    self.cancelOperation()
                    self.status = .error
                    self.errorText = "本地网络已断开，连接恢复后会自动复查。"
                } else if changed {
                    self.scheduleNetworkRefresh("网络已变化，正在重新确认连接。")
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.xct.vpn-gpt.network"))
    }

    private func configureSelectionTimer() {
        selectionTimer?.invalidate()
        let interval: TimeInterval = isPanelVisible ? 2 : 15
        let watch = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.synchronizeSelection() }
        }
        watch.tolerance = isPanelVisible ? 0.2 : 3
        RunLoop.main.add(watch, forMode: .common)
        selectionTimer = watch
    }

    private func scheduleNetworkRefresh(_ reason: String) {
        networkRevision += 1
        globalScanInvalidated = true
        if isSwitching {
            pendingLifecycleRefresh = true
            return
        }
        pendingLifecycleRefresh = false
        cancelOperation()
        status = .stale
        notice = reason
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func tick() {
        guard !sleeping, !localOffline else { return }
        if isPanelVisible, Date().timeIntervalSince(lastPanelRefreshAt) >= 30 {
            lastPanelRefreshAt = Date()
            objectWillChange.send()
        }
        if let report, !isBusy,
           Date().timeIntervalSince(report.checkedAt) > Double(settings.intervalMinutes * 60 + 60),
           status != .error && status != .disconnected { status = .stale }
        if isPanelVisible, !isBusy, let lastScan = globalScan?.finishedAt ?? globalScan?.startedAt,
           Date().timeIntervalSince(lastScan) >= 900 {
            scanCandidates()
            return
        }
        if !isBusy && (lastAttemptAt == nil || Date().timeIntervalSince(lastAttemptAt!) >= Double(settings.intervalMinutes * 60)) {
            refresh()
        }
    }

    private func appendEvent(_ title: String, _ detail: String) {
        events.insert(EventEntry(title: title, detail: detail), at: 0)
        events = Array(events.prefix(40))
    }

    private func load() {
        let decoder = JSONDecoder()
        if let data = try? Data(contentsOf: storageDirectory.appendingPathComponent("settings.json")),
           let value = try? decoder.decode(AppSettings.self, from: data) { settings = value }
        if let data = try? Data(contentsOf: storageDirectory.appendingPathComponent("state.json")),
           let value = try? decoder.decode(SavedState.self, from: data) {
            report = value.report?.group == settings.group ? value.report : nil
            events = value.events
            observations = value.observations
            notifiedLevel = value.notifiedLevel
            switchReceipt = value.switchReceipt
            globalScan = value.globalScan
            globalScanSocket = value.globalScanSocket
            // A different network may be in use while the app was not running.
            // Cached samples remain visible, but cannot authorize a new switch.
            globalScanInvalidated = value.globalScan != nil
            problemKey = report.map { $0.group + "\n" + $0.selection } ?? ""
            problemCount = notifiedLevel > 0 ? 2 : 0
        }
    }

    private func persistSettings() { save(settings, name: "settings.json") }
    private func persistState() {
        save(SavedState(report: report, events: events, observations: observations,
                        notifiedLevel: notifiedLevel, switchReceipt: switchReceipt,
                        globalScan: globalScan, globalScanSocket: globalScanSocket,
                        globalScanInvalidated: globalScanInvalidated), name: "state.json")
    }

    private func save<T: Encodable>(_ value: T, name: String) {
        do {
            let manager = FileManager.default
            try manager.createDirectory(at: storageDirectory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(value)
            let url = storageDirectory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { notice = "结果可正常使用，但本地设置未能保存：\(error.localizedDescription)" }
    }
}

private enum LocalFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
