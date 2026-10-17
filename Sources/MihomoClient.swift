import Foundation
import Darwin

enum ClientError: LocalizedError {
    case disconnected(String)
    case controller(String)
    case group(String)
    case selectionChanged(String)
    case writeUncertain(String)

    var errorDescription: String? {
        switch self {
        case .disconnected(let detail): return "无法连接 Clash Verge：\(detail)"
        case .controller(let detail): return "控制接口返回异常：\(detail)"
        case .group(let detail): return detail
        case .selectionChanged(let detail): return "策略组已发生变化：\(detail)。请重新检测。"
        case .writeUncertain(let detail): return "切换结果尚未确认：\(detail)。请刷新当前选择后再操作。"
        }
    }
}

/// This small boundary also allows deterministic fixtures without a live proxy.
struct MihomoRequest: Sendable {
    var url: String
    var socketPath: String? = nil
    var proxyPort: Int? = nil
    var method = "GET"
    var body: Data? = nil
    var timeout: TimeInterval = 4
    var maximumBytes = 2 * 1_024 * 1_024
}

struct MihomoResponse: Sendable {
    var status: Int
    var body: Data
}

protocol MihomoTransport: Sendable {
    func perform(_ request: MihomoRequest) async throws -> MihomoResponse
}

struct MihomoClient: Sendable {
    private let transport: any MihomoTransport
    private let probeURL = "https://chatgpt.com/cdn-cgi/trace"

    init(transport: any MihomoTransport = EfficientMihomoTransport()) {
        self.transport = transport
    }

    func snapshot(socketOverride: String = "") async throws -> ControllerSnapshot {
        let override = socketOverride.trimmingCharacters(in: .whitespacesAndNewlines)
        let paths: [String]
        if !override.isEmpty {
            paths = [(override as NSString).expandingTildeInPath]
        } else {
            paths = [
                "/var/run/clash-verge-service/users/\(getuid())/verge-mihomo.sock",
                "/tmp/verge-mihomo.sock",
                NSHomeDirectory() + "/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/verge-mihomo.sock"
            ].filter { FileManager.default.fileExists(atPath: $0) }
        }
        guard !paths.isEmpty else {
            throw ClientError.disconnected("未发现本机控制套接字，请启动 Clash Verge，或在设置中填写套接字路径。")
        }

        var lastError: Error = ClientError.disconnected("控制套接字不可用。")
        for path in paths {
            do {
                async let version = object(path: "/version", socket: path)
                async let configuration = object(path: "/configs", socket: path)
                async let proxies = proxyMap(socket: path)
                let (versionObject, configObject, map) = try await (version, configuration, proxies)
                let mixedPort = integer(configObject["mixed-port"]) ?? 0
                let httpPort = integer(configObject["port"]) ?? 0
                return ControllerSnapshot(
                    socketPath: path,
                    version: versionObject["version"] as? String ?? "未知版本",
                    proxyPort: validPort(mixedPort) ? mixedPort : (validPort(httpPort) ? httpPort : 0),
                    mode: configObject["mode"] as? String ?? "unknown",
                    groups: groups(in: map),
                    resolvedNodes: resolutions(in: map),
                    inventory: Self.nodeInventory(in: map)
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// Refreshes live selections without repeating version and configuration
    /// requests. The controller connection settings remain those already found.
    func selectionSnapshot(snapshot: ControllerSnapshot) async throws -> ControllerSnapshot {
        let map = try await proxyMap(socket: snapshot.socketPath)
        return ControllerSnapshot(
            socketPath: snapshot.socketPath, version: snapshot.version,
            proxyPort: snapshot.proxyPort, mode: snapshot.mode,
            groups: groups(in: map), resolvedNodes: resolutions(in: map),
            inventory: Self.nodeInventory(in: map)
        )
    }

    func check(
        snapshot: ControllerSnapshot,
        group: String,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> CheckReport {
        guard let expected = snapshot.group(named: group) else {
            throw ClientError.group("未找到策略组“\(group)”，请在设置中重新选择。")
        }
        await progress("确认策略组与当前节点…")
        let initial = try await stableGroup(snapshot: snapshot, expected: expected)
        let resolved = resolve(group, in: initial.map)
        guard !initial.group.selected.isEmpty else {
            throw ClientError.group("策略组“\(group)”没有当前选择，暂时无法检测。")
        }

        // These two paths are deliberately independent: the local HTTP proxy's
        // routing rules need not send the trace request through this group.
        async let path = observePath(port: snapshot.proxyPort)
        var samples: [ProbeSample] = []
        for index in 0..<3 {
            try Task.checkCancellation()
            await progress("检测当前节点 \(index + 1)/3…")
            samples.append(try await probe(name: resolved, socket: snapshot.socketPath))
            if index < 2 { try await Task.sleep(nanoseconds: 400_000_000) }
        }
        if samples.allSatisfy({ $0.latencyMS == nil }) {
            await progress("首次连接失败，稍后复核…")
            try await Task.sleep(nanoseconds: 800_000_000)
            for index in 0..<2 {
                await progress("复核当前节点 \(index + 1)/2…")
                samples.append(try await probe(name: resolved, socket: snapshot.socketPath))
                if index == 0 { try await Task.sleep(nanoseconds: 400_000_000) }
            }
        }

        let observedPath = try await path
        await progress("核对检测期间的策略组选择…")
        let final = try await stableGroup(snapshot: snapshot, expected: initial.group)
        guard resolve(group, in: final.map) == resolved else {
            throw ClientError.selectionChanged("“\(group)”的实际节点在检测期间发生了变化")
        }
        return CheckReport(
            checkedAt: Date(), group: group, selection: initial.group.selected,
            current: NodeResult(name: initial.group.selected, resolvedNode: resolved,
                                samples: samples, testedAt: Date()),
            path: observedPath
        )
    }

    func candidates(
        snapshot: ControllerSnapshot,
        group: String,
        progress: @escaping @Sendable (String) async -> Void
    ) async throws -> [NodeResult] {
        guard let expected = snapshot.group(named: group) else {
            throw ClientError.group("未找到策略组“\(group)”。")
        }
        let initial = try await stableGroup(snapshot: snapshot, expected: expected)
        var seen = Set<String>()
        let excluded: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS"]
        let members = Array(initial.group.members.filter {
            $0 != initial.group.selected && !excluded.contains($0.uppercased()) && seen.insert($0).inserted
        }.prefix(12))
        var results: [NodeResult] = []

        // At most three requests run simultaneously; a large subscription cannot
        // flood the controller or local network.
        for offset in stride(from: 0, to: members.count, by: 3) {
            try Task.checkCancellation()
            let batch = Array(members[offset..<min(offset + 3, members.count)])
            await progress("检测候选 \(offset + 1)–\(offset + batch.count)/\(members.count)…")
            let batchResults = try await withThrowingTaskGroup(of: NodeResult.self) { tasks in
                for name in batch {
                    let resolved = resolve(name, in: initial.map)
                    tasks.addTask {
                        var samples: [ProbeSample] = []
                        for index in 0..<2 {
                            samples.append(try await self.probe(name: name, socket: snapshot.socketPath))
                            if index == 0 { try await Task.sleep(nanoseconds: 300_000_000) }
                        }
                        return NodeResult(name: name, resolvedNode: resolved,
                                          samples: samples, testedAt: Date())
                    }
                }
                var output: [NodeResult] = []
                for try await result in tasks { output.append(result) }
                return output
            }
            results.append(contentsOf: batchResults)
        }
        let final = try await stableGroup(snapshot: snapshot, expected: initial.group)
        guard resolve(group, in: final.map) == resolve(group, in: initial.map) else {
            throw ClientError.selectionChanged("“\(group)”的实际节点在候选检测期间发生了变化")
        }
        return results.map { result in
            guard resolve(result.name, in: final.map) == result.resolvedNode else {
                return NodeResult(name: result.name, resolvedNode: resolve(result.name, in: final.map),
                                  samples: [ProbeSample(latencyMS: nil, error: "该候选在检测期间更换了实际节点，请重新检测。")],
                                  testedAt: result.testedAt)
            }
            return result
        }.sorted {
            if $0.successes != $1.successes { return $0.successes > $1.successes }
            if $0.medianMS != $1.medianMS { return ($0.medianMS ?? Int.max) < ($1.medianMS ?? Int.max) }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Samples every real leaf reachable from every strategy group. Looking up
    /// a leaf's delay never changes a group's current selection or local rules.
    func scanAll(
        snapshot: ControllerSnapshot,
        progress: @escaping @Sendable (String) async -> Void,
        partial: @escaping @Sendable (GlobalScanReport) async -> Void
    ) async throws -> GlobalScanReport {
        try await scan(snapshot: snapshot, scope: .allGroups, group: nil,
                       progress: progress, partial: partial)
    }

    /// Tests this group's direct members. Nested groups contribute only their
    /// current real node, keeping a focused scan independent of subscription size.
    func scanCurrentGroup(
        snapshot: ControllerSnapshot,
        group: String,
        progress: @escaping @Sendable (String) async -> Void,
        partial: @escaping @Sendable (GlobalScanReport) async -> Void
    ) async throws -> GlobalScanReport {
        try await scan(snapshot: snapshot, scope: .currentGroup, group: group,
                       progress: progress, partial: partial)
    }

    private func scan(
        snapshot: ControllerSnapshot,
        scope: ScanScope,
        group: String?,
        progress: @escaping @Sendable (String) async -> Void,
        partial: @escaping @Sendable (GlobalScanReport) async -> Void
    ) async throws -> GlobalScanReport {
        let label = scope == .currentGroup ? "当前组扫描" : "全组扫描"
        func inventory(in map: [String: [String: Any]]) -> [NodeInventoryEntry] {
            if let group { return Self.currentGroupInventory(in: map, group: group) }
            return Self.nodeInventory(in: map)
        }
        try Task.checkCancellation()
        await progress(scope == .currentGroup ? "读取当前代理组与节点…" : "读取所有代理组与节点…")
        let initialMap = try await proxyMap(socket: snapshot.socketPath)
        if let group, initialMap[group]?["all"] as? [String] == nil {
            throw ClientError.group("未找到策略组“\(group)”，请在设置中重新选择。")
        }
        let initialInventory = inventory(in: initialMap)
        guard !initialInventory.isEmpty else {
            throw ClientError.group(scope == .currentGroup
                ? "当前代理组中未发现可检测的代理节点，请检查策略组的成员与当前选择。"
                : "所有代理组中均未发现可检测的代理节点，请检查 Clash Verge 的订阅与配置。")
        }
        var report = GlobalScanReport(
            startedAt: Date(), finishedAt: nil,
            groupCount: scope == .currentGroup ? 1 : groups(in: initialMap).count,
            inventory: initialInventory, results: [], completedRounds: 0,
            scope: scope, groupName: group
        )
        var resultsByName: [String: GlobalNodeResult] = [:]
        var invalidatedNames = Set<String>()
        var newNames = Set<String>()
        let initialNames = Set(initialInventory.map(\.name))
        await partial(report)

        for round in 1...2 {
            try Task.checkCancellation()
            let entries = initialInventory.filter { !invalidatedNames.contains($0.name) }
            for offset in stride(from: 0, to: entries.count, by: 3) {
                try Task.checkCancellation()
                let batch = Array(entries[offset..<min(offset + 3, entries.count)])
                await progress("\(label) 第\(round)/2轮 · \(offset)/\(entries.count)节点 · 最多3并发")
                let batchResults = try await withThrowingTaskGroup(of: NodeResult.self) { tasks in
                    for node in batch {
                        tasks.addTask {
                            var samples: [ProbeSample] = []
                            for index in 0..<2 {
                                try Task.checkCancellation()
                                samples.append(try await self.probe(name: node.name, socket: snapshot.socketPath))
                                if index == 0 { try await Task.sleep(nanoseconds: 400_000_000) }
                            }
                            return NodeResult(name: node.name, resolvedNode: node.name,
                                              samples: samples, testedAt: Date())
                        }
                    }
                    var output: [NodeResult] = []
                    for try await result in tasks { output.append(result) }
                    return output
                }
                try Task.checkCancellation()
                for result in batchResults {
                    guard let node = batch.first(where: { $0.name == result.name }) else { continue }
                    if var previous = resultsByName[result.name] {
                        previous.rounds.append(result)
                        resultsByName[result.name] = previous
                    } else {
                        resultsByName[result.name] = GlobalNodeResult(node: node, rounds: [result])
                    }
                }
                report.results = initialInventory.compactMap { resultsByName[$0.name] }
                await progress("\(label) 第\(round)/2轮 · \(offset + batch.count)/\(entries.count)节点 · 最多3并发")
                await partial(report)
            }

            // Re-evaluate the same scope: nested selections may change which
            // leaves belong to a current-group scan while it is in progress.
            try Task.checkCancellation()
            await progress("核对第\(round)轮节点清单…")
            let currentInventory = inventory(in: try await proxyMap(socket: snapshot.socketPath))
            let currentByName = Dictionary(uniqueKeysWithValues: currentInventory.map { ($0.name, $0) })
            for node in initialInventory where currentByName[node.name] != node {
                invalidatedNames.insert(node.name)
                resultsByName.removeValue(forKey: node.name)
            }
            newNames.formUnion(Set(currentByName.keys).subtracting(initialNames))
            report.results = initialInventory.compactMap { resultsByName[$0.name] }
            report.completedRounds = round
            await partial(report)
            if round == 1 {
                let update = newNames.isEmpty ? "" : " · 新增\(newNames.count)个节点，重扫后纳入"
                await progress("第一轮完成，2秒后复测\(update)")
                try await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        try Task.checkCancellation()
        report.finishedAt = Date()
        var summary = "\(label)完成 · \(report.results.count)/\(initialInventory.count)节点"
        if !invalidatedNames.isEmpty { summary += " · \(invalidatedNames.count)个节点已变化，需重扫" }
        if !newNames.isEmpty { summary += " · 新增\(newNames.count)个节点，重扫后纳入" }
        await progress(summary)
        await partial(report)
        return report
    }

    /// Resolves only `now` for a nested group, never that group's full `all`
    /// tree. A cycle, absent member, or group without a current leaf is skipped.
    static func currentGroupInventory(in map: [String: [String: Any]], group: String) -> [NodeInventoryEntry] {
        guard var members = map[group]?["all"] as? [String] else { return [] }
        if let selected = map[group]?["now"] as? String, !selected.isEmpty {
            members.append(selected)
        }
        let inventory = Dictionary(uniqueKeysWithValues: nodeInventory(in: map).map { ($0.name, $0) })
        func currentLeaf(_ name: String) -> String? {
            var current = name
            var seen = Set<String>()
            while seen.insert(current).inserted {
                guard let value = map[current] else { return nil }
                if value["all"] == nil { return inventory[current] == nil ? nil : current }
                guard let next = value["now"] as? String, !next.isEmpty else { return nil }
                current = next
            }
            return nil
        }
        let names = Set(members.compactMap { currentLeaf($0) })
        return names.compactMap { inventory[$0] }.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    /// Enumerates group membership rather than following `now`, so nested
    /// selectors, URL-test groups and repeated subscription nodes are covered.
    /// Pure and internal so fixtures can verify cycles and unusual node names.
    static func nodeInventory(in map: [String: [String: Any]]) -> [NodeInventoryEntry] {
        let groupedMembers = map.compactMapValues { $0["all"] as? [String] }
        let excludedKinds: Set<String> = ["direct", "reject", "rejectdrop", "pass", "dns", "compatible"]
        let groupKinds: Set<String> = ["selector", "urltest", "fallback", "loadbalance", "relay"]
        func normalized(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        func leafKind(_ name: String) -> String? {
            guard let value = map[name], value["all"] == nil else { return nil }
            let kind = value["type"] as? String ?? "Unknown"
            guard !excludedKinds.contains(normalized(kind)),
                  !groupKinds.contains(normalized(kind)),
                  !(kind == "Unknown" && excludedKinds.contains(normalized(name))) else { return nil }
            return kind
        }
        var memberships: [String: Set<String>] = [:]
        var directSelectors: [String: Set<String>] = [:]
        for (group, members) in groupedMembers {
            if (map[group]?["type"] as? String)?.lowercased() == "selector" {
                for member in members where leafKind(member) != nil {
                    directSelectors[member, default: []].insert(group)
                }
            }
            var visitedGroups = Set<String>()
            var pending = [group]
            while let current = pending.popLast() {
                guard visitedGroups.insert(current).inserted else { continue }
                for member in groupedMembers[current] ?? [] {
                    if groupedMembers[member] != nil {
                        if !visitedGroups.contains(member) { pending.append(member) }
                    } else if leafKind(member) != nil {
                        memberships[member, default: []].insert(group)
                    }
                }
            }
        }
        func ordered(_ names: Set<String>) -> [String] {
            names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
        return memberships.compactMap { name, groups in
            guard let kind = leafKind(name) else { return nil }
            return NodeInventoryEntry(name: name, kind: kind, groups: ordered(groups),
                                      selectableGroups: ordered(directSelectors[name] ?? []))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Called only following an explicit user selection. No probe calls this.
    func select(snapshot: ControllerSnapshot, group: String, target: String, expectedSelection: String,
                expectedResolvedNode: String? = nil) async throws {
        guard let expected = snapshot.group(named: group), expected.canSelect else {
            throw ClientError.group("只有 Selector 策略组支持手动切换。")
        }
        guard expected.members.contains(target) else {
            throw ClientError.group("“\(target)”不是“\(group)”的可选成员。")
        }
        let map = try await proxyMap(socket: snapshot.socketPath)
        guard let current = groups(in: map).first(where: { $0.name == group }), current.canSelect else {
            throw ClientError.group("“\(group)”已不可用，或不再支持手动切换。")
        }
        guard current.selected == expectedSelection else {
            throw ClientError.selectionChanged("当前选择为“\(current.selected)”，与界面显示的“\(expectedSelection)”不同")
        }
        guard current.members.contains(target) else {
            throw ClientError.group("“\(target)”已从“\(group)”中移除。")
        }
        if let expectedResolvedNode, resolve(target, in: map) != expectedResolvedNode {
            throw ClientError.selectionChanged("候选“\(target)”的实际节点已变化，之前的检测结果不再适用")
        }
        if current.selected == target { return }
        let data = try JSONSerialization.data(withJSONObject: ["name": target])
        try Task.checkCancellation()
        let response: MihomoResponse
        do {
            response = try await controller(MihomoRequest(
                url: "http://localhost/proxies/" + component(group), socketPath: snapshot.socketPath,
                method: "PUT", body: data, timeout: 4
            ))
        } catch {
            // Once dispatched, a failed transport cannot establish whether the
            // controller applied the request before the response was lost.
            throw ClientError.writeUncertain("切换请求发出后未取得完整响应")
        }
        guard (200..<300).contains(response.status) else {
            throw ClientError.controller("切换失败，HTTP \(response.status)。")
        }
        let selectedMap: [String: [String: Any]]
        do { selectedMap = try await proxyMap(socket: snapshot.socketPath) }
        catch { throw ClientError.writeUncertain("控制接口已接受切换，但无法读取当前选择") }
        guard let selected = groups(in: selectedMap).first(where: { $0.name == group }), selected.selected == target else {
            throw ClientError.writeUncertain("控制接口已接受请求，但当前选择与“\(target)”不一致")
        }
    }

    private func stableGroup(snapshot: ControllerSnapshot, expected: ProxyGroup) async throws -> (group: ProxyGroup, map: [String: [String: Any]]) {
        let map = try await proxyMap(socket: snapshot.socketPath)
        guard let current = groups(in: map).first(where: { $0.name == expected.name }) else {
            throw ClientError.group("策略组“\(expected.name)”已不存在，请重新选择。")
        }
        guard current.selected == expected.selected else {
            throw ClientError.selectionChanged("“\(expected.name)”已从“\(expected.selected)”变为“\(current.selected)”")
        }
        return (current, map)
    }

    private func probe(name: String, socket: String) async throws -> ProbeSample {
        var url = URLComponents(string: "http://localhost/proxies/" + component(name) + "/delay")!
        url.queryItems = [URLQueryItem(name: "url", value: probeURL), URLQueryItem(name: "timeout", value: "4000")]
        do {
            let response = try await controller(MihomoRequest(url: url.string!, socketPath: socket, timeout: 4.6))
            guard (200..<300).contains(response.status) else {
                return ProbeSample(latencyMS: nil, error: "目标探测失败（HTTP \(response.status)）")
            }
            let value = try JSONSerialization.jsonObject(with: response.body) as? [String: Any]
            guard let delay = integer(value?["delay"]), delay >= 0 else {
                return ProbeSample(latencyMS: nil, error: "控制接口未返回有效延迟")
            }
            return ProbeSample(latencyMS: delay, error: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ProbeSample(latencyMS: nil, error: brief(error.localizedDescription))
        }
    }

    private func observePath(port: Int) async throws -> PathObservation {
        guard validPort(port) else {
            return PathObservation(exitIP: nil, httpStatus: nil, reachable: false,
                                   error: "未发现可用的本地 HTTP 代理端口。")
        }
        do {
            let response = try await transport.perform(MihomoRequest(
                url: probeURL, proxyPort: port, timeout: 8, maximumBytes: 64 * 1_024
            ))
            let body = String(data: response.body, encoding: .utf8) ?? ""
            let fields = body.split(whereSeparator: \.isNewline).reduce(into: [String: String]()) { result, line in
                let pair = line.split(separator: "=", maxSplits: 1)
                if pair.count == 2 { result[String(pair[0])] = String(pair[1]) }
            }
            let ip = fields["ip"].flatMap { validIPAddress($0) ? $0 : nil }
            let reachable = (200..<300).contains(response.status)
            return PathObservation(exitIP: ip, httpStatus: response.status, reachable: reachable,
                                   error: reachable ? (ip == nil ? "目标可达，但未取得有效出口 IP。" : nil) : "目标返回 HTTP \(response.status)。")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return PathObservation(exitIP: nil, httpStatus: nil, reachable: false,
                                   error: brief(error.localizedDescription))
        }
    }

    private func controller(_ request: MihomoRequest) async throws -> MihomoResponse {
        do { return try await transport.perform(request) }
        catch is CancellationError { throw CancellationError() }
        catch let error as ClientError { throw error }
        catch { throw ClientError.disconnected(brief(error.localizedDescription)) }
    }

    private func object(path: String, socket: String) async throws -> [String: Any] {
        let response = try await controller(MihomoRequest(url: "http://localhost" + path, socketPath: socket))
        guard (200..<300).contains(response.status) else {
            throw ClientError.controller("\(path) 返回 HTTP \(response.status)。")
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                throw ClientError.controller("\(path) 的数据格式无法识别。")
            }
            return object
        } catch let error as ClientError { throw error }
        catch { throw ClientError.controller("\(path) 没有返回有效的 JSON 数据。") }
    }

    private func proxyMap(socket: String) async throws -> [String: [String: Any]] {
        let value = try await object(path: "/proxies", socket: socket)
        guard let proxies = value["proxies"] as? [String: [String: Any]] else {
            throw ClientError.controller("未返回节点列表。")
        }
        return proxies
    }

    private func groups(in map: [String: [String: Any]]) -> [ProxyGroup] {
        map.compactMap { name, value -> ProxyGroup? in
            guard let members = value["all"] as? [String] else { return nil }
            return ProxyGroup(name: name, kind: value["type"] as? String ?? "Unknown",
                              selected: value["now"] as? String ?? "", members: members)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func resolutions(in map: [String: [String: Any]]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: map.keys.map { ($0, resolve($0, in: map)) })
    }

    private func resolve(_ name: String, in map: [String: [String: Any]]) -> String {
        var current = name
        var seen = Set<String>()
        while seen.insert(current).inserted,
              let next = map[current]?["now"] as? String, !next.isEmpty, next != current {
            current = next
        }
        return current
    }

    private func component(_ value: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        return number.intValue
    }

    private func validPort(_ port: Int) -> Bool { (1...65535).contains(port) }
    private func brief(_ value: String) -> String { String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(240)) }

    private func validIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return value.withCString { inet_pton(AF_INET, $0, &ipv4) == 1 || inet_pton(AF_INET6, $0, &ipv6) == 1 }
    }
}

struct CurlMihomoTransport: MihomoTransport {
    func perform(_ request: MihomoRequest) async throws -> MihomoResponse {
        let marker = "\n__VPN_ASSISTANT_HTTP_STATUS__"
        var arguments = [
            "--silent", "--show-error", "--noproxy", "",
            "--connect-timeout", "2", "--max-time", String(request.timeout),
            "--request", request.method, "--write-out", marker + "%{http_code}"
        ]
        if let socket = request.socketPath {
            arguments += ["--unix-socket", socket, "--proxy", ""]
        } else if let port = request.proxyPort {
            arguments += ["--proxy", "http://127.0.0.1:\(port)"]
        } else {
            arguments += ["--proxy", ""]
        }
        if let body = request.body {
            guard let json = String(data: body, encoding: .utf8) else {
                throw ClientError.controller("请求体不是 UTF-8。")
            }
            arguments += ["--header", "Content-Type: application/json", "--data-binary", json]
        }
        arguments += ["--url", request.url]
        let runner = BoundedProcessRunner(arguments: arguments, timeout: request.timeout + 0.4,
                                          maximumBytes: request.maximumBytes + 128)
        let output = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await runner.run()
        }, onCancel: { runner.cancel() })
        guard output.status == 0 else {
            throw CurlFailure(message: output.error.isEmpty ? "curl 连接失败（\(output.status)）。" : output.error)
        }
        let markerData = Data(marker.utf8)
        guard let range = output.data.range(of: markerData, options: .backwards),
              let statusText = String(data: output.data[range.upperBound...], encoding: .utf8),
              let status = Int(statusText), status > 0 else {
            throw CurlFailure(message: "未取得 HTTP 响应状态。")
        }
        let body = Data(output.data[..<range.lowerBound])
        guard body.count <= request.maximumBytes else {
            throw CurlFailure(message: "控制接口返回内容超出大小限制。")
        }
        return MihomoResponse(status: status, body: body)
    }
}

private struct CurlFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}

/// Pipes are drained on separate queues. Cancellation and the wall-clock timeout
/// terminate curl, escalate after 300 ms, and resume only once both pipes close.
private final class BoundedProcessRunner: @unchecked Sendable {
    struct Output {
        var status: Int32
        var data: Data
        var error: String
    }
    private let arguments: [String]
    private let timeout: TimeInterval
    private let maximumBytes: Int
    private let process = Process()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Output, Error>?
    private var output = Data()
    private var errorOutput = Data()
    private var failure: Error?
    private var finished = false
    private var launched = false
    private var timer: DispatchWorkItem?

    init(arguments: [String], timeout: TimeInterval, maximumBytes: Int) {
        self.arguments = arguments
        self.timeout = timeout
        self.maximumBytes = maximumBytes
    }

    func run() async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            let stdout = Pipe()
            let stderr = Pipe()
            let drains = DispatchGroup()
            drains.enter()
            drains.enter()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            // Do not inherit a user's .curlrc, which could change routing or add
            // unexpected credentials. -q must be curl's first argument.
            process.arguments = ["-q"] + arguments
            process.terminationHandler = { [self] _ in
                drains.notify(queue: .global(qos: .utility)) { self.complete() }
            }

            lock.lock()
            self.continuation = continuation
            if let failure {
                finished = true
                self.continuation = nil
                process.terminationHandler = nil
                lock.unlock()
                try? stdout.fileHandleForReading.close()
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForReading.close()
                try? stderr.fileHandleForWriting.close()
                continuation.resume(throwing: failure)
                return
            }
            do {
                try process.run()
                launched = true
                lock.unlock()
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForWriting.close()
                DispatchQueue.global(qos: .utility).async { [self] in
                    drain(stdout.fileHandleForReading, isError: false)
                    drains.leave()
                }
                DispatchQueue.global(qos: .utility).async { [self] in
                    drain(stderr.fileHandleForReading, isError: true)
                    drains.leave()
                }
                let timeoutItem = DispatchWorkItem { [self] in stop(CurlFailure(message: "连接超时，请检查代理是否可用。")) }
                lock.lock()
                if !finished { timer = timeoutItem }
                let shouldSchedule = !finished
                lock.unlock()
                if shouldSchedule { DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timeoutItem) }
            } catch {
                finished = true
                self.continuation = nil
                process.terminationHandler = nil
                lock.unlock()
                try? stdout.fileHandleForReading.close()
                try? stdout.fileHandleForWriting.close()
                try? stderr.fileHandleForReading.close()
                try? stderr.fileHandleForWriting.close()
                continuation.resume(throwing: error)
            }
        }
    }

    func cancel() { stop(CancellationError()) }

    private func stop(_ reason: Error) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        if failure == nil { failure = reason }
        let running = launched && process.isRunning
        if running { process.terminate() }
        lock.unlock()
        if running {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [self] in
                lock.lock()
                if !finished && launched && process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
                lock.unlock()
            }
        }
    }

    private func drain(_ handle: FileHandle, isError: Bool) {
        defer { try? handle.close() }
        do {
            while let chunk = try handle.read(upToCount: 32 * 1_024), !chunk.isEmpty {
                lock.lock()
                let limit = isError ? 16 * 1_024 : maximumBytes
                let count = isError ? errorOutput.count : output.count
                if isError { errorOutput.append(chunk.prefix(max(0, limit - count))) }
                else { output.append(chunk.prefix(max(0, limit - count))) }
                let overflow = count + chunk.count > limit
                lock.unlock()
                if overflow { stop(CurlFailure(message: "控制接口返回内容超出大小限制。")) }
            }
        } catch { stop(CurlFailure(message: "读取控制接口响应失败。")) }
    }

    private func complete() {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        process.terminationHandler = nil
        timer?.cancel()
        timer = nil
        let failure = failure
        let result = Output(status: process.terminationStatus, data: output,
                            error: String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
        self.continuation = nil
        lock.unlock()
        if let failure { continuation.resume(throwing: failure) }
        else { continuation.resume(returning: result) }
    }
}
