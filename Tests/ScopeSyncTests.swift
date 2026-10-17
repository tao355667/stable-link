import Foundation
import Darwin

private struct ScopeSyncFailure: Error, CustomStringConvertible {
    let description: String
}

private func verify(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ScopeSyncFailure(description: message) }
}

/// Requests cannot leave this actor. Held responses deliberately ignore task
/// cancellation so the model must reject responses from a superseded operation.
private actor ScopeSyncFixture: MihomoTransport {
    static let socket = "/scope-sync-fixture.sock"
    static let group = "ChatGPT"
    static let original = "原节点 / 🇸🇬"
    static let alternate = "备用节点"
    static let automatic = "自动选择"
    static let nested = "自动叶子一"
    static let nestedOther = "自动叶子二"
    static let deep = "深层叶子一"
    static let deepOther = "深层叶子二"
    static let outside = "外组节点"

    static var map: [String: [String: Any]] {
        [
            group: ["type": "Selector", "all": [original, alternate, automatic, "多层组", "循环一", "空组", "不存在", "DIRECT", "REJECT", original], "now": original],
            automatic: ["type": "URLTest", "all": [nested, nestedOther], "now": nested],
            "多层组": ["type": "Selector", "all": ["深层组", nestedOther], "now": "深层组"],
            "深层组": ["type": "Fallback", "all": [deep, deepOther], "now": deep],
            "循环一": ["type": "Selector", "all": ["循环二"], "now": "循环二"],
            "循环二": ["type": "Selector", "all": ["循环一"], "now": "循环一"],
            "空组": ["type": "URLTest", "all": [nestedOther]],
            "其他代理组": ["type": "Selector", "all": [outside], "now": outside],
            original: ["type": "Trojan"], alternate: ["type": "Trojan"],
            nested: ["type": "VMess"], nestedOther: ["type": "VMess"],
            deep: ["type": "Shadowsocks"], deepOther: ["type": "Shadowsocks"],
            outside: ["type": "Trojan"],
            "DIRECT": ["type": "Direct"], "REJECT": ["type": "Reject"]
        ]
    }

    static var focusedNames: Set<String> { [original, alternate, nested, deep] }
    static var allNames: Set<String> { focusedNames.union([nestedOther, deepOther, outside]) }

    private var map = ScopeSyncFixture.map
    private var requests: [MihomoRequest] = []
    private var probes: [String: Int] = [:]
    private var activeProbes = 0
    private var maximumProbes = 0
    private var proxyReads = 0
    private var versionReads = 0
    private var heldProxyRead: Int?
    private var proxyWaiters: [CheckedContinuation<Void, Never>] = []
    private var heldVersionRead: Int?
    private var versionWaiters: [CheckedContinuation<Void, Never>] = []
    private var pauseProbes = false
    private var probeWaiters: [CheckedContinuation<Void, Never>] = []

    func perform(_ request: MihomoRequest) async throws -> MihomoResponse {
        requests.append(request)
        try verify(request.method == "GET", "A scope or synchronization test tried to modify the controller")
        try verify(request.socketPath == Self.socket && request.proxyPort == nil,
                   "A request escaped the fixture controller boundary")
        guard let url = URLComponents(string: request.url) else {
            throw ScopeSyncFailure(description: "Invalid fixture URL")
        }
        switch url.path {
        case "/version":
            versionReads += 1
            if heldVersionRead == versionReads {
                heldVersionRead = nil
                await withCheckedContinuation { versionWaiters.append($0) }
            }
            return try json(["version": "scope-sync-fixture"])
        case "/configs": return try json(["mixed-port": 0, "mode": "rule"])
        case "/proxies":
            proxyReads += 1
            let captured = try json(["proxies": map])
            if heldProxyRead == proxyReads {
                heldProxyRead = nil
                await withCheckedContinuation { proxyWaiters.append($0) }
            }
            return captured
        default:
            let encoded = url.percentEncodedPath
            guard encoded.hasPrefix("/proxies/"), encoded.hasSuffix("/delay"),
                  let name = String(encoded.dropFirst("/proxies/".count).dropLast("/delay".count)).removingPercentEncoding,
                  map[name] != nil else {
                throw ScopeSyncFailure(description: "Unexpected fixture request: \(request.url)")
            }
            probes[name, default: 0] += 1
            activeProbes += 1
            maximumProbes = max(maximumProbes, activeProbes)
            defer { activeProbes -= 1 }
            if pauseProbes { await withCheckedContinuation { probeWaiters.append($0) } }
            try await Task.sleep(nanoseconds: 15_000_000)
            return try json(["delay": 90])
        }
    }

    private func json(_ object: Any) throws -> MihomoResponse {
        MihomoResponse(status: 200, body: try JSONSerialization.data(withJSONObject: object))
    }

    func choose(_ name: String, in group: String = ScopeSyncFixture.group) { map[group]?["now"] = name }
    func requestPaths() -> [String] { requests.compactMap { URLComponents(string: $0.url)?.path } }
    func probeCounts() -> [String: Int] { probes }
    func maximumConcurrency() -> Int { maximumProbes }
    func proxyReadCount() -> Int { proxyReads }
    func holdProxyResponse(afterAdditionalReads count: Int) { heldProxyRead = proxyReads + count }
    func proxyResponseIsHeld() -> Bool { !proxyWaiters.isEmpty }
    func releaseProxyResponses() {
        let pending = proxyWaiters
        proxyWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func holdVersionResponse(afterAdditionalReads count: Int) { heldVersionRead = versionReads + count }
    func versionResponseIsHeld() -> Bool { !versionWaiters.isEmpty }
    func releaseVersionResponses() {
        let pending = versionWaiters
        versionWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
    func holdProbeResponses() { pauseProbes = true }
    func hasHeldProbes() -> Bool { !probeWaiters.isEmpty }
    func releaseProbeResponses() {
        pauseProbes = false
        let pending = probeWaiters
        probeWaiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

@main
@MainActor
private struct ScopeSyncTests {
    static func main() async {
        do {
            try await run("Current-group default preserves older saved settings", settingsMigration)
            try await run("Focused inventory resolves only selected nested leaves", focusedInventory)
            try await run("Focused scan probes four samples with at most three simultaneous requests", focusedScan)
            try await run("Optional full scan still includes all groups and nested alternatives", fullScan)
#if SCOPE_SYNC_MODEL_TESTS
            try await run("Model dispatch and cache validity follow the selected scan scope", modelScope)
            try await run("Changing scope during a scan replaces its in-flight result", scopeChangeDuringScan)
            try await run("External logical and nested selections refresh without a full snapshot", externalSelection)
            try await run("External selection still synchronizes during a node scan", externalSelectionDuringScan)
            try await run("A late old check cannot overwrite the synchronized selection", lateCheck)
            try await run("A late scan snapshot cannot overwrite a newer selection-only snapshot", lateScanSnapshot)
#endif
            print("All scope and selection-sync tests passed. Only mock GET requests and temporary storage were used.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run(_ name: String, _ test: () async throws -> Void) async throws {
        try await test()
        print("PASS: \(name)")
    }

    private static func settingsMigration() async throws {
        try verify(AppSettings().scanScope == .currentGroup, "New installations must default to current-group scanning")
        try verify(AppSettings().group == "节点选择", "New installations must follow the main selector rather than silently choosing a service-specific group")
        let old = Data(#"{"group":"开发工具","intervalMinutes":11,"notificationsEnabled":false,"notifyOnRecovery":true,"socketOverride":"/custom/socket"}"#.utf8)
        let value = try JSONDecoder().decode(AppSettings.self, from: old)
        try verify(value.scanScope == .currentGroup, "Older settings without a scan scope must use current-group scanning")
        try verify(value.group == "开发工具" && value.intervalMinutes == 11 && !value.notificationsEnabled &&
                   value.notifyOnRecovery && value.socketOverride == "/custom/socket", "Migration lost existing settings")
        var updated = value
        updated.scanScope = .allGroups
        let reloaded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(updated))
        try verify(reloaded == updated, "Explicit all-group preference did not survive a settings round trip")
    }

    private static func focusedInventory() async throws {
        let map = ScopeSyncFixture.map
        let focused = MihomoClient.currentGroupInventory(in: map, group: ScopeSyncFixture.group)
        try verify(Set(focused.map(\.name)) == ScopeSyncFixture.focusedNames,
                   "Focused inventory expanded a nested group's unselected leaves or included unrelated groups")
        try verify(focused.count == 4, "Focused inventory did not deduplicate repeated direct members")
        try verify(MihomoClient.currentGroupInventory(in: map, group: "missing").isEmpty,
                   "A missing group must not fall back to all-group scanning")
        try verify(Set(MihomoClient.nodeInventory(in: map).map(\.name)) == ScopeSyncFixture.allNames,
                   "Full inventory no longer includes nested alternatives and external groups")
    }

    private static func focusedScan() async throws {
        let fixture = ScopeSyncFixture()
        let client = MihomoClient(transport: fixture)
        let snapshot = try await client.snapshot(socketOverride: ScopeSyncFixture.socket)
        let report = try await client.scanCurrentGroup(snapshot: snapshot, group: ScopeSyncFixture.group,
                                                       progress: { _ in }, partial: { _ in })
        let counts = await fixture.probeCounts()
        try verify(Set(counts.keys) == ScopeSyncFixture.focusedNames && counts.values.allSatisfy { $0 == 4 },
                   "Focused scan did not limit its four samples to current-group nodes")
        let concurrency = await fixture.maximumConcurrency()
        try verify(concurrency == 3, "Focused scan must retain the three-request concurrency bound")
        try verify(report.scope == .currentGroup && report.groupName == ScopeSyncFixture.group && report.groupCount == 1,
                   "Focused report lost its group identity")
        try verify(report.finishedAt != nil && report.completedRounds == 2 && report.stableResults.count == 4,
                   "Focused scan did not complete both rounds")
    }

    private static func fullScan() async throws {
        let fixture = ScopeSyncFixture()
        let client = MihomoClient(transport: fixture)
        let snapshot = try await client.snapshot(socketOverride: ScopeSyncFixture.socket)
        let report = try await client.scanAll(snapshot: snapshot, progress: { _ in }, partial: { _ in })
        let counts = await fixture.probeCounts()
        try verify(Set(counts.keys) == ScopeSyncFixture.allNames && counts.values.allSatisfy { $0 == 4 },
                   "Optional all-group scan omitted nodes outside the focused group")
        try verify(report.scope == .allGroups && report.groupName == nil && report.stableResults.count == 7,
                   "All-group report was confused with a focused scan")
        let concurrency = await fixture.maximumConcurrency()
        try verify(concurrency <= 3, "All-group scan exceeded the concurrency bound")
    }

#if SCOPE_SYNC_MODEL_TESTS
    private static func setup(_ fixture: ScopeSyncFixture) async throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-gpt-scope-sync-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let client = MihomoClient(transport: fixture)
        let model = AppModel(autoStart: false, client: client, storageDirectory: directory)
        model.settings.group = ScopeSyncFixture.group
        model.settings.socketOverride = ScopeSyncFixture.socket
        model.settings.notificationsEnabled = false
        model.snapshot = try await client.snapshot(socketOverride: ScopeSyncFixture.socket)
        return (model, directory)
    }

    private static func seedReport(_ model: AppModel) {
        let selected = model.currentGroup!.selected
        let leaf = model.snapshot!.resolvedNodes[ScopeSyncFixture.group]!
        model.report = CheckReport(checkedAt: Date(), group: ScopeSyncFixture.group, selection: selected,
            current: NodeResult(name: selected, resolvedNode: leaf,
                samples: [ProbeSample(latencyMS: 90), ProbeSample(latencyMS: 90)], testedAt: Date()),
            path: PathObservation(exitIP: nil, httpStatus: 200, reachable: true))
        model.status = .healthy
    }

    private static func eventually(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !(await condition()) {
            try verify(Date() < deadline, "Timed out: " + message)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func modelScope() async throws {
        let fixture = ScopeSyncFixture()
        let (model, directory) = try await setup(fixture)
        defer { model.cancelOperation(); try? FileManager.default.removeItem(at: directory) }
        model.scanCandidates()
        try await eventually("focused model scan") { !model.isBusy }
        try verify(model.errorText == nil && model.globalScanFresh, "Focused model scan did not become valid")
        try verify(model.globalScan?.scope == .currentGroup && Set(model.globalResults.map { $0.node.name }) == ScopeSyncFixture.focusedNames,
                   "Default model scan dispatched the all-group engine")
        model.setScanScope(.allGroups)
        try verify(!model.globalScanFresh && model.stableNodes.isEmpty,
                   "Changing scope reused a completed report from another scope")
        let stored = try JSONDecoder().decode(AppSettings.self, from: Data(contentsOf: directory.appendingPathComponent("settings.json")))
        try verify(stored.scanScope == .allGroups, "Changing scan scope did not persist the preference")
        if !model.isScanning { model.scanCandidates() }
        try await eventually("optional full model scan") { !model.isBusy }
        try verify(model.globalScanFresh && model.globalScan?.scope == .allGroups &&
                   Set(model.globalResults.map { $0.node.name }) == ScopeSyncFixture.allNames,
                   "All-group choice did not dispatch a complete all-group scan")
        model.setScanScope(.currentGroup)
        try verify(!model.globalScanFresh && model.stableNodes.isEmpty,
                   "All-group samples stayed authorized after returning to focused scope")
        model.cancelOperation()
    }

    private static func scopeChangeDuringScan() async throws {
        let fixture = ScopeSyncFixture()
        let (model, directory) = try await setup(fixture)
        defer { model.cancelOperation(); try? FileManager.default.removeItem(at: directory) }
        await fixture.holdProbeResponses()
        model.scanCandidates()
        try await eventually("held focused probes") { await fixture.hasHeldProbes() }
        model.setScanScope(.allGroups)
        await fixture.releaseProbeResponses()
        try await eventually("replacement full scan") {
            !model.isBusy && model.globalScan?.scope == .allGroups && model.globalScan?.finishedAt != nil
        }
        try verify(model.globalScanFresh && Set(model.globalResults.map { $0.node.name }) == ScopeSyncFixture.allNames,
                   "An old focused scan replaced the new full scan after a scope change")
    }

    private static func externalSelection() async throws {
        let fixture = ScopeSyncFixture()
        let (model, directory) = try await setup(fixture)
        defer { model.cancelOperation(); try? FileManager.default.removeItem(at: directory) }
        seedReport(model)
        let before = await fixture.requestPaths().count
        await fixture.choose(ScopeSyncFixture.automatic)
        await model.pollSelectionNow()
        try verify(model.currentGroup?.selected == ScopeSyncFixture.automatic &&
                   model.snapshot?.resolvedNodes[ScopeSyncFixture.group] == ScopeSyncFixture.nested,
                   "External group selection was not reflected in the current snapshot")
        try verify(model.report == nil && model.status != .healthy, "Old healthy report survived an external selection change")
        let newPaths = Array((await fixture.requestPaths()).dropFirst(before))
        try verify(newPaths == ["/proxies"], "Selection sync must read only /proxies, without a full snapshot or node probes")
        model.cancelOperation()

        seedReport(model)
        await fixture.choose(ScopeSyncFixture.nestedOther, in: ScopeSyncFixture.automatic)
        await model.pollSelectionNow()
        try verify(model.currentGroup?.selected == ScopeSyncFixture.automatic &&
                   model.snapshot?.resolvedNodes[ScopeSyncFixture.group] == ScopeSyncFixture.nestedOther,
                   "Changing only a nested group's current leaf did not refresh the resolved node")
        try verify(model.report == nil && model.status != .healthy, "A nested leaf change left the old health report valid")
    }

    private static func externalSelectionDuringScan() async throws {
        let fixture = ScopeSyncFixture()
        let (model, directory) = try await setup(fixture)
        defer { model.cancelOperation(); try? FileManager.default.removeItem(at: directory) }
        seedReport(model)
        await fixture.holdProbeResponses()
        model.scanCandidates()
        try await eventually("busy node scan") { await fixture.hasHeldProbes() }
        try verify(model.isScanning, "Fixture did not create an active scan")
        await fixture.choose(ScopeSyncFixture.alternate)
        await model.pollSelectionNow()
        try verify(model.currentGroup?.selected == ScopeSyncFixture.alternate,
                   "A busy scan prevented external selection synchronization")
        try verify(model.report == nil, "A busy scan retained the previous selection's report")
        await fixture.releaseProbeResponses()
        model.cancelOperation()
    }

    private static func lateCheck() async throws {
        let fixture = ScopeSyncFixture()
        let (model, directory) = try await setup(fixture)
        defer { model.cancelOperation(); try? FileManager.default.removeItem(at: directory) }
        seedReport(model)
        // refresh snapshot, initial selection audit, final selection audit.
        // Capture the final audit while it still sees the original selection.
        await fixture.holdProxyResponse(afterAdditionalReads: 3)
        model.refresh()
        try await eventually("old check's captured final audit") { await fixture.proxyResponseIsHeld() }
        await fixture.choose(ScopeSyncFixture.alternate)
        await model.pollSelectionNow()
        try verify(model.currentGroup?.selected == ScopeSyncFixture.alternate && model.report == nil,
                   "Selection sync did not invalidate the old check immediately")
        await fixture.releaseProxyResponses()
        try await Task.sleep(nanoseconds: 150_000_000)
        try verify(model.currentGroup?.selected == ScopeSyncFixture.alternate,
                   "A late check restored the previous snapshot after selection synchronization")
        try verify(model.report?.selection != ScopeSyncFixture.original,
                   "A late check published healthy results for the previous selection")
        try await eventually("new selection's follow-up check") {
            model.report?.selection == ScopeSyncFixture.alternate && !model.isChecking
        }
    }

    private static func lateScanSnapshot() async throws {
        let fixture = ScopeSyncFixture()
        let (model, directory) = try await setup(fixture)
        defer { model.cancelOperation(); try? FileManager.default.removeItem(at: directory) }
        seedReport(model)
        let initialProxyReads = await fixture.proxyReadCount()
        // A complete scan obtains two full snapshots: one before probing, one
        // after. Hold the final /version while its concurrent /proxies request
        // has already captured the original selection.
        await fixture.holdVersionResponse(afterAdditionalReads: 2)
        model.setScanScope(.allGroups)
        try await eventually("scan's final snapshot captured old proxies") {
            let held = await fixture.versionResponseIsHeld()
            let reads = await fixture.proxyReadCount()
            return held && reads >= initialProxyReads + 5
        }
        try verify(model.isScanning, "Fixture did not hold the scan's final snapshot")
        await fixture.choose(ScopeSyncFixture.alternate)
        await model.pollSelectionNow()
        try verify(model.currentGroup?.selected == ScopeSyncFixture.alternate && model.report == nil,
                   "Selection-only snapshot did not synchronize while the full snapshot was pending")
        await fixture.releaseVersionResponses()
        try await eventually("full scan completion after releasing old snapshot") { !model.isScanning }
        try verify(model.currentGroup?.selected == ScopeSyncFixture.alternate &&
                   model.snapshot?.resolvedNodes[ScopeSyncFixture.group] == ScopeSyncFixture.alternate,
                   "The scan's delayed full snapshot restored the old logical selection or resolved leaf")
        try verify(model.report?.selection != ScopeSyncFixture.original,
                   "The scan restored health observations for the previous selection")
        try verify(model.globalScan?.scope == .allGroups && model.globalScan?.finishedAt != nil,
                   "A harmless logical selection change discarded the full scan")
    }
#endif
}
