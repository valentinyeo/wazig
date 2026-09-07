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
