import SwiftUI

/// The LED Sign and LCD Screen styles. The whole window is the display; the current piece of lyrics
/// (as long as the "lyric length" setting says) is shown centered in the 5×7 dot font, no scrolling.
/// - LED: the piece is shown at once; words light up fully as they're sung, upcoming ones are dim.
/// - LCD: the piece types itself out letter by letter as it's sung.
/// Overlapping lines (ad-libs, duets) and background vocals get their own rows.
struct DotDisplay: View, Equatable {
    let chunks: [LyricChunk]
    let lyricsID: Int
    let length: LyricLength
    let clock: PlaybackClock
    let style: LyricStyle
    let ledColor: SignColor
    let scale: Double

    static func == (a: Self, b: Self) -> Bool {
        a.lyricsID == b.lyricsID && a.length == b.length && a.clock == b.clock && a.style == b.style
            && a.ledColor == b.ledColor && a.scale == b.scale
    }

    var body: some View {
        GeometryReader { geo in
            // Half-point steps keep the grid crisp on Retina.
            let cell = ((min(max(geo.size.width / 100, 5), 16) * scale) * 2).rounded() / 2
            let gridCols = Int((geo.size.width / cell).rounded(.up))
            let gridRows = Int((geo.size.height / cell).rounded(.up))

            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !clock.playing)) { context in
                DotBoard(words: words(at: clock.time(at: context.date)),
                         maxCols: gridCols - 8, gridCols: gridCols, gridRows: gridRows,
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

/// Lays the words out in dots, centers them on the grid, and hands them to the LED or LCD shader.
struct DotBoard: View, Equatable {
    let words: [DotWord]
    let maxCols: Int
    let gridCols: Int
    let gridRows: Int
    let cell: Double
    let size: CGSize
    let style: LyricStyle
    let ledColor: SignColor

    static func == (a: Self, b: Self) -> Bool {
        a.words == b.words && a.maxCols == b.maxCols && a.gridCols == b.gridCols
            && a.gridRows == b.gridRows && a.cell == b.cell && a.style == b.style && a.ledColor == b.ledColor
    }

    var body: some View {
        let bitmap = DotBitmap(words: words, wordGap: style == .lcd ? DotBitmap.charAdvance : 4,
                               maxCols: maxCols)
        let origin = CGPoint(x: (gridCols - bitmap.cols) / 2, y: (gridRows - bitmap.rows) / 2)
        let dots = Shader.Argument.floatArray(bitmap.packed)

        return Rectangle().colorEffect(style == .lcd
            ? ShaderLibrary.lcdBoard(.float2(size), .float(cell), .color(LCDColors.ink), .color(LCDColors.backlight),
                                     dots, .float2(origin), .float(Float(bitmap.cols)), .float(Float(bitmap.rows)),
                                     .float(Float(bitmap.packedStride)))
            : ShaderLibrary.ledBoard(.float(cell), .color(ledColor.color),
                                     dots, .float2(origin), .float(Float(bitmap.cols)), .float(Float(bitmap.rows)),
                                     .float(Float(bitmap.packedStride))))
    }
}
