const std = @import("std");

// WebP helpers. Actual pixel decoding uses the vendored libwebp (vendor/libwebp);
// this file only holds the container detection so it can be unit-tested off-Windows.

pub fn isWebPBytes(data: []const u8) bool {
    return data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and std.mem.eql(u8, data[8..12], "WEBP");
}

test "isWebPBytes detects the RIFF/WEBP container signature" {
    try std.testing.expect(isWebPBytes("RIFF\xf4\x01\x00\x00WEBPVP8L"));
    try std.testing.expect(!isWebPBytes("RIFF\xf4\x01\x00\x00WAVEfmt "));
    try std.testing.expect(!isWebPBytes("\x89PNG\r\n\x1a\n123456"));
    try std.testing.expect(!isWebPBytes("RIFFshort"));
    try std.testing.expect(!isWebPBytes(""));
}
