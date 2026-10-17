import Foundation

enum ScanScope: String, Codable, CaseIterable {
    case currentGroup, allGroups
    var title: String { self == .currentGroup ? "当前代理组" : "全部代理组" }
}

struct AppSettings: Codable, Equatable {
    var group = "节点选择"
    var intervalMinutes = 5
    var notificationsEnabled = true
    var notifyOnRecovery = false
    var socketOverride = ""
    var scanScope: ScanScope = .currentGroup

    init() { }

    private enum CodingKeys: String, CodingKey {
        case group, intervalMinutes, notificationsEnabled, notifyOnRecovery, socketOverride, scanScope
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        group = try values.decodeIfPresent(String.self, forKey: .group) ?? "节点选择"
        intervalMinutes = try values.decodeIfPresent(Int.self, forKey: .intervalMinutes) ?? 5
        notificationsEnabled = try values.decodeIfPresent(Bool.self, forKey: .notificationsEnabled) ?? true
        notifyOnRecovery = try values.decodeIfPresent(Bool.self, forKey: .notifyOnRecovery) ?? false
        socketOverride = try values.decodeIfPresent(String.self, forKey: .socketOverride) ?? ""
        scanScope = try values.decodeIfPresent(ScanScope.self, forKey: .scanScope) ?? .currentGroup
    }
}

struct ProxyGroup: Codable, Identifiable, Equatable {
    var name: String
    var kind: String
    var selected: String
    var members: [String]
    var id: String { name }
    var canSelect: Bool { kind.lowercased() == "selector" }
}

struct ControllerSnapshot: Codable, Equatable {
    var socketPath: String
    var version: String
    var proxyPort: Int
    var mode: String
    var groups: [ProxyGroup]
    var resolvedNodes: [String: String]
    var inventory: [NodeInventoryEntry] = []
    func group(named name: String) -> ProxyGroup? { groups.first { $0.name == name } }
}

struct NodeInventoryEntry: Codable, Identifiable, Equatable {
    var name: String
    var kind: String
    var groups: [String]
    var selectableGroups: [String]
    var id: String { name }
}

struct GlobalNodeResult: Codable, Identifiable, Equatable {
    var node: NodeInventoryEntry
    var rounds: [NodeResult]
    var id: String { node.name }
    var samples: [ProbeSample] { rounds.flatMap(\.samples) }
    var successes: Int { samples.filter { $0.latencyMS != nil }.count }
    var summary: NodeResult {
        NodeResult(name: node.name, resolvedNode: node.name, samples: samples,
                   testedAt: rounds.last?.testedAt ?? .distantPast)
    }
    var medianMS: Int? { summary.medianMS }
    var jitterMS: Int? {
        let values = samples.compactMap(\.latencyMS)
        guard let minimum = values.min(), let maximum = values.max(), values.count >= 2 else { return nil }
        return maximum - minimum
    }
    var isStable: Bool {
        guard rounds.count >= 2, rounds.allSatisfy({ $0.samples.count >= 2 }),
              samples.count >= 4, successes == samples.count,
              let medianMS, let jitterMS else { return false }
        return jitterMS <= max(1000, medianMS * 3 / 4)
    }
    var stabilityLabel: String {
        if rounds.count < 2 { return rounds.isEmpty ? "待检测" : "待复核" }
        if successes != samples.count { return successes == 0 ? "不可达" : "有失败" }
        return isStable ? "本轮稳定" : "波动较大"
    }
}

struct GlobalScanReport: Codable {
    var startedAt: Date
    var finishedAt: Date?
    var groupCount: Int
    var inventory: [NodeInventoryEntry]
    var results: [GlobalNodeResult]
    var completedRounds: Int
    var scope: ScanScope? = nil
    var groupName: String? = nil
    var stableResults: [GlobalNodeResult] {
        guard finishedAt != nil, completedRounds >= 2 else { return [] }
        return results.filter(\.isStable).sorted {
            if $0.jitterMS != $1.jitterMS { return ($0.jitterMS ?? Int.max) < ($1.jitterMS ?? Int.max) }
            if $0.medianMS != $1.medianMS { return ($0.medianMS ?? Int.max) < ($1.medianMS ?? Int.max) }
            return $0.node.name.localizedStandardCompare($1.node.name) == .orderedAscending
        }
    }
}

struct ProbeSample: Codable, Equatable {
    var latencyMS: Int?
    var error: String?
}

struct NodeResult: Codable, Identifiable, Equatable {
    var name: String
    var resolvedNode: String
    var samples: [ProbeSample]
    var testedAt: Date
    var id: String { name }
    var successes: Int { samples.filter { $0.latencyMS != nil }.count }
    var medianMS: Int? {
        let values = samples.compactMap(\.latencyMS).sorted()
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return values[middle - 1] + (values[middle] - values[middle - 1]) / 2
        }
        return values[middle]
    }
    var passes: Bool { successes >= max(1, samples.count - 1) }
}

struct PathObservation: Codable, Equatable {
    var exitIP: String?
    var httpStatus: Int?
    var reachable: Bool
    var error: String?
}

struct CheckReport: Codable {
    var checkedAt: Date
    var group: String
    var selection: String
    var current: NodeResult
    var path: PathObservation
    var candidates: [NodeResult] = []
}

enum HealthStatus: String, Codable {
    case unknown, checking, healthy, degraded, unreachable, disconnected, error, stale
    var title: String {
        switch self {
        case .unknown: return "等待检测"
        case .checking: return "正在检测"
        case .healthy: return "网络可达"
        case .degraded: return "连接不稳定"
        case .unreachable: return "目标不可达"
        case .disconnected: return "代理未连接"
        case .error: return "检测未完成"
        case .stale: return "结果已过期"
        }
    }
    var symbol: String {
        switch self {
        case .unknown: return "circle.dotted"
        case .checking: return "arrow.trianglehead.2.clockwise.rotate.90"
        case .healthy: return "checkmark.shield.fill"
        case .degraded: return "exclamationmark.triangle.fill"
        case .unreachable: return "xmark.shield.fill"
        case .disconnected: return "network.slash"
        case .error: return "exclamationmark.circle.fill"
        case .stale: return "clock.badge.exclamationmark"
        }
    }
    static func evaluate(_ report: CheckReport) -> HealthStatus {
        if report.current.successes == 0 && !report.path.reachable { return .unreachable }
        if !report.current.passes || !report.path.reachable { return .degraded }
        return .healthy
    }
}

struct SwitchReceipt: Codable {
    var group: String
    var previousSelection: String
    var newSelection: String
    var switchedAt: Date
}

struct EventEntry: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var title: String
    var detail: String
}
