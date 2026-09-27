import SwiftUI

@main
struct LyricAuraApp: App {
    @StateObject private var watcher = MusicWatcher()

    var body: some Scene {
        WindowGroup("LyricAura") {
            ContentView(watcher: watcher)
                .frame(minWidth: 420, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 560)

        Settings {
            SettingsView()
        }
    }
}
