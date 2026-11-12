//
//  SettingsView.swift
//

import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SettingsView: View {

    @EnvironmentObject private var store: RuleStore

    @State private var newNumber = ""
    @State private var newIsPrefix = false
    @State private var showingGuide = false
    @State private var showingImport = false
    @State private var exportDocument: RulesDocument?
    @State private var showingExporter = false

    /// Tweak 通道状态。
    /// 主通道是 App Group 容器（App 一定写得进，SpringBoard 一定读得到），
    /// 固定路径是备通道。区分两者才能判断到底哪一环出了问题。
    private var tweakChannelStatus: String {
        let fm = FileManager.default
        if fm.fileExists(atPath: SharedConfig.tweakConfigInContainerURL.path) {
            return "已导出（容器）"
        }
        if fm.fileExists(atPath: SharedConfig.tweakConfigURL.path) {
            return "已导出（固定路径）"
        }
        return "未导出"
    }

    /// 实际生效的通道位置，给排障用
    private var tweakChannelPath: String {
        let fm = FileManager.default
        if fm.fileExists(atPath: SharedConfig.tweakConfigInContainerURL.path) {
            return "App Group 容器"
        }
        if fm.fileExists(atPath: SharedConfig.tweakConfigURL.path) {
            return SharedConfig.tweakDirectory.path
        }
        return "—"
    }

    var body: some View {
        NavigationView {
            List {

                // MARK: 白名单

                Section {
                    ForEach(store.whitelist) { entry in
                        HStack {
                            Text(entry.number)
                                .font(.system(.body, design: .monospaced))
                            if entry.isPrefix {
                                Text("前缀")
                                    .font(.caption2)
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.green)
                                    .cornerRadius(4)
                            }
                            Spacer()
                            if !entry.note.isEmpty {
                                Text(entry.note)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) {
                                store.removeWhitelist(entry)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                } header: {
                    Text("白名单")
                } footer: {
                    Text("白名单优先级最高。前缀白名单用于 955xx 银行、953xx 运营商这类整段放行。")
                }

                Section {
                    TextField("号码或前缀", text: $newNumber)
                        .font(.system(.body, design: .monospaced))
                        .keyboardType(.numbersAndPunctuation)

                    Toggle("作为前缀", isOn: $newIsPrefix)

                    Button("添加") {
                        store.addWhitelist(number: newNumber, isPrefix: newIsPrefix)
                        newNumber = ""
                        newIsPrefix = false
                    }
                    .disabled(newNumber.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                // MARK: 规则自动升级

                Section {
                    HStack {
                        Text("可升级规则")
                        Spacer()
                        Text("\(store.promotableCount()) 条")
                            .foregroundColor(store.promotableCount() > 0 ? .orange : .secondary)
                    }

                    Button("执行升级") {
                        store.promoteObservableRules()
                    }
                    .disabled(store.promotableCount() == 0)
                } header: {
                    Text("规则自动升级")
                } footer: {
                    Text("观察期满 7 天且命中 3 次以上的「仅标记」规则，会升级成真拦截。升级前建议先到记录页确认没有误拦。")
                }

                // MARK: 数据

                Section("数据") {
                    Button("批量导入号码") { showingImport = true }

                    Button("导出规则备份") {
                        if let data = store.exportRulesJSON() {
                            exportDocument = RulesDocument(data: data)
                            showingExporter = true
                        }
                    }
                }

                // MARK: 运行状态

                Section("运行状态") {
                    InfoRow(title: "共享容器",
                            value: SharedConfig.isAppGroupAvailable ? "App Group" : "本地目录")
                    InfoRow(title: "Tweak 通道", value: tweakChannelStatus)
                    InfoRow(title: "通道路径", value: tweakChannelPath)
                    InfoRow(title: "规则数", value: "\(store.rules.count)")
                    InfoRow(title: "生效规则", value: "\(store.engineRuleCount)")
                } footer: {
                    if tweakChannelStatus == "未导出" {
                        Text(SharedConfig.tweakChannelDiagnostics)
                    }
                }

                Section("操作") {
                    Button("重建引擎并刷新来电识别") {
                        // 先清缓存重新探测：先装 App 后装 Tweak 时，
                        // 目录可能是 Tweak 装好后才建出来的。
                        SharedConfig.resetTweakChannelCache()
                        store.rebuildEngine()
                        store.syncExports()
                        store.scheduleDirectoryReload()
                    }

                    Button("打开系统设置") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }

                Section {
                    Button("使用说明") { showingGuide = true }
                } footer: {
                    Text("CallGuard · 自用拦截方案")
                }
            }
            .navigationTitle("设置")
            .sheet(isPresented: $showingGuide) { GuideView() }
            .sheet(isPresented: $showingImport) {
                ImportView().environmentObject(store)
            }
            .fileExporter(
                isPresented: $showingExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "callguard-rules"
            ) { result in
                switch result {
                case .success:
                    store.lastReloadMessage = "规则备份已导出"
                case .failure(let error):
                    store.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - 导出文档

struct RulesDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - 信息行
//
// 不用 LabeledContent，那是 iOS 16+ API，本项目最低支持 15.0。

private struct InfoRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}

// MARK: - 使用说明

private struct GuideView: View {

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {

                    GuideSection(
                        title: "第一步：开启来电识别",
                        text: "设置 → 电话 → 来电阻止与身份识别 → 打开 CallGuard。不开启的话，精确黑名单不会生效。"
                    )

                    GuideSection(
                        title: "第二步：先跑观察期",
                        text: "种子规则默认是「仅标记」，来电会显示标签但不拦截。跑一周后到「记录」页看误拦情况，再把确认的号段改成「拦截」。"
                    )

                    GuideSection(
                        title: "第三步：装 Tweak 补号段",
                        text: "CallDirectory 不支持号段匹配，170/171 这类整段拦截必须靠越狱 Tweak。Tweak 装好后，号段规则才真正生效。"
                    )

                    GuideSection(
                        title: "关于误拦",
                        text: "在「记录」页长按任意一条，可以直接加入白名单或确认拉黑。白名单优先级最高，会压过所有拦截规则。"
                    )

                    GuideSection(
                        title: "关于自动升级",
                        text: "规则跑满 7 天、命中 3 次以上，就可以在设置页一键升级成拦截。这个阈值可以按自己的误拦容忍度调整。"
                    )
                }
                .padding()
            }
            .navigationTitle("使用说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
}

private struct GuideSection: View {
    let title: String
    // 不能叫 body：会和 View 协议的 `var body` 重名，编译期直接报
    // invalid redeclaration of 'body'
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
