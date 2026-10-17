import Foundation
import Darwin

private struct GlobalModelTestFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw GlobalModelTestFailure(description: message) }
}

/// This transport owns every request, including snapshots. Nothing reaches curl,
/// a live proxy, notification services or the user's application storage.
private actor GlobalModelFixture: MihomoTransport {
    static let socket = "/global-model-fixture.sock"
    static let current = "当前节点"
    static let direct = "可直接切换 / 🇸🇬"
    static let nested = "嵌套叶子"
    static let outside = "其他组一号"
    static let outsideSecond = "其他组二号"
    private var requests: [MihomoRequest] = []

    static var map: [String: [String: Any]] {
        [
            "ChatGPT": ["type": "Selector", "all": [current, direct, "自动组"], "now": current],
            "自动组": ["type": "URLTest", "all": [nested], "now": nested],
            "其他代理组": ["type": "Selector", "all": [outside, outsideSecond], "now": outside],
            current: ["type": "Trojan"], direct: ["type": "Trojan"],
            nested: ["type": "VMess"], outside: ["type": "Shadowsocks"],
            outsideSecond: ["type": "Shadowsocks"]
        ]
    }

    func perform(_ request: MihomoRequest) async throws -> MihomoResponse {
        requests.append(request)
        try require(request.method == "GET", "A model regression attempted to switch a mock node")
        try require(request.socketPath == Self.socket && request.proxyPort == nil, "Model request escaped the mock controller boundary")
        guard let url = URLComponents(string: request.url) else {
            throw GlobalModelTestFailure(description: "Invalid mock controller URL")
        }
        switch url.path {
        case "/version": return try json(["version": "global-model-fixture"])
        case "/configs": return try json(["mixed-port": 0, "mode": "rule"])
        case "/proxies": return try json(["proxies": Self.map])
        default:
            guard url.percentEncodedPath.hasPrefix("/proxies/"), url.percentEncodedPath.hasSuffix("/delay") else {
                throw GlobalModelTestFailure(description: "Unexpected mock model request: \(request.url)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
            return try json(["delay": 80])
        }
    }

    private func json(_ value: Any) throws -> MihomoResponse {
        MihomoResponse(status: 200, body: try JSONSerialization.data(withJSONObject: value))
    }

    func verbs() -> [String] { requests.map(\.method) }
    func requestCount() -> Int { requests.count }
}

@MainActor
private struct CompletedGlobalContext {
    let model: AppModel
    let fixture: GlobalModelFixture
    let directory: URL
}

@main
@MainActor
private struct GlobalScanModelTests {
    static func main() async {
        do {
            try await run("Partial and cancelled scans retain samples without stable authorization", partialAndCancelledScan)
            let completed = try await run("Completed scans include other groups but only direct members can switch", completedScanScope)
            defer { try? FileManager.default.removeItem(at: completed.directory) }
            try await run("Cached completed scans always require a new scan after relaunch") {
                try await cachedScanRequiresRecheck(completed)
            }
            try await run("Fresh scan completion cannot authorize old node samples", staleSamples)
            print("All global scan model tests passed. Only mock GET requests and temporary storage were used.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run<T>(_ name: String, _ test: () async throws -> T) async throws -> T {
        let result = try await test()
        print("PASS: \(name)")
        return result
    }

    private static func setup() throws -> CompletedGlobalContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-gpt-global-model-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = GlobalModelFixture()
        let model = AppModel(autoStart: false, client: MihomoClient(transport: fixture), storageDirectory: directory)
        model.settings.group = "ChatGPT"
        model.settings.socketOverride = GlobalModelFixture.socket
        model.settings.scanScope = .allGroups
        model.settings.notificationsEnabled = false
        return CompletedGlobalContext(model: model, fixture: fixture, directory: directory)
    }

    private static func eventually(_ message: String, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() {
            try require(Date() < deadline, "Timed out: " + message)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func partialAndCancelledScan() async throws {
        let context = try setup()
        let model = context.model
        defer {
            model.cancelOperation()
            try? FileManager.default.removeItem(at: context.directory)
        }
        model.scanCandidates()
        try require(model.isScanning, "Global scan should immediately expose a busy state")
        // At least one node now has all four passing samples, but another batch
        // is still pending: the scan as a whole must not authorize a selection.
        try await eventually("second-round partial results") {
            model.globalResults.contains { $0.rounds.count == 2 } &&
                model.globalScan?.finishedAt == nil && model.isScanning
        }
        try require(!model.globalResults.isEmpty && model.globalResults.contains { !$0.samples.isEmpty }, "Partial probe samples should remain visible")
        try require(model.stableNodes.isEmpty && !model.globalScanFresh, "An incomplete scan exposed stable nodes")
        try require(!model.canUseGlobalNode(GlobalModelFixture.direct), "An in-progress scan enabled a switch")
        let sampleCount = model.globalResults.reduce(0) { $0 + $1.samples.count }
        model.cancelOperation()
        try require(!model.isBusy, "Cancel should finish the model operation immediately")
        try require(model.globalResults.reduce(0) { $0 + $1.samples.count } == sampleCount, "Cancel discarded visible partial samples")
        try require(model.stableNodes.isEmpty && !model.globalScanFresh, "Cancel retained stable authorization")
        try await Task.sleep(nanoseconds: 80_000_000)
        try require(model.globalScan?.finishedAt == nil, "A late cancelled batch published a completed scan")
        try require(model.globalResults.reduce(0) { $0 + $1.samples.count } == sampleCount, "A late cancelled batch replaced the retained samples")
        let verbs = await context.fixture.verbs()
        try require(verbs.allSatisfy { $0 == "GET" }, "Partial scan mutated the controller")
    }

    private static func completedScanScope() async throws -> CompletedGlobalContext {
        let context = try setup()
        do {
            let model = context.model
            model.scanCandidates()
            try await eventually("completed global model scan") { !model.isBusy }
            try require(model.errorText == nil && model.globalScanFresh, "Successful scan did not become usable")
            try require(model.globalScan?.completedRounds == 2 && model.globalScan?.finishedAt != nil, "Model accepted an incomplete global report")
            try require(model.globalResults.count == 5 && model.stableNodes.count == 5, "Global results omitted nodes outside the current group")
            let stableNames = Set(model.stableNodes.map { $0.node.name })
            try require(stableNames.contains(GlobalModelFixture.outside) && stableNames.contains(GlobalModelFixture.outsideSecond), "Other groups' stable nodes should appear in the global list")
            try require(model.canUseGlobalNode(GlobalModelFixture.direct), "A stable direct member should allow an explicit switch")
            try require(!model.canUseGlobalNode(GlobalModelFixture.nested), "A transitive leaf cannot be selected as a direct group member")
            try require(!model.canUseGlobalNode(GlobalModelFixture.outside), "A stable node from another group cannot be directly selected here")
            try require(!model.canUseGlobalNode(GlobalModelFixture.current), "The current selection should not offer a redundant switch")
            let verbs = await context.fixture.verbs()
            try require(verbs.allSatisfy { $0 == "GET" }, "Completed scan mutated the controller")
            return context
        } catch {
            context.model.cancelOperation()
            try? FileManager.default.removeItem(at: context.directory)
            throw error
        }
    }

    private static func cachedScanRequiresRecheck(_ context: CompletedGlobalContext) async throws {
        let persisted = try Data(contentsOf: context.directory.appendingPathComponent("state.json"))
        let saved = try JSONSerialization.jsonObject(with: persisted) as? [String: Any]
        try require(saved?["globalScanInvalidated"] as? Bool == false, "Fixture did not save a completed valid scan")
        let reloaded = AppModel(autoStart: false, client: MihomoClient(transport: context.fixture), storageDirectory: context.directory)
        reloaded.settings.notificationsEnabled = false
        reloaded.settings.socketOverride = GlobalModelFixture.socket
        reloaded.snapshot = context.model.snapshot
        try require(reloaded.globalResults.count == 5, "Reload should retain cached samples for review")
        try require(!reloaded.globalScanFresh && reloaded.stableNodes.isEmpty, "Cached samples trusted the network state from the previous process")
        try require(!reloaded.canUseGlobalNode(GlobalModelFixture.direct), "Cached data authorized a new switch")
        let before = await context.fixture.requestCount()
        reloaded.switchTo(GlobalModelFixture.direct)
        try require(!reloaded.isBusy && reloaded.switchReceipt == nil, "A cached candidate began a switch transaction")
        let after = await context.fixture.requestCount()
        try require(before == after, "Rejected cached candidate should not dispatch a controller request")
        let verbs = await context.fixture.verbs()
        try require(verbs.allSatisfy { $0 == "GET" }, "Cache reload attempted a controller mutation")
    }

    private static func staleSamples() async throws {
        let context = try setup()
        defer { try? FileManager.default.removeItem(at: context.directory) }
        let model = context.model
        let client = MihomoClient(transport: context.fixture)
        model.snapshot = try await client.snapshot(socketOverride: GlobalModelFixture.socket)
        let inventory = model.snapshot!.inventory
        func nodeResult(_ name: String, at date: Date) -> GlobalNodeResult {
            let node = inventory.first { $0.name == name }!
            return GlobalNodeResult(node: node, rounds: (0..<2).map { _ in
                NodeResult(name: name, resolvedNode: name,
                           samples: [ProbeSample(latencyMS: 80), ProbeSample(latencyMS: 90)], testedAt: date)
            })
        }
        model.globalScan = GlobalScanReport(startedAt: Date().addingTimeInterval(-1300), finishedAt: Date(),
            groupCount: 3, inventory: inventory,
            results: [nodeResult(GlobalModelFixture.direct, at: Date().addingTimeInterval(-901)),
                      nodeResult(GlobalModelFixture.outside, at: Date())], completedRounds: 2)
        try require(model.globalScanFresh, "Fixture needs a fresh report completion time")
        try require(model.globalResults.count == 2, "Old raw observations should remain available for inspection")
        try require(model.stableNodes.map { $0.node.name } == [GlobalModelFixture.outside], "Fresh report completion incorrectly refreshed old node samples")
        try require(!model.canUseGlobalNode(GlobalModelFixture.direct), "A node older than fifteen minutes authorized a switch")
        let verbs = await context.fixture.verbs()
        try require(verbs.allSatisfy { $0 == "GET" }, "Old-sample check mutated the controller")
    }
}
