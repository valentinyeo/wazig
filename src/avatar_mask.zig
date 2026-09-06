// Per-pixel anti-aliased circular alpha for 32bpp BGRA avatar bitmaps.
// GDI clip regions (CreateEllipticRgn) have hard 1-bit edges, so the smooth
// circle is baked into the bitmap alpha and composited with AlphaBlend.
const std = @import("std");

/// Coverage of a circle (center at size/2, radius size/2) at a pixel center,
/// as an 8-bit alpha. One-pixel signed-distance approximation of the area.
pub fn alphaAt(x: usize, y: usize, size: usize) u8 {
    const radius: f32 = @as(f32, @floatFromInt(size)) / 2.0;
    const px = @as(f32, @floatFromInt(x)) + 0.5;
    const py = @as(f32, @floatFromInt(y)) + 0.5;
    const dx = px - radius;
    const dy = py - radius;
    const dist = @sqrt(dx * dx + dy * dy);
    const coverage = std.math.clamp(radius - dist + 0.5, 0.0, 1.0);
    return @intFromFloat(coverage * 255.0);
}

/// Applies the circle mask to a top-down 32bpp BGRA buffer, premultiplying
/// the color by the alpha so the buffer satisfies the AC_SRC_ALPHA contract
/// (WIC emits PBGRA with opaque alpha; lowering alpha alone would leave
/// color > alpha and produce a bright halo at the rim).
pub fn applyMask(pixels: []u8, size: usize) void {
    var y: usize = 0;
    while (y < size) : (y += 1) {
        var x: usize = 0;
        while (x < size) : (x += 1) {
            const a: u16 = alphaAt(x, y, size);
            const i = (y * size + x) * 4;
            pixels[i + 0] = @intCast(@as(u16, pixels[i + 0]) * a / 255);
            pixels[i + 1] = @intCast(@as(u16, pixels[i + 1]) * a / 255);
            pixels[i + 2] = @intCast(@as(u16, pixels[i + 2]) * a / 255);
            pixels[i + 3] = @intCast(a);
        }
    }
}

/// Fills a top-down 32bpp BGRA buffer with a premultiplied circle of the
/// given color and anti-aliased alpha (for the initials fallback avatar).
pub fn fillCircle(pixels: []u8, size: usize, r: u8, g: u8, b: u8) void {
    var y: usize = 0;
    while (y < size) : (y += 1) {
        var x: usize = 0;
        while (x < size) : (x += 1) {
            const a: u16 = alphaAt(x, y, size);
            const i = (y * size + x) * 4;
            pixels[i + 0] = @intCast(@as(u16, b) * a / 255);
            pixels[i + 1] = @intCast(@as(u16, g) * a / 255);
            pixels[i + 2] = @intCast(@as(u16, r) * a / 255);
            pixels[i + 3] = @intCast(a);
        }
    }
}

test "circle mask is transparent in corners and opaque in the middle" {
    const size = 42;
    try std.testing.expectEqual(@as(u8, 0), alphaAt(0, 0, size));
    try std.testing.expectEqual(@as(u8, 0), alphaAt(size - 1, size - 1, size));
    try std.testing.expectEqual(@as(u8, 255), alphaAt(size / 2, size / 2, size));
    // The edge pixels straddle the boundary and must be a real blend.
    const edge = alphaAt(size - 1, size / 2, size);
    try std.testing.expect(edge > 0 and edge < 255);
}

test "fillCircle premultiplies color" {
    const size = 8;
    var pixels = [_]u8{0} ** (size * size * 4);
    fillCircle(&pixels, size, 255, 128, 0);
    // Partial-alpha edge pixel (x=0, y=1): coverage ~0.2, so premultiplied
    // red ~50 while unpremultiplied would be 255.
    const i = (1 * size + 0) * 4;
    try std.testing.expect(pixels[i + 3] > 0 and pixels[i + 3] < 255);
    try std.testing.expectEqual(pixels[i + 3], pixels[i + 2]); // red == alpha
    try std.testing.expectApproxEqAbs(@as(f32, @floatFromInt(pixels[i + 1])), @as(f32, @floatFromInt(pixels[i + 3])) * 128.0 / 255.0, 1.5);
    try std.testing.expectEqual(@as(u8, 0), pixels[0 + 3]); // corner transparent
}

test "applyMask premultiplies an opaque buffer" {
    const size = 8;
    var pixels = [_]u8{255} ** (size * size * 4);
    applyMask(&pixels, size);
    const i = (1 * size + 0) * 4;
    try std.testing.expect(pixels[i + 3] > 0 and pixels[i + 3] < 255);
    try std.testing.expect(pixels[i + 2] <= pixels[i + 3]); // color <= alpha
    try std.testing.expectEqual(@as(u8, 255), pixels[((size / 2) * size + (size / 2)) * 4 + 3]); // center opaque
}
