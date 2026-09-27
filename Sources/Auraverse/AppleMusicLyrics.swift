import Foundation
import SQLite3

/// Reads the lyrics Music.app itself downloaded, straight out of its URL cache.
///
/// Music caches its Apple Music API responses in ~/Library/Caches/com.apple.Music/Cache.db
/// (a standard NSURLCache SQLite db). Responses for `…&include=syllable-lyrics` are JSON with
/// the song's name/artist/duration and the lyrics as TTML, usually with per-word timing.
/// Big responses live in fsCachedData/<file>, small ones inline in the db.
/// Music only caches lyrics for songs it has fetched them for, so this can miss.
enum AppleMusicLyrics {
    private static let cacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/com.apple.Music")

    /// Looks for the track's lyrics in cache entries newer than `after` (0 = all).
    /// Also returns the newest entry seen, so the next check can skip everything already read.
    static func find(_ track: Track, after: Int64 = 0) -> (lines: [TimedLine]?, newestEntry: Int64) {
        let responses = cachedResponses(after: after)
        let newest = responses.map(\.entry).max() ?? after
        // Cheap byte search before a full JSON decode. Skipped for names JSON would escape.
        let needle = track.name.contains(where: { "\"\\/".contains($0) }) ? nil : Data(track.name.utf8)

        for response in responses {
            if let needle, response.body.range(of: needle) == nil { continue }
            guard let json = try? JSONDecoder().decode(Response.self, from: response.body) else { continue }
            for song in json.data where matches(song.attributes, track) {
                guard let lyrics = song.relationships?.syllableLyrics?.data.first?.attributes,
                      let ttml = lyrics.ttmlLocalizations ?? lyrics.ttml else { continue }
                let lines = TTMLParser.parse(ttml)
                if !lines.isEmpty { return (lines, newest) }
            }
        }
        return (nil, newest)
    }

    private static func matches(_ song: Response.Song.Attributes, _ track: Track) -> Bool {
        func norm(_ s: String) -> String { s.lowercased().trimmingCharacters(in: .whitespaces) }
        let artist = norm(song.artistName), trackArtist = norm(track.artist)
        return norm(song.name) == norm(track.name)
            && (artist.contains(trackArtist) || trackArtist.contains(artist))
            && abs(Double(song.durationInMillis) / 1000 - track.duration) < 3
    }

    /// Raw bodies of cached lyrics responses with entry ID > `after`, newest first.
    private static func cachedResponses(after: Int64) -> [(entry: Int64, body: Data)] {
        var db: OpaquePointer?
        let path = cacheDir.appendingPathComponent("Cache.db").path
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT r.entry_ID, d.isDataOnFS, d.receiver_data FROM cfurl_cache_response r
            JOIN cfurl_cache_receiver_data d ON d.entry_ID = r.entry_ID
            WHERE r.request_key LIKE '%syllable-lyrics%' AND r.entry_ID > ?
            ORDER BY r.time_stamp DESC
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, after)

        var responses: [(Int64, Data)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let entry = sqlite3_column_int64(statement, 0)
            let length = Int(sqlite3_column_bytes(statement, 2))
            guard let bytes = sqlite3_column_blob(statement, 2), length > 0 else { continue }
            let blob = Data(bytes: bytes, count: length)
            if sqlite3_column_int(statement, 1) == 1 {
                // On disk: the blob is the file name.
                let name = String(decoding: blob, as: UTF8.self)
                if let data = try? Data(contentsOf: cacheDir.appendingPathComponent("fsCachedData/\(name)")) {
                    responses.append((entry, data))
                }
            } else {
                responses.append((entry, blob))
            }
        }
        return responses
    }

    private struct Response: Decodable {
        let data: [Song]

        struct Song: Decodable {
            let attributes: Attributes
            let relationships: Relationships?

            struct Attributes: Decodable {
                let name: String
                let artistName: String
                let durationInMillis: Int
            }
            struct Relationships: Decodable {
                let syllableLyrics: LyricsList?
                enum CodingKeys: String, CodingKey { case syllableLyrics = "syllable-lyrics" }
            }
            struct LyricsList: Decodable {
                let data: [Lyrics]
            }
            struct Lyrics: Decodable {
                let attributes: LyricsAttributes
            }
            struct LyricsAttributes: Decodable {
                let ttml: String?
                let ttmlLocalizations: String?
            }
        }
    }
}

/// Parses Apple's lyrics TTML:
///
///     <p begin="0.000" end="1.539"><span begin="0.000" end="0.451">I</span> <span …>lo—</span></p>
///
/// Each `<p>` is a line. Timed `<span>`s are words or syllables: spans touching with no whitespace
/// between them are syllables of one word. `<span ttm:role="x-bg">` wraps background vocals, which are
/// kept separately (`TimedLine.background`) so they can be shown as their own line.
/// Line-timed lyrics have no spans; their words get estimated timings.
final class TTMLParser: NSObject, XMLParserDelegate {
    private var lines: [(start: Double, end: Double, words: [TimedWord], background: [TimedWord])] = []

    private var inLine = false
    private var lineStart = 0.0, lineEnd = 0.0
    private var lineText = ""
    private var lineWords: [TimedWord] = []
    private var lineBackground: [TimedWord] = []
    private var pendingWord: TimedWord?
    private var pendingIsBackground = false

    /// Open spans, innermost last. `container` = has child spans, `background` = inside an x-bg span.
    private var spans: [(start: Double?, end: Double?, text: String, container: Bool, background: Bool)] = []

    static func parse(_ ttml: String) -> [TimedLine] {
        let delegate = TTMLParser()
        let parser = XMLParser(data: Data(ttml.utf8))
        parser.delegate = delegate
        guard parser.parse() else { return [] }
        return delegate.timedLines()
    }

    private func timedLines() -> [TimedLine] {
        var timed: [TimedLine] = []
        for (i, line) in lines.enumerated() {
            timed.append(TimedLine(start: line.start, words: line.words, background: line.background))
            // Long gap before the next line (or after the last): show ♪ instead of a stale line.
            let next = i + 1 < lines.count ? lines[i + 1].start : .infinity
            if next - line.end > 4 { timed.append(TimedLine(start: line.end + 0.5, words: [])) }
        }
        return timed
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        switch name {
        case "p":
            inLine = true
            lineStart = Self.seconds(attributes["begin"]) ?? 0
            lineEnd = Self.seconds(attributes["end"]) ?? lineStart
            lineText = ""
            lineWords = []
            lineBackground = []
            pendingWord = nil
        case "span" where inLine:
            if !spans.isEmpty { spans[spans.count - 1].container = true }
            let background = attributes["ttm:role"] == "x-bg" || spans.last?.background == true
            spans.append((Self.seconds(attributes["begin"]), Self.seconds(attributes["end"]), "", false, background))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard inLine else { return }
        lineText += string
        if spans.isEmpty || spans[spans.count - 1].start == nil || spans[spans.count - 1].container {
            // Text between timed spans: whitespace means the current word is finished.
            if string.contains(where: \.isWhitespace) { flushWord() }
        } else {
            spans[spans.count - 1].text += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "span" where inLine:
            guard let span = spans.popLast() else { return }
            if span.container {
                flushWord() // background vocal group ended
            } else if let start = span.start {
                addTimedText(span.text, start: start, end: span.end ?? start, background: span.background)
            }
        case "p":
            flushWord()
            let words = lineWords.isEmpty
                ? LyricChunker.estimateWords(lineText, start: lineStart, end: lineEnd)
                : lineWords
            lines.append((lineStart, lineEnd, words, lineBackground))
            inLine = false
        default:
            break
        }
    }

    /// A timed span is usually one word or syllable, but can hold several words ("What you");
    /// those share the span's time, split by length.
    private func addTimedText(_ text: String, start: Double, end: Double, background: Bool) {
        let parts = text.split(whereSeparator: \.isWhitespace)
        guard !parts.isEmpty else { return }
        // Switching between main and background vocals always ends the current word.
        if text.first?.isWhitespace == true || (pendingWord != nil && pendingIsBackground != background) { flushWord() }
        pendingIsBackground = background

        let total = Double(parts.reduce(0) { $0 + $1.count })
        var t = start
        for (i, part) in parts.enumerated() {
            let d = (end - start) * Double(part.count) / total
            if i > 0 { flushWord() }
            if var word = pendingWord { // continuing a word split into syllables
                word.text += part
                word.end = t + d
                pendingWord = word
            } else {
                pendingWord = (String(part), t, t + d)
            }
            t += d
        }
        if text.last?.isWhitespace == true { flushWord() }
    }

    private func flushWord() {
        if let word = pendingWord, !word.text.isEmpty {
            if pendingIsBackground { lineBackground.append(word) } else { lineWords.append(word) }
        }
        pendingWord = nil
    }

    /// "12.345", "1:23.456" or "01:23:45.678" (optionally with a trailing "s").
    private static func seconds(_ value: String?) -> Double? {
        guard let value else { return nil }
        var total = 0.0
        for part in value.replacingOccurrences(of: "s", with: "").split(separator: ":") {
            guard let n = Double(part) else { return nil }
            total = total * 60 + n
        }
        return total
    }
}
