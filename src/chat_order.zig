//! Sidebar ordering for the chat list: pinned chats first, then newest
//! message first, with the jid as a deterministic tie-break.
const std = @import("std");

/// True when chat `right` must move above chat `left` in the insertion sort.
/// Within the pinned and unpinned groups the original newest-first order is
/// preserved, so the sort is stable.
pub fn shouldMoveUp(pin_left: bool, pin_right: bool, by_time: std.math.Order, jid_tiebreak: std.math.Order) bool {
    if (pin_right != pin_left) return pin_right;
    return by_time == .lt or (by_time == .eq and jid_tiebreak == .gt);
}

test "pinned chats move above unpinned ones regardless of age" {
    try std.testing.expect(shouldMoveUp(false, true, .gt, .lt));
    try std.testing.expect(!shouldMoveUp(true, false, .lt, .gt));
}

test "within a group the newest-first order with jid tie-break holds" {
    try std.testing.expect(shouldMoveUp(true, true, .lt, .gt));
    try std.testing.expect(!shouldMoveUp(false, false, .gt, .lt));
    try std.testing.expect(shouldMoveUp(false, false, .eq, .gt));
    try std.testing.expect(!shouldMoveUp(false, false, .eq, .lt));
}
