//! Where each voice note was last left, so reopening a chat (or restarting
//! the app) shows the progress bar there and play resumes from it. A tiny
//! on-device text file, one "<key hex> <position ms> <duration ms>" line per
//! note, rewritten only on pause, stop or chat switch.

const std = @import("std");

pub const capacity = 64;

pub const Entry = struct { key: u64, pos_ms: u32, dur_ms: u32 };

pub const Store = struct {
    entries: [capacity]Entry = undefined,
    count: usize = 0,

    pub fn get(self: *const Store, key: u64) ?Entry {
        for (self.entries[0..self.count]) |entry| {
            if (entry.key == key) return entry;
        }
        return null;
    }

    /// Remember a position. A position of 0 (never played, or finished and
    /// reset to the start) forgets the note. The oldest entry makes room.
    /// Returns true when the store changed.
    pub fn set(self: *Store, key: u64, pos_ms: u32, dur_ms: u32) bool {
        for (self.entries[0..self.count], 0..) |*entry, index| {
            if (entry.key != key) continue;
            if (pos_ms == 0) {
                var shift = index;
                while (shift + 1 < self.count) : (shift += 1) self.entries[shift] = self.entries[shift + 1];
                self.count -= 1;
                return true;
            }
            if (entry.pos_ms == pos_ms and entry.dur_ms == dur_ms) return false;
            entry.pos_ms = pos_ms;
            entry.dur_ms = dur_ms;
            return true;
        }
        if (pos_ms == 0) return false;
        if (self.count == capacity) {
            var shift: usize = 1;
            while (shift < capacity) : (shift += 1) self.entries[shift - 1] = self.entries[shift];
            self.count -= 1;
        }
        self.entries[self.count] = .{ .key = key, .pos_ms = pos_ms, .dur_ms = dur_ms };
        self.count += 1;
        return true;
    }

    /// Parse the file; malformed or truncated lines are skipped.
    pub fn load(self: *Store, contents: []const u8) void {
        var lines = std.mem.tokenizeAny(u8, contents, "\r\n");
        while (lines.next()) |line| {
            var parts = std.mem.tokenizeScalar(u8, line, ' ');
            const key_text = parts.next() orelse continue;
            if (key_text.len != 16) continue;
            const key = std.fmt.parseInt(u64, key_text, 16) catch continue;
            const pos = std.fmt.parseInt(u32, parts.next() orelse continue, 10) catch continue;
            const dur = std.fmt.parseInt(u32, parts.next() orelse continue, 10) catch continue;
            _ = self.set(key, pos, dur);
        }
    }

    /// The whole file contents, or null when the buffer is too small.
    pub fn serialize(self: *const Store, buffer: []u8) ?[]const u8 {
        var length: usize = 0;
        for (self.entries[0..self.count]) |entry| {
            const line = std.fmt.bufPrint(buffer[length..], "{x:0>16} {d} {d}\n", .{ entry.key, entry.pos_ms, entry.dur_ms }) catch return null;
            length += line.len;
        }
        return buffer[0..length];
    }
};

test "remember, update and reset a position" {
    var store: Store = .{};
    try std.testing.expect(store.set(1, 4000, 10000));
    try std.testing.expectEqual(@as(u32, 4000), store.get(1).?.pos_ms);
    try std.testing.expect(!store.set(1, 4000, 10000));
    try std.testing.expect(store.set(1, 7000, 10000));
    try std.testing.expectEqual(@as(u32, 7000), store.get(1).?.pos_ms);
    // Finished: reset to the start forgets the note.
    try std.testing.expect(store.set(1, 0, 10000));
    try std.testing.expect(store.get(1) == null);
    try std.testing.expect(!store.set(2, 0, 5000));
}

test "capacity drops the oldest entry" {
    var store: Store = .{};
    var key: u64 = 1;
    while (key <= capacity + 3) : (key += 1) _ = store.set(key, 100, 1000);
    try std.testing.expectEqual(@as(usize, capacity), store.count);
    try std.testing.expect(store.get(1) == null);
    try std.testing.expect(store.get(4) != null);
    try std.testing.expect(store.get(capacity + 3) != null);
}

test "round trip through the file text, skipping corrupt lines" {
    var store: Store = .{};
    _ = store.set(0xabc, 1500, 9000);
    _ = store.set(0xdef, 2500, 8000);
    var buffer: [512]u8 = undefined;
    const text = store.serialize(&buffer).?;
    var reloaded: Store = .{};
    reloaded.load("garbage\n0000000000000abc\nzzzzzzzzzzzzzzzz 1 2\n");
    try std.testing.expectEqual(@as(usize, 0), reloaded.count);
    reloaded.load(text);
    try std.testing.expectEqual(@as(usize, 2), reloaded.count);
    try std.testing.expectEqual(@as(u32, 2500), reloaded.get(0xdef).?.pos_ms);
    try std.testing.expectEqual(@as(u32, 9000), reloaded.get(0xabc).?.dur_ms);
}
