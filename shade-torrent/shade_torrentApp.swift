//
//  shade_torrentApp.swift
//  shade-torrent
//

import SwiftUI

@main
struct shade_torrentApp: App {
    @State private var updater = UpdateChecker()

    var body: some Scene {
        WindowGroup {
            ContentView(updater: updater)
                .task { await updater.checkForUpdates() }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updater.checkForUpdates(silent: false) }
                }
            }
        }
    }
}
