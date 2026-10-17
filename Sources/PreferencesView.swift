import AppKit
import SwiftUI

@MainActor
struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @State private var draft = AppSettings()
    @State private var showsAdvanced = false

    private var groups: [ProxyGroup] {
        model.snapshot?.groups.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        } ?? []
    }
    private var hasChanges: Bool { draft != model.settings }

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    connectionSettings
                    monitoringSettings
                    notificationSettings
                    startupSettings
                    advancedSettings
                }
                .padding(.horizontal, 22)
                .padding(.top, 3)
                .padding(.bottom, 20)
            }
            .scrollIndicators(.automatic)
            if let error = model.errorText, !error.isEmpty {
                feedback(error, symbol: "exclamationmark.circle", color: AssistantTheme.color(for: .error))
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
            } else if let notice = model.notice, !notice.isEmpty {
                feedback(notice, symbol: "info.circle", color: AssistantTheme.secondary)
                    .padding(.horizontal, 22)
                    .padding(.bottom, 10)
            }
            footer
        }
        .font(.system(size: 13))
        .foregroundStyle(AssistantTheme.text)
        .frame(width: 550, height: 680)
        .background(AssistantTheme.background)
        .tint(AssistantTheme.accent)
        .onAppear { draft = model.settings }
        .onChange(of: model.settings.notificationsEnabled) { _, value in
            // A granted system permission enables notifications immediately in the model.
            draft.notificationsEnabled = value
        }
        .onChange(of: model.settings.scanScope) { oldValue, value in
            // Keep this window in sync when the panel changes the saved scan scope.
            if draft.scanScope == oldValue { draft.scanScope = value }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(AssistantTheme.secondary)
                .accessibilityHidden(true)
            Text("偏好设置")
                .font(.system(size: 16, weight: .semibold))
            Spacer()
            Text("稳连")
                .font(.system(size: 11))
                .foregroundStyle(AssistantTheme.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 19)
    }

    private var connectionSettings: some View {
        section("Clash 连接") {
            SurfaceGroup {
                HStack(spacing: 10) {
                    Image(systemName: "network")
                        .font(.system(size: 19))
                        .foregroundStyle(AssistantTheme.secondary)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text(model.snapshot == nil ? "尚未连接" : "Clash Verge / mihomo")
                            Circle()
                                .fill(model.snapshot == nil ? AssistantTheme.secondary : AssistantTheme.color(for: .healthy))
                                .frame(width: 5, height: 5)
                                .accessibilityHidden(true)
                        }
                        if let snapshot = model.snapshot {
                            Text("内核 \(snapshot.version) · 代理端口 \(String(snapshot.proxyPort))")
                                .font(.system(size: 11))
                                .foregroundStyle(AssistantTheme.secondary)
                        } else {
                            Text("启动 Clash Verge 后重新连接")
                                .font(.system(size: 11))
                                .foregroundStyle(AssistantTheme.secondary)
                        }
                    }
                    Spacer(minLength: 10)
                    Button(model.isBusy ? "连接中…" : "重新连接") { model.refresh() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isBusy)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                separator
                Button { model.openClash() } label: {
                    HStack {
                        Text("打开 Clash Verge")
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(AssistantTheme.secondary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var monitoringSettings: some View {
        section("检测") {
            SurfaceGroup {
                settingsRow("关注的策略组") {
                    Picker("关注的策略组", selection: $draft.group) {
                        if !groups.contains(where: { $0.name == draft.group }) {
                            Text(draft.group.isEmpty ? "尚未选择" : "\(draft.group)（未发现）")
                                .tag(draft.group)
                        }
                        ForEach(groups) { group in
                            Text(group.canSelect ? group.name : "\(group.name)（自动选择）").tag(group.name)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 247)
                    .disabled(groups.isEmpty || model.isBusy)
                }
                separator
                settingsRow("扫描范围") {
                    Picker("扫描范围", selection: $draft.scanScope) {
                        ForEach(ScanScope.allCases, id: \.self) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 153)
                    .disabled(model.isSwitching)
                }
                separator
                settingsRow("定时检测") {
                    Picker("定时检测", selection: $draft.intervalMinutes) {
                        ForEach([1, 3, 5, 10, 15, 30], id: \.self) { interval in
                            Text("每 \(interval) 分钟").tag(interval)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 153)
                    .disabled(model.isBusy)
                }
                separator
                VStack(alignment: .leading, spacing: 5) {
                    Text("默认扫描当前代理组，也可选择全部代理组。使用面板时每 15 分钟复扫；收起后暂停候选自动扫描，手动开始的扫描会继续完成。当前节点按上方频率检测。")
                    if let group = groups.first(where: { $0.name == draft.group }), !group.canSelect {
                        Text("此组自动选择节点。需要手动切换时，请选择 Selector 策略组。")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(AssistantTheme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AssistantTheme.inset)
            }
        }
    }

    private var notificationSettings: some View {
        section("通知") {
            SurfaceGroup {
                toggleRow("连接异常时通知我", isOn: $draft.notificationsEnabled)
                    .disabled(model.isBusy)
                separator
                toggleRow("恢复可用时也通知", isOn: $draft.notifyOnRecovery)
                    .disabled(!draft.notificationsEnabled || model.isBusy)
                separator
                HStack(spacing: 8) {
                    Text("系统权限")
                    Spacer()
                    Text(model.notificationPermission)
                        .foregroundStyle(AssistantTheme.secondary)
                    if model.notificationPermission != "已允许" {
                        Button(model.notificationPermission == "已拒绝" ? "查看开启方式…" : "允许通知…") {
                            model.requestNotifications()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isBusy)
                    }
                }
                .font(.system(size: 11))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            Text("同一故障不会重复提醒。")
                .font(.system(size: 11))
                .foregroundStyle(AssistantTheme.secondary)
                .padding(.horizontal, 2)
        }
    }

    private var startupSettings: some View {
        section("启动") {
            SurfaceGroup {
                toggleRow("登录 Mac 时启动", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                .disabled(model.isBusy)
            }
            Text("开机启动立即生效，其余更改请保存。")
                .font(.system(size: 11))
                .foregroundStyle(AssistantTheme.secondary)
                .padding(.horizontal, 2)
        }
    }

    private var advancedSettings: some View {
        SurfaceGroup {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { showsAdvanced.toggle() }
            } label: {
                HStack {
                    Text("高级连接设置")
                    Spacer()
                    Image(systemName: showsAdvanced ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(AssistantTheme.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("高级连接设置，\(showsAdvanced ? "已展开" : "已收起")")
            .accessibilityHint("展开后可设置自定义控制接口")
            if showsAdvanced {
                separator
                VStack(alignment: .leading, spacing: 9) {
                    Text("控制接口 Socket 路径")
                        .font(.system(size: 12))
                    TextField("留空，自动发现", text: $draft.socketOverride)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                        .disableAutocorrection(true)
                        .disabled(model.isBusy)
                    Text("通常无需填写，仅用于自定义 Unix Socket。")
                        .font(.system(size: 11))
                        .foregroundStyle(AssistantTheme.secondary)
                    if let path = model.snapshot?.socketPath {
                        Text("当前接口：\(path)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(AssistantTheme.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(AssistantTheme.inset)
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(AssistantTheme.line).frame(height: 1)
            HStack(spacing: 10) {
                Image(systemName: hasChanges ? "circle.fill" : "checkmark.circle")
                    .font(.system(size: hasChanges ? 6 : 11))
                    .foregroundStyle(hasChanges ? AssistantTheme.accent : AssistantTheme.secondary)
                    .frame(width: 11)
                    .accessibilityHidden(true)
                Text(hasChanges ? "有未保存的更改" : "设置已保存")
                    .font(.system(size: 11))
                    .foregroundStyle(AssistantTheme.secondary)
                Spacer(minLength: 8)
                Button("还原更改") { draft = model.settings }
                    .disabled(!hasChanges || model.isBusy)
                Button("保存设置") {
                    var normalized = draft
                    normalized.intervalMinutes = min(30, max(1, draft.intervalMinutes))
                    normalized.socketOverride = draft.socketOverride.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.settings = draft
                    model.saveSettings()
                    // Keep rejected input in the editor so the user can correct it.
                    if model.settings == normalized { draft = model.settings }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChanges || model.isBusy)
                .keyboardShortcut("s", modifiers: .command)
            }
            .controlSize(.regular)
            .padding(.horizontal, 23)
            .padding(.vertical, 14)
        }
        .background(AssistantTheme.background)
    }

    private var separator: some View {
        Rectangle().fill(AssistantTheme.line.opacity(0.7)).frame(height: 1)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(AssistantTheme.secondary)
                .padding(.horizontal, 2)
            content()
        }
    }

    private func settingsRow<Content: View>(_ title: String, @ViewBuilder control: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(title)
            Spacer(minLength: 8)
            control()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(title, isOn: isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
    }

    private func feedback(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .padding(.top, 1)
            Text(text)
                .foregroundStyle(AssistantTheme.secondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(text)
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .combine)
    }
}
