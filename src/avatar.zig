const std = @import("std");

pub fn isGroupJid(jid: []const u8) bool {
    return std.mem.endsWith(u8, jid, "@g.us");
}

pub const Rgb = struct { r: u8, g: u8, b: u8 };

const palette = [_]Rgb{
    .{ .r = 0, .g = 168, .b = 132 },
    .{ .r = 83, .g = 189, .b = 235 },
    .{ .r = 235, .g = 140, .b = 84 },
    .{ .r = 178, .g = 132, .b = 235 },
    .{ .r = 235, .g = 195, .b = 84 },
    .{ .r = 235, .g = 110, .b = 150 },
};

// Stable per-sender color so the same person keeps one color within a chat.
pub fn colorFor(seed: []const u8) Rgb {
    if (seed.len == 0) return palette[0];
    var hash: u32 = 2166136261;
    for (seed) |byte| {
        hash ^= byte;
        hash = hash *% 16777619;
    }
    return palette[hash % palette.len];
}

// First grapheme-ish chunk of a UTF-16 name: pairs up surrogate halves so an
// emoji initial does not render as a lone surrogate.
pub fn initial(sender: []const u16) []const u16 {
    if (sender.len == 0) return sender;
    const first = sender[0];
    if (first >= 0xd800 and first <= 0xdbff and sender.len > 1 and sender[1] >= 0xdc00 and sender[1] <= 0xdfff)
        return sender[0..2];
    return sender[0..1];
}

test "group jid detection" {
    try std.testing.expect(isGroupJid("1234-5678@g.us"));
    try std.testing.expect(!isGroupJid("1234567890@s.whatsapp.net"));
    try std.testing.expect(!isGroupJid(""));
}

test "color is stable per seed and non-empty" {
    const a = colorFor("1234567890@s.whatsapp.net");
    try std.testing.expectEqual(a, colorFor("1234567890@s.whatsapp.net"));
    try std.testing.expectEqual(Rgb{ .r = 0, .g = 168, .b = 132 }, colorFor(""));
    const different = colorFor("1987654321@s.whatsapp.net");
    try std.testing.expect(!std.meta.eql(a, different) or !std.meta.eql(a, colorFor("15550001111@s.whatsapp.net")));
}

test "initial handles ascii and surrogate pairs" {
    try std.testing.expectEqualSlices(u16, &[_]u16{'A'}, initial(&[_]u16{ 'A', 'l', 'i', 'c', 'e' }));
    try std.testing.expectEqualSlices(u16, &[_]u16{ 0xd83d, 0xde00 }, initial(&[_]u16{ 0xd83d, 0xde00, 'a' }));
    try std.testing.expectEqualSlices(u16, &[_]u16{}, initial(&[_]u16{}));
}
