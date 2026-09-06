const std = @import("std");

// WebP helpers. Actual pixel decoding uses the vendored libwebp (vendor/libwebp);
// this file only holds the container detection so it can be unit-tested off-Windows.

pub fn isWebPBytes(data: []const u8) bool {
    return data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP");
}

// Target box shared by all media decode paths: fit within max_w x max_h,
// preserving aspect, never smaller than 1 pixel. Static images, WebP
// stickers and GIF frames all render inside this box.
pub const FitBox = struct { width: u32, height: u32 };

pub fn fitBox(source_width: u32, source_height: u32, max_width: u32, max_height: u32) FitBox {
    if (source_width == 0 or source_height == 0) return .{ .width = 1, .height = 1 };
    var width: u32 = @min(source_width, max_width);
    var height: u64 = @as(u64, source_height) * width / source_width;
    if (height > max_height) {
        height = max_height;
        width = @intCast(@max(1, @as(u64, source_width) * max_height / source_height));
    }
    if (height == 0) height = 1;
    return .{ .width = width, .height = @intCast(height) };
}

fn chunkSizeAt(data: []const u8, offset: usize) ?usize {
    if (offset + 8 > data.len) return null;
    const size = std.mem.readInt(u32, data[offset + 4 ..][0..4], .little);
    return size;
}

// The simple decode API (WebPDecodeRGBA) cannot decode animated WebP: it
// reports the canvas size but returns no pixels. Walk the RIFF chunk tree to
// the first ANMF (animation frame) chunk and return its inner VP8/VP8L
// bitstream, which decodes standalone as a still image.
pub fn firstAnimationFrame(data: []const u8) ?[]const u8 {
    if (!isWebPBytes(data)) return null;
    var offset: usize = 12;
    while (offset + 8 <= data.len) {
        const size = chunkSizeAt(data, offset) orelse return null;
        if (std.mem.eql(u8, data[offset .. offset + 4], "ANMF")) {
            // ANMF payload: 16-byte frame header, then optional ALPH chunk and
            // the VP8/VP8L chunk.
            var inner = offset + 8 + 16;
            const inner_size = chunkSizeAt(data, inner) orelse return null;
            if (std.mem.eql(u8, data[inner .. inner + 4], "ALPH")) {
                // ponytail: the bare VP8 payload decodes without the alpha
                // plane, so lossy-with-alpha stickers lose transparency; the
                // upgrade path is WebPAnimDecoder (vendor src/demux).
                if (inner_size > data.len - inner - 8) return null;
                inner += 8 + inner_size + (inner_size & 1);
            }
            const bitstream_size = chunkSizeAt(data, inner) orelse return null;
            if (std.mem.startsWith(u8, data[inner .. inner + 4], "VP8")) {
                inner += 8;
                if (inner + bitstream_size > data.len) return null;
                return data[inner .. inner + bitstream_size];
            }
            return null;
        }
        // Guard the advance: a hostile size value must not overflow a 32-bit
        // usize; chunks larger than the buffer are invalid.
        if (size > data.len - offset - 8) return null;
        offset += 8 + size + (size & 1);
    }
    return null;
}

test "isWebPBytes detects the RIFF/WEBP container signature" {
    try std.testing.expect(isWebPBytes("RIFF\xf4\x01\x00\x00WEBPVP8L"));
    try std.testing.expect(!isWebPBytes("RIFF\xf4\x01\x00\x00WAVEfmt "));
    try std.testing.expect(!isWebPBytes("\x89PNG\r\n\x1a\n123456"));
    try std.testing.expect(!isWebPBytes("RIFFshort"));
    try std.testing.expect(!isWebPBytes(""));
}

test "firstAnimationFrame extracts the VP8 payload of the first ANMF chunk" {
    var data: [66]u8 = undefined;
    @memcpy(data[0..12], "RIFF" ++ "\x40\x00\x00\x00" ++ "WEBP");
    @memcpy(data[12..20], "VP8X" ++ "\x0a\x00\x00\x00");
    @memset(data[20..30], 0);
    @memcpy(data[30..38], "ANMF" ++ "\x1e\x00\x00\x00");
    @memset(data[38..54], 0); // 16-byte frame header
    @memcpy(data[54..62], "VP8 " ++ "\x04\x00\x00\x00");
    @memcpy(data[62..66], "bits");
    try std.testing.expectEqualSlices(u8, "bits", firstAnimationFrame(&data).?);

    // ANMF frame with an ALPH chunk before the VP8 bitstream.
    var alpha: [82]u8 = undefined;
    @memcpy(alpha[0..12], "RIFF" ++ "\x4a\x00\x00\x00" ++ "WEBP");
    @memcpy(alpha[12..20], "VP8X" ++ "\x0a\x00\x00\x00");
    @memset(alpha[20..30], 0);
    @memcpy(alpha[30..38], "ANMF" ++ "\x2c\x00\x00\x00");
    @memset(alpha[38..54], 0); // 16-byte frame header
    @memcpy(alpha[54..62], "ALPH" ++ "\x04\x00\x00\x00");
    @memcpy(alpha[62..66], "alph");
    @memcpy(alpha[66..74], "VP8 " ++ "\x04\x00\x00\x00");
    @memcpy(alpha[74..78], "bits");
    try std.testing.expectEqualSlices(u8, "bits", firstAnimationFrame(&alpha).?);
    try std.testing.expect(firstAnimationFrame("RIFFshort") == null);
}

test "fitBox fits within the box preserving aspect" {
    // The media display box is 420 x 250.
    try std.testing.expectEqual(FitBox{ .width = 420, .height = 250 }, fitBox(2100, 1250, 420, 250));
    try std.testing.expectEqual(FitBox{ .width = 168, .height = 250 }, fitBox(840, 1250, 420, 250));
    try std.testing.expectEqual(FitBox{ .width = 420, .height = 200 }, fitBox(2100, 1000, 420, 250));
    try std.testing.expectEqual(FitBox{ .width = 40, .height = 25 }, fitBox(40, 25, 420, 250));
    try std.testing.expectEqual(FitBox{ .width = 1, .height = 1 }, fitBox(0, 0, 420, 250));
    try std.testing.expectEqual(FitBox{ .width = 1, .height = 250 }, fitBox(1, 10000, 420, 250));
}
