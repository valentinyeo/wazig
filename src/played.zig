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
        const hash = std.hash.Wyhash.hash(0, id);
        for (self.hashes[0..@min(self.count, self.hashes.len)]) |entry| {
            if (entry == hash) return true;
        }
        return false;
    }

    pub fn load(self: *Set, contents: []const u8) void {
        var lines = std.mem.tokenizeAny(u8, contents, "\r\n");
        while (lines.next()) |line| {
            if (self.count >= self.hashes.len) break;
            self.hashes[self.count] = std.fmt.parseInt(u64, line, 16) catch continue;
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
        return std.fmt.bufPrint(line_buffer, "{x}\n", .{hash}) catch null;
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
