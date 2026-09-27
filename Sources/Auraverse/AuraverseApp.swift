import SwiftUI

@main
struct AuraverseApp: App {
    @StateObject private var watcher = MusicWatcher()

    init() {
        Self.migrateSettingsFromLyricAura()
    }

    var body: some Scene {
        WindowGroup("Auraverse") {
            ContentView(watcher: watcher)
                .frame(minWidth: 420, minHeight: 360)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 760, height: 560)

        Settings {
            SettingsView()
        }
    }

    /// The app used to be called LyricAura (bundle id com.ayaansajjad.LyricAura); carry its settings over once.
    private static func migrateSettingsFromLyricAura() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedFromLyricAura"),
              let old = UserDefaults(suiteName: "com.ayaansajjad.LyricAura") else { return }
        for key in [SettingsKey.style, SettingsKey.theme, SettingsKey.font, SettingsKey.weight,
                    SettingsKey.textSize, SettingsKey.length, SettingsKey.emojis] {
            if let value = old.object(forKey: key), defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: "migratedFromLyricAura")
    }
}
