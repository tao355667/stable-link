import AppKit
import SwiftUI

private enum PanelTab: String, CaseIterable {
    case connectivity = "连通性", exit = "出口", history = "记录"
}

private enum NodeFilter: CaseIterable {
    case stable, all
}

private struct ProbeBars: View {
    var result: NodeResult?
    var fresh = true
    private var count: Int {
        guard fresh, let result, !result.samples.isEmpty else { return 0 }
        return Int(ceil(Double(result.successes) / Double(result.samples.count) * 3))
    }
    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<3) { index in
                RoundedRectangle(cornerRadius: 0.7)
                    .fill(index < count ? AssistantTheme.text.opacity(0.75) : AssistantTheme.tertiary.opacity(0.45))
                    .frame(width: 2.5, height: CGFloat(4 + index * 3))
            }
        }
        .frame(width: 14, height: 12)
        .accessibilityLabel(fresh ? (result.map { "探测成功 \($0.successes)/\($0.samples.count)" } ?? "尚未检测") : "尚无有效的稳定结果")
    }
}

@MainActor
struct PanelView: View {
    @ObservedObject var model: AppModel
    var openSettings: () -> Void
    @State private var tab = PanelTab.connectivity
    @State private var expandedNode: String?
    @State private var nodeFilter = NodeFilter.all
    @State private var showsMoreResults = false
    @State private var showsDiagnostics = false
    @State private var showsRoutes = false

    private var logicalSelection: String { model.currentGroup?.selected ?? "未发现策略组" }
    private var selectedName: String {
        guard model.currentGroup != nil else { return model.snapshot == nil ? "等待连接 Clash" : "未发现代理组" }
        if let resolved = model.snapshot?.resolvedNodes[model.settings.group] { return resolved }
        if let report = model.report, report.group == model.settings.group, report.selection == logicalSelection {
            return report.current.resolvedNode
        }
        return logicalSelection
    }
    // A report belongs to a node as well as a group. Never show the previous
    // node's measurements while an external or in-app selection is being checked.
    private var currentReport: CheckReport? {
        guard model.currentGroup != nil, let report = model.report,
              report.group == model.settings.group, report.selection == logicalSelection,
              report.current.resolvedNode == selectedName else { return nil }
        return report
    }
    private var currentResultTTL: TimeInterval { Double(model.settings.intervalMinutes * 60 + 60) }
    private var currentState: HealthStatus {
        if model.isSwitching || model.isChecking { return .checking }
        if [.error, .disconnected, .unknown, .stale].contains(model.status) { return model.status }
        guard let report = currentReport else { return .unknown }
        return Date().timeIntervalSince(report.checkedAt) < currentResultTTL ? model.status : .stale
    }
    private var currentMeasurements: NodeResult? {
        guard ![HealthStatus.unknown, .stale, .disconnected, .error].contains(currentState),
              let report = currentReport, Date().timeIntervalSince(report.checkedAt) < currentResultTTL else { return nil }
        return report.current
    }
    private var currentReason: String {
        if model.errorText != nil || [.checking, .disconnected, .stale].contains(currentState) { return model.statusReason }
        guard currentReport != nil else { return "当前节点尚未完成检测，点击“检测当前”了解连接情况。" }
        return model.statusReason
    }
    private var ruleRoutes: (main: String, chatGPT: String?)? {
        guard let snapshot = model.snapshot, snapshot.mode.lowercased() == "rule",
              let mainGroup = snapshot.group(named: "节点选择") else { return nil }
        let main = snapshot.resolvedNodes[mainGroup.name] ?? mainGroup.selected
        let chatGPT = snapshot.groups.first { $0.name.caseInsensitiveCompare("ChatGPT") == .orderedSame }
            .map { snapshot.resolvedNodes[$0.name] ?? $0.selected }
        return (main, chatGPT == main ? nil : chatGPT)
    }
    private var stableCount: Int { model.globalScanFresh ? model.stableNodes.count : 0 }
    private var visibleGlobalNodes: [NodeInventoryEntry] {
        nodeFilter == .stable ? (model.globalScanFresh ? model.stableNodes.map(\.node) : []) : model.globalInventory
    }
    private var inventorySummary: String {
        if model.settings.scanScope == .currentGroup {
            return "当前代理组 · \(model.globalInventory.count) 个节点"
        }
        let count = model.snapshot?.groups.count ?? model.globalScan?.groupCount ?? 0
        return "\(count) 个代理组 · \(model.globalInventory.count) 个去重节点"
    }
    private var scanButtonTitle: String { model.settings.scanScope == .currentGroup ? "扫描当前组" : "扫描节点" }

    var body: some View {
        VStack(spacing: 0) {
            header
            currentNodeCard.padding(.horizontal, 10)
            if model.isBusy { progressLine.padding(.top, 6) }
            if let error = model.errorText, !error.isEmpty {
                inlineMessage(error, symbol: "exclamationmark.circle", color: AssistantTheme.color(for: .error))
                    .padding(.horizontal, 9).padding(.top, 5)
            } else if let notice = model.notice, !notice.isEmpty {
                inlineMessage(notice, symbol: "info.circle")
                    .padding(.horizontal, 9).padding(.top, 5)
            }
            candidatesHeading
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    stableCandidates
                    if let routes = ruleRoutes { routeDisclosure(routes) }
                    moreResults
                    diagnostics
                }
                .padding(.horizontal, 10).padding(.bottom, 8)
            }
            .scrollIndicators(.automatic)
            footer
        }
        .frame(width: 400, height: 480)
        .background(AssistantTheme.background)
        .foregroundStyle(AssistantTheme.text)
        .font(.system(size: 12))
        .tint(AssistantTheme.accent)
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 16, weight: .semibold)).accessibilityHidden(true)
            Text("稳连-代理节点稳定性检测工具")
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Spacer()
            iconButton("arrow.up.right.square", label: "打开 Clash Verge") { model.openClash() }
            iconButton("gearshape", label: "打开设置", action: openSettings)
        }
        .padding(.horizontal, 13).padding(.top, 8).padding(.bottom, 7)
    }

    private var currentNodeCard: some View {
        SurfaceGroup {
            HStack(spacing: 8) {
                Text("当前代理组").foregroundStyle(AssistantTheme.secondary)
                Spacer(minLength: 8)
                Menu {
                    ForEach(model.snapshot?.groups ?? []) { group in
                        Button {
                            model.setMonitoredGroup(group.name)
                        } label: {
                            if group.name == model.settings.group {
                                Label(group.name, systemImage: "checkmark")
                            } else {
                                Text(group.name)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(model.settings.group).font(.system(size: 11)).foregroundStyle(AssistantTheme.text)
                            .lineLimit(1).truncationMode(.middle).help(model.settings.group)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                    }
                    .foregroundStyle(AssistantTheme.text)
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.small)
                .font(.system(size: 11)).tint(AssistantTheme.text).fixedSize(horizontal: false, vertical: true)
                .disabled(model.isSwitching || model.snapshot == nil)
                .help("选择在此查看和切换节点的代理组")
                .accessibilityLabel("当前代理组 " + model.settings.group + "，选择代理组")
            }
            .font(.system(size: 11)).padding(.horizontal, 11).frame(height: 26)
            separator
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 15)).foregroundStyle(AssistantTheme.accent).accessibilityHidden(true)
                    Text(selectedName).font(.system(size: 16, weight: .semibold))
                        .lineLimit(1).truncationMode(.middle).help(selectedName)
                    Spacer(minLength: 4)
                    HStack(spacing: 4) {
                        Circle().fill(AssistantTheme.color(for: currentState)).frame(width: 5, height: 5)
                        Text(currentState.title).font(.system(size: 10))
                    }
                    .foregroundStyle(AssistantTheme.color(for: currentState)).fixedSize()
                }
                HStack(spacing: 8) {
                    Text(currentMeasurements.map { "成功 \($0.successes)/\($0.samples.count)" } ?? "成功 —")
                        .fixedSize()
                    Text(currentMeasurements?.medianMS.map { "延迟 \($0) ms" } ?? "延迟 —")
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(currentReport.map { AssistantTheme.time($0.checkedAt) + (currentState == .stale ? " 已过期" : " 检测") } ?? "尚未检测")
                        .lineLimit(1).fixedSize()
                    lightButton("检测当前", symbol: "arrow.clockwise", disabled: model.isBusy) { model.refresh() }
                        .keyboardShortcut("r", modifiers: .command)
                }
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(AssistantTheme.secondary)
                if logicalSelection != selectedName, model.currentGroup != nil {
                    Text("经由 \(logicalSelection)").font(.system(size: 10))
                        .foregroundStyle(AssistantTheme.secondary).lineLimit(1).truncationMode(.middle)
                        .help("组内选择：" + logicalSelection)
                }
                if !model.isBusy, [.unknown, .degraded, .unreachable, .disconnected, .stale].contains(currentState), model.errorText == nil {
                    Text(currentReason).font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 11).padding(.vertical, 8)
            if model.hasUndoSelection {
                separator
                recoveryRow
            }
        }
    }

    private var progressLine: some View {
        HStack(spacing: 7) {
            ProgressView().controlSize(.mini)
            Text(model.progress).lineLimit(1).truncationMode(.middle).help(model.progress)
            Spacer(minLength: 0)
            if !model.isSwitching {
                Button("取消") { model.cancelOperation() }.buttonStyle(.plain)
                    .accessibilityLabel(model.isScanning ? "取消节点扫描" : "取消当前检测")
            }
        }
        .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary).padding(.horizontal, 15)
    }

    private var candidatesHeading: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("可切换的稳定节点").font(.system(size: 12, weight: .semibold))
                Text(String(model.switchableStableNodes.count)).font(.system(size: 12)).monospacedDigit()
                    .foregroundStyle(AssistantTheme.secondary)
                Spacer(minLength: 4)
                Button(model.isScanning ? "扫描中…" : scanButtonTitle) { model.scanCandidates() }
                    .font(.system(size: 11)).buttonStyle(.plain).disabled(model.isBusy)
                    .accessibilityLabel(scanButtonTitle)
            }
            HStack(spacing: 4) {
                Text(scanSummary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Menu {
                    ForEach(ScanScope.allCases, id: \.self) { scope in
                        Button {
                            model.setScanScope(scope)
                        } label: {
                            if model.settings.scanScope == scope {
                                Label(scope.title, systemImage: "checkmark")
                            } else {
                                Text(scope.title)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text("扫描选项").font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .medium))
                    }
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.small)
                .font(.system(size: 10)).tint(AssistantTheme.secondary).fixedSize().disabled(model.isSwitching)
                .help("默认扫描当前代理组；全部扫描的其他结果可在“更多扫描结果”查看")
            }
            .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
        }
        .padding(.horizontal, 13).padding(.top, 8).padding(.bottom, 6)
    }

    private var scanSummary: String {
        if model.candidateListRechecking { return "上轮结果 · 复检中，完成后可切换" }
        if model.isScanning { return "两轮复核中 · 完成后可切换" }
        if model.globalScanFresh, let finished = model.globalScan?.finishedAt {
            return "仅当前组 · \(AssistantTheme.time(finished)) 扫描完成"
        }
        return model.globalScan == nil ? "扫描后筛选当前组的可用节点" : "扫描结果已过期 · 请重新扫描"
    }

    private var stableCandidates: some View {
        SurfaceGroup {
            if model.switchableStableNodes.isEmpty {
                stableEmptyState
            } else {
                ForEach(Array(model.switchableStableNodes.enumerated()), id: \.element.id) { index, result in
                    if index > 0 { separator }
                    stableCandidateRow(result)
                }
            }
        }
    }

    private func stableCandidateRow(_ result: GlobalNodeResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "globe.asia.australia.fill")
                .font(.system(size: 14)).foregroundStyle(AssistantTheme.secondary)
                .frame(width: 17).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(result.node.name).font(.system(size: 12, weight: .medium))
                    .lineLimit(1).truncationMode(.middle).help(result.node.name)
                Text("\(result.medianMS.map { "\($0) ms" } ?? "—") · \(result.successes)/\(result.samples.count) 次成功")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(AssistantTheme.secondary)
            }
            Spacer(minLength: 4)
            lightButton(model.switchingTarget == result.node.name ? "切换中…" : "切换", disabled: model.isBusy || !model.canUseGlobalNode(result.node.name)) {
                model.switchTo(result.node.name)
            }
            .help("将“\(model.settings.group)”切换到“\(result.node.name)”，随后自动复检")
            .accessibilityLabel("切换到 " + result.node.name)
        }
        .padding(.horizontal, 11).padding(.vertical, 7)
    }

    private var stableEmptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if model.isScanning { ProgressView().controlSize(.mini) }
                Text(stableEmptyTitle).font(.system(size: 12, weight: .medium))
            }
            Text(stableEmptyReason).font(.system(size: 11)).foregroundStyle(AssistantTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !model.isScanning {
                lightButton(scanButtonTitle, symbol: "arrow.clockwise", disabled: model.isBusy) { model.scanCandidates() }
            }
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stableEmptyTitle: String {
        if model.isScanning { return "正在寻找稳定节点" }
        if model.currentGroup == nil { return "先连接 Clash Verge" }
        if model.currentGroup?.canSelect == false { return "当前代理组自动选择节点" }
        if !model.globalScanFresh { return "扫描后即可选择稳定节点" }
        return "暂无其他可切换的稳定节点"
    }

    private var stableEmptyReason: String {
        if model.isScanning { return "正在对节点进行两轮检测。完成后，可直接在这里切换。" }
        if model.currentGroup == nil { return "启动 Clash Verge 并载入配置，然后点击“检测当前”。" }
        if model.currentGroup?.canSelect == false { return "此组由 Clash 自动管理。可在上方选择支持手动切换的代理组。" }
        if !model.globalScanFresh { return "默认只扫描当前代理组，速度更快。每个节点完成 4 次探测后显示结果。" }
        return "当前正在使用的节点不在候选中。其他节点的失败或波动原因可在“更多扫描结果”查看。"
    }

    private func routeDisclosure(_ routes: (main: String, chatGPT: String?)) -> some View {
        DisclosureGroup(isExpanded: $showsRoutes) {
            VStack(alignment: .leading, spacing: 4) {
                Text("主代理 → \(routes.main)")
                if let chatGPT = routes.chatGPT { Text("ChatGPT → \(chatGPT)") }
                Text("规则模式下，不同服务可能使用不同代理组。")
                    .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
            }
            .font(.system(size: 11)).lineLimit(2).padding(.top, 5).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack {
                Text("分流详情")
                Spacer()
                if routes.chatGPT != nil { Text("ChatGPT 使用其他节点").foregroundStyle(AssistantTheme.secondary) }
            }
            .font(.system(size: 10))
        }
        .padding(.horizontal, 3).padding(.vertical, 2).tint(AssistantTheme.secondary)
    }

    private var moreResults: some View {
        DisclosureGroup(isExpanded: $showsMoreResults) {
            VStack(alignment: .leading, spacing: 6) {
                Text(inventorySummary).font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                nodeFilters
                SurfaceGroup {
                    if visibleGlobalNodes.isEmpty {
                        Text("当前范围尚无扫描结果。点击“\(scanButtonTitle)”开始检测。")
                            .font(.system(size: 11)).foregroundStyle(AssistantTheme.secondary)
                            .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(visibleGlobalNodes.enumerated()), id: \.element.id) { index, node in
                            if index > 0 { separator }
                            let result = model.scanResult(named: node.name)
                            Button { expandedNode = expandedNode == node.name ? nil : node.name } label: {
                                globalNodeHeader(node, result: result, expanded: expandedNode == node.name)
                            }
                            .buttonStyle(.plain).accessibilityLabel(node.name + "，展开节点扫描详情")
                            if expandedNode == node.name { globalNodeDetails(node, result: result) }
                        }
                    }
                }
            }
            .padding(.top, 6)
        } label: {
            HStack {
                Text("更多扫描结果")
                Spacer()
                Text(String(model.globalInventory.count)).foregroundStyle(AssistantTheme.secondary).monospacedDigit()
            }
            .font(.system(size: 11))
        }
        .tint(AssistantTheme.secondary).padding(.horizontal, 3).padding(.vertical, 2)
    }

    private var diagnostics: some View {
        DisclosureGroup(isExpanded: $showsDiagnostics) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 4) {
                    ForEach(PanelTab.allCases, id: \.self) { item in
                        Button { tab = item } label: {
                            Text(item.rawValue).font(.system(size: 11, weight: tab == item ? .medium : .regular))
                                .frame(maxWidth: .infinity).frame(height: 25)
                                .foregroundStyle(tab == item ? AssistantTheme.text : AssistantTheme.secondary)
                                .background(tab == item ? AssistantTheme.surface : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7))
                                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(tab == item ? AssistantTheme.line : .clear))
                        }
                        .buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : [])
                    }
                }
                switch tab {
                case .connectivity: connectivityContent
                case .exit: exitContent
                case .history: historyContent
                }
            }
            .padding(.top, 6)
        } label: {
            Text("诊断详情").font(.system(size: 11))
        }
        .tint(AssistantTheme.secondary).padding(.horizontal, 3).padding(.vertical, 2)
    }

    private var nodeFilters: some View {
        HStack(spacing: 4) {
            ForEach(NodeFilter.allCases, id: \.self) { item in
                Button { nodeFilter = item } label: {
                    HStack(spacing: 5) {
                        Text(item == .stable ? "本轮稳定" : "全部")
                        Text(String(item == .stable ? stableCount : model.globalInventory.count))
                            .monospacedDigit().foregroundStyle(AssistantTheme.secondary)
                    }
                    .font(.system(size: 11, weight: nodeFilter == item ? .medium : .regular))
                    .frame(maxWidth: .infinity).frame(height: 25)
                    .foregroundStyle(nodeFilter == item ? AssistantTheme.text : AssistantTheme.secondary)
                    .background(nodeFilter == item ? AssistantTheme.surface : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(nodeFilter == item ? AssistantTheme.line : .clear))
                }
                .buttonStyle(.plain).accessibilityAddTraits(nodeFilter == item ? .isSelected : [])
            }
        }
    }
    private func globalLabel(_ result: GlobalNodeResult?) -> String {
        guard let result else { return "未检测" }
        guard model.globalScanFresh else {
            if model.isScanning { return result.rounds.count < 2 ? "待复核" : "待完成" }
            return "待重扫"
        }
        guard globalResultFresh(result) else { return "已过期" }
        return result.stabilityLabel
    }

    private func globalResultFresh(_ result: GlobalNodeResult) -> Bool {
        model.globalScanFresh && Date().timeIntervalSince(result.summary.testedAt) < 900
    }

    private func globalNodeHeader(_ node: NodeInventoryEntry, result: GlobalNodeResult?, expanded: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "globe.asia.australia.fill")
                .font(.system(size: 14)).foregroundStyle(Color(red: 0.38, green: 0.55, blue: 0.81))
                .frame(width: 17, height: 17).padding(.top, 1).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(node.name).font(.system(size: 12, weight: .medium))
                        .lineLimit(1).truncationMode(.middle).help(node.name)
                    Spacer(minLength: 0)
                    Text(globalLabel(result)).font(.system(size: 10))
                        .foregroundStyle(AssistantTheme.secondary).fixedSize()
                    ProbeBars(result: result?.summary, fresh: result.map { globalResultFresh($0) && $0.isStable } ?? false)
                }
                Text(result.map { "成功 \($0.successes)/4 · 中位 \($0.medianMS.map { "\($0) ms" } ?? "—") · 波动 \($0.jitterMS.map { "\($0) ms" } ?? "—")" }
                     ?? "成功 —/4 · 中位 — · 波动 —")
                    .font(.system(size: 10)).monospacedDigit().foregroundStyle(AssistantTheme.secondary)
                    .lineLimit(1).truncationMode(.tail)
            }
            Image(systemName: expanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold)).foregroundStyle(AssistantTheme.tertiary)
                .frame(width: 8, height: 20)
        }
        .padding(.horizontal, 11).padding(.vertical, 7).frame(maxWidth: .infinity, alignment: .leading)
        .background(expanded ? AssistantTheme.inset : AssistantTheme.surface)
        .contentShape(Rectangle())
    }

    private func globalNodeDetails(_ node: NodeInventoryEntry, result: GlobalNodeResult?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("节点类型", value: node.kind)
            VStack(alignment: .leading, spacing: 4) {
                Text("所属策略组").foregroundStyle(AssistantTheme.secondary)
                Text(node.groups.joined(separator: " · ")).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 11))
            if let result {
                detailRow("本轮结论", value: globalLabel(result))
                detailRow("已完成", value: "\(result.rounds.count)/2 轮 · \(result.samples.count)/4 次探测")
                detailRow("检测时间", value: AssistantTheme.time(result.summary.testedAt))
                if !globalResultFresh(result) {
                    Text(model.isScanning ? "当前范围扫描正在进行，完成复核后再判断稳定性。" : "检测结果已失效，请重新扫描节点。")
                        .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                }
                ForEach(Array(result.samples.enumerated()), id: \.offset) { index, sample in
                    if sample.latencyMS == nil {
                        Text("第 \(index + 1) 次失败：\(sample.error ?? "连接失败")")
                            .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if result.rounds.count >= 2, result.successes == result.samples.count, !result.isStable {
                    Text("探测均成功，但本轮延迟波动较大，未进入稳定筛选。")
                        .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                }
            } else {
                Text("尚未检测此节点。完成两轮扫描后才能判断本轮稳定性。")
                    .font(.system(size: 11)).foregroundStyle(AssistantTheme.secondary)
            }
            Text("本轮稳定：两轮共 4 次探测全部成功，且延迟波动在允许范围内。波动是最高与最低延迟之差。仅反映本轮观测，不代表长期稳定；出口、登录、对话和 Codex 任务尚未验证。")
                .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.currentGroup?.members.contains(node.name) != true {
                Text("此节点不在所关注策略组的直接成员中，可在 Clash 内使用。")
                    .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.currentGroup?.canSelect != true {
                Text("所关注策略组自动管理节点，请在 Clash 内使用，或选择可手动切换的策略组。")
                    .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if node.name == selectedName {
                Text("当前关注策略组正在使用此节点。")
                    .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
            }
            lightButton("切换到此节点", symbol: "arrow.left.arrow.right",
                        disabled: model.isBusy || !model.canUseGlobalNode(node.name)) {
                model.switchTo(node.name)
            }
        }
        .padding(.leading, 36).padding(.trailing, 11).padding(.bottom, 9).padding(.top, 3)
        .frame(maxWidth: .infinity, alignment: .leading).background(AssistantTheme.inset)
    }

    private var connectivityContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            SurfaceGroup {
                sectionRow("chatgpt.com", symbol: "bubble.left.and.bubble.right.fill", trailing: currentState.title)
                separator
                infoRow("策略组", value: model.settings.group)
                separator
                infoRow("当前节点", value: selectedName)
                if model.currentGroup != nil, logicalSelection != selectedName {
                    separator
                    infoRow("组内选择", value: logicalSelection)
                }
                if let report = currentReport {
                    separator
                    infoRow("节点探测", value: "\(report.current.successes)/\(report.current.samples.count) 次成功")
                    separator
                    infoRow("中位延迟", value: report.current.medianMS.map { "\($0) ms" } ?? "未知")
                    separator
                    infoRow("当前路径 HTTP", value: report.path.httpStatus.map(String.init) ?? "未知")
                    ForEach(Array(report.current.samples.enumerated()), id: \.offset) { index, sample in
                        separator
                        infoRow("第 \(index + 1) 次", value: sample.latencyMS.map { "\($0) ms" } ?? (sample.error ?? "未通过"))
                    }
                }
            }
            inlineMessage(currentReason, symbol: currentState.symbol, color: AssistantTheme.color(for: currentState))
            Text("检测覆盖节点连通性和目标访问，不代表登录、对话或 Codex 任务已验证。")
                .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 5)
            lightButton("重新检测", symbol: "arrow.clockwise", disabled: model.isBusy) { model.refresh() }
                .padding(.horizontal, 4)
        }
    }

    private var exitContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            SurfaceGroup {
                sectionRow("当前访问出口", symbol: "network", trailing: currentReport?.path.exitIP == nil ? "未知" : "已采样")
                separator
                VStack(alignment: .leading, spacing: 6) {
                    Text(currentReport?.path.exitIP ?? "尚未取得出口 IP")
                        .font(.system(size: 18, weight: .medium, design: .monospaced))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(currentReport == nil ? "当前节点尚无出口观测，完成检测后可查看。" : model.ipObservationSummary).font(.system(size: 11))
                        .foregroundStyle(AssistantTheme.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .padding(11).frame(maxWidth: .infinity, alignment: .leading).background(AssistantTheme.inset)
                separator
                infoRow("与所选节点的关系", value: "尚未验证")
                separator
                infoRow("统计窗口", value: "近 24 小时")
                separator
                infoRow("最近完成", value: currentReport.map { AssistantTheme.time($0.checkedAt) } ?? "尚未检测")
            }
            inlineMessage("出口来自现有代理分流路径，不能据此证明所选节点的出口固定。", symbol: "info.circle")
            if let error = currentReport?.path.error { inlineMessage(error, symbol: "exclamationmark.circle") }
            lightButton("重新采样", symbol: "arrow.clockwise", disabled: model.isBusy) { model.refresh() }
                .padding(.horizontal, 4)
        }
    }

    private var historyContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            SurfaceGroup {
                sectionRow("最近动态", symbol: "clock", trailing: "\(model.events.count) 条")
                if model.events.isEmpty {
                    separator
                    Text("完成检测后，状态变化会记录在这里。")
                        .font(.system(size: 12)).foregroundStyle(AssistantTheme.secondary)
                        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(model.events) { event in
                        separator
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(event.title).font(.system(size: 12, weight: .medium))
                                Spacer()
                                Text(AssistantTheme.time(event.date)).font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                            }
                            Text(event.detail).font(.system(size: 11)).foregroundStyle(AssistantTheme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.horizontal, 11).padding(.vertical, 8)
                    }
                }
            }
            Text("记录保存在这台 Mac。复制诊断时会隐藏出口 IP 和本机接口路径。")
                .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary).padding(.horizontal, 5)
        }
    }

    private var recoveryRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 11)).foregroundStyle(AssistantTheme.secondary)
            Text("原节点：" + (model.switchReceipt?.previousSelection ?? ""))
                .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondary)
                .lineLimit(1).truncationMode(.middle)
                .help(model.switchReceipt?.previousSelection ?? "")
            Spacer(minLength: 3)
            lightButton("恢复原节点", disabled: !model.canUndo) { model.undoSwitch() }
        }
        .padding(.horizontal, 11).padding(.vertical, 5)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            separator
            HStack(spacing: 16) {
                Button("复制诊断") { model.copyDiagnostics() }
                Spacer()
                Button("打开 Clash") { model.openClash() }
                Button("退出") { NSApp.terminate(nil) }
            }
            .font(.system(size: 11)).foregroundStyle(AssistantTheme.secondary).buttonStyle(.plain)
            .padding(.horizontal, 11).frame(height: 28)
        }
        .background(AssistantTheme.background)
    }

    private var separator: some View { Rectangle().fill(AssistantTheme.line.opacity(0.7)).frame(height: 0.5) }

    private func iconButton(_ symbol: String, label: String, disabled: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }
        .buttonStyle(.plain).foregroundStyle(AssistantTheme.secondary)
        .help(label).accessibilityLabel(label).disabled(disabled)
    }

    private func lightButton(_ title: String, symbol: String? = nil, disabled: Bool = false,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 10)) }
                Text(title)
            }
            .font(.system(size: 11)).foregroundStyle(disabled ? AssistantTheme.tertiary : AssistantTheme.text)
            .padding(.horizontal, 9).frame(height: 24).background(AssistantTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(AssistantTheme.line))
        }
        .buttonStyle(.plain).disabled(disabled)
    }

    private func detailRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(AssistantTheme.secondary)
            Spacer(minLength: 0)
            Text(value).lineLimit(1).truncationMode(.middle).help(value)
        }
        .font(.system(size: 11))
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).foregroundStyle(AssistantTheme.secondary)
            Spacer(minLength: 0)
            Text(value).foregroundStyle(AssistantTheme.text).lineLimit(2).truncationMode(.middle)
                .help(value).multilineTextAlignment(.trailing)
        }
        .font(.system(size: 12)).padding(.horizontal, 11).padding(.vertical, 8)
    }

    private func sectionRow(_ title: String, symbol: String, trailing: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 16)).foregroundStyle(AssistantTheme.accent).frame(width: 18)
            Text(title).font(.system(size: 13, weight: .medium))
            Spacer()
            Text(trailing).font(.system(size: 11)).foregroundStyle(AssistantTheme.secondary)
        }
        .padding(.horizontal, 11).frame(height: 32)
    }

    private func inlineMessage(_ text: String, symbol: String,
                               color: Color = AssistantTheme.secondary) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11)).foregroundStyle(color).padding(.top, 1)
            Text(text).font(.system(size: 11)).foregroundStyle(AssistantTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 5).padding(.vertical, 3)
    }
}
