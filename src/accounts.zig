//! Status labels for the Manage accounts screen: pure functions so CI can
//! test the state-to-text mapping without Windows.

const std = @import("std");
const tj = @import("telegram_json.zig");

pub fn telegramLabel(state: tj.AuthState) []const u8 {
    return switch (state) {
        .ready => "Telegram - connected",
        .wait_parameters, .wait_phone, .wait_code, .wait_password, .wait_registration, .wait_email => "Telegram - needs login",
        else => "Telegram - not connected",
    };
}

pub fn whatsappLabel(buffer: []u8, sync_running: bool, last_refresh_unix: i64) []const u8 {
    // Keep the longest result under the 63-character palette label cap.
    if (!sync_running) return "WhatsApp - live sync stopped";
    if (last_refresh_unix <= 0) return "WhatsApp - live sync running, never refreshed";
    var stamp: [20]u8 = undefined;
    return std.fmt.bufPrint(buffer, "WhatsApp - live sync running, refreshed {s}", .{tj.formatTimestamp(&stamp, last_refresh_unix)}) catch "WhatsApp - live sync running";
}

test "labels describe sync and Telegram states" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("WhatsApp - live sync stopped", whatsappLabel(&buffer, false, 123));
    try std.testing.expectEqualStrings("WhatsApp - live sync running, never refreshed", whatsappLabel(&buffer, true, 0));
    const stamped = whatsappLabel(&buffer, true, 86400 + 3600);
    try std.testing.expect(std.mem.startsWith(u8, stamped, "WhatsApp - live sync running, refreshed 1970-01-02 01:00:00"));
    try std.testing.expect(stamped.len <= 63);
    try std.testing.expectEqualStrings("Telegram - connected", telegramLabel(.ready));
    try std.testing.expectEqualStrings("Telegram - needs login", telegramLabel(.wait_code));
    try std.testing.expectEqualStrings("Telegram - not connected", telegramLabel(.unknown));
}
