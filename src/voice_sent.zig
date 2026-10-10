//! Voice notes, pasted images and files sent from wazig through wacli. wacli
//! stores a sent row late, or with a file path this PC cannot open, so the app
//! keeps its own copy and lays it over the stored row (a voice note also over
//! a stand-in bubble) so the media shows or plays at once, transcribes from
//! the local file, and is never downloaded back (every download pauses sync).

const std = @import("std");

pub const max_entries = 32;

/// One sent note: where its OGG lives and which stored row claimed it.
pub const Entry = struct {
    jid: [191]u8 = undefined,
    jid_len: usize = 0,
    file: [520]u8 = undefined,
    file_len: usize = 0,
    queued_unix: i64 = 0,
    seconds: u32 = 0,
    /// A recorded voice note (audio row, stand-in bubble). False for a pasted
    /// image or other file, which matches any non-audio media row.
    voice: bool = true,
    matched_id: [191]u8 = undefined,
    matched_len: usize = 0,
    seq: u64 = 0,

    pub fn jidSlice(self: *const Entry) []const u8 {
        return self.jid[0..self.jid_len];
    }
    pub fn fileSlice(self: *const Entry) []const u8 {
        return self.file[0..self.file_len];
    }
    pub fn matchedSlice(self: *const Entry) []const u8 {
        return self.matched_id[0..self.matched_len];
    }
};

/// wacli labels every audio row "Sent audio" (even a received one) or
/// "[Audio]". Under a player that text is noise, so it is hidden.
pub fn isAudioPlaceholder(text: []const u8) bool {
    return std.mem.eql(u8, text, "Sent audio") or std.mem.eql(u8, text, "[Audio]");
}

/// A stored row is one of our own voice notes: from me, an audio row.
pub fn isOwnVoiceRow(from_me: bool, media_type: []const u8) bool {
    return from_me and std.ascii.eqlIgnoreCase(media_type, "audio");
}

/// A stored row is one of our own images or files: from me, a media row that
/// is not audio.
pub fn isOwnFileRow(from_me: bool, media_type: []const u8) bool {
    return from_me and media_type.len > 0 and !std.ascii.eqlIgnoreCase(media_type, "audio");
}

/// Does this stored row belong to the send queued at `queued_unix`? The row
/// must be our own media of the right kind (`voice` picks audio, otherwise
/// image or file) and stamped at or just before the queue time (the same 5
/// second slack the text-send match uses).
pub fn rowMatchesEntry(from_me: bool, media_type: []const u8, row_unix: i64, queued_unix: i64, voice: bool) bool {
    const own = if (voice) isOwnVoiceRow(from_me, media_type) else isOwnFileRow(from_me, media_type);
    return own and row_unix >= queued_unix - 5;
}

/// Is this stored message id one of ours with a remembered local file?
pub fn claimsId(entries: []const Entry, jid: []const u8, id: []const u8) bool {
    for (entries) |*entry| {
        if (entry.matched_len == 0) continue;
        if (std.mem.eql(u8, entry.jidSlice(), jid) and std.mem.eql(u8, entry.matchedSlice(), id)) return true;
    }
    return false;
}

/// An own media row that wazig still holds the file for is never fetched:
/// the download would pause live sync for a file already on this PC.
pub fn needsDownload(from_me: bool, has_local_path: bool, claimed_by_sent_entry: bool) bool {
    if (has_local_path) return false;
    if (from_me and claimed_by_sent_entry) return false;
    return true;
}

/// Append, dropping the oldest entry when full.
pub fn push(list: *[max_entries]Entry, count: *usize, entry: Entry) void {
    if (count.* == max_entries) {
        var i: usize = 1;
        while (i < max_entries) : (i += 1) list[i - 1] = list[i];
        count.* -= 1;
    }
    list[count.*] = entry;
    count.* += 1;
}

test "own audio row is a voice note, received and text rows are not" {
    try std.testing.expect(isOwnVoiceRow(true, "audio"));
    try std.testing.expect(isOwnVoiceRow(true, "Audio"));
    try std.testing.expect(!isOwnVoiceRow(false, "audio"));
    try std.testing.expect(!isOwnVoiceRow(true, ""));
    try std.testing.expect(!isOwnVoiceRow(true, "image"));
}

test "stored row matches a note queued at or before its timestamp" {
    try std.testing.expect(rowMatchesEntry(true, "audio", 1000, 1000, true));
    try std.testing.expect(rowMatchesEntry(true, "audio", 996, 1000, true));
    try std.testing.expect(!rowMatchesEntry(true, "audio", 990, 1000, true));
    try std.testing.expect(!rowMatchesEntry(false, "audio", 1000, 1000, true));
}

test "a sent image or file maps to a non-audio own row, never to audio" {
    try std.testing.expect(rowMatchesEntry(true, "image", 1000, 1000, false));
    try std.testing.expect(rowMatchesEntry(true, "document", 1001, 1000, false));
    try std.testing.expect(!rowMatchesEntry(true, "audio", 1000, 1000, false));
    try std.testing.expect(!rowMatchesEntry(true, "image", 1000, 1000, true));
    try std.testing.expect(!rowMatchesEntry(false, "image", 1000, 1000, false));
    try std.testing.expect(!rowMatchesEntry(true, "", 1000, 1000, false));
    try std.testing.expect(!rowMatchesEntry(true, "image", 990, 1000, false));
}

test "claimsId finds only matched entries of that chat" {
    var entry = Entry{};
    @memcpy(entry.jid[0..1], "j");
    entry.jid_len = 1;
    var list = [_]Entry{entry};
    try std.testing.expect(!claimsId(&list, "j", "X"));
    @memcpy(list[0].matched_id[0..1], "X");
    list[0].matched_len = 1;
    try std.testing.expect(claimsId(&list, "j", "X"));
    try std.testing.expect(!claimsId(&list, "k", "X"));
    try std.testing.expect(!claimsId(&list, "j", "Y"));
}

test "own media with a local file is not downloaded" {
    try std.testing.expect(!needsDownload(true, true, true));
    try std.testing.expect(!needsDownload(true, false, true));
    try std.testing.expect(!needsDownload(false, true, false));
    try std.testing.expect(needsDownload(false, false, false));
    try std.testing.expect(needsDownload(true, false, false));
}

test "audio placeholders are hidden, real captions are kept" {
    try std.testing.expect(isAudioPlaceholder("Sent audio"));
    try std.testing.expect(isAudioPlaceholder("[Audio]"));
    try std.testing.expect(!isAudioPlaceholder("see you at 5"));
}

test "push drops the oldest entry when full" {
    var list: [max_entries]Entry = [_]Entry{.{}} ** max_entries;
    var count: usize = 0;
    var n: u64 = 0;
    while (n < max_entries + 2) : (n += 1) push(&list, &count, .{ .seq = n });
    try std.testing.expectEqual(@as(usize, max_entries), count);
    try std.testing.expectEqual(@as(u64, 2), list[0].seq);
    try std.testing.expectEqual(@as(u64, max_entries + 1), list[max_entries - 1].seq);
}

/// One persisted line: jid, message id, file and an optional kind ("f" for an
/// image or file, anything else or absent for a voice note), tab separated.
/// Loaded entries are already matched to their stored row, so they need no
/// queue time.
pub fn parseLine(line: []const u8) ?Entry {
    var parts = std.mem.splitScalar(u8, line, '\t');
    const jid = parts.next() orelse return null;
    const id = parts.next() orelse return null;
    const file = parts.next() orelse return null;
    var entry = Entry{};
    if (parts.next()) |kind| entry.voice = !std.mem.eql(u8, kind, "f");
    if (jid.len == 0 or jid.len > entry.jid.len or id.len == 0 or id.len > entry.matched_id.len or file.len == 0 or file.len > entry.file.len) return null;
    @memcpy(entry.jid[0..jid.len], jid);
    entry.jid_len = jid.len;
    @memcpy(entry.matched_id[0..id.len], id);
    entry.matched_len = id.len;
    @memcpy(entry.file[0..file.len], file);
    entry.file_len = file.len;
    return entry;
}

test "persisted line parses and junk is rejected" {
    const entry = parseLine("1@s.whatsapp.net\tABC123\tC:\\x\\paste-1.ogg").?;
    try std.testing.expectEqualStrings("1@s.whatsapp.net", entry.jidSlice());
    try std.testing.expectEqualStrings("ABC123", entry.matchedSlice());
    try std.testing.expectEqualStrings("C:\\x\\paste-1.ogg", entry.fileSlice());
    try std.testing.expect(entry.voice);
    try std.testing.expect(!parseLine("1@s.whatsapp.net\tABC\tC:\\x\\paste-1.png\tf").?.voice);
    try std.testing.expect(parseLine("only\ttwo") == null);
    try std.testing.expect(parseLine("") == null);
}
