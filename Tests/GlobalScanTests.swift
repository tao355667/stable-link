import Foundation
import Darwin

private struct ScanTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ScanTestFailure(description: message) }
}

/// Every request ends here. This fixture never invokes curl or a real controller.
private actor ScanFixture: MihomoTransport {
    private let maps: [[String: [String: Any]]]
    private let patterns: [String: [Int?]]
    private var requests: [MihomoRequest] = []
    private var proxyReads = 0
    private var samplesByName: [String: Int] = [:]
    private var activeDelays = 0
    private var maximumDelays = 0

    init(maps: [[String: [String: Any]]], patterns: [String: [Int?]] = [:]) {
        self.maps = maps
        self.patterns = patterns
    }

    func perform(_ request: MihomoRequest) async throws -> MihomoResponse {
        requests.append(request)
        try expect(request.method == "GET", "A global scan issued a controller mutation")
        try expect(request.socketPath == "/global-scan-fixture.sock", "Scan escaped the mock socket boundary")
        try expect(request.proxyPort == nil, "A node scan unexpectedly used the local proxy route")
        guard let components = URLComponents(string: request.url) else {
            throw ScanTestFailure(description: "Invalid scan URL")
        }
        if components.path == "/proxies" {
            let map = maps[min(proxyReads, maps.count - 1)]
            proxyReads += 1
            return try json(["proxies": map])
        }
        let path = components.percentEncodedPath
        guard path.hasPrefix("/proxies/"), path.hasSuffix("/delay") else {
            throw ScanTestFailure(description: "Unexpected mock request: \(request.url)")
        }
        let encodedName = String(path.dropFirst("/proxies/".count).dropLast("/delay".count))
        try expect(!encodedName.contains("/"), "A slash in the node name became another path segment")
        guard let name = encodedName.removingPercentEncoding,
              maps[0][name] != nil else {
            throw ScanTestFailure(description: "Probe name was not preserved or was never in the original inventory")
        }
        try expect(components.queryItems?.first(where: { $0.name == "url" })?.value == "https://chatgpt.com/cdn-cgi/trace", "Target URL was not preserved")
        let sampleIndex = samplesByName[name, default: 0]
        samplesByName[name] = sampleIndex + 1
        activeDelays += 1
        maximumDelays = max(maximumDelays, activeDelays)
        do { try await Task.sleep(nanoseconds: 30_000_000) }
        catch { activeDelays -= 1; throw error }
        activeDelays -= 1
        let pattern = patterns[name] ?? [100, 110, 105, 115]
        guard let delay = pattern[min(sampleIndex, pattern.count - 1)] else {
            return try json(["message": "fixture timeout"], status: 504)
        }
        return try json(["delay": delay])
    }

    private func json(_ value: Any, status: Int = 200) throws -> MihomoResponse {
        MihomoResponse(status: status, body: try JSONSerialization.data(withJSONObject: value))
    }

    func counts() -> [String: Int] { samplesByName }
    func verbs() -> [String] { requests.map(\.method) }
    func readCount() -> Int { proxyReads }
    func maximumConcurrency() -> Int { maximumDelays }
}

private actor ScanObserver {
    private var reports: [GlobalScanReport] = []
    private var messages: [String] = []
    func observe(_ report: GlobalScanReport) { reports.append(report) }
    func progress(_ message: String) { messages.append(message) }
    func snapshots() -> [GlobalScanReport] { reports }
    func didComplete() -> Bool { reports.contains { $0.finishedAt != nil } }
    func completedRoundCount() -> Int { reports.map(\.completedRounds).max() ?? 0 }
    func progressMessages() -> [String] { messages }
}

@main
private struct GlobalScanTests {
    static func main() async {
        do {
            try await run("Recursive inventory, cycles, sources and unusual names", inventoryChecks)
            try await run("Stability requires complete samples and bounded jitter", stabilityChecks)
            try await run("Every leaf beyond twelve is probed twice per round with bounded concurrency", exhaustiveChecks)
            try await run("Selection changes do not invalidate direct leaf probes", selectionChanges)
            try await run("Deleted, changed and newly added nodes cannot retain stable results", inventoryChanges)
            try await run("Cancellation prevents later batches and completion", cancellationDuringBatch)
            try await run("Cancellation between rounds prevents the second round", cancellationBetweenRounds)
            print("All global scan tests passed. Only mock GET requests were used.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run(_ name: String, _ test: () async throws -> Void) async throws {
        try await test()
        print("PASS: \(name)")
    }

    private static func snapshot(_ map: [String: [String: Any]]) -> ControllerSnapshot {
        ControllerSnapshot(socketPath: "/global-scan-fixture.sock", version: "fixture", proxyPort: 0,
                           mode: "rule", groups: [], resolvedNodes: [:],
                           inventory: MihomoClient.nodeInventory(in: map))
    }

    private static func inventoryChecks() async throws {
        let special = "🇸🇬 叶子 / ?+#% 空格"
        let map: [String: [String: Any]] = [
            "A": ["type": "Selector", "all": ["B", "leaf0", "leaf0", "DIRECT", "REJECT", "PASS", "DNS", "伪装直连", "空自动组", "不存在"], "now": "DIRECT"],
            "B": ["type": "URLTest", "all": ["leaf1", "C"], "now": "leaf1"],
            "C": ["type": "Selector", "all": ["A", "leaf2", special], "now": "leaf2"],
            "D": ["type": "Fallback", "all": ["leaf2", "B"], "now": "leaf2"],
            "E": ["type": "Selector", "all": [special], "now": special],
            "leaf0": ["type": "Shadowsocks"], "leaf1": ["type": "VMess"],
            "leaf2": ["type": "Trojan"], special: ["type": "WireGuard"],
            "DIRECT": ["type": "Direct"], "REJECT": ["type": "Reject"],
            "PASS": ["type": "Pass"], "DNS": ["type": "DNS"],
            "伪装直连": ["type": "Direct"], "空自动组": ["type": "URLTest"],
            "未被任何组引用": ["type": "Trojan"]
        ]
        let inventory = MihomoClient.nodeInventory(in: map)
        try expect(inventory.count == 4, "Inventory must deduplicate real leaves, exclude builtins and terminate cycles")
        try expect(Set(inventory.map(\.name)) == Set(["leaf0", "leaf1", "leaf2", special]), "All nested leaves must be collected regardless of now")
        let byName = Dictionary(uniqueKeysWithValues: inventory.map { ($0.name, $0) })
        try expect(Set(byName["leaf1"]!.groups) == Set(["A", "B", "C", "D"]), "groups must retain all transitive source groups")
        try expect(Set(byName[special]!.groups) == Set(["A", "B", "C", "D", "E"]), "Special node name or its transitive sources were lost")
        try expect(byName["leaf0"]!.selectableGroups == ["A"], "A duplicate direct member must have one selectable group")
        try expect(byName["leaf1"]!.selectableGroups.isEmpty, "A URLTest direct member cannot be selected manually")
        try expect(byName["leaf2"]!.selectableGroups == ["C"], "An indirect Selector parent or Fallback cannot directly select a leaf")
        try expect(Set(byName[special]!.selectableGroups) == Set(["C", "E"]), "Only direct Selector memberships can enable a switch")
        try expect(byName[special]!.kind == "WireGuard", "Leaf protocol must survive enumeration")
    }

    private static func result(_ values: [Int?]) -> GlobalNodeResult {
        let node = NodeInventoryEntry(name: "fixture", kind: "Trojan", groups: ["all"], selectableGroups: ["all"])
        return GlobalNodeResult(node: node, rounds: stride(from: 0, to: values.count, by: 2).map { start in
            NodeResult(name: node.name, resolvedNode: node.name,
                       samples: values[start..<min(start + 2, values.count)].map {
                           ProbeSample(latencyMS: $0, error: $0 == nil ? "timeout" : nil)
                       }, testedAt: Date())
        })
    }

    private static func stabilityChecks() async throws {
        try expect(!result([100, 110]).isStable, "A single successful round must wait for recheck")
        try expect(!result([100, 110, 105]).isStable, "An incomplete second round cannot pass")
        try expect(result([100, 110, 105, 115]).isStable, "Four consistent successes should pass")
        try expect(result([2400, 2500, 2550, 2600]).isStable, "Consistent high latency must not be mistaken for instability")
        try expect(!result([20, nil, 25, 21]).isStable, "Low latency cannot hide a failed sample")
        try expect(!result([100, 100, 100, 2900]).isStable, "Large jitter must fail even with four successes")
        try expect(result([100, 100, 1100, 1100]).isStable, "The absolute 1000ms jitter boundary is inclusive")
        try expect(!result([100, 100, 1101, 1101]).isStable, "Jitter above the absolute boundary must fail")
        try expect(result([1250, 2000, 2000, 2750]).isStable, "The median-scaled jitter boundary is inclusive")
        try expect(!result([1249, 2000, 2000, 2750]).isStable, "Jitter above 75 percent of median must fail")
    }

    private static func nodeMap(_ names: [String]) -> [String: [String: Any]] {
        let split = min(8, names.count)
        let direct = Array(names.prefix(split))
        let nested = Array(names.dropFirst(split))
        var map: [String: [String: Any]] = [
            "全部 / 🌏": ["type": "Selector", "all": direct + (nested.isEmpty ? [] : ["自动选择"]), "now": names[0]],
            "DIRECT": ["type": "Direct"], "REJECT": ["type": "Reject"]
        ]
        if !nested.isEmpty {
            map["自动选择"] = ["type": "URLTest", "all": nested, "now": nested[0]]
        }
        for name in names { map[name] = ["type": "Trojan"] }
        return map
    }

    private static func scan(_ fixture: ScanFixture, map: [String: [String: Any]],
                             observer: ScanObserver) async throws -> GlobalScanReport {
        try await MihomoClient(transport: fixture).scanAll(snapshot: snapshot(map), progress: {
            await observer.progress($0)
        }, partial: {
            await observer.observe($0)
        })
    }

    private static func exhaustiveChecks() async throws {
        let names = (1...15).map { "🇯🇵 代理 \($0) / ?+#%" }
        let map = nodeMap(names)
        let fixture = ScanFixture(maps: [map], patterns: [
            names[0]: [20, nil, 25, 21], names[1]: [100, 100, 100, 2900],
            names[2]: [2400, 2500, 2550, 2600]
        ])
        let observer = ScanObserver()
        let report = try await scan(fixture, map: map, observer: observer)
        try expect(report.inventory.count == 15 && report.results.count == 15, "Global scan retained the former twelve-node cap")
        try expect(report.completedRounds == 2 && report.finishedAt != nil, "A completed scan needs two full rounds and a completion time")
        try expect(report.results.allSatisfy { $0.rounds.count == 2 && $0.rounds.allSatisfy { $0.samples.count == 2 } }, "Every leaf requires two samples in each of two rounds")
        let counts = await fixture.counts()
        try expect(Set(counts.keys) == Set(names) && counts.values.allSatisfy { $0 == 4 }, "Every deduplicated leaf must receive exactly four GET probes")
        let maximum = await fixture.maximumConcurrency()
        try expect(maximum == 3, "Global node probes should overlap but never exceed three concurrent requests")
        let verbs = await fixture.verbs()
        try expect(verbs.allSatisfy { $0 == "GET" }, "Global scan changed controller state")
        let reads = await fixture.readCount()
        try expect(reads == 3, "Inventory needs verification after each round")
        let partials = await observer.snapshots()
        try expect(partials.contains { $0.results.count == 3 && $0.completedRounds == 0 }, "First batch was not made visible immediately")
        try expect(partials.contains { $0.results.count == 12 && $0.completedRounds == 0 }, "Intermediate batch progress was lost")
        try expect(partials.filter { $0.completedRounds == 0 }.allSatisfy { $0.stableResults.isEmpty }, "One-round partial results were prematurely labelled stable")
        let stableNames = Set(report.stableResults.map { $0.node.name })
        try expect(stableNames.count == 13 && !stableNames.contains(names[0]) && !stableNames.contains(names[1]), "Live scan must filter packet loss and high jitter")
        try expect(stableNames.contains(names[2]), "A consistent high-latency node should remain available")
    }

    private static func selectionChanges() async throws {
        let names = ["一号", "二号", "三号"]
        let map = nodeMap(names)
        var changed = map
        changed["全部 / 🌏"]?["now"] = names[1]
        var changedAgain = changed
        changedAgain["全部 / 🌏"]?["now"] = names[2]
        let fixture = ScanFixture(maps: [map, changed, changedAgain])
        let report = try await scan(fixture, map: map, observer: ScanObserver())
        try expect(report.stableResults.count == 3 && report.finishedAt != nil, "Unrelated group selections invalidated direct leaf observations")
    }

    private static func inventoryChanges() async throws {
        let names = ["删除节点", "协议变化", "来源变化", "保持稳定"]
        var map = nodeMap(names)
        map["其他来源"] = ["type": "Selector", "all": ["保持稳定"], "now": "保持稳定"]
        var changed = map
        changed.removeValue(forKey: "删除节点")
        changed["协议变化"] = ["type": "VMess"]
        changed["全部 / 🌏"]?["all"] = ["协议变化", "保持稳定", "新增节点"]
        changed["其他来源"]?["all"] = ["保持稳定", "来源变化"]
        changed["新增节点"] = ["type": "Trojan"]

        // Test both audit boundaries. The later mutation has already collected
        // four successes, which must still be discarded when its identity shifts.
        let initialMap = map
        let updatedMap = changed
        async let early = mutationCheck(map: initialMap, changed: updatedMap, mutateAtFinalAudit: false)
        async let late = mutationCheck(map: initialMap, changed: updatedMap, mutateAtFinalAudit: true)
        try await early
        try await late
    }

    private static func mutationCheck(map: [String: [String: Any]], changed: [String: [String: Any]],
                                      mutateAtFinalAudit: Bool) async throws {
        let fixture = ScanFixture(maps: mutateAtFinalAudit ? [map, map, changed] : [map, changed, changed])
        let observer = ScanObserver()
        let report = try await scan(fixture, map: map, observer: observer)
        try expect(report.results.map { $0.node.name } == ["保持稳定"], "Removed, protocol-changed or moved nodes retained stale scan results")
        try expect(report.stableResults.map { $0.node.name } == ["保持稳定"], "An invalidated identity or untested new node was labelled stable")
        let counts = await fixture.counts()
        try expect(counts["新增节点"] == nil, "New inventory entries must wait for a fresh complete scan")
        try expect(counts["保持稳定"] == 4, "An unchanged node lost its second round")
        let expectedChangedCount = mutateAtFinalAudit ? 4 : 2
        try expect(counts["协议变化"] == expectedChangedCount && counts["来源变化"] == expectedChangedCount, "Invalidated entries must not be probed in later batches")
        let partials = await observer.snapshots()
        try expect(partials.last?.results.map { $0.node.name } == ["保持稳定"], "Final partial report kept an invalidated stable result")
    }

    private static func eventually(_ description: String, condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await condition()) {
            try expect(Date() < deadline, "Timed out waiting for \(description)")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private static func cancellationDuringBatch() async throws {
        let map = nodeMap((1...15).map { "取消测试 \($0)" })
        let fixture = ScanFixture(maps: [map])
        let observer = ScanObserver()
        let task = Task { try await scan(fixture, map: map, observer: observer) }
        try await eventually("the first concurrent batch") { await fixture.counts().count == 3 }
        task.cancel()
        do {
            _ = try await task.value
            throw ScanTestFailure(description: "Cancelled scan returned a completed report")
        } catch is CancellationError { }
        let counts = await fixture.counts()
        try expect(counts.count == 3 && counts.values.allSatisfy { $0 <= 2 }, "Cancellation started a later batch")
        let completed = await observer.didComplete()
        try expect(!completed, "Cancelled scan published a finished report")
        let reads = await fixture.readCount()
        try expect(reads == 1, "Cancelled first batch continued to later inventory audits")
    }

    private static func cancellationBetweenRounds() async throws {
        let map = nodeMap(["轮间一号", "轮间二号", "轮间三号"])
        let fixture = ScanFixture(maps: [map])
        let observer = ScanObserver()
        let task = Task { try await scan(fixture, map: map, observer: observer) }
        try await eventually("the first round audit") { await observer.completedRoundCount() == 1 }
        task.cancel()
        do {
            _ = try await task.value
            throw ScanTestFailure(description: "Cancelled round gap returned a completed report")
        } catch is CancellationError { }
        let counts = await fixture.counts()
        try expect(counts.count == 3 && counts.values.allSatisfy { $0 == 2 }, "Cancelled round gap still began another round")
        let completed = await observer.didComplete()
        try expect(!completed, "Cancelled round gap published a finished report")
    }
}
