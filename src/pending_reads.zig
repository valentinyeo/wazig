//! Pending mark-read queue file parsing (WAZI-74). Reads that never reached
//! the WhatsApp store are mirrored to disk and retried on the next launch.

const std = @import("std");

pub const max_pending_reads = 8;
pub const max_jid_len = 191;

/// Parses one jid per line from the queue file into `out`, which holds
/// null-terminated entries. Rejects empty lines, entries that do not fit,
/// and lines without an '@' (jid marker), so a corrupt or truncated file can
/// never enqueue garbage. Duplicates collapse; capacity is `out.len`.
pub fn term(entry: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, entry, 0) orelse entry.len;
    return entry[0..end];
}

pub fn parse(contents: []const u8, out: *[max_pending_reads][max_jid_len + 1]u8) usize {
    var count: usize = 0;
    var lines = std.mem.tokenizeAny(u8, contents, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0 or line.len > max_jid_len) continue;
        if (std.mem.indexOfScalar(u8, line, '@') == null) continue;
        var seen = false;
        for (out[0..count]) |entry| {
            if (std.mem.eql(u8, term(&entry), line)) seen = true;
        }
        if (seen) continue;
        @memcpy(out[count][0..line.len], line);
        out[count][line.len] = 0;
        count += 1;
        if (count == out.len) break;
    }
    return count;
}

test "parse keeps valid unique jids and skips junk" {
    var out: [max_pending_reads][max_jid_len + 1]u8 = undefined;
    const count = parse("123@s.whatsapp.net\n\nbad-but-not-a-jid\n123@s.whatsapp.net\n456@g.us\n", &out);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("123@s.whatsapp.net", term(&out[0]));
    try std.testing.expectEqualStrings("456@g.us", term(&out[1]));
}

test "parse caps at the queue capacity and drops oversized lines" {
    var out: [max_pending_reads][max_jid_len + 1]u8 = undefined;
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(std.testing.allocator);
    var index: usize = 0;
    while (index < max_pending_reads + 3) : (index += 1) {
        try contents.print(std.testing.allocator, "{d}@s.whatsapp.net\n", .{index});
    }
    try contents.appendSlice(std.testing.allocator, "a" ** (max_jid_len + 1) ++ "@s.whatsapp.net\n");
    const count = parse(contents.items, &out);
    try std.testing.expectEqual(@as(usize, max_pending_reads), count);
}
