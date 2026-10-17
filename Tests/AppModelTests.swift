import Foundation
import Darwin

private struct ModelTestFailure: Error, CustomStringConvertible {
    var description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ModelTestFailure(description: message) }
}

/// Every request terminates here. This fixture never creates a URLSession, curl
/// process, socket, notification request, or persistent user configuration.
private actor MockMihomoTransport: MihomoTransport {
    enum Scenario {
        case snapshotFailsAfterSwitch
        case externalSelectionAlreadyChanged
        case candidateResolutionChanged
        case controllerUnavailable
        case delayedSnapshot
    }

    static let socket = "/model-test-fixture.sock"
    static let group = "ChatGPT"
    static let original = "原节点 / SG"
    static let candidate = "候选 自动组"
    static let testedLeaf = "候选叶子 一"
    static let changedLeaf = "候选叶子 二"

    private let scenario: Scenario
    private var selection = original
    private var candidateLeaf = testedLeaf
    private var requests: [MihomoRequest] = []
    private var puts = 0
    private var confirmedWrite = false
    private var failSnapshots = true
    private var snapshotHeld = true
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var activeRequests = 0

    init(_ scenario: Scenario) {
        self.scenario = scenario
        if scenario == .externalSelectionAlreadyChanged { selection = Self.candidate }
        if scenario == .candidateResolutionChanged { candidateLeaf = Self.changedLeaf }
    }

    func perform(_ request: MihomoRequest) async throws -> MihomoResponse {
        requests.append(request)
        activeRequests += 1
        defer { activeRequests -= 1 }
        guard let url = URLComponents(string: request.url) else {
            throw ModelTestFailure(description: "Mock received an invalid URL")
        }
        if request.proxyPort == nil {
            try require(request.socketPath == Self.socket, "Controller request must remain on the mock socket")
        }
        if scenario == .delayedSnapshot && snapshotHeld {
            // Ignore task cancellation until explicitly released, to exercise a
            // late transport response after the UI has already cancelled.
            await withCheckedContinuation { continuation in waiters.append(continuation) }
        }
        if scenario == .controllerUnavailable {
            throw ClientError.controller("Fixture controller is unavailable")
        }
        if scenario == .snapshotFailsAfterSwitch && failSnapshots && confirmedWrite {
            throw ClientError.controller("Fixture snapshot failed after confirmed selection")
        }
        if request.proxyPort != nil {
            try require(request.proxyPort == 7897, "Path observation must use the fixture proxy port")
            return MihomoResponse(status: 200, body: Data("ip=203.0.113.45\nloc=SG\n".utf8))
        }
        if request.method == "PUT" {
            try require(url.path == "/proxies/" + Self.group, "Only the fixture group may be selected")
            let value = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: String]
            guard let target = value?["name"] else {
                throw ModelTestFailure(description: "Mock selection is missing its structured target")
            }
            try require([Self.original, Self.candidate].contains(target), "Unexpected selection target")
            puts += 1
            selection = target
            return MihomoResponse(status: 204, body: Data())
        }
        switch url.path {
        case "/version": return try json(["version": "model-fixture"])
        case "/configs": return try json(["mixed-port": 7897, "mode": "rule"])
        case "/proxies":
            let response = try proxyMap()
            // select() reads the current selection immediately after PUT. Allow
            // that confirmation, then fail the subsequent full snapshot.
            if puts > 0 { confirmedWrite = true }
            return response
        default:
            if url.percentEncodedPath.hasPrefix("/proxies/") && url.percentEncodedPath.hasSuffix("/delay") {
                return try json(["delay": 34])
            }
            throw ModelTestFailure(description: "Unexpected mock request: \(request.method) \(url.path)")
        }
    }

    func putCount() -> Int { puts }
    func requestCount() -> Int { requests.count }
    func activeCount() -> Int { activeRequests }
    func requestedPaths() -> [String] { requests.compactMap { URLComponents(string: $0.url)?.path } }
    func permitSnapshots() { failSnapshots = false }
    func releaseSnapshot() {
        snapshotHeld = false
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    private func proxyMap() throws -> MihomoResponse {
        let map: [String: [String: Any]] = [
            Self.group: ["type": "Selector", "now": selection, "all": [Self.original, Self.candidate]],
            Self.original: ["type": "Shadowsocks"],
            Self.candidate: ["type": "URLTest", "now": candidateLeaf, "all": [Self.testedLeaf, Self.changedLeaf]],
            Self.testedLeaf: ["type": "Shadowsocks"],
            Self.changedLeaf: ["type": "Shadowsocks"]
        ]
        return try json(["proxies": map])
    }

    private func json(_ object: Any) throws -> MihomoResponse {
        MihomoResponse(status: 200, body: try JSONSerialization.data(withJSONObject: object))
    }
}

@main
@MainActor
private struct AppModelTests {
    static func main() async {
        do {
            try await run("Confirmed switch retains undo after snapshot failure", recoveryAfterSnapshotFailure)
            try await run("Preflight selection conflict never creates a receipt or PUT", externalSelectionConflict)
            try await run("Changed candidate leaf rejects the stale probe before PUT", changedCandidateResolution)
            try await run("Refresh failure replaces old healthy state with error", failedRefreshInvalidatesHealth)
            try await run("Cancellation rejects late transport results", cancellationRejectsLateResults)
            print("All AppModel tests passed. Only in-memory controller fixtures and temporary storage were used.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run(_ name: String, _ body: () async throws -> Void) async throws {
        try await body()
        print("PASS: \(name)")
    }

    private static func setup(_ fixture: MockMihomoTransport) throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-gpt-model-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let model = AppModel(autoStart: false, client: MihomoClient(transport: fixture), storageDirectory: directory)
        model.settings.group = MockMihomoTransport.group
        model.settings.socketOverride = MockMihomoTransport.socket
        model.settings.notificationsEnabled = false
        model.snapshot = ControllerSnapshot(
            socketPath: MockMihomoTransport.socket, version: "model-fixture", proxyPort: 7897, mode: "rule",
            groups: [
                ProxyGroup(name: MockMihomoTransport.group, kind: "Selector", selected: MockMihomoTransport.original,
                           members: [MockMihomoTransport.original, MockMihomoTransport.candidate]),
                ProxyGroup(name: MockMihomoTransport.candidate, kind: "URLTest", selected: MockMihomoTransport.testedLeaf,
                           members: [MockMihomoTransport.testedLeaf, MockMihomoTransport.changedLeaf])
            ],
            resolvedNodes: [MockMihomoTransport.group: MockMihomoTransport.original,
                            MockMihomoTransport.candidate: MockMihomoTransport.testedLeaf]
        )
        let current = NodeResult(name: MockMihomoTransport.original, resolvedNode: MockMihomoTransport.original,
                                 samples: [ProbeSample(latencyMS: 30), ProbeSample(latencyMS: 32), ProbeSample(latencyMS: 34)],
                                 testedAt: Date())
        let candidate = NodeResult(name: MockMihomoTransport.candidate, resolvedNode: MockMihomoTransport.testedLeaf,
                                   samples: [ProbeSample(latencyMS: 30), ProbeSample(latencyMS: 34)], testedAt: Date())
        model.report = CheckReport(checkedAt: Date().addingTimeInterval(-10), group: MockMihomoTransport.group,
                                   selection: MockMihomoTransport.original, current: current,
                                   path: PathObservation(exitIP: "203.0.113.45", httpStatus: 200, reachable: true),
                                   candidates: [candidate])
        model.status = .healthy
        return (model, directory)
    }

    /// Every wait has its own two-second deadline; a regression cannot hang CI.
    private static func eventually(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !(await condition()) {
            guard Date() < deadline else { throw ModelTestFailure(description: "Timed out: " + message) }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func recoveryAfterSnapshotFailure() async throws {
        let fixture = MockMihomoTransport(.snapshotFailsAfterSwitch)
        let (model, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.switchTo(MockMihomoTransport.candidate)
        try require(model.isSwitching, "A valid explicit selection must start a switch")
        try await eventually("confirmed switch failure should finish") { !model.isBusy }
        let writes = await fixture.putCount()
        try require(writes == 1, "One explicit switch must issue exactly one mock PUT")
        try require(model.currentGroup?.selected == MockMihomoTransport.candidate, "Confirmed target must be reflected even if the next snapshot fails")
        try require(model.status == .error, "A failed post-switch snapshot must not claim healthy")
        try require(model.switchReceipt?.previousSelection == MockMihomoTransport.original, "The original selection must remain available")
        try require(model.canUndo, "Recovery must remain available after the confirmed write's snapshot fails")

        await fixture.permitSnapshots()
        model.undoSwitch()
        try await eventually("undo should finish") { !model.isBusy }
        let writesAfterUndo = await fixture.putCount()
        try require(writesAfterUndo == 2, "Explicit undo must issue one additional mock PUT")
        try require(model.currentGroup?.selected == MockMihomoTransport.original, "Undo must restore the actual original group member")
        try require(model.switchReceipt == nil && !model.canUndo, "Successful undo must clear the recovery receipt")
        try require(model.status == .healthy, "Successful undo should complete its network recheck")
    }

    private static func externalSelectionConflict() async throws {
        let fixture = MockMihomoTransport(.externalSelectionAlreadyChanged)
        let (model, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.switchTo(MockMihomoTransport.candidate)
        try await eventually("selection conflict should finish") { !model.isBusy }
        let writes = await fixture.putCount()
        let paths = await fixture.requestedPaths()
        try require(writes == 0, "A preflight conflict must never write to the controller")
        try require(model.switchReceipt == nil, "An external selection must never be attributed to this app's failed switch")
        try require(!model.canUndo, "The app must not offer to undo another application's selection")
        try require(model.status == .error, "The conflict must replace the old healthy state")
        try require(paths == ["/proxies"], "A rejected preflight must not run uncertain-write snapshot reconciliation")
    }

    private static func changedCandidateResolution() async throws {
        let fixture = MockMihomoTransport(.candidateResolutionChanged)
        let (model, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.switchTo(MockMihomoTransport.candidate)
        try await eventually("candidate resolution conflict should finish") { !model.isBusy }
        let writes = await fixture.putCount()
        try require(writes == 0, "A candidate that now resolves to an untested node must be rejected before PUT")
        try require(model.switchReceipt == nil, "A rejected candidate must not create a recovery receipt")
        try require(model.errorText?.contains("实际节点已变化") == true, "The conflict should tell the user why candidate results are no longer valid")
    }

    private static func failedRefreshInvalidatesHealth() async throws {
        let fixture = MockMihomoTransport(.controllerUnavailable)
        let (model, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousDate = model.report?.checkedAt
        model.refresh()
        try require(model.status == .checking, "Refresh should visibly enter checking state")
        try await eventually("failed refresh should finish") { !model.isBusy }
        try require(model.status == .error, "A new failure must not leave the old report's healthy state visible")
        try require(model.report?.checkedAt == previousDate, "Last successful diagnostics should be retained as historical data")
        try require(model.errorText != nil && model.lastAttemptAt != nil, "Failure must expose an explanation and attempt time")
        let writes = await fixture.putCount()
        try require(writes == 0, "Refresh must remain read-only")
    }

    private static func cancellationRejectsLateResults() async throws {
        let fixture = MockMihomoTransport(.delayedSnapshot)
        let (model, directory) = try setup(fixture)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previousDate = model.report?.checkedAt
        model.refresh()
        try await eventually("snapshot requests should enter the mock gate") { await fixture.requestCount() == 3 }
        model.cancelOperation()
        try require(!model.isBusy && model.status == .stale, "Cancellation should immediately finish and mark retained results stale")
        try require(model.lastAttemptAt != nil, "Cancellation must record an attempt so periodic checks do not immediately restart")
        await fixture.releaseSnapshot()
        try await eventually("late mock responses should drain") { await fixture.activeCount() == 0 }
        // Let the cancelled operation return to the main actor after its three
        // structured snapshot children finish; the operation token must reject it.
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(model.report?.checkedAt == previousDate, "A late response must never replace the retained report")
        try require(model.status == .stale && !model.isBusy, "A late response must not restore healthy or restart an operation")
        let writes = await fixture.putCount()
        try require(writes == 0, "Cancellation test must not modify a proxy selection")
    }
}
