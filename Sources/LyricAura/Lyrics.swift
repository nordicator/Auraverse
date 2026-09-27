import Foundation

struct LyricWord: Identifiable {
    let id: Int
    let text: String
    let start: Double
    let end: Double
    /// Looked up once at parse time, not every frame.
    let emoji: String?
}

/// A short piece of a lyric line (long lines are cut into several) shown on screen at once.
struct LyricChunk: Identifiable {
    let id: Int
    let start: Double
    let words: [LyricWord]
}

/// Fetches synced lyrics from lrclib.net (free, no API key).
enum LyricsFetcher {
    private struct Result: Decodable {
        let syncedLyrics: String?
    }

    static func fetch(_ track: Track) async -> [TimedLine] {
        // Exact match first, then fall back to a search.
        var get = URLComponents(string: "https://lrclib.net/api/get")!
        get.queryItems = [
            .init(name: "track_name", value: track.name),
            .init(name: "artist_name", value: track.artist),
            .init(name: "album_name", value: track.album),
            .init(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        if let r: Result = await load(get.url!), let lrc = r.syncedLyrics {
            return parse(lrc)
        }

        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [
            .init(name: "track_name", value: track.name),
            .init(name: "artist_name", value: track.artist),
        ]
        if let results: [Result] = await load(search.url!),
           let lrc = results.lazy.compactMap(\.syncedLyrics).first {
            return parse(lrc)
        }
        return []
    }

    private static func load<T: Decodable>(_ url: URL) async -> T? {
        var request = URLRequest(url: url)
        request.setValue("LyricAura 0.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - LRC parsing

    /// Parses LRC lines like "[01:23.45] some words", including enhanced LRC
    /// word tags ("<01:23.45> some <01:23.90> words") when present.
    static func parse(_ lrc: String) -> [TimedLine] {
        let lineTag = #/\[(\d+):(\d+(?:\.\d+)?)\]/#
        var lines: [(time: Double, text: String)] = []
        for raw in lrc.split(separator: "\n") {
            let stamps = raw.matches(of: lineTag)
            guard let last = stamps.last else { continue }
            let text = raw[last.range.upperBound...].trimmingCharacters(in: .whitespaces)
            for m in stamps {
                lines.append((seconds(m.1, m.2), text))
            }
        }
        lines.sort { $0.time < $1.time }

        return lines.enumerated().map { i, line in
            let end = i + 1 < lines.count ? lines[i + 1].time : line.time + 5
            return (line.time, timedWords(line.text, start: line.time, end: end))
        }
    }

    private static func timedWords(_ text: String, start: Double, end: Double) -> [TimedWord] {
        let wordTag = #/<(\d+):(\d+(?:\.\d+)?)>/#
        let tags = text.matches(of: wordTag)
        guard !tags.isEmpty else { return LyricChunker.estimateWords(text, start: start, end: end) }

        // Enhanced LRC: real per-word timings.
        var result: [TimedWord] = []
        for (i, tag) in tags.enumerated() {
            let segmentEnd = i + 1 < tags.count ? tags[i + 1].range.lowerBound : text.endIndex
            let segmentWords = text[tag.range.upperBound..<segmentEnd].split(whereSeparator: \.isWhitespace)
            let s = seconds(tag.1, tag.2)
            let e = i + 1 < tags.count ? seconds(tags[i + 1].1, tags[i + 1].2) : end
            for w in segmentWords { result.append((String(w), s, e)) }
        }
        return result
    }

    private static func seconds(_ min: Substring, _ sec: Substring) -> Double {
        (Double(min) ?? 0) * 60 + (Double(sec) ?? 0)
    }
}

typealias TimedWord = (text: String, start: Double, end: Double)
/// A lyric line as the source gave it. Kept whole so it can be re-split when the "lyric length" setting changes.
typealias TimedLine = (start: Double, words: [TimedWord])

/// Turns timed lines into on-screen chunks. Shared by every lyrics source.
enum LyricChunker {
    /// A line with no words becomes an empty chunk (shown as ♪). Lines longer than `maxWords` are cut into
    /// evenly sized pieces (e.g. 7 words with max 5 → 4 + 3, not 5 + 2).
    static func chunks(from lines: [TimedLine], maxWords: Int) -> [LyricChunk] {
        var chunks: [LyricChunk] = []
        var nextID = 0
        for line in lines {
            let words = line.words
            if words.isEmpty {
                chunks.append(LyricChunk(id: nextID, start: line.start, words: []))
                nextID += 1
                continue
            }
            let pieces = words.count <= maxWords ? 1 : (words.count + maxWords - 1) / maxWords
            let size = (words.count + pieces - 1) / pieces
            for (p, from) in stride(from: 0, to: words.count, by: size).enumerated() {
                let slice = words[from..<min(from + size, words.count)]
                let chunkWords = slice.map { w in
                    defer { nextID += 1 }
                    return LyricWord(id: nextID, text: w.text, start: w.start, end: w.end, emoji: Emoji.for(w.text))
                }
                chunks.append(LyricChunk(id: nextID, start: p == 0 ? line.start : slice.first!.start, words: chunkWords))
                nextID += 1
            }
        }
        // Lines can overlap (ad-libs, background vocals start before the previous line ends).
        // The stage picks "the last chunk that has started", so starts must never go backwards.
        var latest = -Double.infinity
        return chunks.map { chunk in
            latest = max(latest, chunk.start)
            return LyricChunk(id: chunk.id, start: latest, words: chunk.words)
        }
    }

    /// No per-word timing available: guess, spreading the words by length over the time the line is probably being sung.
    static func estimateWords(_ text: String, start: Double, end: Double) -> [TimedWord] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let singTime = min(end - start, Double(words.count) * 0.4 + 0.6)
        let weights = words.map { Double($0.count + 2) }
        let total = weights.reduce(0, +)
        var t = start
        return zip(words, weights).map { word, weight in
            let d = singTime * weight / total
            defer { t += d }
            return (word, t, t + d)
        }
    }
}
