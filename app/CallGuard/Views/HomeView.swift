//
//  HomeView.swift
//  概览：拦截统计 + 各层状态。
//

import SwiftUI

struct HomeView: View {

    @EnvironmentObject private var store: RuleStore

    @State private var directoryStatus = "点击查询"
    @State private var checking = false

    /// Tweak 是否已在 SpringBoard 里加载。靠 Tweak 写的心跳文件判断，
    /// 而不是靠配置文件存在 —— 后者只能说明 App 导出成功。
    @State private var tweakRunning = false
    @State private var tweakDetail = "实时拦截号段 / 正则，需在 Sileo 安装 CallGuard Tweak"

    /// hook 自检结果。-1 表示旧版心跳没有这个字段（未知）。
    @State private var tweakHooked = -1
    @State private var tweakHookTotal = 0

    /// CallDirectory 两个导出文件的实际条目数。
    /// 「L2 已启用」和「L2 真的有条目」是两件事，必须分开显示。
    @State private var blockEntries = 0
    @State private var identifyEntries = 0

    private func refreshTweakState() {
        guard let info = SharedConfig.tweakReadyInfo else {
            tweakRunning = false
            tweakHooked = -1
            tweakHookTotal = 0
            tweakDetail = "实时拦截号段 / 正则，需在 Sileo 安装 CallGuard Tweak"
            return
        }
        tweakRunning = true
        let version = info["version"] as? String ?? "?"
        let rules   = (info["ruleCount"] as? NSNumber)?.intValue ?? 0
        let hooked  = (info["hooked"] as? NSNumber)?.intValue ?? -1
        let total   = (info["hookTotal"] as? NSNumber)?.intValue ?? 0
        let commit  = info["commit"] as? String ?? ""

        tweakHooked    = hooked
        tweakHookTotal = total

        var parts: [String] = ["已运行", "v\(version)"]
        if hooked >= 0 && total > 0 {
            parts.append("挂载 \(hooked)/\(total) hook")
        }
        parts.append("加载 \(rules) 条规则")
        if !commit.isEmpty && commit != "dev" {
            parts.append("build \(commit)")
        }
        tweakDetail = parts.joined(separator: " · ")
    }

    /// Tweak 加载了但一条 hook 都没挂上 —— 这时 L1 不能显示绿点，
    /// 否则"绿点 + 什么都不发生"会让人以为拦截在正常工作。
    private var tweakState: StatusRow.State {
        guard tweakRunning else { return .unknown }
        if tweakHookTotal > 0 && tweakHooked == 0 { return .warn }
        return .ok
    }

    private func refreshDirectoryEntries() {
        let counts = SharedConfig.callDirectoryEntryCounts
        blockEntries    = counts.block
        identifyEntries = counts.identify
    }

    private var entryDetail: String {
        if blockEntries == 0 && identifyEntries == 0 {
            return "拦截 0 / 识别 0 —— 空转中，来电不会有任何标签"
        }
        return "拦截 \(blockEntries) / 识别 \(identifyEntries)"
    }

    private var entryState: StatusRow.State {
        if blockEntries == 0 && identifyEntries == 0 { return .warn }
        return .ok
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {

                    HStack(spacing: 12) {
                        StatCard(title: "今日拦截",
                                 value: "\(store.todayBlocked)",
                                 tint: .red)
                        StatCard(title: "累计拦截",
                                 value: "\(store.totalBlocked)",
                                 tint: .orange)
                    }

                    HStack(spacing: 12) {
                        StatCard(title: "规则总数",
                                 value: "\(store.rules.count)",
                                 tint: .blue)
                        StatCard(title: "生效规则",
                                 value: "\(store.engineRuleCount)",
                                 tint: .green)
                    }

                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeader(title: "拦截层状态")

                        StatusRow(
                            title: "L1 越狱 Tweak",
                            detail: tweakDetail,
                            state: tweakState
                        )

                        Divider().padding(.leading, 16)

                        StatusRow(
                            title: "L2 来电识别",
                            detail: directoryStatus,
                            state: directoryState,
                            action: {
                                checking = true
                                store.directoryStatus { result in
                                    DispatchQueue.main.async {
                                        directoryStatus = result
                                        checking = false
                                        refreshDirectoryEntries()
                                    }
                                }
                            }
                        )

                        Divider().padding(.leading, 16)

                        StatusRow(
                            title: "L2 条目数",
                            detail: entryDetail,
                            state: entryState
                        )

                        Divider().padding(.leading, 16)

                        StatusRow(
                            title: "共享容器",
                            detail: SharedConfig.isAppGroupAvailable
                                ? "App Group 可用"
                                : "App Group 不可用，已降级到本地目录",
                            state: SharedConfig.isAppGroupAvailable ? .ok : .warn
                        )
                    }
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    if let msg = store.lastReloadMessage {
                        Text(msg)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Spacer(minLength: 20)
                }
                .padding()
            }
            .navigationTitle("CallGuard")
            .onAppear {
                store.refreshLogs()
                refreshTweakState()
                refreshDirectoryEntries()

                // L2 状态不再等用户手点。不查就永远显示「点击查询」灰点，
                // 用户根本不会想到去点它。
                if directoryStatus == "点击查询" && !checking {
                    checking = true
                    store.directoryStatus { result in
                        DispatchQueue.main.async {
                            directoryStatus = result
                            checking = false
                            refreshDirectoryEntries()
                        }
                    }
                }
            }
        }
    }

    private var directoryState: StatusRow.State {
        if directoryStatus.hasPrefix("已启用") { return .ok }
        if directoryStatus.hasPrefix("未启用") { return .warn }
        return .unknown
    }
}

// MARK: - 组件

private struct StatCard: View {
    let title: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.footnote)
                .foregroundColor(.secondary)
            Text(value)
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .foregroundColor(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }
}

private struct StatusRow: View {

    enum State {
        case ok, warn, unknown
    }

    let title: String
    let detail: String
    var state: State
    var action: (() -> Void)?

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                    Text(detail)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.leading)
                }

                Spacer()

                if action != nil {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }

    private var color: Color {
        switch state {
        case .ok:      return .green
        case .warn:    return .orange
        case .unknown: return .gray
        }
    }
}
