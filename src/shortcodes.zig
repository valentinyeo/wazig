//! Slack/Discord style :shortcodes: typed in the composer. Pure logic: finds
//! the shortcode being typed before the caret, matches it against the emoji
//! catalog's CLDR names ("woozy face" is :woozy_face:) plus the small gemoji
//! alias table (:+1:, :joy:), and resolves a finished :name:.

const std = @import("std");
const picker = @import("emoji_picker.zig");
const data = @import("shortcode_data.zig");

pub const max_matches = 6;
pub const min_query = 2;
const max_name = 63;

pub const Match = struct {
    emoji: []const u8,
    code: [max_name]u8 = undefined,
    code_len: usize = 0,

    pub fn name(self: *const Match) []const u8 {
        return self.code[0..self.code_len];
    }
};

/// What the caret is inside: `start` is the UTF-16 index of the colon, the
/// shortcode text runs to `end` (exclusive), and `query` is its lowercase name.
pub const Typing = struct {
    start: usize,
    end: usize,
    closed: bool,
    query_buf: [max_name]u8 = undefined,
    query_len: usize = 0,

    pub fn query(self: *const Typing) []const u8 {
        return self.query_buf[0..self.query_len];
    }
};

fn isCodeChar(unit: u16) bool {
    return unit < 128 and (std.ascii.isAlphanumeric(@intCast(unit)) or unit == '_' or unit == '+' or unit == '-');
}

/// Looks at the text before the caret. Returns the shortcode being typed
/// (":woo") or just finished (":woozy:"), or null. A colon only opens a
/// shortcode at the start of the text or after a non-alphanumeric character
/// other than ':' and '/', so "12:30", "http://x" and "a:b" never trigger.
pub fn typing(before_caret: []const u16) ?Typing {
    var end = before_caret.len;
    var closed = false;
    if (end > 0 and before_caret[end - 1] == ':') {
        closed = true;
        end -= 1;
    }
    var begin = end;
    while (begin > 0 and isCodeChar(before_caret[begin - 1])) begin -= 1;
    if (begin == 0 or before_caret[begin - 1] != ':') return null;
    const colon = begin - 1;
    if (colon > 0) {
        const prev = before_caret[colon - 1];
        if (prev == ':' or prev == '/' or prev == '\\') return null;
        if (prev < 128 and std.ascii.isAlphanumeric(@intCast(prev))) return null;
    }
    const length = end - begin;
    if (length == 0 or length > max_name) return null;
    if (!closed and (length < min_query or !std.ascii.isAlphabetic(@intCast(before_caret[begin])))) return null;
    var result = Typing{ .start = colon, .end = before_caret.len, .closed = closed, .query_len = length };
    for (before_caret[begin..end], 0..) |unit, index| result.query_buf[index] = std.ascii.toLower(@intCast(unit));
    return result;
}

/// Lowercase, spaces and hyphens to '_', other punctuation dropped.
fn normalize(text: []const u8, out: *[max_name]u8) usize {
    var length: usize = 0;
    for (text) |byte| {
        const lowered = std.ascii.toLower(byte);
        const mapped: u8 = if (byte == ' ' or byte == '-') '_' else lowered;
        if (!(std.ascii.isAlphanumeric(mapped) or mapped == '_' or mapped == '+')) continue;
        if (length == max_name) break;
        out[length] = mapped;
        length += 1;
    }
    return length;
}

/// Offers every (shortcode, emoji) pair to `sink` until it returns false.
fn forEachCode(sink: anytype) void {
    var buffer: [max_name]u8 = undefined;
    for (0..picker.count) |index| {
        const length = normalize(picker.name(index), &buffer);
        if (!sink.offer(buffer[0..length], picker.emoji(index))) return;
    }
    var lines = std.mem.splitScalar(u8, data.aliases, '\n');
    while (lines.next()) |line| {
        var words = std.mem.splitScalar(u8, line, ' ');
        const emoji = words.next() orelse continue;
        while (words.next()) |word| {
            if (word.len > 0 and !sink.offer(word, emoji)) return;
        }
    }
}

const Collector = struct {
    query: []const u8,
    out: []Match,
    count: usize = 0,

    fn offer(self: *Collector, code: []const u8, emoji: []const u8) bool {
        if (!std.mem.startsWith(u8, code, self.query)) return true;
        // One entry per emoji, keeping its shortest name.
        for (self.out[0..self.count], 0..) |*kept, index| {
            if (!std.mem.eql(u8, kept.emoji, emoji)) continue;
            if (code.len < kept.code_len) {
                self.remove(index);
                self.insert(code, emoji);
            }
            return true;
        }
        self.insert(code, emoji);
        return true;
    }

    fn remove(self: *Collector, index: usize) void {
        std.mem.copyForwards(Match, self.out[index .. self.count - 1], self.out[index + 1 .. self.count]);
        self.count -= 1;
    }

    /// Keeps the list ordered by name length, so the exact and shortest
    /// names come first; ties keep catalog order.
    fn insert(self: *Collector, code: []const u8, emoji: []const u8) void {
        var at: usize = 0;
        while (at < self.count and self.out[at].code_len <= code.len) at += 1;
        if (at >= self.out.len) return;
        const last = @min(self.count, self.out.len - 1);
        std.mem.copyBackwards(Match, self.out[at + 1 .. last + 1], self.out[at..last]);
        var entry = Match{ .emoji = emoji, .code_len = code.len };
        @memcpy(entry.code[0..code.len], code);
        self.out[at] = entry;
        self.count = @min(self.count + 1, self.out.len);
    }
};

/// Fills `out` with the emojis whose shortcode starts with `query`
/// (lowercase), shortest names first, one per emoji. Returns the count.
pub fn matches(query: []const u8, out: []Match) usize {
    if (query.len == 0 or query.len > max_name) return 0;
    var collector = Collector{ .query = query, .out = out };
    forEachCode(&collector);
    return collector.count;
}

/// The emoji for a finished ":name:": the exact shortcode, else the best
/// prefix match (":woozy:" finds woozy_face), else null.
pub fn resolve(query: []const u8) ?[]const u8 {
    var found: [1]Match = undefined;
    if (matches(query, &found) == 0) return null;
    return found[0].emoji;
}

fn utf16(comptime text: []const u8) []const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

test "typing starts after a colon and two letters" {
    try std.testing.expect(typing(utf16(":w")) == null);
    const t = typing(utf16("hi :Woo")).?;
    try std.testing.expectEqualStrings("woo", t.query());
    try std.testing.expectEqual(@as(usize, 3), t.start);
    try std.testing.expect(!t.closed);
    try std.testing.expect(typing(utf16(":woo")) != null);
}

test "typing ignores times, urls and mid-word colons" {
    try std.testing.expect(typing(utf16("12:30")) == null);
    try std.testing.expect(typing(utf16("at 12:30")) == null);
    try std.testing.expect(typing(utf16("12:30:")) == null);
    try std.testing.expect(typing(utf16("http://")) == null);
    try std.testing.expect(typing(utf16("http://example")) == null);
    try std.testing.expect(typing(utf16("see https://a.b/c:woo")) == null);
    try std.testing.expect(typing(utf16("a:bc")) == null);
    try std.testing.expect(typing(utf16("::woo")) == null);
    try std.testing.expect(typing(utf16("ratio 3:2 ok")) == null);
    try std.testing.expect(typing(utf16("(:woo")) != null);
}

test "typing sees a finished shortcode" {
    const t = typing(utf16("go :woozy:")).?;
    try std.testing.expect(t.closed);
    try std.testing.expectEqualStrings("woozy", t.query());
    try std.testing.expectEqual(@as(usize, 3), t.start);
    try std.testing.expectEqual(@as(usize, 10), t.end);
    try std.testing.expect(typing(utf16(":+1:")) != null);
    try std.testing.expect(typing(utf16("::")) == null);
    try std.testing.expect(typing(utf16(": :")) == null);
}

test "prefix matching finds the woozy face by its CLDR name" {
    var out: [max_matches]Match = undefined;
    const count = matches("woo", &out);
    var found = false;
    for (out[0..count]) |entry| {
        if (std.mem.eql(u8, entry.emoji, "🥴")) {
            found = true;
            try std.testing.expectEqualStrings("woozy_face", entry.name());
        }
    }
    try std.testing.expect(found);
    out[0] = undefined;
    try std.testing.expectEqual(@as(usize, 1), matches("woozy", out[0..1]));
    try std.testing.expectEqualStrings("🥴", out[0].emoji);
}

test "shortest names come first and every emoji appears once" {
    var out: [max_matches]Match = undefined;
    const count = matches("smi", &out);
    try std.testing.expect(count == max_matches);
    for (out[0..count], 0..) |entry, index| {
        if (index > 0) try std.testing.expect(out[index - 1].code_len <= entry.code_len);
        for (out[0..index]) |earlier| try std.testing.expect(!std.mem.eql(u8, earlier.emoji, entry.emoji));
    }
}

test "gemoji aliases resolve" {
    try std.testing.expectEqualStrings("👍", resolve("+1").?);
    try std.testing.expectEqualStrings("😂", resolve("joy").?);
    try std.testing.expectEqualStrings("🎉", resolve("tada").?);
    try std.testing.expectEqualStrings("🥴", resolve("woozy_face").?);
    try std.testing.expectEqualStrings("🥴", resolve("woozy").?);
    try std.testing.expectEqualStrings("🔥", resolve("fire").?);
    try std.testing.expect(resolve("zzzzqq") == null);
}

test "no match for nonsense and empty queries" {
    var out: [max_matches]Match = undefined;
    try std.testing.expectEqual(@as(usize, 0), matches("", &out));
    try std.testing.expectEqual(@as(usize, 0), matches("qqzx", &out));
}
