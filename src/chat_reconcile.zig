//! WAZI-79: deciding when the conversation on screen must be re-read after a
//! chat-list refresh lands, and how a failed messages read is retried. Pure
//! logic, so it is unit testable without Windows (like chat_order.zig).

const std = @import("std");

/// A failed or empty messages read is retried at most this often. The first
/// retry waits two refresh ticks (~2s), the second waits four; after that
/// the read stays failed until a chat switch or another refresh tries again.
pub const max_message_read_retries = 2;

/// True when a freshly read chat row says the open conversation is missing
/// messages, so a fresh read should be queued for it. Reconciliation only
/// covers the chat that is already on screen: a row for another chat is left
/// to the click and selection flows that open it, so a jid mismatch never
/// triggers a read here. wacli timestamps are fixed-width
/// "YYYY-MM-DDTHH:MM:SS", so plain byte order matches chronological order,
/// the same order the sidebar sort relies on. A row without a timestamp
/// never triggers a read; an open conversation whose last finished read is
/// missing (no displayed timestamp) always counts as stale.
pub fn openChatStale(chat_jid: []const u8, chat_ts: []const u8, displayed_jid: []const u8, displayed_ts: []const u8) bool {
    if (chat_jid.len == 0 or chat_ts.len == 0) return false;
    if (!std.mem.eql(u8, chat_jid, displayed_jid)) return false;
    if (displayed_ts.len == 0) return true;
    return std.mem.order(u8, chat_ts, displayed_ts) == .gt;
}

/// Backoff ticks before retry `attempt` (1-based) of a failed messages
/// read, or null when the budget is spent.
pub fn retryDelayTicks(attempt: u32) ?u32 {
    if (attempt > max_message_read_retries) return null;
    return 2 * attempt;
}

test "a newer chat row timestamp flags the open conversation stale" {
    try std.testing.expect(openChatStale("123@g.us", "2026-09-06T13:34:39", "123@g.us", "2026-09-06T13:30:00"));
    try std.testing.expect(!openChatStale("123@g.us", "2026-09-06T13:34:39", "123@g.us", "2026-09-06T13:34:39"));
    try std.testing.expect(!openChatStale("123@g.us", "2026-09-06T13:34:39", "123@g.us", "2026-09-06T13:40:00"));
}

test "other chats and rows without a timestamp never trigger a read" {
    try std.testing.expect(!openChatStale("123@g.us", "2026-09-06T13:34:39", "456@g.us", ""));
    try std.testing.expect(!openChatStale("123@g.us", "", "123@g.us", ""));
    try std.testing.expect(!openChatStale("", "2026-09-06T13:34:39", "", ""));
}

test "a conversation that never finished a read counts as stale" {
    try std.testing.expect(openChatStale("123@g.us", "2026-09-06T13:34:39", "123@g.us", ""));
}

test "retry backoff grows and the budget stops after two retries" {
    try std.testing.expectEqual(@as(?u32, 2), retryDelayTicks(1));
    try std.testing.expectEqual(@as(?u32, 4), retryDelayTicks(2));
    try std.testing.expectEqual(@as(?u32, null), retryDelayTicks(3));
}
