import SwiftUI

/// Album artwork lookup for the background.
enum Artwork {
    static let defaultColors: [Color] = [
        .indigo, .purple, .blue,
        .purple, .black, .indigo,
        .blue, .indigo, .purple,
    ]

    /// Fallback when Music can't hand us the artwork (e.g. streamed tracks): iTunes Search API.
    static func search(_ track: Track) async -> NSImage? {
        struct Response: Decodable {
            struct Item: Decodable { let artworkUrl100: String? }
            let results: [Item]
        }
        var url = URLComponents(string: "https://itunes.apple.com/search")!
        url.queryItems = [
            .init(name: "term", value: "\(track.artist) \(track.name)"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "1"),
        ]
        guard let (data, _) = try? await URLSession.shared.data(from: url.url!),
              let small = try? JSONDecoder().decode(Response.self, from: data).results.first?.artworkUrl100,
              let big = URL(string: small.replacingOccurrences(of: "100x100", with: "600x600")),
              let (imageData, _) = try? await URLSession.shared.data(from: big) else { return nil }
        return NSImage(data: imageData)
    }

    /// Redraws the cover once at a fixed small size, so the GPU works with a 512px texture
    /// instead of a (possibly 3000px) original every frame.
    static func prepared(_ image: NSImage) -> NSImage? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = 512
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let small = ctx.makeImage() else { return nil }
        return NSImage(cgImage: small, size: NSSize(width: side, height: side))
    }
}
