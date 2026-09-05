pub const picker_emojis = [_][]const u8{ "👍", "❤️", "😂", "😮", "😢", "🙏", "👏", "🔥", "🎉", "🥰", "😭", "😅", "😉", "🤔", "😊", "😍" };

pub const picker_base: u16 = 3101;

pub fn pickerEmojiForCommand(command: u16) ?[]const u8 {
    const index = command -% picker_base;
    if (index < picker_emojis.len) return picker_emojis[index];
    return null;
}

test "picker command ids map to the picker emojis" {
    const std = @import("std");
    for (picker_emojis, 0..) |emoji, index| {
        try std.testing.expectEqualStrings(emoji, pickerEmojiForCommand(picker_base + @as(u16, @intCast(index))).?);
    }
    try std.testing.expectEqual(@as(?[]const u8, null), pickerEmojiForCommand(picker_base + picker_emojis.len));
    try std.testing.expectEqual(@as(?[]const u8, null), pickerEmojiForCommand(0));
}
