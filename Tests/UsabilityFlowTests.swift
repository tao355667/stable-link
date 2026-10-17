import Foundation
import Darwin

private struct UsabilityFailure: Error, CustomStringConvertible {
    let description: String
}

private func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw UsabilityFailure(description: message) }
}

/// The fixture owns every controller request. Even the explicit switch and
/// undo stay in memory; no socket, curl process or real proxy is ever used.
private actor UsabilityFixture: MihomoTransport {
    static let socket = "/usability-flow-fixture.sock"
    static let group = "节点选择"
    static let otherGroup = "其他代理组"
    static let original = "日本-优化2"
    static let alternate = "稳定备用 / 🇸🇬"
    static let automatic = "自动选择"
    static let nested = "嵌套实际节点"
    static let outside = "其他组节点"

    private var selected = original
    private var requests: [MihomoRequest] = []
    private var writes: [(String, String)] = []
    private var heldProbeName: String?
    private var heldProbes: [CheckedContinuation<Void, Never>] = []

    private var map: [String: [String: Any]] {
        [
            Self.group: ["type": "Selector", "all": [Self.original, Self.alternate, Self.automatic], "now": selected],
            Self.automatic: ["type": "URLTest", "all": [Self.nested], "now": Self.nested],
            Self.otherGroup: ["type": "Selector", "all": [Self.outside], "now": Self.outside],
            Self.original: ["type": "Trojan"], Self.alternate: ["type": "Trojan"],
            Self.nested: ["type": "VMess"], Self.outside: ["type": "Shadowsocks"]
        ]
    }

    func perform(_ request: MihomoRequest) async throws -> MihomoResponse {
        requests.append(request)
        try require(request.socketPath == Self.socket && request.proxyPort == nil,
                    "A usability request escaped the in-memory controller boundary")
        guard let url = URLComponents(string: request.url) else {
            throw UsabilityFailure(description: "Invalid fixture URL")
        }
        if request.method == "PUT" {
            try require(url.path == "/proxies/" + Self.group, "Only the explicitly selected group may be changed")
            let object = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: String]
            guard let name = object?["name"], [Self.original, Self.alternate].contains(name) else {
                throw UsabilityFailure(description: "Unexpected switch target")
            }
            writes.append((Self.group, name))
            selected = name
            return MihomoResponse(status: 204, body: Data())
        }
        try require(request.method == "GET", "Unexpected fixture request method")
        switch url.path {
        case "/version": return try json(["version": "usability-fixture"])
        case "/configs": return try json(["mixed-port": 0, "mode": "rule"])
        case "/proxies": return try json(["proxies": map])
        default:
            let encoded = url.percentEncodedPath
            guard encoded.hasPrefix("/proxies/"), encoded.hasSuffix("/delay"),
                  let name = String(encoded.dropFirst("/proxies/".count).dropLast("/delay".count)).removingPercentEncoding,
                  map[name] != nil else {
                throw UsabilityFailure(description: "Unexpected fixture request: \(request.url)")
            }
            if name == heldProbeName {
                await withCheckedContinuation { heldProbes.append($0) }
            }
            return try json(["delay": 85])
        }
    }

    private func json(_ value: Any) throws -> MihomoResponse {
        MihomoResponse(status: 200, body: try JSONSerialization.data(withJSONObject: value))
    }

    func writtenTargets() -> [String] { writes.map { $0.1 } }
    func writtenGroups() -> [String] { writes.map { $0.0 } }
    func verbs() -> [String] { requests.map(\.method) }
    func holdCurrentProbe() { heldProbeName = Self.original }
    func holdAlternateProbe() { heldProbeName = Self.alternate }
    func currentProbeIsHeld() -> Bool { !heldProbes.isEmpty }
    func releaseCurrentProbes() {
        heldProbeName = nil
        let pending = heldProbes
        heldProbes.removeAll()
        pending.forEach { $0.resume() }
    }
}

@MainActor
private struct UsabilityContext {
    let model: AppModel
    let fixture: UsabilityFixture
    let directory: URL
}

@main
@MainActor
private struct UsabilityFlowTests {
    static func main() async {
        do {
            try await run("Home candidates contain only stable, selectable alternatives and stay visible while busy", candidateRows)
            try await run("Clicking a stable alternative switches once, rechecks, and can restore the previous node", directSwitchAndUndo)
            try await run("Changing the monitored group cancels old checks, isolates cached data, and never changes Clash", monitoredGroup)
            print("All usability flow tests passed. Only in-memory controller requests and temporary storage were used.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run(_ name: String, _ body: () async throws -> Void) async throws {
        try await body()
        print("PASS: \(name)")
    }

    private static func setup(scope: ScanScope = .currentGroup) async throws -> UsabilityContext {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-gpt-usability-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = UsabilityFixture()
        let client = MihomoClient(transport: fixture)
        let model = AppModel(autoStart: false, client: client, storageDirectory: directory)
        try require(model.settings.group == UsabilityFixture.group, "Default helper group must be the main selector")
        model.settings.socketOverride = UsabilityFixture.socket
        model.settings.notificationsEnabled = false
        model.settings.scanScope = scope
        model.snapshot = try await client.snapshot(socketOverride: UsabilityFixture.socket)
        return UsabilityContext(model: model, fixture: fixture, directory: directory)
    }

    private static func eventually(_ message: String, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(12)
        while !(await condition()) {
            try require(Date() < deadline, "Timed out: " + message)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func completeScan(_ model: AppModel) async throws {
        model.scanCandidates()
        try await eventually("complete two-round scan") { !model.isBusy }
        try require(model.errorText == nil && model.globalScanFresh, "Fixture scan did not produce fresh stable results")
        try require(model.globalScan?.completedRounds == 2 && model.stableNodes.allSatisfy { $0.samples.count == 4 },
                    "Stable alternatives must have two rounds and four passing samples")
    }

    private static func candidateRows() async throws {
        let context = try await setup(scope: .allGroups)
        let model = context.model
        defer { model.cancelOperation(); try? FileManager.default.removeItem(at: context.directory) }
        try await completeScan(model)
        try require(Set(model.stableNodes.map { $0.node.name }) ==
                    [UsabilityFixture.original, UsabilityFixture.alternate, UsabilityFixture.nested, UsabilityFixture.outside],
                    "All-group fixture should include current, nested, and unrelated stable nodes")
        try require(model.switchableStableNodes.map { $0.node.name } == [UsabilityFixture.alternate],
                    "Home offered the current node, a transitive leaf, or a node from another group")
        try require(model.canUseGlobalNode(UsabilityFixture.alternate), "Stable direct alternative must enable switching")
        model.isChecking = true
        try require(model.switchableStableNodes.map { $0.node.name } == [UsabilityFixture.alternate],
                    "Checking should disable controls without making candidate rows disappear")
        try require(!model.canUseGlobalNode(UsabilityFixture.alternate), "Busy controls allowed a second operation")
        model.isChecking = false
        let verbs = await context.fixture.verbs()
        try require(verbs.allSatisfy { $0 == "GET" }, "Discovering stable alternatives changed a controller selection")
    }

    private static func directSwitchAndUndo() async throws {
        let context = try await setup()
        let model = context.model
        defer { model.cancelOperation(); try? FileManager.default.removeItem(at: context.directory) }
        try await completeScan(model)
        try require(model.switchableStableNodes.map { $0.node.name } == [UsabilityFixture.alternate],
                    "The initial home screen did not expose its direct stable alternative")
        await context.fixture.holdAlternateProbe()
        model.switchTo(UsabilityFixture.alternate)
        try require(model.isSwitching, "Clicking a valid stable row did not begin a switch")
        try await eventually("confirmed switch's held recheck") { await context.fixture.currentProbeIsHeld() }
        try require(model.currentGroup?.selected == UsabilityFixture.alternate && model.report == nil,
                    "A switched node displayed the previous node's health during recheck")
        try require(model.hasUndoSelection && !model.canUndo,
                    "Recovery should remain visible while its action waits for recheck to finish")
        try require(model.switchingTarget == UsabilityFixture.alternate,
                    "The selected row lost its visible switching target during recheck")
        await context.fixture.releaseCurrentProbes()
        try await eventually("switch and post-switch recheck") { !model.isBusy }
        let firstTargets = await context.fixture.writtenTargets()
        try require(firstTargets == [UsabilityFixture.alternate],
                    "One user selection must issue exactly one PUT")
        try require(model.currentGroup?.selected == UsabilityFixture.alternate &&
                    model.snapshot?.resolvedNodes[UsabilityFixture.group] == UsabilityFixture.alternate,
                    "Confirmed switch did not update the displayed logical and actual node")
        try require(model.report?.selection == UsabilityFixture.alternate &&
                    model.report?.current.resolvedNode == UsabilityFixture.alternate &&
                    model.report?.current.samples.count == 3,
                    "The switched node's current-health card did not receive its own recheck")
        try require(model.switchReceipt?.previousSelection == UsabilityFixture.original && model.canUndo,
                    "The switch lost its original node recovery action")
        try require(!model.switchableStableNodes.contains { $0.node.name == UsabilityFixture.alternate },
                    "The newly current node was still offered as an alternative")
        model.undoSwitch()
        try await eventually("restore and post-restore recheck") { !model.isBusy }
        let finalTargets = await context.fixture.writtenTargets()
        let finalGroups = await context.fixture.writtenGroups()
        try require(finalTargets == [UsabilityFixture.alternate, UsabilityFixture.original],
                    "Restore must add precisely one PUT for the original node")
        try require(finalGroups == [UsabilityFixture.group, UsabilityFixture.group],
                    "Switch or restore changed an unrelated proxy group")
        try require(model.currentGroup?.selected == UsabilityFixture.original &&
                    model.report?.selection == UsabilityFixture.original,
                    "Restore did not refresh the original node's selection and health")
        try require(model.switchReceipt == nil && !model.canUndo, "Successful restore did not clear its recovery action")
    }

    private static func monitoredGroup() async throws {
        let context = try await setup()
        let model = context.model
        defer { model.cancelOperation(); try? FileManager.default.removeItem(at: context.directory) }
        try await completeScan(model)
        model.report = CheckReport(checkedAt: Date(), group: UsabilityFixture.group, selection: UsabilityFixture.original,
            current: NodeResult(name: UsabilityFixture.original, resolvedNode: UsabilityFixture.original,
                                samples: [ProbeSample(latencyMS: 85)], testedAt: Date()),
            path: PathObservation(exitIP: nil, httpStatus: nil, reachable: false))
        await context.fixture.holdCurrentProbe()
        model.refresh()
        try await eventually("original group's held health check") { await context.fixture.currentProbeIsHeld() }
        model.setPanelVisible(true)
        model.setMonitoredGroup(UsabilityFixture.otherGroup)
        try require(model.settings.group == UsabilityFixture.otherGroup &&
                    model.currentGroup?.selected == UsabilityFixture.outside,
                    "Choosing a monitored group did not immediately display its real selection")
        try require(model.report == nil && model.globalScan == nil && model.switchableStableNodes.isEmpty,
                    "Changing group displayed the previous group's health or cached alternatives")
        await context.fixture.releaseCurrentProbes()
        try await eventually("new group's check and focused scan") {
            !model.isBusy && model.report?.group == UsabilityFixture.otherGroup && model.globalScanFresh
        }
        try require(model.report?.selection == UsabilityFixture.outside &&
                    model.report?.current.resolvedNode == UsabilityFixture.outside,
                    "The cancelled old check overwrote the new group's actual node")
        try require(model.globalScan?.groupName == UsabilityFixture.otherGroup &&
                    model.globalResults.map { $0.node.name } == [UsabilityFixture.outside],
                    "New group reused or mixed the old group's focused scan")
        let saved = try JSONDecoder().decode(AppSettings.self,
            from: Data(contentsOf: context.directory.appendingPathComponent("settings.json")))
        try require(saved.group == UsabilityFixture.otherGroup, "Monitoring-group preference was not saved")
        let verbs = await context.fixture.verbs()
        try require(verbs.allSatisfy { $0 == "GET" }, "Changing the helper's monitored group issued a Clash selection PUT")
    }
}
