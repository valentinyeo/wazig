//! WAZI-100: durable send outbox. Every queued send (WhatsApp and Slack,
//! text and staged file) carries a client-generated 128-bit hex id and is
//! mirrored as one JSON line to outbox.jsonl, so a crash or an update
//! restart can never silently lose a message: unsent entries reload on
//! startup, show as pending bubbles, and send. Pure format logic lives here
//! so it can be unit tested without Windows; main.zig owns the file I/O.
//!
//! One line per entry:
//! {"id":"<32 hex>","provider":"whatsapp|slack","jid":"...","text":"...",
//!  "file":"...","reply_to":"...","reply_sender":"...","client_msg_id":"...",
//!  "queued_unix":1234567890}

const std = @import("std");

/// Length of a client send id: 128 random bits, lowercase hex.
pub const id_len = 32;
pub const max_jid_len = 191;
pub const max_text_len = 4095;
pub const max_file_len = 519;
/// Slack's client_msg_id (a UUID string) rides along for bubble correlation.
pub const max_client_msg_id_len = 63;
/// A 4095-byte text of control characters escapes to 6 bytes each, plus
/// field overhead; the writer never produces longer lines, so the reader
/// can safely reject anything past this as corrupt.
pub const max_line_len = 32 * 1024;
/// Loader capacity bound; the app's queues are smaller.
pub const max_entries = 64;

pub const Provider = enum { whatsapp, slack };

/// One nul-terminated fixed string field, mirroring main.zig's Utf8Text:
/// a stored value is never truncated back into existence, so parse rejects
/// fields that do not fit instead of silently shortening them.
pub fn Str(comptime capacity: usize) type {
    return struct {
        buf: [capacity + 1]u8 = [_]u8{0} ** (capacity + 1),
        len: usize = 0,

        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }

        pub fn set(self: *@This(), text: []const u8) void {
            self.len = @min(text.len, capacity);
            @memcpy(self.buf[0..self.len], text[0..self.len]);
            self.buf[self.len] = 0;
        }
    };
}

pub const Entry = struct {
    id: [id_len]u8 = [_]u8{'0'} ** id_len,
    provider: Provider = .whatsapp,
    jid: Str(max_jid_len) = .{},
    text: Str(max_text_len) = .{},
    file: Str(max_file_len) = .{},
    reply_to: Str(max_jid_len) = .{},
    reply_sender: Str(max_jid_len) = .{},
    client_msg_id: Str(max_client_msg_id_len) = .{},
    queued_unix: i64 = 0,

    pub fn idSlice(self: *const Entry) []const u8 {
        return &self.id;
    }
};

/// True for a 128-bit lowercase hex id, the only shape mintSendId produces.
pub fn validId(id: []const u8) bool {
    if (id.len != id_len) return false;
    for (id) |byte| {
        const digit = switch (byte) {
            '0'...'9' => true,
            'a'...'f' => true,
            else => false,
        };
        if (!digit) return false;
    }
    return true;
}

/// Random bytes to the 32-character hex id the outbox keys entries by.
pub fn hexId(random: [16]u8) [id_len]u8 {
    return std.fmt.bytesToHex(random, .lower);
}

const line_fields = struct {
    id: []const u8,
    provider: []const u8,
    jid: []const u8,
    text: []const u8,
    file: []const u8,
    reply_to: []const u8,
    reply_sender: []const u8,
    client_msg_id: []const u8,
    queued_unix: i64,
};

/// Appends `entry` as one JSONL line (newline included).
pub fn writeLine(writer: *std.Io.Writer, entry: *const Entry) !void {
    try std.json.Stringify.value(line_fields{
        .id = entry.idSlice(),
        .provider = @tagName(entry.provider),
        .jid = entry.jid.slice(),
        .text = entry.text.slice(),
        .file = entry.file.slice(),
        .reply_to = entry.reply_to.slice(),
        .reply_sender = entry.reply_sender.slice(),
        .client_msg_id = entry.client_msg_id.slice(),
        .queued_unix = entry.queued_unix,
    }, .{}, writer);
    try writer.writeByte('\n');
}

/// The parsed form: every field defaults, so a line written by another
/// version that omits empty fields still loads, and the explicit checks
/// below decide what is invalid.
const parsed_line = struct {
    id: []const u8 = "",
    provider: []const u8 = "",
    jid: []const u8 = "",
    text: []const u8 = "",
    file: []const u8 = "",
    reply_to: []const u8 = "",
    reply_sender: []const u8 = "",
    client_msg_id: []const u8 = "",
    queued_unix: i64 = 0,
};

/// Parses one JSONL line into `out`. Returns false for anything that is not
/// a well-formed entry (empty, corrupt JSON, wrong id shape, unknown
/// provider, field that does not fit, no message and no file); the loader
/// skips the line instead of sending garbage.
pub fn parseLine(allocator: std.mem.Allocator, line: []const u8, out: *Entry) bool {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0 or trimmed.len > max_line_len) return false;
    var parsed = std.json.parseFromSlice(parsed_line, allocator, trimmed, .{ .ignore_unknown_fields = true }) catch return false;
    defer parsed.deinit();
    const value = parsed.value;
    if (!validId(value.id)) return false;
    const provider = std.meta.stringToEnum(Provider, value.provider) orelse return false;
    if (value.jid.len == 0 or value.jid.len > max_jid_len) return false;
    if (value.text.len == 0 and value.file.len == 0) return false;
    if (value.text.len > max_text_len or value.file.len > max_file_len or
        value.reply_to.len > max_jid_len or value.reply_sender.len > max_jid_len or
        value.client_msg_id.len > max_client_msg_id_len) return false;
    out.* = .{ .provider = provider, .queued_unix = value.queued_unix };
    @memcpy(&out.id, value.id);
    out.jid.set(value.jid);
    out.text.set(value.text);
    out.file.set(value.file);
    out.reply_to.set(value.reply_to);
    out.reply_sender.set(value.reply_sender);
    out.client_msg_id.set(value.client_msg_id);
    return true;
}

/// Line-by-line loader: `next` returns each valid entry from the file,
/// skipping corrupt lines and collapsing duplicates by id (first wins).
/// The borrowed result stays valid until the following `next` call.
pub const Scanner = struct {
    allocator: std.mem.Allocator,
    rest: []const u8,
    seen: [max_entries][id_len]u8 = [_][id_len]u8{[_]u8{0} ** id_len} ** max_entries,
    seen_count: usize = 0,
    current: Entry = .{},

    pub fn init(allocator: std.mem.Allocator, contents: []const u8) Scanner {
        return .{ .allocator = allocator, .rest = contents };
    }

    pub fn next(self: *Scanner) ?*const Entry {
        while (self.rest.len > 0) {
            var line = self.rest;
            if (std.mem.indexOfScalar(u8, self.rest, '\n')) |newline| {
                line = self.rest[0..newline];
                self.rest = self.rest[newline + 1 ..];
            } else {
                self.rest = &.{};
            }
            if (!parseLine(self.allocator, line, &self.current)) continue;
            for (self.seen[0..self.seen_count]) |seen_id| {
                if (std.mem.eql(u8, &seen_id, self.current.idSlice())) break;
            } else {
                if (self.seen_count < self.seen.len) {
                    self.seen[self.seen_count] = self.current.id;
                    self.seen_count += 1;
                }
                return &self.current;
            }
            // A duplicate id: keep scanning so later entries still load.
        }
        return null;
    }
};

/// Index of the queued job to evict when the shared job queue is full, or
/// null when nothing may be dropped. `keep[i]` marks queue entries that are
/// writes (sends, reactions): a full queue never evicts one of those
/// (WAZI-100); the incoming job instead waits and its owner retries on the
/// next tick. Scans from the back so the oldest droppable job goes first,
/// as before: index 0 holds the newest (urgent) job and must survive.
pub fn evictionVictim(keep: []const bool) ?usize {
    var index: usize = keep.len;
    while (index > 0) {
        index -= 1;
        if (!keep[index]) return index;
    }
    return null;
}

test "line round trip keeps every field through escapes" {
    const allocator = std.testing.allocator;
    var entry = Entry{
        .provider = .slack,
        .queued_unix = 1_700_000_000,
    };
    entry.id = hexId([_]u8{0xab} ** 16);
    entry.jid.set("1701234567-1234567890@us-east-1.ahoy.4-1-1.chcimbabwe-internal.slack.com");
    entry.text.set("line one\n\"quoted\" back\\slash, emoji 🎉 and unicode ünïcodé");
    entry.file.set("C:\\Users\\test\\AppData\\Local\\Messages\\paste\\paste-1.png");
    entry.reply_to.set("1700000000.000100");
    entry.reply_sender.set("U12345678");
    entry.client_msg_id.set("d9b1c0f2-6b0d-4f6a-9e1a-3c8f2d5b7a01");

    var allocating = std.Io.Writer.Allocating.init(allocator);
    defer allocating.deinit();
    try writeLine(&allocating.writer, &entry);
    const line = try allocating.toOwnedSlice();
    defer allocator.free(line);

    var parsed = Entry{};
    try std.testing.expect(parseLine(allocator, line, &parsed));
    try std.testing.expectEqual(Provider.slack, parsed.provider);
    try std.testing.expectEqualSlices(u8, entry.idSlice(), parsed.idSlice());
    try std.testing.expectEqualStrings(entry.jid.slice(), parsed.jid.slice());
    try std.testing.expectEqualStrings(entry.text.slice(), parsed.text.slice());
    try std.testing.expectEqualStrings(entry.file.slice(), parsed.file.slice());
    try std.testing.expectEqualStrings(entry.reply_to.slice(), parsed.reply_to.slice());
    try std.testing.expectEqualStrings(entry.reply_sender.slice(), parsed.reply_sender.slice());
    try std.testing.expectEqualStrings(entry.client_msg_id.slice(), parsed.client_msg_id.slice());
    try std.testing.expectEqual(entry.queued_unix, parsed.queued_unix);
}

test "scanner skips corrupt lines and loads the valid ones" {
    const allocator = std.testing.allocator;
    var entry = Entry{ .provider = .whatsapp, .queued_unix = 42 };
    entry.id = hexId([_]u8{1} ** 16);
    entry.jid.set("1234567890@s.whatsapp.net");
    entry.text.set("hello");
    var allocating = std.Io.Writer.Allocating.init(allocator);
    defer allocating.deinit();
    try writeLine(&allocating.writer, &entry);
    const good = try allocating.toOwnedSlice();
    defer allocator.free(good);

    const contents = std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s}{s}{s}{s}", .{
        "not json at all\n",
        "\n",
        "{\"id\":\"too-short\",\"provider\":\"whatsapp\",\"jid\":\"x\",\"text\":\"y\",\"queued_unix\":1}\n",
        // Right length, but not hex.
        "{\"id\":\"0123456789abcdef0123456789abcdeg\",\"provider\":\"whatsapp\",\"jid\":\"x\",\"text\":\"y\",\"queued_unix\":1}\n",
        // Unknown provider tag.
        "{\"id\":\"0123456789abcdef0123456789abcdef\",\"provider\":\"carrier-pigeon\",\"jid\":\"x\",\"text\":\"y\",\"queued_unix\":1}\n",
        // Well-formed JSON but no text and no file: never sendable.
        "{\"id\":\"0123456789abcdef0123456789abcdef\",\"provider\":\"whatsapp\",\"jid\":\"x\",\"queued_unix\":1}\n",
        good,
        // Truncated mid-line, as a crash mid-write could leave the file.
        "{\"id\":\"0123456789abcdef0123456789abcde\n",
    }) catch unreachable;
    defer allocator.free(contents);

    var scanner = Scanner.init(allocator, contents);
    const first = scanner.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(Provider.whatsapp, first.provider);
    try std.testing.expectEqualStrings("1234567890@s.whatsapp.net", first.jid.slice());
    try std.testing.expectEqualStrings("hello", first.text.slice());
    try std.testing.expectEqual(@as(i64, 42), first.queued_unix);
    try std.testing.expect(scanner.next() == null);
}

test "scanner collapses duplicate ids and keeps the first entry" {
    const allocator = std.testing.allocator;
    var first = Entry{};
    first.id = hexId([_]u8{2} ** 16);
    first.jid.set("1234567890@s.whatsapp.net");
    first.text.set("original");
    var duplicate = first;
    duplicate.text.set("resend from an older snapshot");
    var third = Entry{};
    third.id = hexId([_]u8{3} ** 16);
    third.jid.set("1234567890@s.whatsapp.net");
    third.text.set("after");

    var allocating = std.Io.Writer.Allocating.init(allocator);
    defer allocating.deinit();
    try writeLine(&allocating.writer, &first);
    try writeLine(&allocating.writer, &duplicate);
    try writeLine(&allocating.writer, &third);

    const whole = try allocating.toOwnedSlice();
    defer allocator.free(whole);
    var scanner = Scanner.init(allocator, whole);
    const loaded_first = scanner.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("original", loaded_first.text.slice());
    const loaded_third = scanner.next() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("after", loaded_third.text.slice());
    try std.testing.expect(scanner.next() == null);
}

test "evictionVictim never evicts a write and gives up when only writes remain" {
    // Writes only: nothing may be dropped, whatever arrives.
    try std.testing.expectEqual(@as(?usize, null), evictionVictim(&.{ true, true, true }));
    // The oldest droppable job goes first, scanning from the back.
    try std.testing.expectEqual(@as(?usize, 3), evictionVictim(&.{ true, false, false, false }));
    try std.testing.expectEqual(@as(?usize, 1), evictionVictim(&.{ true, false, true, true }));
    try std.testing.expectEqual(@as(?usize, 0), evictionVictim(&.{ false, true, true, true }));
    try std.testing.expectEqual(@as(?usize, null), evictionVictim(&.{}));
}
