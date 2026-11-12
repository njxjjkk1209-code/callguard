//
//  LogsView.swift
//

import SwiftUI

struct LogsView: View {

    @EnvironmentObject private var store: RuleStore
    @State private var showingClearConfirm = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        NavigationView {
            List {
                if store.logs.isEmpty {
                    Text("还没有拦截记录。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                ForEach(store.logs) { log in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(log.number)
                                .font(.system(.body, design: .monospaced))

                            HStack(spacing: 6) {
                                Text(log.label.isEmpty ? log.action.displayName : log.label)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                Text(Self.formatter.string(from: log.ts))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }

                        Spacer()

                        Text(log.action.displayName)
                            .font(.caption2)
                            .foregroundColor(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(badgeColor(log.action))
                            .cornerRadius(4)
                    }
                    .padding(.vertical, 2)
                    .contextMenu {
                        Button {
                            store.addWhitelist(number: log.number, isPrefix: false)
                        } label: {
                            Label("误拦，加入白名单", systemImage: "checkmark.shield")
                        }

                        Button {
                            store.addRule(type: .exact, value: log.number,
                                          label: "已确认骚扰", action: .block)
                        } label: {
                            Label("确认骚扰，加入黑名单", systemImage: "nosign")
                        }
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("拦截记录")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(store.logs.isEmpty)
                }
            }
            .confirmationDialog("清空全部记录？", isPresented: $showingClearConfirm) {
                Button("清空", role: .destructive) { store.clearLogs() }
                Button("取消", role: .cancel) {}
            }
            .refreshable { store.refreshLogs() }
            .onAppear { store.refreshLogs() }
        }
    }

    private func badgeColor(_ action: RuleAction) -> Color {
        switch action {
        case .allow:   return .green
        case .mark:    return .gray
        case .silence: return .orange
        case .block:   return .red
        }
    }
}
