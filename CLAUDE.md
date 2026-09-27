# LyricAura

Basic macOS SwiftUI app: shows synced lyrics for whatever's playing in Apple Music.

## Rules
- **DO NOT test by launching the app or opening any windows.** No `open LyricAura.app`, no running the binary, no screenshots, no UI automation. Compiling (`swift build` / `./build.sh`) is fine and is how to verify. The user runs the app themselves.
- Keep it extremely basic. Don't add features that weren't asked for.

## Layout
- `Sources/LyricAura/` — SwiftUI app (SwiftPM executable target)
  - `MusicWatcher.swift` — follows Music via its `com.apple.Music.playerInfo` distributed notification + a 1.5s AppleScript poll (background queue — never on main) for seeks. Publishes a `PlaybackClock` that only changes on play/pause/seek/track change
  - `AppleMusicLyrics.swift` — primary lyrics source: reads Music.app's own cached Apple Music API responses (`~/Library/Caches/com.apple.Music/Cache.db` + `fsCachedData/`) and parses the TTML (word/syllable timing). Only has songs Music has fetched lyrics for; re-checked every 5s while falling back to LRCLIB.
  - `Lyrics.swift` — fallback: fetches synced (LRC) lyrics from lrclib.net, parses them into short chunks with per-word timings (real if enhanced LRC, estimated otherwise)
  - `Artwork.swift` — album art (from Music, or iTunes Search fallback), downscaled once to 512px
  - `Styles.swift` — user-selectable styles (Classic/Fisheye/VHS/Liquid), warped + blurred album-cover background (shader and blur run on a 1/8-size copy, 30fps), keyword → emoji popups
  - `Settings.swift` — user options (@AppStorage): theme, font, weight, text size, lyric length (word/phrase/short/full line), emojis; the Settings window (⌘,). Parsers produce whole `TimedLine`s; `MusicWatcher.chunks(maxWords:)` splits them per the length setting (cached)
  - `ContentView.swift` — the lyrics window. Performance matters (user complained about heat): never put the whole window under one per-frame TimelineView. See the rendering-budget comment at the top
- `Shaders/Shaders.metal` — SwiftUI Metal shaders; `build.sh` compiles them to `Contents/Resources/default.metallib` (needs `xcodebuild -downloadComponent MetalToolchain`). `swift run` won't have them.
- `Info.plist` — bundle info (includes `NSAppleEventsUsageDescription`, needed to talk to Music)
- `build.sh` — builds and wraps the binary into `LyricAura.app`

## Build
    ./build.sh        # produces ./LyricAura.app
