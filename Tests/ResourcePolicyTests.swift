import Combine
import Darwin
import Foundation

private struct ResourcePolicyFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw ResourcePolicyFailure(description: message) }
}

/// Owns every request. The suite cannot reach a live controller, HTTP proxy,
/// notification service, or the user's saved application state.
private actor ResourceFixture: MihomoTransport {
    static let socket = "/resource-policy-fixture.sock"
    static let group = "节点选择"
    static let nodes = (0..<15).map { "资源测试节点 \($0)" }

    struct Metrics: Equatable {
        var requests = 0
        var versions = 0
        var proxyReads = 0
        var probes = 0
    }

    private var selected = ResourceFixture.nodes[0]
    private var metrics = Metrics()

    func select(_ name: String) { selected = name }
    func counts() -> Metrics { metrics }

    func perform(_ request: MihomoRequest) async throws -> MihomoResponse {
        try require(request.method == "GET", "A resource test attempted to modify a controller")
        try require(request.socketPath == Self.socket && request.proxyPort == nil,
                    "A request escaped the isolated resource fixture")
        metrics.requests += 1
        guard let url = URLComponents(string: request.url) else {
            throw ResourcePolicyFailure(description: "Invalid fixture URL")
        }
        switch url.path {
        case "/version":
            metrics.versions += 1
            return try json(["version": "resource-policy-fixture"])
        case "/configs": return try json(["mixed-port": 0, "mode": "rule"])
        case "/proxies":
            metrics.proxyReads += 1
            var map: [String: [String: Any]] = [
                Self.group: ["type": "Selector", "all": Self.nodes, "now": selected]
            ]
            for name in Self.nodes { map[name] = ["type": "Trojan"] }
            return try json(["proxies": map])
        default:
            let path = url.percentEncodedPath
            guard path.hasPrefix("/proxies/"), path.hasSuffix("/delay"),
                  let name = String(path.dropFirst("/proxies/".count).dropLast("/delay".count)).removingPercentEncoding,
                  Self.nodes.contains(name) else {
                throw ResourcePolicyFailure(description: "Unexpected fixture request: \(request.url)")
            }
            metrics.probes += 1
            try await Task.sleep(nanoseconds: 2_000_000)
            return try json(["delay": 80])
        }
    }

    private func json(_ value: Any) throws -> MihomoResponse {
        MihomoResponse(status: 200, body: try JSONSerialization.data(withJSONObject: value))
    }
}

@MainActor
private struct ResourceContext {
    let model: AppModel
    let fixture: ResourceFixture
    let directory: URL

    func cleanUp() {
        model.cancelOperation()
        model.setPanelVisible(false)
        try? FileManager.default.removeItem(at: directory)
    }
}

private struct SavedFileVersion: Equatable {
    var modifiedAt: Date?
    var inode: UInt64?
    var contents: Data

    init?(at url: URL) {
        guard let contents = try? Data(contentsOf: url),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        self.contents = contents
        modifiedAt = attributes[.modificationDate] as? Date
        inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}

@main
@MainActor
private struct ResourcePolicyTests {
    static func main() async {
        do {
            try await unchangedPollsDoNotPublish()
            print("PASS: Unchanged selection polls publish nothing; external changes still update the actual node")
            try await scansThrottleDiskWrites()
            print("PASS: Many scan batches produce at most four observed state writes and preserve the completed report")
            try await panelVisibilityPolicy()
            print("PASS: Closing stays quiet; opening synchronizes and starts one stale-candidate scan")
            print("All resource policy tests passed. Only mock GET requests and temporary storage were used.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func setup() async throws -> ResourceContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-gpt-resource-policy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = ResourceFixture()
        let client = MihomoClient(transport: fixture)
        let model = AppModel(autoStart: false, client: client, storageDirectory: directory)
        model.settings.group = ResourceFixture.group
        model.settings.socketOverride = ResourceFixture.socket
        model.settings.notificationsEnabled = false
        model.settings.scanScope = .currentGroup
        model.snapshot = try await client.snapshot(socketOverride: ResourceFixture.socket)
        return ResourceContext(model: model, fixture: fixture, directory: directory)
    }

    private static func unchangedPollsDoNotPublish() async throws {
        let context = try await setup()
        defer { context.cleanUp() }
        let model = context.model
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        defer { subscription.cancel() }
        let before = await context.fixture.counts()
        for _ in 0..<8 { await model.pollSelectionNow() }
        let after = await context.fixture.counts()
        try require(after.proxyReads - before.proxyReads == 8,
                    "The poll fixture did not actually exercise eight controller reads")
        try require(publications == 0, "Unchanged controller reads triggered \(publications) model publications")
        try require(after.versions == before.versions,
                    "Selection-only polling needlessly refreshed controller metadata")
        await context.fixture.select(ResourceFixture.nodes[1])
        await model.pollSelectionNow()
        try require(publications > 0, "An external node change did not publish a UI update")
        try require(model.currentGroup?.selected == ResourceFixture.nodes[1] &&
                    model.snapshot?.resolvedNodes[ResourceFixture.group] == ResourceFixture.nodes[1],
                    "External switching no longer updates both the logical selection and actual node")
    }

    private static func scansThrottleDiskWrites() async throws {
        let context = try await setup()
        defer { context.cleanUp() }
        let model = context.model
        var scanPublications = 0
        let subscription = model.$globalScan.dropFirst().sink { _ in scanPublications += 1 }
        defer { subscription.cancel() }
        let file = context.directory.appendingPathComponent("state.json")
        var previous: SavedFileVersion?
        var observedWrites = 0
        func observeFile() {
            guard let current = SavedFileVersion(at: file), current != previous else { return }
            observedWrites += 1
            previous = current
        }
        model.scanCandidates()
        let deadline = Date().addingTimeInterval(12)
        while model.isBusy {
            observeFile()
            try require(Date() < deadline, "Timed out waiting for a 15-node two-round fixture scan")
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        observeFile()
        try require(model.errorText == nil && model.globalScanFresh, "The fixture scan failed or stayed unusable")
        try require(scanPublications >= 14,
                    "Insufficient scan updates to exercise the disk throttle: \(scanPublications)")
        try require(observedWrites > 0 && observedWrites <= 4,
                    "Scan state was written \(observedWrites) times for \(scanPublications) updates")
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        let scan = saved?["globalScan"] as? [String: Any]
        let results = scan?["results"] as? [[String: Any]]
        try require(scan?["completedRounds"] as? Int == 2 && scan?["finishedAt"] != nil,
                    "The final completed scan was not persisted")
        try require(results?.count == ResourceFixture.nodes.count && saved?["globalScanInvalidated"] as? Bool == false,
                    "Throttling lost final node results or their validated state")
        let counts = await context.fixture.counts()
        try require(counts.probes == ResourceFixture.nodes.count * 4,
                    "The write-throttle test did not finish all four probes per node")
        print("  Scan evidence: \(scanPublications) report updates, \(observedWrites) observed file writes, \(counts.probes) probes")
    }

    private static func panelVisibilityPolicy() async throws {
        let context = try await setup()
        defer { context.cleanUp() }
        let model = context.model
        let before = await context.fixture.counts()
        model.setPanelVisible(false)
        try await Task.sleep(nanoseconds: 50_000_000)
        let closed = await context.fixture.counts()
        try require(closed == before && !model.isBusy,
                    "A hidden panel immediately dispatched work or started a scan")
        model.setPanelVisible(true)
        try require(model.isScanning, "Opening a panel with no valid candidates did not start a scan")
        let deadline = Date().addingTimeInterval(2)
        var opening = await context.fixture.counts()
        while opening.probes == 0 {
            try require(Date() < deadline, "Opening did not immediately synchronize and probe candidates")
            try await Task.sleep(nanoseconds: 2_000_000)
            opening = await context.fixture.counts()
        }
        try require(opening.proxyReads >= before.proxyReads + 3,
                    "Panel opening did not include an immediate selection sync alongside scan reads")
        model.setPanelVisible(true)
        model.setPanelVisible(true)
        model.scanCandidates()
        try await Task.sleep(nanoseconds: 50_000_000)
        let busy = await context.fixture.counts()
        try require(busy.versions == before.versions + 1,
                    "Repeated opens or scan clicks started more than one full scan while busy")
        model.setPanelVisible(false)
        let closing = await context.fixture.counts()
        try await Task.sleep(nanoseconds: 50_000_000)
        let afterClosing = await context.fixture.counts()
        try require(afterClosing == closing, "Closing the panel immediately dispatched extra requests")
    }
}
