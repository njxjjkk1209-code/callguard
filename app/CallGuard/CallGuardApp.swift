//
//  CallGuardApp.swift
//

import SwiftUI

@main
struct CallGuardApp: App {

    @StateObject private var store: RuleStore

    @MainActor
    init() {
        _store = StateObject(wrappedValue: RuleStore.shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onAppear { store.bootstrap() }
        }
    }
}
