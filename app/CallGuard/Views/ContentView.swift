//
//  ContentView.swift
//

import SwiftUI

struct ContentView: View {

    @EnvironmentObject private var store: RuleStore

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("概览", systemImage: "shield.lefthalf.filled") }

            RulesView()
                .tabItem { Label("规则", systemImage: "list.bullet.rectangle") }

            LogsView()
                .tabItem { Label("记录", systemImage: "clock.arrow.circlepath") }

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape") }
        }
        .alert("出错了", isPresented: errorBinding) {
            Button("知道了") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    /// errorMessage 是 @Published 的可选值，这里转成可写 Binding
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { presented in
                if !presented { store.errorMessage = nil }
            }
        )
    }
}
