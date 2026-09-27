import SwiftUI

// User-configurable options, stored with @AppStorage under these keys.
enum SettingsKey {
    static let style = "style"
    static let theme = "theme"
    static let font = "font"
    static let weight = "weight"
    static let textSize = "textSize"
    static let length = "length"
    static let emojis = "emojis"
    static let signColor = "signColor"
    static let reactToMusic = "reactToMusic"
    static let musicIntensity = "musicIntensity"

    /// How strongly visuals follow the music (`MusicAudio`): 0 when turned off, otherwise the intensity setting.
    static var musicReaction: Double {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: reactToMusic) as? Bool ?? true else { return 0 }
        return defaults.object(forKey: musicIntensity) as? Double ?? 1
    }
}

/// LED color for the LED Sign style.
enum SignColor: String, CaseIterable, Identifiable {
    case amber, red, green, blue, white

    var id: Self { self }
    var name: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .amber: Color(red: 1, green: 0.62, blue: 0.1)
        case .red: Color(red: 1, green: 0.18, blue: 0.1)
        case .green: Color(red: 0.25, green: 1, blue: 0.3)
        case .blue: Color(red: 0.25, green: 0.6, blue: 1)
        case .white: Color(red: 1, green: 0.97, blue: 0.9)
        }
    }
}

/// Colors for the lyrics and how the background is toned.
enum LyricTheme: String, CaseIterable, Identifiable {
    case aura, midnight, neon, mono, light

    var id: Self { self }

    var name: String {
        switch self {
        case .aura: "Aura"
        case .midnight: "Midnight"
        case .neon: "Neon"
        case .mono: "Mono"
        case .light: "Light"
        }
    }

    /// Sung words, and the header text.
    var text: Color {
        switch self {
        case .aura, .midnight, .mono: .white
        case .neon: Color(red: 0.35, green: 1, blue: 0.95)
        case .light: .black
        }
    }

    /// Words not sung yet.
    var unsung: Color {
        switch self {
        case .light: .black.opacity(0.3)
        case .midnight: .white.opacity(0.25)
        default: .white.opacity(0.35)
        }
    }

    /// Laid over the background so the lyrics stay readable.
    var overlay: Color {
        switch self {
        case .aura: .black.opacity(0.3)
        case .midnight: .black.opacity(0.6)
        case .neon: .black.opacity(0.45)
        case .mono: .black.opacity(0.35)
        case .light: .white.opacity(0.55)
        }
    }

    var saturation: Double {
        switch self {
        case .aura: 1.3
        case .midnight: 1.0
        case .neon: 1.6
        case .mono: 0
        case .light: 1.1
        }
    }
}

enum LyricFont: String, CaseIterable, Identifiable {
    case system, rounded, serif, mono, futura, avenir, didot, markerFelt

    var id: Self { self }

    var name: String {
        switch self {
        case .system: "System"
        case .rounded: "Rounded"
        case .serif: "Serif"
        case .mono: "Monospaced"
        case .futura: "Futura"
        case .avenir: "Avenir Next"
        case .didot: "Didot"
        case .markerFelt: "Marker Felt"
        }
    }

    func font(size: Double, weight: Font.Weight) -> Font {
        switch self {
        case .system: .system(size: size, weight: weight)
        case .rounded: .system(size: size, weight: weight, design: .rounded)
        case .serif: .system(size: size, weight: weight, design: .serif)
        case .mono: .system(size: size, weight: weight, design: .monospaced)
        // All of these ship with macOS.
        case .futura: .custom("Futura", size: size).weight(weight)
        case .avenir: .custom("Avenir Next", size: size).weight(weight)
        case .didot: .custom("Didot", size: size).weight(weight)
        case .markerFelt: .custom("Marker Felt", size: size).weight(weight)
        }
    }
}

enum LyricWeight: String, CaseIterable, Identifiable {
    case regular, semibold, bold, heavy

    var id: Self { self }
    var name: String { rawValue.capitalized }

    var weight: Font.Weight {
        switch self {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
    }
}

/// How much of a line is shown at once.
enum LyricLength: String, CaseIterable, Identifiable {
    case word, phrase, short, line

    var id: Self { self }

    var name: String {
        switch self {
        case .word: "Word by word"
        case .phrase: "Phrases (up to 3 words)"
        case .short: "Short (up to 5 words)"
        case .line: "Full lines"
        }
    }

    var maxWords: Int {
        switch self {
        case .word: 1
        case .phrase: 3
        case .short: 5
        case .line: .max
        }
    }
}

/// Everything the lyric views need to know about how text should look.
struct LyricLook: Equatable {
    var font: LyricFont
    var weight: Font.Weight
    /// Multiplier on the size picked from the window width.
    var scale: Double
    var theme: LyricTheme

    func font(size: Double) -> Font { font.font(size: size, weight: weight) }
}

/// The Settings window (⌘,).
struct SettingsView: View {
    @AppStorage(SettingsKey.style) private var style = LyricStyle.classic
    @AppStorage(SettingsKey.theme) private var theme = LyricTheme.aura
    @AppStorage(SettingsKey.font) private var font = LyricFont.system
    @AppStorage(SettingsKey.weight) private var weight = LyricWeight.heavy
    @AppStorage(SettingsKey.textSize) private var textSize = 1.0
    @AppStorage(SettingsKey.length) private var length = LyricLength.short
    @AppStorage(SettingsKey.emojis) private var emojis = true
    @AppStorage(SettingsKey.signColor) private var signColor = SignColor.amber
    @AppStorage(SettingsKey.reactToMusic) private var reactToMusic = true
    @AppStorage(SettingsKey.musicIntensity) private var musicIntensity = 1.0

    var body: some View {
        Form {
            Section("Look") {
                Picker("Style", selection: $style) {
                    ForEach(LyricStyle.allCases) { Text($0.name).tag($0) }
                }
                Picker("Theme", selection: $theme) {
                    ForEach(LyricTheme.allCases) { Text($0.name).tag($0) }
                }
                Picker("LED color", selection: $signColor) {
                    ForEach(SignColor.allCases) { Text($0.name).tag($0) }
                }
                .disabled(style != .led)
                Toggle("Emojis", isOn: $emojis)
                    .disabled(style.isSign)
            }
            Section {
                Toggle("React to music", isOn: $reactToMusic)
                Slider(value: $musicIntensity, in: 0.2...2) {
                    Text("Intensity")
                } minimumValueLabel: {
                    Image(systemName: "speaker.wave.1")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3")
                }
                .disabled(!reactToMusic)
            } header: {
                Text("Music")
            } footer: {
                Text("The background pulses with the bass and the LED/LCD side meters follow the song.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Font", selection: $font) {
                    ForEach(LyricFont.allCases) { f in
                        Text(f.name).font(f.font(size: 13, weight: .regular)).tag(f)
                    }
                }
                Picker("Weight", selection: $weight) {
                    ForEach(LyricWeight.allCases) { Text($0.name).tag($0) }
                }
                Slider(value: $textSize, in: 0.6...1.6, step: 0.1) {
                    Text("Size")
                } minimumValueLabel: {
                    Text("A").font(.caption)
                } maximumValueLabel: {
                    Text("A").font(.title3)
                }
            } header: {
                Text("Text")
            } footer: {
                if style.isSign {
                    Text("\(style.name) always uses its own dot font at a fixed size.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(style.isSign) // the dot displays use a fixed font and size so the text never runs into the meters
            Section {
                Picker("Lyric length", selection: $length) {
                    ForEach(LyricLength.allCases) { Text($0.name).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize()
    }
}
