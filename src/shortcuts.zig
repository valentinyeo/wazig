// Data behind the keyboard shortcuts help overlay (F1, or the "Keyboard
// shortcuts" command palette entry). Kept as plain data, separate from the
// drawing code in main.zig, so the list can be tested on its own.
const std = @import("std");

pub const Shortcut = struct {
    key: []const u8,
    desc: []const u8,
};

pub const Group = struct {
    name: []const u8,
    items: []const Shortcut,
};

pub const groups = [_]Group{
    .{ .name = "Chats", .items = &[_]Shortcut{
        .{ .key = "Ctrl+1..9", .desc = "Open the chat at that position in the list" },
        .{ .key = "Ctrl+Tab / Ctrl+Shift+Tab", .desc = "Next / previous chat" },
        .{ .key = "Ctrl+Shift+Home", .desc = "Jump to the first chat" },
        .{ .key = "Ctrl+Shift+End", .desc = "Jump to the last chat" },
        .{ .key = "Ctrl+Page Up / Ctrl+Page Down", .desc = "Move the selection by a page" },
        .{ .key = "Mouse wheel over the list", .desc = "Scroll the chat list" },
        .{ .key = "Ctrl+F or /", .desc = "Focus search" },
        .{ .key = "U", .desc = "Toggle unread chats" },
        .{ .key = "Ctrl+E or E", .desc = "Archive or unarchive the selected chat" },
        .{ .key = "R", .desc = "Refresh" },
        .{ .key = "Q", .desc = "Quit Messages" },
    } },
    .{ .name = "Messages", .items = &[_]Shortcut{
        .{ .key = "Alt+J / Alt+K", .desc = "Select the next / previous message" },
        .{ .key = "Up / Down", .desc = "Walk the message highlight (composer empty)" },
        .{ .key = "Ctrl+Up / Ctrl+Down", .desc = "Walk the message highlight" },
        .{ .key = "Page Up / Page Down", .desc = "Scroll the chat a screen at a time" },
        .{ .key = "Ctrl+End", .desc = "Jump back to the newest message" },
        .{ .key = "Alt+G, Alt+G", .desc = "Jump to the latest message (press twice)" },
        .{ .key = "Ctrl+R", .desc = "React to message (search any emoji)" },
        .{ .key = "Ctrl+Shift+R", .desc = "Reply to the selected message" },
        .{ .key = "Ctrl+C or Ctrl+Shift+C", .desc = "Copy the selected message text" },
        .{ .key = "Ctrl+P", .desc = "Play or pause the selected voice message" },
        .{ .key = "Ctrl+T", .desc = "Show or hide the transcript" },
        .{ .key = "Enter or R on a failed message", .desc = "Resend it" },
    } },
    .{ .name = "Composer", .items = &[_]Shortcut{
        .{ .key = "Enter", .desc = "Send the message, or focus the composer if it isn't focused" },
        .{ .key = "Shift+Enter", .desc = "Insert a new line" },
        .{ .key = "C", .desc = "Focus the composer" },
        .{ .key = "Ctrl+V", .desc = "Paste a copied image to send" },
        .{ .key = "Esc", .desc = "Cancel the reply or discard a pasted image" },
        .{ .key = "Arrows / Enter / Esc, emoji picker open", .desc = "Move, insert or close the emoji picker" },
    } },
    .{ .name = "Messengers", .items = &[_]Shortcut{
        .{ .key = "Alt+1..9", .desc = "Switch between WhatsApp, Slack and Telegram" },
    } },
    .{ .name = "Open and view", .items = &[_]Shortcut{
        .{ .key = "Ctrl+O", .desc = "Open links and media in the selected message" },
        .{ .key = "Double-click a video", .desc = "Play it inline" },
        .{ .key = "F11", .desc = "Toggle fullscreen for the inline video player" },
        .{ .key = "Esc, Space, Enter or a click", .desc = "Close the image viewer" },
    } },
    .{ .name = "App", .items = &[_]Shortcut{
        .{ .key = "Ctrl+K", .desc = "Open the command palette" },
        .{ .key = "F1", .desc = "Show this keyboard shortcuts overlay" },
        .{ .key = "Up / Down / J / K, palette open", .desc = "Move the palette selection" },
        .{ .key = "Enter / Esc, palette open", .desc = "Run the selected item, or close the palette" },
        .{ .key = "Ctrl+D", .desc = "Toggle dictation" },
        .{ .key = "Ctrl+- / Ctrl++ / Ctrl+0", .desc = "Make text smaller, larger, or reset it" },
    } },
};

fn hasDuplicateKeys(group: Group) bool {
    for (group.items, 0..) |item, i| {
        for (group.items[i + 1 ..]) |other| {
            if (std.mem.eql(u8, item.key, other.key)) return true;
        }
    }
    return false;
}

test "every group has shortcuts" {
    for (groups) |group| {
        try std.testing.expect(group.items.len > 0);
    }
}

test "no duplicate keys within a group" {
    for (groups) |group| {
        try std.testing.expect(!hasDuplicateKeys(group));
    }
}

test "no empty key or description" {
    for (groups) |group| {
        try std.testing.expect(group.name.len > 0);
        for (group.items) |item| {
            try std.testing.expect(item.key.len > 0);
            try std.testing.expect(item.desc.len > 0);
        }
    }
}
