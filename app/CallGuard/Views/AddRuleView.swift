//
//  AddRuleView.swift
//

import SwiftUI

struct AddRuleView: View {

    @EnvironmentObject private var store: RuleStore
    @Environment(\.dismiss) private var dismiss

    @State private var type: RuleType = .prefix
    @State private var value = ""
    @State private var label = ""
    @State private var action: RuleAction = .mark

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Picker("类型", selection: $type) {
                        ForEach(RuleType.allCases) { t in
                            Text(t.displayName).tag(t)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField(type.hint, text: $value)
                        .font(.system(.body, design: .monospaced))
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(type == .regex ? .default : .numbersAndPunctuation)
                } header: {
                    Text("规则内容")
                } footer: {
                    Text(footerText)
                }

                Section("标签") {
                    TextField("如：房产中介 / 催收", text: $label)
                }

                Section {
                    Picker("动作", selection: $action) {
                        ForEach(RuleAction.allCases) { a in
                            Text(a.displayName).tag(a)
                        }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(actionHint)
                }
            }
            .navigationTitle("添加规则")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        store.addRule(type: type, value: value,
                                      label: label, action: action)
                        dismiss()
                    }
                    .disabled(value.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var footerText: String {
        switch type {
        case .exact:  return "完整号码，可不带国家码，系统会自动归一化"
        case .prefix: return "号段前缀，如 170 表示所有 170 开头的号码。这是 CallDirectory 覆盖不到的部分，只有越狱 Tweak 能拦"
        case .range:  return "格式：起始号码-结束号码，两端都包含"
        case .regex:  return "归一化后的号码做正则匹配，如 86(170|171)\\d{8}"
        }
    }

    private var actionHint: String {
        switch action {
        case .allow:   return "放行：优先级最高，可用来给某个号段开白名单"
        case .mark:    return "仅标记：来电显示标签，不拦截。新号段建议先用这个跑一周"
        case .silence: return "静音：不响铃，但对方仍能打通（会出现在未接里）"
        case .block:   return "拦截：静音并挂断。号段规则慎用，容易误伤"
        }
    }
}
