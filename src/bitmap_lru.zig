// Pure size/recency accounting for the message-image bitmap cache.
//
// main.zig owns the actual HBITMAP objects; this module only tracks how
// many bytes each one costs and when it was last shown, and decides which
// ones to evict once the total goes over budget. Keeping it free of any
// Win32 type makes it possible to unit test the eviction order without a
// Windows target.
const std = @import("std");

pub fn Lru(comptime max_entries: usize) type {
    return struct {
        const Self = @This();

        const Entry = struct {
            key: usize,
            bytes: usize,
            last_used: u64,
            in_use: bool = false,
        };

        entries: [max_entries]Entry = [_]Entry{.{ .key = 0, .bytes = 0, .last_used = 0 }} ** max_entries,
        count: usize = 0,
        clock: u64 = 0,
        total_bytes: usize = 0,

        fn indexOf(self: *const Self, key: usize) ?usize {
            for (self.entries[0..self.count], 0..) |entry, i| {
                if (entry.in_use and entry.key == key) return i;
            }
            return null;
        }

        /// Records that `key` (e.g. a message slot's address) now holds a
        /// bitmap of `bytes` size and was just shown. Advances the clock so
        /// this becomes the most-recently-used entry.
        pub fn touch(self: *Self, key: usize, bytes: usize) void {
            self.clock += 1;
            if (self.indexOf(key)) |i| {
                self.total_bytes -= self.entries[i].bytes;
                self.entries[i].bytes = bytes;
                self.entries[i].last_used = self.clock;
                self.total_bytes += bytes;
                return;
            }
            if (self.count < max_entries) {
                self.entries[self.count] = .{ .key = key, .bytes = bytes, .last_used = self.clock, .in_use = true };
                self.count += 1;
                self.total_bytes += bytes;
            }
        }

        /// Drops `key` from accounting without evicting anything else, e.g.
        /// because the caller already freed that bitmap itself (message
        /// list cleared, chat switched).
        pub fn remove(self: *Self, key: usize) void {
            const i = self.indexOf(key) orelse return;
            self.total_bytes -= self.entries[i].bytes;
            self.entries[i] = self.entries[self.count - 1];
            self.count -= 1;
        }

        /// Picks least-recently-used entries to drop so total_bytes fits
        /// budget, writes their keys into `out` (caller-owned, sized to
        /// max_entries) and removes them from accounting. Returns the
        /// number of keys written. The caller is responsible for freeing
        /// the actual bitmap for each returned key.
        pub fn evict(self: *Self, budget: usize, out: []usize) usize {
            var evicted: usize = 0;
            while (self.total_bytes > budget and self.count > 0 and evicted < out.len) {
                var victim: usize = 0;
                var victim_used: u64 = std.math.maxInt(u64);
                for (self.entries[0..self.count], 0..) |entry, i| {
                    if (entry.last_used < victim_used) {
                        victim_used = entry.last_used;
                        victim = i;
                    }
                }
                out[evicted] = self.entries[victim].key;
                evicted += 1;
                self.total_bytes -= self.entries[victim].bytes;
                self.entries[victim] = self.entries[self.count - 1];
                self.count -= 1;
            }
            return evicted;
        }

        pub fn clear(self: *Self) void {
            self.count = 0;
            self.total_bytes = 0;
        }
    };
}

const testing = std.testing;

test "touch tracks total bytes and updates existing entries" {
    var lru = Lru(8){};
    lru.touch(1, 100);
    lru.touch(2, 200);
    try testing.expectEqual(@as(usize, 300), lru.total_bytes);
    lru.touch(1, 150); // resize key 1, also refreshes recency
    try testing.expectEqual(@as(usize, 350), lru.total_bytes);
}

test "evict drops least-recently-used entries first" {
    var lru = Lru(8){};
    lru.touch(1, 100);
    lru.touch(2, 100);
    lru.touch(3, 100);
    // Re-touch key 1 so key 2 becomes the oldest.
    lru.touch(1, 100);
    var out: [8]usize = undefined;
    const n = lru.evict(150, &out);
    try testing.expectEqual(@as(usize, 2), n);
    // key 2 (oldest) and key 3 (next oldest) should be evicted, key 1 kept.
    var saw_key1 = false;
    for (out[0..n]) |k| {
        try testing.expect(k != 1);
        if (k == 1) saw_key1 = true;
    }
    try testing.expect(!saw_key1);
    try testing.expectEqual(@as(usize, 100), lru.total_bytes);
}

test "evict never removes more than needed to fit budget" {
    var lru = Lru(8){};
    lru.touch(1, 100);
    lru.touch(2, 100);
    var out: [8]usize = undefined;
    const n = lru.evict(250, &out);
    try testing.expectEqual(@as(usize, 0), n);
    try testing.expectEqual(@as(usize, 200), lru.total_bytes);
}

test "remove drops accounting without touching other entries" {
    var lru = Lru(8){};
    lru.touch(1, 100);
    lru.touch(2, 200);
    lru.remove(1);
    try testing.expectEqual(@as(usize, 200), lru.total_bytes);
    try testing.expectEqual(@as(usize, 1), lru.count);
}

test "evict respects the caller's output buffer size" {
    var lru = Lru(8){};
    lru.touch(1, 100);
    lru.touch(2, 100);
    lru.touch(3, 100);
    var out: [1]usize = undefined;
    const n = lru.evict(0, &out);
    try testing.expectEqual(@as(usize, 1), n);
    try testing.expectEqual(@as(usize, 200), lru.total_bytes);
}

test "clear resets accounting" {
    var lru = Lru(4){};
    lru.touch(1, 100);
    lru.clear();
    try testing.expectEqual(@as(usize, 0), lru.total_bytes);
    try testing.expectEqual(@as(usize, 0), lru.count);
}
