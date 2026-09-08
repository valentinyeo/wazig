//! WhatsApp store rows include protocol and system events (receipts, revokes,
//! sync stubs) that wacli returns alongside real chat messages. Only rows with
//! actual renderable content may become message bubbles; anything else used to
//! show up as a phantom "message that was never sent".

pub const Row = struct {
    id: []const u8,
    text: []const u8 = "",
    media_type: []const u8 = "",
    filename: []const u8 = "",
    local_path: []const u8 = "",
    revoked: bool = false,
    reaction_to: []const u8 = "",
};

/// A row is a real chat message when it has an id and something to show:
/// text, an attachment, a delete notice, or a reaction to merge into its
/// target message. Everything else is a protocol or system event and is
/// hidden.
/// wacli stores the literal "(message)" for message payloads it cannot parse
/// (view-once, contacts, group invites and other protobuf fields it does not
/// handle). stripPlaceholder turns it back into no text so isRealMessage can
/// hide the phantom row, while rows that also carry media, a revoke, or a
/// reaction keep rendering.
pub fn stripPlaceholder(text: []const u8) []const u8 {
    if (std.mem.eql(u8, text, "(message)")) return "";
    return text;
}

pub fn isRealMessage(row: Row) bool {
    if (row.id.len == 0) return false;
    return row.text.len > 0 or row.media_type.len > 0 or
        row.filename.len > 0 or row.local_path.len > 0 or row.revoked or
        row.reaction_to.len > 0;
}

const std = @import("std");

test "text message is real" {
    try std.testing.expect(isRealMessage(.{ .id = "ABC1", .text = "hello" }));
}

test "media row without text is real" {
    try std.testing.expect(isRealMessage(.{ .id = "ABC2", .media_type = "image" }));
    try std.testing.expect(isRealMessage(.{ .id = "ABC3", .local_path = "C:\\x.jpg" }));
}

test "revoked row keeps its delete notice" {
    try std.testing.expect(isRealMessage(.{ .id = "ABC4", .revoked = true }));
}

test "reaction row survives so it can merge into its target" {
    try std.testing.expect(isRealMessage(.{ .id = "ABC6", .reaction_to = "ABC1" }));
}

test "protocol stub without content is hidden" {
    try std.testing.expect(!isRealMessage(.{ .id = "ABC5" }));
    try std.testing.expect(!isRealMessage(.{ .id = "", .text = "orphan" }));
}

test "wacli placeholder counts as no text" {
    try std.testing.expectEqualStrings("", stripPlaceholder("(message)"));
    try std.testing.expectEqualStrings("hello", stripPlaceholder("hello"));
    // A human typing the literal text keeps it, and only the exact full
    // string is a placeholder.
    try std.testing.expectEqualStrings("(message) later", stripPlaceholder("(message) later"));
    // Placeholder without media is hidden, placeholder with media stays.
    try std.testing.expect(!isRealMessage(.{ .id = "ABC7", .text = stripPlaceholder("(message)") }));
    try std.testing.expect(isRealMessage(.{ .id = "ABC8", .text = stripPlaceholder("(message)"), .media_type = "gif" }));
    try std.testing.expect(isRealMessage(.{ .id = "ABC9", .text = stripPlaceholder("(message)"), .revoked = true }));
    try std.testing.expect(isRealMessage(.{ .id = "ABC10", .text = stripPlaceholder("(message)"), .reaction_to = "ABC1" }));
}
