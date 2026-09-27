import SwiftUI

// Rendering budget: nothing here redraws the whole window every frame.
// - Background: its own 30fps clock, paused when music is paused.
// - Lyrics column: re-rendered only when a new line starts (explicit schedule of line start times).
// - The line being sung: its own 60fps clock, so only a few words update per frame.
// - Emojis: a 60fps clock that only runs while an emoji is on screen.
// - VHS / Liquid: a 30fps clock for the shader; the other styles have no clock at all.
struct ContentView: View {
    @ObservedObject var watcher: MusicWatcher
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
        ZStack(alignment: .top) {
            effectClock { time in
                ZStack {
                    if !style.isSign || watcher.lines.isEmpty { // the LED board and LCD screen are opaque
                        ArtworkBackground(artwork: watcher.artwork, playing: watcher.clock.playing, theme: theme,
                                          reaction: reaction)
                            .equatable()
                    }

                    if watcher.lines.isEmpty {
                        Text(watcher.status)
                            .font(.title2.bold())
                            .foregroundStyle(theme.text.opacity(0.7))
                    } else if style.isSign {
                        DotDisplay(chunks: watcher.chunks(maxWords: length.maxWords), lyricsID: watcher.lyricsID,
                                   length: length, clock: watcher.clock, style: style, ledColor: signColor,
                                   reaction: reaction)
                            .equatable()
                    } else {
                        LyricsLayer(chunks: watcher.chunks(maxWords: length.maxWords), lyricsID: watcher.lyricsID,
                                    length: length, clock: watcher.clock, emojis: emojis,
                                    look: look,
                                    narrow: style == .fisheye) // the lens magnifies ~2x; keep text off the edges
                            .equatable()
                            .lyricEffect(style, time: time)
                    }
                }
                .windowEffect(style, time: time)
            }
            .ignoresSafeArea()

            header
        }
    }

    /// The LED board is black and the LCD is light green whatever the theme, so pick text that reads on it.
    private var headerColor: Color {
        switch style {
        case .led: .white
        case .lcd: LCDColors.ink
        default: theme.text
        }
    }

    /// 0 = don't react to the music, otherwise how strongly (the intensity setting).
    private var reaction: Double { reactToMusic ? musicIntensity : 0 }

    private var look: LyricLook {
        LyricLook(font: font, weight: weight.weight, scale: textSize, theme: theme)
    }

    /// Only VHS and Liquid animate over time; the other styles get no clock at all.
    @ViewBuilder
    private func effectClock<Content: View>(@ViewBuilder _ content: @escaping (Float) -> Content) -> some View {
        if style == .vhs || style == .liquid {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !watcher.clock.playing)) { context in
                content(Float(context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600)))
            }
        } else {
            content(0)
        }
    }

    private var header: some View {
        ZStack {
            if let track = watcher.track {
                VStack(spacing: 2) {
                    Text(track.name).font(.headline)
                    Text(track.artist).font(.subheadline).opacity(0.7)
                    if let source = watcher.lyricsSource {
                        Text("Lyrics: \(source.rawValue)").font(.caption2).opacity(0.45)
                    }
                }
                .foregroundStyle(headerColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 80)
            }

            // Opens the full Settings window (same as ⌘,).
            SettingsLink {
                Image(systemName: "paintpalette.fill")
                    .foregroundStyle(headerColor.opacity(0.8))
            }
            .buttonStyle(.plain)
            .help("Customize")
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.trailing, 16)
        }
        .padding(.top, 8)
    }
}

/// Works out which line is current, re-rendering only at the moments a new line starts.
/// Equatable so the effect clocks above don't rebuild it at 30fps.
struct LyricsLayer: View, Equatable {
    let chunks: [LyricChunk]
    let lyricsID: Int
    let length: LyricLength
    let clock: PlaybackClock
    let emojis: Bool
    let look: LyricLook
    let narrow: Bool

    static func == (a: Self, b: Self) -> Bool {
        a.lyricsID == b.lyricsID && a.length == b.length && a.clock == b.clock
            && a.emojis == b.emojis && a.look == b.look && a.narrow == b.narrow
    }

    var body: some View {
        TimelineView(.explicit(lineStartDates)) { context in
            // Scheduled dates land exactly on a line's start; don't lose it to floating-point rounding.
            let now = clock.time(at: context.date) + 0.001
            LyricsStage(chunks: chunks, current: chunks.lastIndex { $0.start <= now } ?? -1, now: now,
                        clock: clock, emojis: emojis, look: look, narrow: narrow)
        }
    }

    /// Line starts, plus line ends (an overlapped line stays lit until it's actually finished).
    private var lineStartDates: [Date] {
        guard clock.playing else { return [] }
        let now = clock.time(at: Date())
        return chunks.flatMap { [$0.start, $0.end] }.filter { $0 > now }.sorted()
            .map { clock.date.addingTimeInterval($0 - clock.position) }
    }
}

/// A column of lyric lines that glides up so the current one is always centered.
/// Every line has its own slot in the column, so lines never overlap, and nothing changes size.
///
/// Lines are added and removed only beyond the window's edges, so they visibly scroll in and out
/// rather than fading in place. The top and bottom of the column fade out so lyrics don't sit
/// behind the song title.
struct LyricsStage: View {
    let chunks: [LyricChunk]
    /// Index of the current line, -1 before the first.
    let current: Int
    /// Playback time when this was rendered.
    let now: Double
    let clock: PlaybackClock
    let emojis: Bool
    let look: LyricLook
    var narrow = false

    var body: some View {
        GeometryReader { geo in
            let fontSize = min(max(geo.size.width / 13, 30), 64) * look.scale
            let spacing = fontSize * 0.6
            // Every line is at least one row tall, so this many lines on each side always reaches past the edge.
            let reach = Int((geo.size.height / 2 / (fontSize * 1.1 + spacing)).rounded(.up)) + 1
            let first = max(current - reach, 0)
            let last = min(max(current, 0) + reach, chunks.count - 1)

            ZStack {
                if emojis, current >= 0 {
                    EmojiLayer(words: chunks[max(current - 2, 0)...current].flatMap(\.words).filter { $0.emoji != nil },
                               clock: clock, fontSize: fontSize)
                }

                FocusStack(focus: current - first, spacing: spacing) {
                    // Keyed by the line's own id (not its position) so the column glides instead of swapping text.
                    ForEach(Array(zip(first...last, chunks[first...last])), id: \.1.id) { i, chunk in
                        let live = i == current || (i < current && chunk.overlaps(chunks[current], at: now))
                        LineView(chunk: chunk, clock: clock, fontSize: fontSize, look: look,
                                 state: live ? .live : i < current ? .sung : .upcoming)
                            .opacity(live ? 1 : i > current ? 0.45 : 0.25)
                    }
                }
                .padding(.horizontal, narrow ? geo.size.width * 0.22 : 40)
                .animation(.spring(duration: 0.7, bounce: 0.15), value: current)
            }
            .mask(edgeFade(height: geo.size.height))
        }
    }

    /// Transparent behind the header, fading in below it; fading out again toward the bottom edge.
    private func edgeFade(height: Double) -> some View {
        let header = min(80 / height, 0.3)
        let fade = 0.15
        return LinearGradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: header),
            .init(color: .black, location: min(header + fade, 0.5)),
            .init(color: .black, location: 1 - fade),
            .init(color: .clear, location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// One line. Only the line being sung runs a clock; sung and upcoming lines are static.
struct LineView: View {
    enum State { case sung, live, upcoming }

    let chunk: LyricChunk
    let clock: PlaybackClock
    let fontSize: Double
    let look: LyricLook
    let state: State

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: state != .live || !clock.playing || chunk.words.isEmpty)) { context in
            ChunkView(chunk: chunk, time: time(at: context.date), fontSize: fontSize, look: look)
        }
    }

    private func time(at date: Date) -> Double {
        switch state {
        case .sung: .infinity
        case .upcoming: -.infinity
        case .live: clock.time(at: date)
        }
    }
}

/// Stacks lines vertically and shifts the whole stack so line `focus` sits at the vertical center.
/// Because it's a Layout, SwiftUI animates the position change when `focus` changes.
struct FocusStack: Layout {
    var focus: Int
    var spacing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) }
        var tops: [Double] = []
        var y = 0.0
        for size in sizes {
            tops.append(y)
            y += size.height + spacing
        }
        // Before the first line, park the column just below the center.
        let anchor = sizes.indices.contains(focus) ? tops[focus] + sizes[focus].height / 2 : -spacing
        for i in subviews.indices {
            subviews[i].place(at: CGPoint(x: bounds.midX, y: bounds.midY - anchor + tops[i]),
                              anchor: .top,
                              proposal: ProposedViewSize(width: bounds.width, height: sizes[i].height))
        }
    }
}

struct ChunkView: View {
    let chunk: LyricChunk
    let time: Double
    let fontSize: Double
    let look: LyricLook

    var body: some View {
        if chunk.words.isEmpty {
            Text("♪")
                .font(look.font(size: fontSize))
                .foregroundStyle(look.theme.unsung)
        } else {
            VStack(spacing: fontSize * 0.15) {
                FlowLayout(spacing: fontSize * 0.28, lineSpacing: fontSize * 0.08) {
                    ForEach(chunk.words) { word in
                        WordView(word: word, time: time, fontSize: fontSize, look: look)
                    }
                }
                // Background vocals / ad-libs: a smaller line underneath with its own timing.
                if !chunk.backing.isEmpty {
                    FlowLayout(spacing: fontSize * 0.2, lineSpacing: fontSize * 0.05) {
                        ForEach(chunk.backing) { word in
                            WordView(word: word, time: time, fontSize: fontSize * 0.55, look: look)
                        }
                    }
                    .opacity(0.85)
                }
            }
        }
    }
}

/// A single word that fills in karaoke-style, left to right, while it's being sung.
struct WordView: View {
    let word: LyricWord
    let time: Double
    let fontSize: Double
    let look: LyricLook

    var body: some View {
        let progress = min(max((time - word.start) / max(word.end - word.start, 0.01), 0), 1)
        let edge = 0.25 // softness of the fill edge
        let from = min(max(progress * (1 + edge) - edge, 0), 1)
        let to = min(max(progress * (1 + edge), from), 1)
        let font = look.font(size: fontSize)

        Text(word.text)
            .font(font)
            .foregroundStyle(look.theme.unsung)
            .overlay {
                Text(word.text)
                    .font(font)
                    .foregroundStyle(look.theme.text)
                    .mask(LinearGradient(stops: [.init(color: .black, location: from), .init(color: .clear, location: to)],
                                         startPoint: .leading, endPoint: .trailing))
            }
    }
}

/// Lays words out in centered rows, wrapping as needed.
struct FlowLayout: Layout {
    var spacing: Double
    var lineSpacing: Double

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * Double(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.midX - row.width / 2
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + row.height - size.height), proposal: .unspecified)
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row { var indices: [Int] = []; var width = 0.0; var height = 0.0 }

    private func arrange(_ subviews: Subviews, width: Double) -> [Row] {
        var rows = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : spacing + size.width
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
                rows[rows.count - 1].width = size.width
            } else {
                rows[rows.count - 1].width += extra
            }
            rows[rows.count - 1].indices.append(i)
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
