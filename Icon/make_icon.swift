// Draws the Auraverse app icon: a glowing aura of album-art colors behind an LED dot-matrix
// level meter (like the LED Sign style's side meters). Writes AppIcon.icns next to this file.
//   swift Icon/make_icon.swift
import AppKit
import CoreImage

let size = 1024
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

func color(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func context() -> CGContext {
    CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}

func blurred(_ image: CGImage, _ radius: Double) -> CGImage {
    let ci = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: radius)
        .cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    return CIContext().createCGImage(ci, from: ci.extent)!
}

// macOS icon grid: 824pt body centered on the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

// 1. The aura: soft blobs of color, heavily blurred.
let aura = context()
aura.setFillColor(color(0.05, 0.03, 0.12))
aura.fill(CGRect(x: 0, y: 0, width: size, height: size))
let blobs: [(Double, Double, Double, CGColor)] = [
    (190, 850, 300, color(0.55, 0.2, 1.0)),   // violet, top left
    (850, 830, 290, color(1.0, 0.22, 0.55)),  // pink, top right
    (840, 180, 300, color(1.0, 0.55, 0.12)),  // amber, bottom right
    (180, 190, 290, color(0.1, 0.72, 0.98)),  // cyan, bottom left
]
for (x, y, r, c) in blobs {
    aura.setFillColor(c)
    aura.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
}
let auraImage = blurred(aura.makeImage()!, 110)

// 2. The LED meter: mirrored bars of round dots growing from the middle row.
let pitch = 54.0
let dotRadius = 18.0
let heights = [2, 4, 6, 5, 7, 4, 6, 3, 2] // half-heights in dots, a little waveform
let meter = context()
let litOnly = context() // the glow comes from lit dots only, or the unlit grid blurs into grey haze
let columns = Double(heights.count)
for (i, h) in heights.enumerated() {
    let x = 512 + (Double(i) - (columns - 1) / 2) * pitch
    for row in -6...6 {
        let y = 512 + Double(row) * pitch
        let lit = abs(row) < h
        let dot = CGRect(x: x - dotRadius, y: y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)
        if lit {
            // Warmer at the tips, white-hot in the middle, like the LED shader's hot core.
            let t = Double(abs(row)) / 6
            meter.setFillColor(color(1.0, 0.9 - 0.3 * t, 0.7 - 0.6 * t))
            litOnly.setFillColor(color(1.0, 0.6 - 0.2 * t, 0.2 - 0.15 * t))
            litOnly.fillEllipse(in: dot)
        } else {
            meter.setFillColor(color(1, 1, 1, 0.06))
        }
        meter.fillEllipse(in: dot)
    }
}
let meterImage = meter.makeImage()!
let glowImage = blurred(litOnly.makeImage()!, 30)

// 3. Composite inside the rounded body.
let out = context()
out.saveGState()
out.addPath(shape)
out.clip()
out.draw(auraImage, in: CGRect(x: 0, y: 0, width: size, height: size))
// Darken the middle a touch so the LEDs pop.
let vignette = CGGradient(colorsSpace: nil,
                          colors: [color(0.02, 0.01, 0.05, 0.92), color(0.02, 0.01, 0.05, 0.6), color(0, 0, 0, 0)] as CFArray,
                          locations: [0, 0.6, 1])!
out.drawRadialGradient(vignette, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 512), endRadius: 520, options: [])
out.setBlendMode(.screen)
out.draw(glowImage, in: CGRect(x: 0, y: 0, width: size, height: size))
out.setBlendMode(.normal)
out.draw(meterImage, in: CGRect(x: 0, y: 0, width: size, height: size))
// Glassy highlight across the top.
let shine = CGGradient(colorsSpace: nil, colors: [color(1, 1, 1, 0.18), color(1, 1, 1, 0)] as CFArray,
                       locations: [0, 1])!
out.drawLinearGradient(shine, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
out.restoreGState()
// Thin light rim.
out.addPath(shape)
out.setStrokeColor(color(1, 1, 1, 0.12))
out.setLineWidth(3)
out.strokePath()
let icon = out.makeImage()!

// 4. Every size an .icns needs, then iconutil.
let iconset = here.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let c = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.interpolationQuality = .high
        c.draw(icon, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let png = NSBitmapImageRep(cgImage: c.makeImage()!).representation(using: .png, properties: [:])!
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try! png.write(to: iconset.appendingPathComponent(name))
    }
}
try! NSBitmapImageRep(cgImage: icon).representation(using: .png, properties: [:])!
    .write(to: here.appendingPathComponent("AppIcon.png"))

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", here.appendingPathComponent("AppIcon.icns").path]
try! iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconset)
print("Wrote Icon/AppIcon.icns")
