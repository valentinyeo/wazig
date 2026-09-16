//! WAZI-79: chat messages are re-read through one background wacli call at a
//! time. The rules here decide when a refresh may start a read and when a
//! finished read may be drawn, as pure logic so they can be unit tested
//! without Windows.

const std = @import("std");

/// True when a refresh may start a read. While one read is outstanding every
/// refresh only records the chat it wants (the redo flag), so rapid chat
/// switching can never stack wacli reads that would discard each other's
/// results.
pub fn shouldFetch(inflight: bool) bool {
    return !inflight;
}

/// True when a finished read may be applied to the view: it must be the
/// newest read that was started (sequence) for the chat currently on
/// screen (jid). Anything else is dropped rather than repainting stale
/// data over fresh.
pub fn shouldApply(latest_seq: u64, result_seq: u64, selected_jid: []const u8, result_jid: []const u8) bool {
    if (result_seq != latest_seq) return false;
    return std.mem.eql(u8, selected_jid, result_jid);
}

test "a quiet app always fetches" {
    try std.testing.expect(shouldFetch(false));
}

test "a refresh while a read runs never stacks a second read" {
    try std.testing.expect(!shouldFetch(true));
}

test "the newest read for the selected chat is applied" {
    try std.testing.expect(shouldApply(2, 2, "123@g.us", "123@g.us"));
}

test "a superseded read is dropped even for the same chat" {
    try std.testing.expect(!shouldApply(2, 1, "123@g.us", "123@g.us"));
}

test "a read for a chat the user left is dropped" {
    try std.testing.expect(!shouldApply(2, 2, "456@g.us", "123@g.us"));
}
