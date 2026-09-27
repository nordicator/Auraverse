import Foundation

/// The classic 5×7 dot-matrix font used on LED signs (same glyphs as HD44780 / Adafruit GFX).
/// Each glyph is 5 columns; each column is a 7-bit mask, bit 0 = top row.
enum DotFont {
    static let rows = 7
    static let glyphWidth = 5

    private static let glyphs: [Character: [UInt8]] = [
        " ": [0x00, 0x00, 0x00, 0x00, 0x00],
        "!": [0x00, 0x00, 0x5F, 0x00, 0x00],
        "\"": [0x00, 0x07, 0x00, 0x07, 0x00],
        "#": [0x14, 0x7F, 0x14, 0x7F, 0x14],
        "$": [0x24, 0x2A, 0x7F, 0x2A, 0x12],
        "%": [0x23, 0x13, 0x08, 0x64, 0x62],
        "&": [0x36, 0x49, 0x55, 0x22, 0x50],
        "'": [0x00, 0x05, 0x03, 0x00, 0x00],
        "(": [0x00, 0x1C, 0x22, 0x41, 0x00],
        ")": [0x00, 0x41, 0x22, 0x1C, 0x00],
        "*": [0x08, 0x2A, 0x1C, 0x2A, 0x08],
        "+": [0x08, 0x08, 0x3E, 0x08, 0x08],
        ",": [0x00, 0x50, 0x30, 0x00, 0x00],
        "-": [0x08, 0x08, 0x08, 0x08, 0x08],
        ".": [0x00, 0x60, 0x60, 0x00, 0x00],
        "/": [0x20, 0x10, 0x08, 0x04, 0x02],
        "0": [0x3E, 0x51, 0x49, 0x45, 0x3E],
        "1": [0x00, 0x42, 0x7F, 0x40, 0x00],
        "2": [0x42, 0x61, 0x51, 0x49, 0x46],
        "3": [0x21, 0x41, 0x45, 0x4B, 0x31],
        "4": [0x18, 0x14, 0x12, 0x7F, 0x10],
        "5": [0x27, 0x45, 0x45, 0x45, 0x39],
        "6": [0x3C, 0x4A, 0x49, 0x49, 0x30],
        "7": [0x01, 0x71, 0x09, 0x05, 0x03],
        "8": [0x36, 0x49, 0x49, 0x49, 0x36],
        "9": [0x06, 0x49, 0x49, 0x29, 0x1E],
        ":": [0x00, 0x36, 0x36, 0x00, 0x00],
        ";": [0x00, 0x56, 0x36, 0x00, 0x00],
        "=": [0x14, 0x14, 0x14, 0x14, 0x14],
        "?": [0x02, 0x01, 0x51, 0x09, 0x06],
        "@": [0x32, 0x49, 0x79, 0x41, 0x3E],
        "A": [0x7E, 0x11, 0x11, 0x11, 0x7E],
        "B": [0x7F, 0x49, 0x49, 0x49, 0x36],
        "C": [0x3E, 0x41, 0x41, 0x41, 0x22],
        "D": [0x7F, 0x41, 0x41, 0x22, 0x1C],
        "E": [0x7F, 0x49, 0x49, 0x49, 0x41],
        "F": [0x7F, 0x09, 0x09, 0x01, 0x01],
        "G": [0x3E, 0x41, 0x41, 0x51, 0x32],
        "H": [0x7F, 0x08, 0x08, 0x08, 0x7F],
        "I": [0x00, 0x41, 0x7F, 0x41, 0x00],
        "J": [0x20, 0x40, 0x41, 0x3F, 0x01],
        "K": [0x7F, 0x08, 0x14, 0x22, 0x41],
        "L": [0x7F, 0x40, 0x40, 0x40, 0x40],
        "M": [0x7F, 0x02, 0x04, 0x02, 0x7F],
        "N": [0x7F, 0x04, 0x08, 0x10, 0x7F],
        "O": [0x3E, 0x41, 0x41, 0x41, 0x3E],
        "P": [0x7F, 0x09, 0x09, 0x09, 0x06],
        "Q": [0x3E, 0x41, 0x51, 0x21, 0x5E],
        "R": [0x7F, 0x09, 0x19, 0x29, 0x46],
        "S": [0x46, 0x49, 0x49, 0x49, 0x31],
        "T": [0x01, 0x01, 0x7F, 0x01, 0x01],
        "U": [0x3F, 0x40, 0x40, 0x40, 0x3F],
        "V": [0x1F, 0x20, 0x40, 0x20, 0x1F],
        "W": [0x7F, 0x20, 0x18, 0x20, 0x7F],
        "X": [0x63, 0x14, 0x08, 0x14, 0x63],
        "Y": [0x03, 0x04, 0x78, 0x04, 0x03],
        "Z": [0x61, 0x51, 0x49, 0x45, 0x43],
        "♪": [0x20, 0x70, 0x3F, 0x01, 0x02], // shown during instrumental breaks
    ]

    /// Signs are uppercase ASCII: fold accents, straighten curly quotes and dashes, drop anything else.
    static func normalize(_ text: String) -> String {
        let replaced = text
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "“", with: "\"").replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "…", with: "...")
        let folded = replaced.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).uppercased()
        return String(folded.filter { glyphs[$0] != nil })
    }

    /// Column masks for already-normalized text, with one blank column between letters.
    static func columns(_ text: String) -> [UInt8] {
        var columns: [UInt8] = []
        for (i, character) in text.enumerated() {
            if i > 0 { columns.append(0) }
            columns += glyphs[character] ?? []
        }
        return columns
    }
}

/// A word to put on a dot display.
struct DotWord: Equatable {
    /// Already `DotFont.normalize`d.
    var text: String
    /// 0...1: how bright its dots are.
    var brightness: Float
    /// How many of its characters are shown (for typing it out). The layout always uses the full word,
    /// so rows don't reflow while typing.
    var visible: Int
    /// Start a new row with this word (a separate lyric line, or the background vocals).
    var newRow = false
}

/// A block of text laid out in dots, packed small enough for a SwiftUI shader argument.
///
/// Shader arguments go through Metal's small-data path (4 KB, i.e. 1024 floats), so one float per dot
/// is far too big for a few rows of text. Instead each text row is stored as one byte per column
/// (bits 0–6 = the 7 dots, bit 7 = dim) and three bytes are packed into each float (exact up to 2^24).
struct DotBitmap {
    /// Width in dots.
    var cols: Int
    /// Height in dots.
    var rows: Int
    /// Text rows × cols column bytes.
    private(set) var bytes: [UInt8]

    static let charAdvance = DotFont.glyphWidth + 1
    static let rowGap = 3
    static let rowPitch = DotFont.rows + rowGap
    static let dimFlag: UInt8 = 0x80
    static let dimBrightness: Float = 0.3

    var textRows: Int { (rows + Self.rowGap) / Self.rowPitch }
    var packedStride: Int { (cols + 2) / 3 }

    /// `bytes` packed 3 per float, `packedStride` floats per text row. Decoded by `dotValue` in Shaders.metal.
    var packed: [Float] {
        var out = [Float](repeating: 0, count: textRows * packedStride)
        for t in 0..<textRows {
            for x in 0..<cols {
                out[t * packedStride + x / 3] += Float(UInt32(bytes[t * cols + x]) << (8 * UInt32(x % 3)))
            }
        }
        return out
    }

    /// Wraps the words into rows no wider than `maxCols`, each row centered.
    init(words: [DotWord], wordGap: Int, maxCols: Int) {
        // Greedy word wrap on full word widths.
        func width(_ w: DotWord) -> Int { max(w.text.count * Self.charAdvance - 1, 0) }
        var lines: [[Int]] = [[]]
        var lineWidth = 0
        for (i, word) in words.enumerated() {
            let extra = lines[lines.count - 1].isEmpty ? width(word) : wordGap + width(word)
            if (word.newRow || lineWidth + extra > maxCols), !lines[lines.count - 1].isEmpty {
                lines.append([i])
                lineWidth = width(word)
            } else {
                lines[lines.count - 1].append(i)
                lineWidth += extra
            }
        }
        let lineWidths = lines.map { line in
            line.map { width(words[$0]) }.reduce(0, +) + wordGap * max(line.count - 1, 0)
        }

        cols = min(lineWidths.max() ?? 0, maxCols)
        rows = lines.count * Self.rowPitch - Self.rowGap
        bytes = [UInt8](repeating: 0, count: lines.count * cols)

        for (l, line) in lines.enumerated() {
            var x = (cols - lineWidths[l]) / 2
            for i in line {
                let word = words[i]
                let dim = word.brightness < 1 ? Self.dimFlag : 0
                for (c, character) in word.text.enumerated() where c < word.visible {
                    for (gx, mask) in DotFont.columns(String(character)).enumerated() {
                        set(x + c * Self.charAdvance + gx, l, mask | dim)
                    }
                }
                x += width(word) + wordGap
            }
        }
    }

    private mutating func set(_ x: Int, _ line: Int, _ byte: UInt8) {
        guard x >= 0, x < cols else { return }
        bytes[line * cols + x] = byte
    }
}
