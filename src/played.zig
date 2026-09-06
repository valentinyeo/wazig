//! Local record of which voice notes the user has already played.
//! Kept entirely on-device; nothing is sent to the other party.

const std = @import("std");

pub const Set = struct {
    // ponytail: fixed 2048-entry ring; once full, the oldest entry is
    // overwritten and that voice note falls back to unplayed. Upgrade path:
    // hash-set file with compaction.
    hashes: [2048]u64 = [_]u64{0} ** 2048,
    count: usize = 0,

    pub fn wasPlayed(self: *const Set, id: []const u8) bool {
        if (id.len == 0) return false;
        return self.wasPlayedRaw(std.hash.Wyhash.hash(0, id));
    }

    pub fn wasPlayedRaw(self: *const Set, hash: u64) bool {
        for (self.hashes[0..@min(self.count, self.hashes.len)]) |entry| {
            if (entry == hash) return true;
        }
        return false;
    }

    /// Parses the store contents (one 16-digit hex hash per line). Lines of
    /// any other length are treated as corrupt — including a truncated tail
    /// from a crash mid-write, which must not become a phantom entry. The
    /// file is append-only, so parsing wraps head-first and the newest
    /// entries survive the ring capacity.
    pub fn load(self: *Set, contents: []const u8) void {
        var lines = std.mem.tokenizeAny(u8, contents, "\r\n");
        while (lines.next()) |line| {
            if (line.len != 16) continue;
            const hash = std.fmt.parseInt(u64, line, 16) catch continue;
            self.hashes[self.count % self.hashes.len] = hash;
            self.count += 1;
        }
    }

    /// Returns the hex line to append to the store file, or null when the id
    /// was already recorded.
    pub fn mark(self: *Set, id: []const u8, line_buffer: []u8) ?[]const u8 {
        if (id.len == 0) return null;
        const hash = std.hash.Wyhash.hash(0, id);
        if (self.wasPlayed(id)) return null;
        self.hashes[self.count % self.hashes.len] = hash;
        self.count += 1;
        return std.fmt.bufPrint(line_buffer, "{x:0>16}\n", .{hash}) catch null;
    }
};

test "mark and recall played ids, ignore repeats and empty ids" {
    var set: Set = .{};
    var buffer: [40]u8 = undefined;
    const line = set.mark("abc", &buffer).?;
    try std.testing.expect(set.wasPlayed("abc"));
    try std.testing.expect(!set.wasPlayed("xyz"));
    try std.testing.expect(set.mark("abc", &buffer) == null);
    try std.testing.expect(set.mark("", &buffer) == null);
    var reloaded: Set = .{};
    reloaded.load(line);
    try std.testing.expect(reloaded.wasPlayed("abc"));
}

test "load skips malformed and truncated lines" {
    var set: Set = .{};
    set.load("deadbeefdeadbeef\nzzzz\nbeef\nbeef00000000000\n");
    try std.testing.expectEqual(@as(usize, 1), set.count);
    try std.testing.expect(set.wasPlayedRaw(0xdeadbeefdeadbeef));
    try std.testing.expect(!set.wasPlayedRaw(0xbeef));
}

test "load wraps so the newest entries survive the ring capacity" {
    var set: Set = .{ .count = 2048 };
    set.hashes[0] = 0x11; // oldest slot when the ring is full
    set.load("0000000000000022\n0000000000000033\n");
    try std.testing.expectEqual(@as(usize, 2050), set.count);
    // Slot 0 (the oldest) was overwritten by the wrap; the newest two survive.
    try std.testing.expect(!set.wasPlayedRaw(0x11));
    try std.testing.expect(set.wasPlayedRaw(0x22));
    try std.testing.expect(set.wasPlayedRaw(0x33));
}
