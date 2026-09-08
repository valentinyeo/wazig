//! WAZI-67: on-disk snapshots of the chat list and per-chat message reads so
//! a relaunch (an update included) opens with content instead of an empty
//! sidebar. Pure envelope logic lives here so it can be unit tested without
//! Windows; main.zig owns the file I/O.
//!
//! Envelope: "wazig-msg-cache v1\n<jid>\n" + raw wacli JSON. The jid line is
//! verified on read, so a filename hash collision can only waste a file, it
//! can never show one chat's messages inside another chat.

const std = @import("std");

pub const header = "wazig-msg-cache v1\n";

/// Builds the on-disk envelope for one cached chat payload.
pub fn envelope(allocator: std.mem.Allocator, jid: []const u8, payload: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}\n{s}", .{ header, jid, payload });
}

/// Returns the payload only when the envelope is well-formed and the stored
/// jid matches. Anything corrupt, foreign, or belonging to another chat is
/// treated as absent.
pub fn payloadFor(data: []const u8, jid: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, data, header)) return null;
    const rest = data[header.len..];
    const line_end = std.mem.indexOfScalar(u8, rest, '\n') orelse return null;
    if (!std.mem.eql(u8, rest[0..line_end], jid)) return null;
    return rest[line_end + 1 ..];
}

test "envelope round trip returns the payload for the matching jid" {
    const allocator = std.testing.allocator;
    const stored = try envelope(allocator, "1234@g.us", "{\"data\":[]}");
    defer allocator.free(stored);
    const payload = payloadFor(stored, "1234@g.us") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("{\"data\":[]}", payload);
}

test "payloadFor rejects a different jid" {
    const allocator = std.testing.allocator;
    const stored = try envelope(allocator, "1234@g.us", "{}");
    defer allocator.free(stored);
    try std.testing.expect(payloadFor(stored, "other@g.us") == null);
}

test "payloadFor rejects corrupt and empty data" {
    try std.testing.expect(payloadFor("", "1234@g.us") == null);
    try std.testing.expect(payloadFor("garbage", "1234@g.us") == null);
    try std.testing.expect(payloadFor(header, "1234@g.us") == null);
}
