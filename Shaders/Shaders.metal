// SwiftUI shader effects. Compiled into default.metallib by build.sh.
#include <metal_stdlib>
#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

static float hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

// MARK: - Lyrics distortions

/// Barrel / fisheye lens: the middle is magnified and bulges toward you, the edges get squashed,
/// straight lines bow outward. Returns where to sample the original view for this pixel.
///
/// r is the distance from the center (0 = center, 1 = the corners). We sample from radius
/// f(r) = mix(r, 1 - sqrt(1 - r²), strength): a blend of "no lens" and a hemisphere projection.
/// f(1) = 1 so corners stay put, f'(0) = 1 - strength so the center is zoomed by 1 / (1 - strength),
/// and f' keeps growing toward the edge, which is what bends lines instead of just zooming.
[[ stitchable ]] float2 fisheye(float2 position, float2 size, float strength) {
    float2 c = size * 0.5;
    float radius = length(c);
    float2 d = (position - c) / radius;
    float r = length(d);
    if (r < 1e-4) return c;
    float sphere = 1.0 - sqrt(max(1.0 - r * r, 0.0));
    float f = mix(r, sphere, strength);
    return c + d * (f / r) * radius;
}

/// Gentle underwater wobble.
[[ stitchable ]] float2 wave(float2 position, float time, float amount) {
    return position + float2(sin(position.y * 0.035 + time * 2.2) * amount,
                             cos(position.x * 0.025 + time * 1.7) * amount * 0.6);
}

// MARK: - Whole-window effects

/// Old tape look: wobble, a rolling tracking band, glitch lines, RGB split, scanlines, grain.
[[ stitchable ]] half4 vhs(float2 position, SwiftUI::Layer layer, float2 size, float time) {
    float y = position.y / size.y;

    float shift = sin(position.y * 0.03 + time * 2.0) * 1.2;

    float bandY = y - fract(time * 0.12);
    float band = smoothstep(0.0, 0.02, bandY) * (1.0 - smoothstep(0.02, 0.07, bandY));
    shift += band * (hash(float2(floor(position.y / 3.0), floor(time * 30.0))) - 0.5) * 30.0;

    float glitch = step(0.985, hash(float2(floor(position.y / 6.0), floor(time * 12.0))));
    shift += glitch * (hash(float2(floor(position.y / 6.0), time)) - 0.5) * 40.0;

    float2 p = position + float2(shift, 0);
    float split = 2.5 + band * 5.0;
    half4 r = layer.sample(p + float2(split, 0));
    half4 g = layer.sample(p);
    half4 b = layer.sample(p - float2(split, 0));
    half4 c = half4(r.r, g.g, b.b, g.a);

    c.rgb *= half(0.82 + 0.18 * sin(position.y * M_PI_F));
    c.rgb += half((hash(position + fract(time) * 100.0) - 0.5) * 0.12);
    c.rgb += half(band * 0.08);

    float2 uv = position / size - 0.5;
    c.rgb *= half(1.0 - dot(uv, uv) * 0.9);
    c.rgb *= half3(1.05, 0.97, 0.9);
    return c;
}

// MARK: - Backgrounds

/// Mirror-repeat so coordinates outside 0...1 fold back into the image instead of smearing its edge.
static float2 mirrorRepeat(float2 uv) {
    return 1.0 - abs(1.0 - fract(uv * 0.5) * 2.0);
}

/// Rotates `p` around the origin.
static float2 rotate(float2 p, float angle) {
    float c = cos(angle), s = sin(angle);
    return float2(c * p.x - s * p.y, s * p.x + c * p.y);
}

/// Samples the cover at `p` (centered coordinates) after a swirl and a flowing wave warp.
static half4 warpedCover(SwiftUI::Layer layer, float2 size, float2 p, float time, float spin) {
    float r = length(p);
    p = rotate(p, spin * time * 0.05 + 1.2 * spin * sin(time * 0.15) * max(0.0, 1.0 - r)); // swirl, strongest in the middle
    p += 0.10 * sin(p.yx * 3.0 + time * float2(0.31, 0.23));
    p += 0.05 * sin(p.yx * 7.0 - time * float2(0.17, 0.29) * spin);
    float2 uv = mirrorRepeat(0.5 + p * 0.75); // zoomed in a bit so it reads as the cover, not a thumbnail
    return layer.sample(clamp(uv * size, float2(0.5), size - 0.5));
}

/// The album cover swirled and warped, two copies turning in opposite directions blended together.
/// Meant to be blurred afterwards. Applied to the cover image stretched over the view, so
/// `layer.sample(uv * size)` reads the cover at normalized coordinate `uv` whatever the aspect ratio.
[[ stitchable ]] half4 artworkFlow(float2 position, SwiftUI::Layer layer, float2 size, float time) {
    float2 p = (position / size - 0.5) * float2(size.x / size.y, 1.0); // centered, square units
    half4 a = warpedCover(layer, size, p, time, 1.0);
    half4 b = warpedCover(layer, size, rotate(p, 2.1) * 1.3, time + 40.0, -1.0);
    return mix(a, b, 0.45h);
}

// MARK: - Dot displays

/// Brightness (0, 0.3 dim, or 1) of grid cell `c` in a `cols` × `rows` dot block placed at grid cell `origin`.
/// The block is packed by `DotBitmap` (DotFont.swift): per text row (7 dot rows + 3 gap rows), one byte per
/// column (bits 0-6 = dots top to bottom, bit 7 = dim), three bytes per float, `stride` floats per text row.
static float dotValue(float2 c, device const float *dots, int count, float2 origin, float cols, float rows, float stride) {
    float2 local = c - origin;
    if (local.x < 0.0 || local.y < 0.0 || local.x >= cols || local.y >= rows) return 0.0;
    int x = int(local.x), y = int(local.y);
    int textRow = y / 10, dotRow = y % 10;
    if (dotRow >= 7) return 0.0;
    int i = textRow * int(stride) + x / 3;
    if (i >= count) return 0.0;
    uint column = (uint(dots[i]) >> (8u * uint(x % 3))) & 0xFFu;
    if (((column >> uint(dotRow)) & 1u) == 0u) return 0.0;
    return (column & 0x80u) != 0u ? 0.3 : 1.0;
}

/// LED sign (bus stop / train platform) filling the whole view: round LEDs on a `cell` grid.
/// Unlit LEDs stay faintly visible, like a real sign; lit ones have a hot core and a little glow.
[[ stitchable ]] half4 ledBoard(float2 position, half4 current, float cell, half4 color,
                                device const float *dots, int count, float2 origin, float cols, float rows, float stride) {
    float2 c = floor(position / cell);
    float on = dotValue(c, dots, count, origin, cols, rows, stride);
    float d = length(position - (c + 0.5) * cell) / (cell * 0.5); // 0 at the LED's center, 1 at the cell edge

    half led = half(1.0 - smoothstep(0.55, 0.75, d));
    half3 off = color.rgb * 0.07h * led;
    half3 lit = color.rgb * led + half3(0.35h) * led * half(1.0 - smoothstep(0.0, 0.4, d));
    half glow = half(exp(-d * d * 2.0) * 0.25 * on);
    return half4(half3(0.012h) + mix(off, lit, half(on)) + color.rgb * glow, 1.0h);
}

/// Character LCD filling the whole view: square pixels with thin gaps on a green backlight,
/// a very faint grid of unlit pixels, and the slight shadow real LCD pixels cast on the glass.
[[ stitchable ]] half4 lcdBoard(float2 position, half4 current, float2 size, float cell, half4 ink, half4 backlight,
                                device const float *dots, int count, float2 origin, float cols, float rows, float stride) {
    float2 c = floor(position / cell);
    half on = half(dotValue(c, dots, count, origin, cols, rows, stride));
    half shadow = half(dotValue(floor((position - cell * 0.3) / cell), dots, count, origin, cols, rows, stride));

    float2 f = fract(position / cell);
    half pixel = half(step(0.07, f.x) * step(f.x, 0.93) * step(0.07, f.y) * step(f.y, 0.93));

    float2 uv = position / size - 0.5;
    half3 color = backlight.rgb * half(1.0 - dot(uv, uv) * 0.45); // a little brighter in the middle
    color = mix(color, ink.rgb, 0.04h * pixel);                    // unlit pixel grid
    color *= 1.0h - 0.15h * shadow * (1.0h - on);
    color = mix(color, ink.rgb, on * pixel * 0.9h);
    return half4(color, 1.0h);
}
