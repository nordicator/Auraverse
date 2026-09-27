# Auraverse

Basic macOS SwiftUI app: shows synced lyrics for whatever's playing in Apple Music.

## Rules
- **DO NOT test by launching the app or opening any windows.** No `open Auraverse.app`, no running the binary, no screenshots, no UI automation. Compiling (`swift build` / `./build.sh`) is fine and is how to verify. The user runs the app themselves.
- Keep it extremely basic. Don't add features that weren't asked for.

## Layout
- `Sources/Auraverse/` — SwiftUI app (SwiftPM executable target)
  - `MusicWatcher.swift` — follows Music via its `com.apple.Music.playerInfo` distributed notification + a 1.5s AppleScript poll (background queue — never on main) for seeks. Publishes a `PlaybackClock` that only changes on play/pause/seek/track change; the published `clock` is frozen while the app is fully hidden (occlusion), which pauses every animation and the audio tap
  - `AppleMusicLyrics.swift` — primary lyrics source: reads Music.app's own cached Apple Music API responses (`~/Library/Caches/com.apple.Music/Cache.db` + `fsCachedData/`) and parses the TTML (word/syllable timing). Background vocals (`ttm:role="x-bg"`) are kept separately (`TimedLine.background` → `LyricChunk.backing`, shown as a smaller second line / extra dot row); overlapping lines (ad-libs, duets) stay lit together via `LyricChunk.overlaps`. Only has songs Music has fetched lyrics for; re-checked every 5s while falling back to LRCLIB.
  - `Lyrics.swift` — fallback: fetches synced (LRC) lyrics from lrclib.net, parses them into short chunks with per-word timings (real if enhanced LRC, estimated otherwise)
  - `MusicAudio.swift` — listens to Music's audio via a Core Audio process tap (private aggregate device; needs `NSAudioCaptureUsageDescription`), FFT → `AudioLevels` (4 band meters, bass `kick`, `energy`, `flow` clock). Stored behind a lock, not published: only views that already have a per-frame clock read it (background, dot displays). Runs only while Music plays
  - `Artwork.swift` — album art (from Music, or iTunes Search fallback), downscaled once to 512px
  - `Styles.swift` — user-selectable styles (Classic/Fisheye/VHS/Liquid), warped + blurred album-cover background (shader and blur run on a 1/8-size copy, 30fps; flows faster when loud, punches in on bass hits), keyword → emoji popups
  - `Settings.swift` — user options (@AppStorage): theme, font, weight, text size, lyric length (word/phrase/short/full line), emojis, react to music + intensity (`SettingsKey.musicReaction`; off = the audio tap never runs); the Settings window (⌘,). Parsers produce whole `TimedLine`s; `MusicWatcher.chunks(maxWords:)` splits them per the length setting (cached)
  - `Sign.swift` + `DotFont.swift` — LED Sign / LCD Screen styles (`DotDisplay`): whole window is the display (`ledBoard` / `lcdBoard` shaders). The current chunk (per the lyric-length setting) is drawn centered in a real 5×7 dot font (uppercase ASCII), wrapped onto rows, no scrolling. Fixed size (font/weight/size settings are disabled for these styles); level meters down both sides (`meterValue`), text limited to `gridCols - 2 * DotBoard.meterCols` so it can't touch them. LED: unsung words dim, light up as sung. LCD: types out letter by letter (no cursor). Don't pixelate regular fonts or apply the effect to the lyric column — that was unreadable / only covered the text's bounds
  - `ContentView.swift` — the lyrics window. Performance matters (user complained about heat): never put the whole window under one per-frame TimelineView. See the rendering-budget comment at the top
- `Shaders/Shaders.metal` — SwiftUI Metal shaders. Shader arguments (e.g. `.floatArray`) go through Metal's 4 KB small-data path — keep arrays well under 1024 floats (dot displays pack 3 column bytes per float; see `DotBitmap`), or the shader silently draws nothing. `build.sh` compiles them to `Contents/Resources/default.metallib` (needs `xcodebuild -downloadComponent MetalToolchain`). `swift run` won't have them.
- `Info.plist` — bundle info (includes `NSAppleEventsUsageDescription`, needed to talk to Music)
- `Icon/make_icon.swift` — draws the app icon (aura + LED meter) → `Icon/AppIcon.icns` (committed; `build.sh` copies it)
- `build.sh` — builds and wraps the binary into `Auraverse.app`

## Build
    ./build.sh        # produces ./Auraverse.app
