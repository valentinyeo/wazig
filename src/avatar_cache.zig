// Pure helpers for the chat avatar disk cache; unit-tested cross-platform via `zig build test`.

pub const max_file_name = 200;
const staleness_nanoseconds: i128 = 7 * 24 * 60 * 60 * 1_000_000_000;

/// Maps a chat JID to a safe cache file name. Characters outside the
/// [a-z A-Z 0-9 @ . _ -] set are replaced with '_' so a JID can never
/// escape the cache directory. Returns null when the JID is empty.
pub fn cacheFileName(buffer: []u8, jid: []const u8) ?[]const u8 {
    if (jid.len == 0 or buffer.len < jid.len) return null;
    for (jid, 0..) |character, index| {
        const safe = (character >= 'a' and character <= 'z') or
            (character >= 'A' and character <= 'Z') or
            (character >= '0' and character <= '9') or
            character == '@' or character == '.' or character == '_' or character == '-';
        buffer[index] = if (safe) character else '_';
    }
    return buffer[0..jid.len];
}

/// A cache file older than one week is treated as missing so changed
/// profile pictures are refetched on later launches.
pub fn isStale(now_nanoseconds: i128, modified_nanoseconds: i128) bool {
    return now_nanoseconds - modified_nanoseconds > staleness_nanoseconds;
}

test "cache file name replaces path-hostile characters and keeps JIDs" {
    var buffer: [max_file_name]u8 = undefined;
    const name = cacheFileName(&buffer, "1234567890@g.us").?;
    try std.testing.expectEqualStrings("1234567890@g.us", name);
    const hostile = cacheFileName(&buffer, "a/b\\c:d*e?\"<>|").?;
    try std.testing.expectEqualStrings("a_b_c_d_e_____", hostile);
    try std.testing.expect(cacheFileName(&buffer, "") == null);
}

test "staleness boundary" {
    const week: i128 = staleness_nanoseconds;
    try std.testing.expect(!isStale(week, 0));
    try std.testing.expect(isStale(week + 1, 0));
}

const std = @import("std");
