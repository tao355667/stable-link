import Foundation
import Darwin

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure(description: message) }
}

private actor ControllerFixture: MihomoTransport {
    let groupName: String
    let initialSelection = "嵌套 组 🌏"
    let leaf = "🇸🇬 叶子 / ?+#%"
    let members = (1...15).map { "备用 \($0) / 节点✅ ?+#%" }
    var selection: String
    var groupKind = "Selector"
    var requests: [MihomoRequest] = []
    var proxyReads = 0
    var mutateAtRead: Int?
    var failFirstThree = false
    var delayCalls = 0
    var activeDelays = 0
    var maximumActiveDelays = 0
    var putStatus = 204
    var confirmSwitch = true
    var nestedLeaf = "🇸🇬 叶子 / ?+#%"
    var failPutTransport = false
    var failReadback = false
    var failProxyReads = false

    init(groupName: String = "ChatGPT / 测试?#%+") {
        self.groupName = groupName
        self.selection = "嵌套 组 🌏"
    }

    func configure(selection: String? = nil, kind: String? = nil, failFirstThree: Bool = false,
                   mutateAtRead: Int? = nil, putStatus: Int = 204, confirmSwitch: Bool = true,
                   nestedLeaf: String? = nil, failPutTransport: Bool = false,
                   failReadback: Bool = false, failProxyReads: Bool = false) {
        if let selection { self.selection = selection }
        if let kind { self.groupKind = kind }
        self.failFirstThree = failFirstThree
        self.mutateAtRead = mutateAtRead
        self.putStatus = putStatus
        self.confirmSwitch = confirmSwitch
        if let nestedLeaf { self.nestedLeaf = nestedLeaf }
        self.failPutTransport = failPutTransport
        self.failReadback = failReadback
        self.failProxyReads = failProxyReads
    }

    func perform(_ request: MihomoRequest) async throws -> MihomoResponse {
        try Task.checkCancellation()
        requests.append(request)
        guard let components = URLComponents(string: request.url) else {
            throw TestFailure(description: "Fixture received an invalid URL")
        }
        if request.proxyPort != nil {
            try expect(request.socketPath == nil, "Trace must use the local HTTP proxy, independent of node probes")
            try expect(request.proxyPort == 7897, "Trace used the wrong HTTP proxy port")
            return MihomoResponse(status: 200, body: Data("ip=203.0.113.7\nloc=SG\n".utf8))
        }
        try expect(request.socketPath == "/fixture.sock", "Controller request must use the selected Unix socket")
        switch components.path {
        case "/version": return try json(["version": "fixture"])
        case "/configs": return try json(["mixed-port": 7897, "mode": "rule"])
        case "/proxies":
            if failProxyReads || (failReadback && requests.contains(where: { $0.method == "PUT" })) {
                throw ClientError.controller("Simulated fixture read failure")
            }
            proxyReads += 1
            if let mutateAtRead, proxyReads >= mutateAtRead { selection = members[0] }
            var proxies: [String: [String: Any]] = [
                groupName: ["type": groupKind, "now": selection, "all": ["DIRECT", "REJECT", initialSelection] + members],
                initialSelection: ["type": "Selector", "now": "第二层 / 组", "all": ["第二层 / 组"]],
                "第二层 / 组": ["type": "Selector", "now": nestedLeaf, "all": [nestedLeaf]],
                nestedLeaf: ["type": "Shadowsocks"]
            ]
            for member in members { proxies[member] = ["type": "Shadowsocks"] }
            return try json(["proxies": proxies])
        default: break
        }
        let encodedPath = components.percentEncodedPath
        if request.method == "PUT" {
            if failPutTransport { throw URLError(.timedOut) }
            try expect(components.path == "/proxies/" + groupName, "Switch URL did not preserve the complete group name")
            try expect(!encodedPath.dropFirst("/proxies/".count).contains("/"), "Slash in a group name must be percent encoded")
            let object = try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: String]
            guard let target = object?["name"] else { throw TestFailure(description: "Switch body must contain a structured name") }
            if (200..<300).contains(putStatus) && confirmSwitch { selection = target }
            return MihomoResponse(status: putStatus, body: Data())
        }
        if encodedPath.hasPrefix("/proxies/"), encodedPath.hasSuffix("/delay") {
            let encodedName = String(encodedPath.dropFirst("/proxies/".count).dropLast("/delay".count))
            try expect(!encodedName.contains("/"), "Slash in a node name must not create another URL path segment")
            guard let name = encodedName.removingPercentEncoding else { throw TestFailure(description: "Invalid percent encoding") }
            try expect(name == leaf || members.contains(name), "Probe did not preserve a complete direct member or resolved leaf")
            try expect(components.queryItems?.first(where: { $0.name == "timeout" })?.value == "4000", "Node timeout was not forwarded")
            try expect(components.queryItems?.first(where: { $0.name == "url" })?.value == "https://chatgpt.com/cdn-cgi/trace", "Target URL was not encoded as one query item")
            delayCalls += 1
            let shouldFail = failFirstThree && delayCalls <= 3
            activeDelays += 1
            maximumActiveDelays = max(maximumActiveDelays, activeDelays)
            do { try await Task.sleep(nanoseconds: 20_000_000) }
            catch { activeDelays -= 1; throw error }
            activeDelays -= 1
            if shouldFail { return try json(["message": "timeout"], status: 504) }
            let delay = members.firstIndex(of: name).map { ($0 + 1) * 10 } ?? 35
            return try json(["delay": delay])
        }
        throw TestFailure(description: "Unexpected fixture request: \(request.method) \(components.path)")
    }

    private func json(_ value: Any, status: Int = 200) throws -> MihomoResponse {
        MihomoResponse(status: status, body: try JSONSerialization.data(withJSONObject: value))
    }

    func verbs() -> [String] { requests.map(\.method) }
    func putCount() -> Int { requests.filter { $0.method == "PUT" }.count }
    func delayConcurrency() -> Int { maximumActiveDelays }
}

/// This server is isolated to loopback, uses an ephemeral port, and never
/// connects to Clash. It exercises the real curl process cancellation paths.
private final class LoopbackServer {
    let process = Process()
    let port: Int
    private let lifetime = Pipe()

    init() throws {
        let script = #"""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlsplit
import time
import sys
import threading
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == '/slow': time.sleep(5)
        self.send_response(200)
        self.end_headers()
        body = b'x' * (1024 * 1024) if path == '/huge' else b'body\n__VPN_ASSISTANT_HTTP_STATUS__123'
        try: self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError): pass
server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
server.daemon_threads = True
threading.Thread(target=lambda: (sys.stdin.buffer.read(), server.shutdown()), daemon=True).start()
print(server.server_port, flush=True)
server.serve_forever()
"""#
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", script]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = lifetime
        try process.run()
        try lifetime.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        var data = Data()
        while data.count < 32, let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            data.append(byte)
            if byte.first == 10 { break }
        }
        try output.fileHandleForReading.close()
        guard let text = String(data: data, encoding: .utf8),
              let port = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            if process.isRunning { process.terminate() }
            throw TestFailure(description: "Local transport fixture did not start")
        }
        self.port = port
    }

    deinit {
        try? lifetime.fileHandleForWriting.close()
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }
}

@main
private struct EngineTests {
    static func main() async {
        do {
            try await run("Read-only diagnostics and special-character nested groups", readOnlyCheck)
            try await run("Retry sample accounting", retryAccounting)
            try await run("Bounded direct-member candidate detection", candidateChecks)
            try await run("Selection changes invalidate diagnostics", selectionChange)
            try await run("Explicit switch safety with mock PUT only", switchChecks)
            try await run("Candidate resolution conflicts and uncertain write outcomes", switchUncertaintyChecks)
            try await run("Real curl proxy routing, output bound, cancellation and timeout", transportChecks)
            print("All engine tests passed. No live controller PUT requests were made.")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run(_ name: String, _ test: () async throws -> Void) async throws {
        try await test()
        print("PASS: \(name)")
    }

    private static func setup(_ fixture: ControllerFixture) async throws -> (MihomoClient, ControllerSnapshot) {
        let client = MihomoClient(transport: fixture)
        return (client, try await client.snapshot(socketOverride: "/fixture.sock"))
    }

    private static func readOnlyCheck() async throws {
        let fixture = ControllerFixture()
        let (client, snapshot) = try await setup(fixture)
        try expect(snapshot.version == "fixture" && snapshot.proxyPort == 7897, "Controller snapshot was parsed incorrectly")
        try expect(snapshot.resolvedNodes[fixture.groupName] == fixture.leaf, "Multiple nested groups were not resolved")
        let report = try await client.check(snapshot: snapshot, group: fixture.groupName) { _ in }
        try expect(report.current.successes == 3 && report.current.passes, "Healthy probes did not pass")
        try expect(report.current.resolvedNode == fixture.leaf, "Node results must refer to the recursively resolved node")
        try expect(report.path.reachable && report.path.exitIP == "203.0.113.7", "Independent path observation was lost")
        // A trace observation is kept in its own field. NodeResult intentionally
        // has no exit-IP field: the routing rule can send trace elsewhere.
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report.current)) as! [String: Any]
        try expect(encoded["exitIP"] == nil, "A path IP must not be attributed to the probed node")
        let verbs = await fixture.verbs()
        try expect(verbs.allSatisfy { $0 == "GET" }, "Default diagnostics must never mutate controller state")
    }

    private static func retryAccounting() async throws {
        let fixture = ControllerFixture()
        await fixture.configure(failFirstThree: true)
        let (client, snapshot) = try await setup(fixture)
        let report = try await client.check(snapshot: snapshot, group: fixture.groupName) { _ in }
        try expect(report.current.samples.count == 5, "Rechecks must retain the initial three failed samples")
        try expect(report.current.successes == 2 && !report.current.passes, "Two later successes must not hide three initial failures")
    }

    private static func candidateChecks() async throws {
        let fixture = ControllerFixture()
        let (client, snapshot) = try await setup(fixture)
        let results = try await client.candidates(snapshot: snapshot, group: fixture.groupName) { _ in }
        try expect(results.count == 12, "Candidate detection must cap work at twelve direct members")
        try expect(Set(results.map(\.name)) == Set(fixture.members.prefix(12)), "Candidates must be selectable direct members")
        try expect(results.allSatisfy { $0.samples.count == 2 && $0.successes == 2 }, "Each candidate needs two samples")
        try expect(results.compactMap(\.medianMS) == results.compactMap(\.medianMS).sorted(), "Equal-success candidates must sort by latency")
        let maximum = await fixture.delayConcurrency()
        try expect(maximum <= 3 && maximum > 1, "Candidate probes must run concurrently with a maximum of three")
        let writes = await fixture.putCount()
        try expect(writes == 0, "Candidate testing must never switch nodes")
    }

    private static func selectionChange() async throws {
        let fixture = ControllerFixture()
        await fixture.configure(mutateAtRead: 3)
        let (client, snapshot) = try await setup(fixture)
        do {
            _ = try await client.check(snapshot: snapshot, group: fixture.groupName) { _ in }
            throw TestFailure(description: "Changed selection must invalidate a check")
        } catch ClientError.selectionChanged { }
    }

    private static func switchUncertaintyChecks() async throws {
        let changedCandidate = ControllerFixture()
        await changedCandidate.configure(selection: changedCandidate.members[0])
        let (changedClient, changedSnapshot) = try await setup(changedCandidate)
        await changedCandidate.configure(nestedLeaf: "外部更改的实际节点")
        do {
            try await changedClient.select(snapshot: changedSnapshot, group: changedCandidate.groupName,
                                           target: changedCandidate.initialSelection,
                                           expectedSelection: changedCandidate.members[0],
                                           expectedResolvedNode: changedCandidate.leaf)
            throw TestFailure(description: "A candidate whose resolved node changed must reject the switch")
        } catch ClientError.selectionChanged { }
        let changedWrites = await changedCandidate.putCount()
        try expect(changedWrites == 0, "Changed candidate resolution must be rejected before any PUT")

        let lostWriteResponse = ControllerFixture()
        await lostWriteResponse.configure(failPutTransport: true)
        let (lostClient, lostSnapshot) = try await setup(lostWriteResponse)
        do {
            try await lostClient.select(snapshot: lostSnapshot, group: lostWriteResponse.groupName,
                                        target: lostWriteResponse.members[0], expectedSelection: lostWriteResponse.initialSelection)
            throw TestFailure(description: "Transport failure after PUT dispatch must be uncertain")
        } catch ClientError.writeUncertain { }

        let lostReadback = ControllerFixture()
        await lostReadback.configure(failReadback: true)
        let (lostReadClient, lostReadSnapshot) = try await setup(lostReadback)
        do {
            try await lostReadClient.select(snapshot: lostReadSnapshot, group: lostReadback.groupName,
                                            target: lostReadback.members[0], expectedSelection: lostReadback.initialSelection)
            throw TestFailure(description: "Readback failure after accepted PUT must be uncertain")
        } catch ClientError.writeUncertain { }

        let failedPreflight = ControllerFixture()
        let (preflightClient, preflightSnapshot) = try await setup(failedPreflight)
        await failedPreflight.configure(failProxyReads: true)
        do {
            try await preflightClient.select(snapshot: preflightSnapshot, group: failedPreflight.groupName,
                                             target: failedPreflight.members[0], expectedSelection: failedPreflight.initialSelection)
            throw TestFailure(description: "Failed preflight must reject the switch without uncertainty")
        } catch ClientError.controller { }
        let preflightWrites = await failedPreflight.putCount()
        try expect(preflightWrites == 0, "Read failure before dispatch must issue zero PUT requests")
    }

    private static func switchChecks() async throws {
        let stale = ControllerFixture()
        let (staleClient, staleSnapshot) = try await setup(stale)
        await stale.configure(selection: stale.members[0])
        do {
            try await staleClient.select(snapshot: staleSnapshot, group: stale.groupName, target: stale.members[1], expectedSelection: stale.initialSelection)
            throw TestFailure(description: "Stale selection must reject the switch")
        } catch ClientError.selectionChanged { }
        let staleWrites = await stale.putCount()
        try expect(staleWrites == 0, "A conflict discovered before writing must issue zero PUT requests")

        let rejected = ControllerFixture()
        await rejected.configure(putStatus: 500)
        let (rejectedClient, rejectedSnapshot) = try await setup(rejected)
        do {
            try await rejectedClient.select(snapshot: rejectedSnapshot, group: rejected.groupName, target: rejected.members[0], expectedSelection: rejected.initialSelection)
            throw TestFailure(description: "Non-2xx switch status must fail")
        } catch ClientError.controller { }

        let unconfirmed = ControllerFixture()
        await unconfirmed.configure(confirmSwitch: false)
        let (unconfirmedClient, unconfirmedSnapshot) = try await setup(unconfirmed)
        do {
            try await unconfirmedClient.select(snapshot: unconfirmedSnapshot, group: unconfirmed.groupName, target: unconfirmed.members[0], expectedSelection: unconfirmed.initialSelection)
            throw TestFailure(description: "Mismatched read-back must fail")
        } catch ClientError.writeUncertain { }

        let automatic = ControllerFixture()
        await automatic.configure(kind: "URLTest")
        let (automaticClient, automaticSnapshot) = try await setup(automatic)
        do {
            try await automaticClient.select(snapshot: automaticSnapshot, group: automatic.groupName, target: automatic.members[0], expectedSelection: automatic.initialSelection)
            throw TestFailure(description: "Automatic groups cannot be explicitly selected")
        } catch ClientError.group { }
        let automaticWrites = await automatic.putCount()
        try expect(automaticWrites == 0, "Non-selector groups must never receive PUT requests")

        let valid = ControllerFixture()
        let (client, snapshot) = try await setup(valid)
        do {
            try await client.select(snapshot: snapshot, group: valid.groupName, target: valid.leaf, expectedSelection: valid.initialSelection)
            throw TestFailure(description: "A nested leaf cannot be selected as a direct member")
        } catch ClientError.group { }
        try await client.select(snapshot: snapshot, group: valid.groupName, target: valid.members[0], expectedSelection: valid.initialSelection)
        let validWrites = await valid.putCount()
        try expect(validWrites == 1, "One explicit successful selection must make exactly one mock PUT")
    }

    private static func transportChecks() async throws {
        let server = try LoopbackServer()
        let transport = CurlMihomoTransport()
        let base = "http://127.0.0.1:\(server.port)"
        let fast = try await transport.perform(MihomoRequest(url: base + "/fast"))
        try expect(fast.status == 200 && String(data: fast.body, encoding: .utf8) == "body\n__VPN_ASSISTANT_HTTP_STATUS__123", "Body/status separation must preserve marker-like body content")

        let previousUpper = ProcessInfo.processInfo.environment["NO_PROXY"]
        let previousLower = ProcessInfo.processInfo.environment["no_proxy"]
        setenv("NO_PROXY", "*", 1)
        setenv("no_proxy", "*", 1)
        defer {
            if let previousUpper { setenv("NO_PROXY", previousUpper, 1) } else { unsetenv("NO_PROXY") }
            if let previousLower { setenv("no_proxy", previousLower, 1) } else { unsetenv("no_proxy") }
            withExtendedLifetime(server) { }
        }
        let proxied = try await transport.perform(MihomoRequest(url: "http://127.0.0.1:1/fast", proxyPort: server.port))
        try expect(proxied.status == 200, "Explicit local HTTP proxy must override NO_PROXY")
        do {
            _ = try await transport.perform(MihomoRequest(url: base + "/huge", maximumBytes: 128))
            throw TestFailure(description: "Oversized response must fail")
        } catch let error as TestFailure { throw error }
        catch { try expect(error.localizedDescription.contains("大小限制"), "Expected an output-limit error") }

        let cancellationStart = Date()
        let task = Task { try await transport.perform(MihomoRequest(url: base + "/slow", timeout: 4)) }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do {
            _ = try await task.value
            throw TestFailure(description: "Cancelled request must throw CancellationError")
        } catch is CancellationError { }
        try expect(Date().timeIntervalSince(cancellationStart) < 2, "Cancellation did not terminate curl promptly")

        let timeoutStart = Date()
        do {
            _ = try await transport.perform(MihomoRequest(url: base + "/slow", timeout: 0.3))
            throw TestFailure(description: "Slow request must time out")
        } catch let error as TestFailure { throw error }
        catch { try expect(Date().timeIntervalSince(timeoutStart) < 2, "Timeout did not bound process lifetime") }
    }
}
