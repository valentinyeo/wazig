//! Emoji catalog for the picker plus the pure logic behind it: name search,
//! recent-emoji persistence (registry string parsing/validation) and grid
//! hit-testing. No Windows calls here so everything is testable headless.
//! The catalog is every standard emoji, generated into emoji_data.zig by
//! tools/gen_emoji_data.py from Unicode's emoji-test.txt.

const std = @import("std");
const data = @import("emoji_data.zig");

pub const grid_columns: usize = 8;
pub const grid_rows: usize = 6;
/// Cell size at 96 DPI; the app scales it with px().
pub const cell_size: i32 = 44;
pub const max_recents: usize = grid_columns;

/// Filled into the "frequently used" row after the user's own recents, so the
/// row is always full and the common WhatsApp reactions are one key away.
pub const default_frequent = [_][]const u8{ "👍", "❤️", "😂", "😮", "😢", "🙏", "🔥", "🎉" };

/// Byte offset of each record in data.records, plus one past the last.
const record_starts = blk: {
    @setEvalBranchQuota(400_000);
    var starts: [countRecords() + 1]u32 = undefined;
    var index: usize = 0;
    starts[0] = 0;
    for (data.records, 0..) |byte, offset| {
        if (byte == '\n') {
            index += 1;
            starts[index] = offset + 1;
        }
    }
    starts[index + 1] = data.records.len + 1;
    break :blk starts;
};

fn countRecords() usize {
    @setEvalBranchQuota(400_000);
    var lines: usize = 1;
    for (data.records) |byte| {
        if (byte == '\n') lines += 1;
    }
    return lines;
}

pub const count: usize = record_starts.len - 1;

fn record(index: usize) []const u8 {
    return data.records[record_starts[index] .. record_starts[index + 1] - 1];
}

fn field(index: usize, which: usize) []const u8 {
    var parts = std.mem.splitScalar(u8, record(index), '|');
    var position: usize = 0;
    while (parts.next()) |part| : (position += 1) {
        if (position == which) return part;
    }
    return "";
}

pub fn emoji(index: usize) []const u8 {
    return field(index, 0);
}

pub fn name(index: usize) []const u8 {
    return field(index, 1);
}

fn aliases(index: usize) []const u8 {
    return field(index, 2);
}

pub fn subgroup(index: usize) []const u8 {
    return data.subgroup_names[data.record_subgroup[index]];
}

/// Catalog index of an emoji string, or null when it is not a standard emoji.
pub fn indexOf(text: []const u8) ?u16 {
    for (0..count) |index| {
        if (std.mem.eql(u8, emoji(index), text)) return @intCast(index);
    }
    return null;
}

/// Writes the "frequently used" row: recents first, then defaults not already
/// shown, up to one grid row. Returns the number written.
pub fn frequentRow(recents: []const u16, out: *[grid_columns]u16) usize {
    var written: usize = 0;
    for (recents) |recent| {
        if (written == grid_columns) break;
        out[written] = recent;
        written += 1;
    }
    for (default_frequent) |text| {
        if (written == grid_columns) break;
        const index = indexOf(text) orelse continue;
        if (std.mem.indexOfScalar(u16, out[0..written], index) != null) continue;
        out[written] = index;
        written += 1;
    }
    return written;
}

/// How well `query` (lowercase ASCII) matches catalog entry `index`: 4 when
/// it is the whole name ("fire"), 3 when it is a whole word of the name or aliases ("fire" in "fire"), 2 when such a
/// word starts with it, 1 for any other substring of the name, aliases or
/// subgroup, 0 for no match.
pub fn matchRank(index: usize, query: []const u8) u8 {
    if (query.len == 0) return 1;
    if (std.ascii.eqlIgnoreCase(name(index), query)) return 4;
    const word = @max(wordMatch(name(index), query), wordMatch(aliases(index), query));
    if (word > 0) return word + 1;
    if (nameMatches(name(index), query) or nameMatches(aliases(index), query) or nameMatches(subgroup(index), query)) return 1;
    return 0;
}

/// 2 when `query` is a whole word of `text`, 1 when a word starts with it.
fn wordMatch(text: []const u8, query: []const u8) u8 {
    var best: u8 = 0;
    var start: usize = 0;
    while (start + query.len <= text.len) : (start += 1) {
        if (start > 0 and std.ascii.isAlphanumeric(text[start - 1])) continue;
        if (!std.ascii.eqlIgnoreCase(text[start..][0..query.len], query)) continue;
        const end = start + query.len;
        if (end == text.len or !std.ascii.isAlphanumeric(text[end])) return 2;
        best = 1;
    }
    return best;
}

/// Fills `out` with the catalog indices matching `query`, word-start matches
/// first, each group in catalog order. Returns the number written.
pub fn search(query: []const u8, out: []u16) usize {
    var written: usize = 0;
    const lowest: u8 = if (query.len == 0) 1 else 4;
    var rank: u8 = lowest;
    while (rank > 0) : (rank -= 1) {
        for (0..count) |index| {
            if (written == out.len) return written;
            if (matchRank(index, query) != rank) continue;
            out[written] = @intCast(index);
            written += 1;
        }
    }
    return written;
}

/// Case-insensitive substring match of an ASCII query against an ASCII name.
pub fn nameMatches(label: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (query.len > label.len) return false;
    var start: usize = 0;
    while (start + query.len <= label.len) : (start += 1) {
        var matched = true;
        for (query, 0..) |character, index| {
            const candidate = label[start + index];
            if (lowerAscii(candidate) != lowerAscii(character)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn lowerAscii(character: u8) u8 {
    return if (character >= 'A' and character <= 'Z') character + 32 else character;
}

/// Parses the persisted recent-emoji registry string ("👍,🔥,❤️") into
/// catalog indices. Unknown, malformed and duplicate entries are dropped (so
/// the old numeric format from before the full catalog is ignored); the most
/// recent first. Returns the number of valid entries written.
pub fn parseRecents(text: []const u8, out: *[max_recents]u16) usize {
    var written: usize = 0;
    var iterator = std.mem.splitScalar(u8, text, ',');
    while (iterator.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (trimmed.len == 0) continue;
        const index = indexOf(trimmed) orelse continue;
        if (std.mem.indexOfScalar(u16, out[0..written], index) != null) continue;
        out[written] = index;
        written += 1;
        if (written == max_recents) break;
    }
    return written;
}

/// Formats recents for the registry as emoji joined by commas: "👍,🔥".
/// Stored as text, not indices, so a regenerated catalog keeps them.
pub fn formatRecents(buffer: []u8, recents: []const u16) []const u8 {
    var len: usize = 0;
    for (recents, 0..) |index, position| {
        const text = emoji(index);
        const separator: usize = if (position > 0) 1 else 0;
        if (len + separator + text.len > buffer.len) break;
        if (separator == 1) buffer[len] = ',';
        len += separator;
        @memcpy(buffer[len..][0..text.len], text);
        len += text.len;
    }
    return buffer[0..len];
}

/// Moves an emoji to the front of the recents list (inserting or promoting),
/// keeping at most max_recents entries.
pub fn pushRecent(recents: []u16, recent_count: *usize, index: u16) void {
    for (recents[0..recent_count.*], 0..) |existing, position| {
        if (existing == index) {
            std.mem.copyBackwards(u16, recents[1 .. position + 1], recents[0..position]);
            recents[0] = index;
            return;
        }
    }
    const capped = @min(recent_count.* + 1, max_recents);
    var position = capped;
    while (position > 1) : (position -= 1) {
        recents[position - 1] = recents[position - 2];
    }
    recents[0] = index;
    recent_count.* = capped;
}

/// Maps a click inside a grid row to a column, or null outside the grid.
/// `cell` is the scaled cell size in pixels.
pub fn cellFromHit(offset_in_row: i32, cell: i32) ?usize {
    if (cell <= 0 or offset_in_row < 0 or offset_in_row >= cell * @as(i32, @intCast(grid_columns))) return null;
    return @intCast(@divTrunc(offset_in_row, cell));
}

fn expectFirstMatch(query: []const u8, expected: []const u8) !void {
    var out: [count]u16 = undefined;
    const found = search(query, &out);
    try std.testing.expect(found > 0);
    try std.testing.expectEqualStrings(expected, emoji(out[0]));
}

fn searchContains(query: []const u8, expected: []const u8) bool {
    var out: [count]u16 = undefined;
    const found = search(query, &out);
    for (out[0..found]) |index| {
        if (std.mem.eql(u8, emoji(index), expected)) return true;
    }
    return false;
}

test "name search matches substrings case-insensitively" {
    try std.testing.expect(nameMatches("thumbs up", "humb"));
    try std.testing.expect(nameMatches("thumbs up", "THUMBS"));
    try std.testing.expect(!nameMatches("thumbs up", "wink"));
    try std.testing.expect(nameMatches("red heart", ""));
}

test "catalog has every standard emoji once, and no skin-tone variants" {
    // Emoji 15+ has well over 1800 base emoji; the old hand list had ~390.
    try std.testing.expect(count > 1800);
    for (0..count) |index| {
        try std.testing.expect(emoji(index).len > 0);
        try std.testing.expect(name(index).len > 0);
        // U+1F3FB..U+1F3FF are the skin-tone modifiers (F0 9F 8F BB..BF).
        for (0x1F3FB..0x1F400) |tone| {
            var encoded: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(tone), &encoded) catch unreachable;
            try std.testing.expect(std.mem.indexOf(u8, emoji(index), encoded[0..len]) == null);
        }
    }
    // No duplicates: a sorted copy has no equal neighbours.
    var sorted: [count][]const u8 = undefined;
    for (&sorted, 0..) |*slot, index| slot.* = emoji(index);
    std.mem.sort([]const u8, &sorted, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);
    for (sorted[1..], 0..) |text, index| try std.testing.expect(!std.mem.eql(u8, text, sorted[index]));
}

test "common emoji are present with their names" {
    for ([_][2][]const u8{
        .{ "👍", "thumbs up" },
        .{ "❤️", "red heart" },
        .{ "😂", "face with tears of joy" },
        .{ "🔥", "fire" },
        .{ "🎉", "party popper" },
        .{ "🙏", "folded hands" },
        .{ "😮", "face with open mouth" },
        .{ "😢", "crying face" },
        .{ "👋", "waving hand" },
        .{ "🇩🇪", "flag: Germany" },
    }) |pair| {
        const index = indexOf(pair[0]) orelse return error.MissingEmoji;
        try std.testing.expectEqualStrings(pair[1], name(index));
    }
    for (default_frequent) |text| try std.testing.expect(indexOf(text) != null);
}

test "search filters by name, alias and subgroup, word starts first" {
    try expectFirstMatch("thumbs", "👍");
    try expectFirstMatch("fire", "🔥");
    try expectFirstMatch("party", "🥳");
    try std.testing.expect(matchRank(indexOf("🎉").?, "party") == 3);
    try expectFirstMatch("laugh", "😂");
    try std.testing.expect(searchContains("heart", "❤️"));
    try std.testing.expect(searchContains("heart", "💔"));
    try std.testing.expect(searchContains("laugh", "🤣"));
    try std.testing.expect(searchContains("party", "🥳"));
    // Subgroup keyword: "hand-fingers-open" reaches the waving hand.
    try std.testing.expect(searchContains("fingers-open", "👋"));
    try std.testing.expect(!searchContains("fire", "👍"));
    var out: [count]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 0), search("zzqqxx", &out));
    try std.testing.expectEqual(count, search("", &out));
}

test "frequent row puts recents first, then fills with defaults" {
    var row: [grid_columns]u16 = undefined;
    const fire = indexOf("🔥").?;
    const wave = indexOf("👋").?;
    try std.testing.expectEqual(grid_columns, frequentRow(&.{ wave, fire }, &row));
    try std.testing.expectEqual(wave, row[0]);
    try std.testing.expectEqual(fire, row[1]);
    try std.testing.expectEqualStrings("👍", emoji(row[2]));
    // Fire is a default too but appears once.
    var fires: usize = 0;
    for (row) |index| {
        if (index == fire) fires += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), fires);
}

test "recents parse validates and deduplicates" {
    var recents: [max_recents]u16 = undefined;
    try std.testing.expectEqual(@as(usize, 2), parseRecents("👍, 🔥,👍", &recents));
    try std.testing.expectEqualStrings("👍", emoji(recents[0]));
    try std.testing.expectEqualStrings("🔥", emoji(recents[1]));
    // The pre-catalog numeric format and junk are ignored.
    try std.testing.expectEqual(@as(usize, 0), parseRecents("3,17,5", &recents));
    try std.testing.expectEqual(@as(usize, 0), parseRecents("bogus", &recents));
    try std.testing.expectEqual(@as(usize, 0), parseRecents("", &recents));
    var full: [max_recents]u16 = undefined;
    try std.testing.expectEqual(@as(usize, max_recents), parseRecents("😀,😃,😄,😁,😆,😅,🤣,😂,🙂,🙃", &full));
    try std.testing.expectEqualStrings("😂", emoji(full[7]));
}

test "format and parse round-trip recents" {
    var buffer: [256]u8 = undefined;
    const recents_in = [_]u16{ indexOf("❤️").?, indexOf("🇩🇪").?, indexOf("👍").? };
    const text = formatRecents(&buffer, &recents_in);
    try std.testing.expectEqualStrings("❤️,🇩🇪,👍", text);
    var recents: [max_recents]u16 = undefined;
    const parsed = parseRecents(text, &recents);
    try std.testing.expectEqualSlices(u16, &recents_in, recents[0..parsed]);
    // A too-small buffer drops whole entries, never half an emoji.
    try std.testing.expectEqualStrings("❤️", formatRecents(buffer[0..8], &recents_in));
}

test "push recent promotes, inserts, and caps" {
    var recents: [max_recents]u16 = [_]u16{0} ** max_recents;
    var recent_count: usize = 0;
    pushRecent(&recents, &recent_count, 3);
    pushRecent(&recents, &recent_count, 17);
    pushRecent(&recents, &recent_count, 3);
    try std.testing.expectEqualSlices(u16, &.{ 3, 17 }, recents[0..recent_count]);
    try std.testing.expectEqual(@as(usize, 2), recent_count);
    for (0..max_recents + 2) |index| pushRecent(&recents, &recent_count, @intCast(index));
    try std.testing.expectEqual(@as(usize, max_recents), recent_count);
    try std.testing.expectEqual(@as(u16, max_recents + 1), recents[0]);
    try std.testing.expectEqual(@as(u16, 2), recents[7]);
}

test "grid hit test maps offsets to columns at any scale" {
    try std.testing.expectEqual(@as(?usize, 0), cellFromHit(0, cell_size));
    try std.testing.expectEqual(@as(?usize, 3), cellFromHit(3 * cell_size, cell_size));
    try std.testing.expectEqual(@as(?usize, null), cellFromHit(-1, cell_size));
    try std.testing.expectEqual(@as(?usize, null), cellFromHit(cell_size * @as(i32, @intCast(grid_columns)), cell_size));
    // 150%: 66 px cells.
    try std.testing.expectEqual(@as(?usize, 1), cellFromHit(66, 66));
    try std.testing.expectEqual(@as(?usize, 0), cellFromHit(65, 66));
}
