import SwiftUI

/// User-selectable looks. Effects are Metal shaders in Shaders/Shaders.metal.
enum LyricStyle: String, CaseIterable, Identifiable {
    case classic, fisheye, vhs, liquid, led, lcd

    var id: Self { self }

    var name: String {
        switch self {
        case .classic: "Classic"
        case .fisheye: "Fisheye"
        case .vhs: "VHS"
        case .liquid: "Liquid"
        case .led: "LED Sign"
        case .lcd: "LCD Screen"
        }
    }

    /// Dot-display styles (see `DotDisplay`): they draw their own opaque screen (no album background) and have no emojis.
    var isSign: Bool { self == .led || self == .lcd }
}

extension View {
    /// Effect applied to the lyric column (and emojis).
    func lyricEffect(_ style: LyricStyle, time: Float) -> some View {
        visualEffect { content, proxy in
            content
                // The lens pulls pixels in from up to about half the view away, so say so,
                // otherwise SwiftUI doesn't give the shader enough of the layer to sample.
                .distortionEffect(ShaderLibrary.fisheye(.float2(proxy.size), .float(0.55)),
                                  maxSampleOffset: CGSize(width: proxy.size.width / 2, height: proxy.size.height / 2),
                                  isEnabled: style == .fisheye)
                .distortionEffect(ShaderLibrary.wave(.float(time), .float(6)),
                                  maxSampleOffset: CGSize(width: 6, height: 6), isEnabled: style == .liquid)
        }
    }

    /// Effect applied to the whole window, background included.
    func windowEffect(_ style: LyricStyle, time: Float) -> some View {
        visualEffect { content, proxy in
            content.layerEffect(ShaderLibrary.vhs(.float2(proxy.size), .float(time)),
                                maxSampleOffset: CGSize(width: 40, height: 0), isEnabled: style == .vhs)
        }
    }
}

/// Classic green backlit LCD.
enum LCDColors {
    static let ink = Color(red: 0.1, green: 0.14, blue: 0.08)
    static let backlight = Color(red: 0.64, green: 0.72, blue: 0.52)
}

// MARK: - Background

/// The album cover swirled and warped by the `artworkFlow` shader, then heavily blurred.
///
/// Everything (shader + blur) happens on a tiny 1/8-size copy that's flattened with `drawingGroup`
/// and then scaled up: ~64x fewer pixels to shade and blur, and the upscale adds even more softness.
/// Redraws at most 30 times a second, and not at all while paused.
struct ArtworkBackground: View, Equatable {
    let artwork: NSImage?
    let playing: Bool
    let theme: LyricTheme

    private static let downscale = 8.0
    /// In small-copy points, so the on-screen blur is this × `downscale`.
    private static let blur = 5.0

    static func == (a: Self, b: Self) -> Bool {
        a.artwork === b.artwork && a.playing == b.playing && a.theme == b.theme
    }

    var body: some View {
        GeometryReader { geo in
            let small = CGSize(width: geo.size.width / Self.downscale, height: geo.size.height / Self.downscale)

            if let artwork {
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { context in
                    let time = Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600))
                    // Stretched on purpose: the shader samples in 0...1 cover coordinates.
                    Image(nsImage: artwork)
                        .resizable()
                        .frame(width: small.width, height: small.height)
                        .layerEffect(ShaderLibrary.artworkFlow(.float2(small), .float(time)), maxSampleOffset: small)
                        .blur(radius: Self.blur, opaque: true) // opaque: don't fade to black at the edges
                        .saturation(theme.saturation)
                        .drawingGroup() // flatten at the small size so the scale-up below is just a texture stretch
                        .scaleEffect(Self.downscale, anchor: .topLeading)
                }
            } else {
                MeshGradient(width: 3, height: 3, points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.5], [0.5, 0.5], [1, 0.5],
                    [0, 1], [0.5, 1], [1, 1],
                ], colors: Artwork.defaultColors)
            }
        }
        .overlay(theme.overlay) // keep the lyrics readable
    }
}

// MARK: - Emojis

/// Little emojis that pop out when certain words are sung.
enum Emoji {
    private static let table: [String: String] = {
        let groups: [(String, [String])] = [
            ("❤️", ["love", "loving", "lover", "heart", "hearts"]),
            ("💔", ["broken", "heartbreak", "goodbye"]),
            ("🔥", ["fire", "burn", "burning", "hot", "lit", "flame", "flames"]),
            ("💸", ["money", "cash", "rich", "paid", "bands", "dollar", "dollars", "racks"]),
            ("💎", ["diamond", "diamonds", "gold", "ice", "icy"]),
            ("🌙", ["moon", "night", "tonight", "midnight"]),
            ("☀️", ["sun", "sunshine", "summer", "morning"]),
            ("⭐️", ["star", "stars", "shine", "shining"]),
            ("✨", ["light", "lights", "magic", "glow"]),
            ("🌧️", ["rain", "raining", "storm"]),
            ("😢", ["cry", "crying", "tears", "sad"]),
            ("🥀", ["lonely", "alone"]),
            ("💃", ["dance", "dancing", "dancer"]),
            ("🎉", ["party", "celebrate"]),
            ("🎶", ["music", "song", "sing", "singing", "melody", "radio"]),
            ("💋", ["kiss", "kissing", "lips"]),
            ("🚗", ["car", "drive", "driving", "ride", "riding"]),
            ("✈️", ["fly", "flying", "plane"]),
            ("🌊", ["ocean", "sea", "wave", "waves", "water"]),
            ("❄️", ["cold", "snow", "freeze", "frozen"]),
            ("💨", ["smoke", "wind", "fast"]),
            ("👑", ["king", "queen", "crown"]),
            ("😇", ["heaven", "angel", "angels"]),
            ("😈", ["devil", "hell", "demon", "demons"]),
            ("🙏", ["god", "pray", "praying", "bless", "blessed"]),
            ("💀", ["dead", "die", "dying", "death", "kill"]),
            ("👻", ["ghost", "ghosts"]),
            ("🌹", ["rose", "roses", "flower", "flowers"]),
            ("🍷", ["wine", "drink", "drinking", "drunk"]),
            ("👀", ["eyes", "look", "looking", "watch", "watching", "see"]),
            ("🌍", ["world", "earth"]),
            ("💭", ["dream", "dreams", "dreaming", "sleep"]),
            ("📱", ["phone", "call", "text"]),
            ("🏠", ["home", "house"]),
            ("⏰", ["time", "clock", "forever"]),
            ("😊", ["happy", "smile", "smiling"]),
            ("🤪", ["crazy", "wild"]),
        ]
        var table: [String: String] = [:]
        for (emoji, words) in groups { for w in words { table[w] = emoji } }
        return table
    }()

    static func `for`(_ word: String) -> String? {
        table[word.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))]
    }
}

/// Emojis float up and fade for a couple of seconds after their word is sung.
/// Positions are computed from the playback time, so there's no state to keep in sync.
/// Only animates while one of the given words actually has an emoji.
struct EmojiLayer: View {
    /// Words from the current and previous couple of lines that have an emoji.
    let words: [LyricWord]
    let clock: PlaybackClock
    let fontSize: Double

    private static let lifetime = 2.2

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: words.isEmpty || !clock.playing)) { context in
            let time = clock.time(at: context.date)
            GeometryReader { geo in
                ForEach(words.filter { time >= $0.start && time - $0.start < Self.lifetime }) { word in
                    let age = (time - word.start) / Self.lifetime
                    // Keep to the left/right margins so they don't sit on the lyrics.
                    let side = random(word.id, 1) < 0.5 ? -1.0 : 1.0
                    let x = geo.size.width / 2 + side * geo.size.width * (0.36 + random(word.id, 2) * 0.08)
                    let y = geo.size.height * (0.4 + random(word.id, 3) * 0.3) - age * 120

                    Text(word.emoji ?? "")
                        .font(.system(size: fontSize * 0.8))
                        .opacity(min(age / 0.08, 1) * (age < 0.6 ? 1 : 1 - (age - 0.6) / 0.4))
                        .rotationEffect(.degrees((random(word.id, 4) - 0.5) * 30 + sin(age * 6) * 6))
                        .position(x: x, y: y)
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// Stable pseudo-random number in 0..<1 per word.
    private func random(_ id: Int, _ salt: Int) -> Double {
        let v = sin(Double(id) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return v - v.rounded(.down)
    }
}
