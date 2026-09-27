import SwiftUI

struct Track: Equatable {
    let name: String
    let artist: String
    let album: String
    let duration: Double
}

/// Where playback was at a known moment. The UI extrapolates from this instead of being told the
/// time every frame, so it only changes on play/pause/seek/track change.
struct PlaybackClock: Equatable {
    var position: Double = 0
    var date = Date()
    var playing = false

    func time(at date: Date) -> Double {
        playing ? position + date.timeIntervalSince(self.date) : position
    }
}

/// Follows Apple Music's current track and playback position,
/// and loads lyrics + artwork when the track changes.
@MainActor
final class MusicWatcher: ObservableObject {
    @Published private(set) var track: Track?
    @Published private(set) var clock = PlaybackClock()
    @Published private(set) var lines: [TimedLine] = []
    /// Bumped whenever `lyrics` is replaced, so views can compare lyrics cheaply.
    @Published private(set) var lyricsID = 0
    @Published private(set) var lyricsSource: LyricsSource?
    @Published private(set) var artwork: NSImage?
    @Published private(set) var status = "Waiting for Apple Music…"

    enum LyricsSource: String {
        case appleMusic = "Apple Music"
        case lrclib = "LRCLIB"
    }

    private let bridge = MusicBridge()
    private var polling = false
    private var pollAgain = false
    private var timer: Timer?
    private var observer: NSObjectProtocol?

    init() {
        poll()
        // Music announces track changes and play/pause itself, so react to that immediately...
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // ...and only poll now and then to catch seeks (which it doesn't announce) and drift.
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.3 // lets macOS batch wakeups
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func poll() {
        guard !polling else { pollAgain = true; return }
        polling = true
        Task {
            apply(await bridge.poll())
            polling = false
            if pollAgain { pollAgain = false; poll() }
        }
    }

    private func apply(_ result: MusicBridge.PollResult) {
        guard case let .playing(newTrack, position, playing, date) = result else {
            if track != nil {
                track = nil
                artwork = nil
                setLyrics([], source: nil)
            }
            if clock.playing { clock.playing = false }
            MusicAudio.shared.update(playing: false)
            status = result == .failed ? "Can't reach Apple Music (check Automation permission)" : "Nothing playing in Apple Music"
            return
        }

        // Only re-anchor when we've drifted, so small AppleScript latency doesn't make the lyrics jitter
        // (and so views depending on the clock aren't invalidated on every poll).
        if playing != clock.playing || abs(clock.time(at: date) - position) > 0.3 || newTrack != track {
            clock = PlaybackClock(position: position, date: date, playing: playing)
        }

        MusicAudio.shared.update(playing: playing && SettingsKey.musicReaction > 0) // off = don't listen at all

        if newTrack != track {
            track = newTrack
            loadLyrics(for: newTrack)
            loadArtwork(for: newTrack)
        }
    }

    private func loadLyrics(for track: Track) {
        setLyrics([], source: nil)
        status = "Loading lyrics…"
        Task {
            let cached = await Task.detached { AppleMusicLyrics.find(track) }.value
            guard self.track == track else { return } // track changed while loading
            if let lines = cached.lines {
                setLyrics(lines, source: .appleMusic)
                return
            }
            let lines = await LyricsFetcher.fetch(track)
            guard self.track == track else { return }
            setLyrics(lines, source: lines.isEmpty ? nil : .lrclib)
            watchAppleMusicCache(for: track, after: cached.newestEntry)
        }
    }

    /// Music may download its (better, word-timed) lyrics after we've looked, e.g. when the
    /// lyrics pane is opened. Keep checking its cache while this track plays and switch over if they show up.
    /// Only cache entries newer than the last check are read, so this is nearly free.
    private func watchAppleMusicCache(for track: Track, after entry: Int64) {
        Task {
            var newest = entry
            while self.track == track {
                try? await Task.sleep(for: .seconds(5))
                guard self.track == track else { return }
                let after = newest
                let found = await Task.detached { AppleMusicLyrics.find(track, after: after) }.value
                newest = max(newest, found.newestEntry)
                if let lines = found.lines, self.track == track {
                    setLyrics(lines, source: .appleMusic)
                    return
                }
            }
        }
    }

    private var chunkCache: (lyricsID: Int, maxWords: Int, chunks: [LyricChunk])?

    /// The lyrics split into on-screen pieces of at most `maxWords` words. Cached, so this is only
    /// recomputed when the lyrics or the "lyric length" setting change.
    func chunks(maxWords: Int) -> [LyricChunk] {
        if let cache = chunkCache, cache.lyricsID == lyricsID, cache.maxWords == maxWords { return cache.chunks }
        let chunks = LyricChunker.chunks(from: lines, maxWords: maxWords)
        chunkCache = (lyricsID, maxWords, chunks)
        return chunks
    }

    private func setLyrics(_ lines: [TimedLine], source: LyricsSource?) {
        self.lines = lines
        lyricsID += 1
        lyricsSource = source
        status = lines.isEmpty ? "No synced lyrics found" : ""
    }

    private func loadArtwork(for track: Track) {
        Task {
            var image = await bridge.artwork().flatMap(NSImage.init(data:))
            if image == nil { image = await Artwork.search(track) }
            guard self.track == track else { return }
            self.artwork = image.flatMap(Artwork.prepared)
        }
    }
}

/// Runs the AppleScript on a background queue: Apple Events block until Music answers,
/// and doing that on the main thread was stalling the animation.
private final class MusicBridge: @unchecked Sendable {
    enum PollResult: Equatable {
        case playing(Track, position: Double, isPlaying: Bool, at: Date)
        case idle
        case failed
    }

    private let queue = DispatchQueue(label: "Auraverse.MusicBridge")
    // Only touched on `queue`.
    private lazy var pollScript = NSAppleScript(source: """
        if application "Music" is running then
            tell application "Music"
                if player state is stopped then return {}
                set t to current track
                return {name of t, artist of t, album of t, duration of t, player position, (player state is playing)}
            end tell
        end if
        return {}
        """)
    private lazy var artworkScript = NSAppleScript(source: """
        tell application "Music" to get data of artwork 1 of current track
        """)

    func poll() async -> PollResult {
        await run {
            var error: NSDictionary?
            guard let r = self.pollScript?.executeAndReturnError(&error), r.numberOfItems == 6 else {
                return error == nil ? .idle : .failed
            }
            let track = Track(
                name: r.atIndex(1)?.stringValue ?? "",
                artist: r.atIndex(2)?.stringValue ?? "",
                album: r.atIndex(3)?.stringValue ?? "",
                duration: r.atIndex(4)?.doubleValue ?? 0
            )
            return .playing(track, position: r.atIndex(5)?.doubleValue ?? 0,
                            isPlaying: r.atIndex(6)?.booleanValue ?? false, at: Date())
        }
    }

    func artwork() async -> Data? {
        await run { self.artworkScript?.executeAndReturnError(nil).data }
    }

    private func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
