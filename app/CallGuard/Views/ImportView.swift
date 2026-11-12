//
//  ImportView.swift
//  批量导入号码：从 12321 网站、Excel、短信里复制一堆号码，粘进来。
//

import SwiftUI

struct ImportView: View {

    @EnvironmentObject private var store: RuleStore
    @Environment(\.dismiss) private var dismiss

    @State private var text = ""
    @State private var action: RuleAction = .block
    @State private var label = "导入"
    @State private var outcome: RuleStore.ImportOutcome?

    var body: some View {
        NavigationView {
            Form {
                Section {
                    TextEditor(text: $text)
                        .frame(minHeight: 180)
                        .font(.system(.body, design: .monospaced))
                        .disableAutocorrection(true)
                        .autocapitalization(.none)
                } header: {
                    Text("号码列表")
                } footer: {
                    Text("每行一个，或用逗号、空格、分号分隔。会自动归一化并去重。")
                }

                Section("导入为") {
                    Picker("动作", selection: $action) {
                        ForEach(RuleAction.allCases) { a in
                            Text(a.displayName).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("标签", text: $label)
                }

                if let outcome {
                    Section("导入结果") {
                        Text(outcome.summary)
                            .font(.subheadline)

                        if !outcome.sample.isEmpty {
                            Text("示例：" + outcome.sample.joined(separator: "、"))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("批量导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        outcome = store.importNumbers(text, action: action, label: label)
                        if (outcome?.added ?? 0) > 0 {
                            text = ""
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
