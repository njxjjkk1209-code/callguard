//
//  RulesView.swift
//

import SwiftUI

struct RulesView: View {

    @EnvironmentObject private var store: RuleStore
    @State private var showingAdd = false
    @State private var filter: RuleType?

    var body: some View {
        NavigationView {
            List {
                if store.rules.isEmpty {
                    Text("还没有规则。点右上角 + 添加，或等待种子数据导入。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                ForEach(filteredRules) { rule in
                    RuleRow(rule: rule)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                store.deleteRule(rule)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }

                            Button {
                                store.toggle(rule)
                            } label: {
                                Label(rule.enabled ? "停用" : "启用",
                                      systemImage: rule.enabled ? "pause" : "play")
                            }
                            .tint(.orange)
                        }
                }
            }
            .listStyle(.plain)
            .navigationTitle("规则")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button("全部") { filter = nil }
                        ForEach(RuleType.allCases) { t in
                            Button(t.displayName) { filter = t }
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddRuleView()
                    .environmentObject(store)
            }
        }
    }

    private var filteredRules: [Rule] {
        guard let filter else { return store.rules }
        return store.rules.filter { $0.type == filter }
    }
}

// MARK: - 行

private struct RuleRow: View {

    let rule: Rule
    @EnvironmentObject private var store: RuleStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(rule.value)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(rule.enabled ? .primary : .secondary)

                Spacer()

                ActionBadge(action: rule.action)
            }

            HStack(spacing: 6) {
                Text(rule.type.displayName)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(.tertiarySystemFill))
                    .cornerRadius(4)

                if !rule.label.isEmpty {
                    Text(rule.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if rule.hitCount > 0 {
                    Text("命中 \(rule.hitCount)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                if let last = rule.lastHitAt {
                    Text("· \(Self.shortDate(last))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            ForEach(RuleAction.allCases) { action in
                Button(action.displayName) {
                    store.setAction(action, for: rule)
                }
            }
        }
    }

    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd"
        return f
    }()

    private static func shortDate(_ date: Date) -> String {
        shortFormatter.string(from: date)
    }
}

private struct ActionBadge: View {
    let action: RuleAction

    var body: some View {
        Text(action.displayName)
            .font(.caption2)
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color)
            .cornerRadius(4)
    }

    private var color: Color {
        switch action {
        case .allow:   return .green
        case .mark:    return .gray
        case .silence: return .orange
        case .block:   return .red
        }
    }
}
