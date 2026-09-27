import SwiftUI

/// The LED Sign and LCD Screen styles. The whole window is the display; the current piece of lyrics
/// (as long as the "lyric length" setting says) is shown centered in the 5×7 dot font, no scrolling.
/// - LED: the piece is shown at once; words light up fully as they're sung, upcoming ones are dim.
/// - LCD: the piece types itself out letter by letter as it's sung.
/// Overlapping lines (ad-libs, duets) and background vocals get their own rows.
/// Level meters down both sides react to the music (`MusicAudio`); the text is kept clear of them.
/// Size is fixed (the text size setting doesn't apply), so the layout always fits.
struct DotDisplay: View, Equatable {
    let chunks: [LyricChunk]
    let lyricsID: Int
    let length: LyricLength
    let clock: PlaybackClock
    let style: LyricStyle
    let ledColor: SignColor
    /// How strongly the side meters follow the music; 0 hides them (see `SettingsKey.musicReaction`).
    let reaction: Double

    static func == (a: Self, b: Self) -> Bool {
        a.lyricsID == b.lyricsID && a.length == b.length && a.clock == b.clock && a.style == b.style
            && a.ledColor == b.ledColor && a.reaction == b.reaction
    }

    var body: some View {
        GeometryReader { geo in
            // Half-point steps keep the grid crisp on Retina.
            let cell = (min(max(geo.size.width / 100, 5), 16) * 2).rounded() / 2
            let gridCols = Int(geo.size.width / cell) // whole columns only, so both meters are fully visible
            let gridRows = Int((geo.size.height / cell).rounded(.up))
            // Meters stop short of the title and the settings button at the top.
            let meterHeight = Float(max(Int((geo.size.height / 2 - 44) / cell), 1))

            // 30fps: plenty for dots, and the meters make this redraw the whole window whenever a bar moves.
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !clock.playing)) { context in
                let bands = clock.playing && reaction > 0
                    ? pointwiseMin(MusicAudio.shared.levels.bands * Float(reaction), .one) : .zero
                DotBoard(words: words(at: clock.time(at: context.date)),
                         bars: (bands * meterHeight).rounded(.toNearestOrAwayFromZero),
                         gridCols: gridCols, gridRows: gridRows,
                         cell: cell, size: geo.size, style: style, ledColor: ledColor)
                    .equatable() // only redraws when what's lit actually changes
            }
        }
    }

    /// What to show: the current piece of lyrics (plus an earlier line that's still being sung over it,
    /// e.g. ad-libs or a duet), each on its own rows, with background vocals on a row underneath.
    /// Each word carries its brightness (LED) or typed-out length (LCD).
    func words(at time: Double) -> [DotWord] {
        guard let current = currentIndex(at: time), !chunks[current].words.isEmpty else {
            return [DotWord(text: "♪", brightness: 1, visible: 1)] // instrumental, or before the first line
        }
        // At most one earlier line: two lines at once, and it keeps the shader data well under its size limit.
        let earlier = chunks[max(current - 3, 0)..<current].filter { $0.overlaps(chunks[current], at: time) }.suffix(1)
        var result: [DotWord] = []
        for chunk in Array(earlier) + [chunks[current]] {
            for (i, word) in chunk.words.enumerated() {
                result.append(dotWord(word, at: time, newRow: i == 0 && !result.isEmpty))
            }
            for (i, word) in chunk.backing.enumerated() where time >= word.start || style == .led {
                result.append(dotWord(word, at: time, newRow: i == 0))
            }
        }
        return result
    }

    private func dotWord(_ word: LyricWord, at time: Double, newRow: Bool) -> DotWord {
        let text = DotFont.normalize(word.text)
        let progress = min(max((time - word.start) / max(word.end - word.start, 0.01), 0), 1)
        switch style {
        case .lcd:
            // Characters appear across the word's duration.
            return DotWord(text: text, brightness: 1, visible: Int((progress * Double(text.count)).rounded(.up)),
                           newRow: newRow)
        default:
            return DotWord(text: text, brightness: time >= word.start ? 1 : 0.3, visible: text.count, newRow: newRow)
        }
    }

    private func currentIndex(at time: Double) -> Int? {
        guard let first = chunks.first, time >= first.start else { return nil }
        // Binary search: last chunk with start <= time.
        var low = 0, high = chunks.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if chunks[mid].start <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }

}

/// Lays the words out in dots, centers them on the grid, and hands them to the LED or LCD shader
/// along with the side meters (`meterValue` in Shaders.metal).
struct DotBoard: View, Equatable {
    /// Columns each side reserves for its meter: an empty edge column, 4 bars with gaps, then 2 empty columns.
    static let meterCols = 10

    let words: [DotWord]
    /// Half-height in dots of each meter bar: bass, low mids, high mids, treble.
    let bars: SIMD4<Float>
    let gridCols: Int
    let gridRows: Int
    let cell: Double
    let size: CGSize
    let style: LyricStyle
    let ledColor: SignColor

    static func == (a: Self, b: Self) -> Bool {
        a.words == b.words && a.bars == b.bars && a.gridCols == b.gridCols
            && a.gridRows == b.gridRows && a.cell == b.cell && a.style == b.style && a.ledColor == b.ledColor
    }

    var body: some View {
        // The bitmap is never wider than maxCols, so centered it can't reach the meters.
        let bitmap = DotBitmap(words: words, wordGap: style == .lcd ? DotBitmap.charAdvance : 4,
                               maxCols: gridCols - 2 * Self.meterCols)
        let origin = CGPoint(x: (gridCols - bitmap.cols) / 2, y: (gridRows - bitmap.rows) / 2)
        let dots = Shader.Argument.floatArray(bitmap.packed)
        let meters: [Shader.Argument] = [.float(Float(gridCols)), .float(Float(Int(size.height / cell / 2))),
                                         .float4(bars.x, bars.y, bars.z, bars.w)]

        return Rectangle().colorEffect(style == .lcd
            ? ShaderLibrary.lcdBoard(.float2(size), .float(cell), .color(LCDColors.ink), .color(LCDColors.backlight),
                                     dots, .float2(origin), .float(Float(bitmap.cols)), .float(Float(bitmap.rows)),
                                     .float(Float(bitmap.packedStride)), meters[0], meters[1], meters[2])
            : ShaderLibrary.ledBoard(.float(cell), .color(ledColor.color),
                                     dots, .float2(origin), .float(Float(bitmap.cols)), .float(Float(bitmap.rows)),
                                     .float(Float(bitmap.packedStride)), meters[0], meters[1], meters[2]))
    }
}
