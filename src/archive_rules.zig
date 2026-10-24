const std = @import("std");

pub const max_entries = 2048;
pub const scan_limit = std.fmt.comptimePrint("{d}", .{max_entries});
pub const max_jid = 191;
pub const max_ts = 47;

pub fn migrateLegacyKeep(state: *State, legacy: *const State, key: anytype, ts: []const u8) bool {
    if (key.provider != .whatsapp or state.find(key.id) != null) return false;
    const colon = std.mem.indexOfScalar(u8, key.id, ':') orelse return false;
    if (colon == 0) return false;
    for (legacy.entries[0..legacy.count]) |*entry| {
        if (!entry.keep or std.mem.indexOfScalar(u8, entry.jidSlice(), ':') != null) continue;
        if (std.mem.eql(u8, entry.jidSlice(), key.id[colon + 1 ..])) return state.archive(key.id, ts, true);
    }
    return false;
}

pub fn pendingHidesChat(show_archived: bool, should_unarchive: bool) bool {
    return show_archived == should_unarchive;
}

pub fn progressStatus(out: []u8, should_unarchive: bool, total: usize, remaining: usize) ?[]const u8 {
    if (total <= 1 or remaining == 0 or remaining > total) return null;
    return std.fmt.bufPrint(out, "{s} {d} of {d}", .{
        if (should_unarchive) @as([]const u8, "Unarchiving") else "Archiving",
        total - remaining + 1,
        total,
    }) catch null;
}

pub const Source = enum { shortcut, menu, control, send, kept };

pub fn logLine(out: []u8, jid: []const u8, archived: bool, source: Source) []const u8 {
    return std.fmt.bufPrint(out, "archive: jid={s} archived={} source={s}", .{ jid, archived, @tagName(source) }) catch unreachable;
}

pub const Action = enum {
    archive,
    keep,
    unarchive,

    pub fn status(self: Action) []const u8 {
        return switch (self) {
            .archive => "Archived",
            .keep => "Kept archived. Won't come back",
            .unarchive => "Chat unarchived",
        };
    }
};

pub const Entry = struct {
    provider: enum { whatsapp, slack, telegram, signal } = .whatsapp,
    account: [32]u8 = undefined,
    account_len: u8 = 0,
    jid: [max_jid]u8 = undefined,
    jid_len: u8 = 0,
    ts: [max_ts]u8 = undefined,
    ts_len: u8 = 0,
    keep: bool = false,
    held: bool = false,
    held_ts: [max_ts]u8 = undefined,
    held_ts_len: u8 = 0,

    pub fn jidSlice(self: *const Entry) []const u8 {
        return self.jid[0..self.jid_len];
    }
    pub fn tsSlice(self: *const Entry) []const u8 {
        return self.ts[0..self.ts_len];
    }
};

pub const State = struct {
    entries: [max_entries]Entry = undefined,
    count: usize = 0,

    pub fn find(self: *const State, jid: []const u8) ?usize {
        for (self.entries[0..self.count], 0..) |*entry, index| {
            if (entry.provider == .whatsapp and std.mem.eql(u8, entry.jidSlice(), jid)) return index;
        }
        return null;
    }

    pub fn localArchived(self: *const State, key: anytype) bool {
        return if (key.provider == .whatsapp) self.find(key.id) != null else if (self.findLocal(key)) |index| self.entries[index].keep else false;
    }

    pub fn isArchived(self: *const State, key: anytype, provider_archived: bool) bool {
        if (key.provider != .whatsapp) {
            if (self.findLocal(key)) |index| return self.entries[index].keep;
        }
        return self.localArchived(key) or provider_archived;
    }

    pub fn setLocalUnarchived(self: *State, key: anytype) bool {
        if (!self.setLocalArchived(key, true)) return false;
        self.entries[self.findLocal(key).?].keep = false;
        return true;
    }

    fn findLocal(self: *const State, key: anytype) ?usize {
        if (key.provider == .whatsapp) return null;
        for (self.entries[0..self.count], 0..) |*entry, index| {
            if (std.mem.eql(u8, @tagName(entry.provider), @tagName(key.provider)) and
                std.mem.eql(u8, entry.jidSlice(), key.id) and
                (std.mem.eql(u8, entry.account[0..entry.account_len], key.account) or
                    (entry.provider != .slack and entry.account_len == 0))) return index;
        }
        return null;
    }

    pub fn setLocalArchived(self: *State, key: anytype, archived: bool) bool {
        if (key.provider == .whatsapp or key.account.len > 32 or key.id.len == 0 or key.id.len > max_jid) return false;
        if (self.findLocal(key)) |index| {
            if (!archived) self.removeAt(index) else self.entries[index].keep = true;
            return true;
        }
        if (!archived) return true;
        if (self.count >= max_entries) {
            for (self.entries[0..self.count], 0..) |*entry, index| {
                if (!entry.keep) {
                    self.removeAt(index);
                    break;
                }
            }
            if (self.count >= max_entries) return false;
        }
        const entry = &self.entries[self.count];
        entry.* = .{ .provider = std.meta.stringToEnum(@FieldType(Entry, "provider"), @tagName(key.provider)).?, .keep = true };
        @memcpy(entry.account[0..key.account.len], key.account);
        entry.account_len = @intCast(key.account.len);
        @memcpy(entry.jid[0..key.id.len], key.id);
        entry.jid_len = @intCast(key.id.len);
        self.count += 1;
        return true;
    }

    pub fn isKept(self: *const State, jid: []const u8) bool {
        const index = self.find(jid) orelse return false;
        return self.entries[index].keep;
    }

    pub fn baseline(self: *const State, jid: []const u8) ?[]const u8 {
        const index = self.find(jid) orelse return null;
        const ts = self.entries[index].tsSlice();
        return if (ts.len == 0) null else ts;
    }

    pub fn holdKept(self: *State, jid: []const u8, provider_archived: bool, ts: []const u8) bool {
        if (provider_archived) return false;
        const index = self.find(jid) orelse return false;
        const entry = &self.entries[index];
        const n = @min(ts.len, max_ts);
        if (entry.held and std.mem.eql(u8, entry.held_ts[0..entry.held_ts_len], ts[0..n])) return false;
        @memcpy(entry.held_ts[0..n], ts[0..n]);
        entry.held_ts_len = @intCast(n);
        entry.held = true;
        return true;
    }

    pub fn releaseHold(self: *State, jid: []const u8) void {
        const index = self.find(jid) orelse return;
        self.entries[index].held = false;
    }

    fn slot(self: *State, jid: []const u8) ?*Entry {
        if (jid.len == 0 or jid.len > max_jid) return null;
        if (self.find(jid)) |index| return &self.entries[index];
        if (self.count >= max_entries) {
            var victim: ?usize = null;
            for (self.entries[0..self.count], 0..) |*entry, index| {
                if (!entry.keep) {
                    victim = index;
                    break;
                }
            }
            const drop = victim orelse return null;
            self.removeAt(drop);
        }
        const entry = &self.entries[self.count];
        entry.* = .{};
        @memcpy(entry.jid[0..jid.len], jid);
        entry.jid_len = @intCast(jid.len);
        self.count += 1;
        return entry;
    }

    pub fn setBaseline(self: *State, jid: []const u8, ts: []const u8) void {
        const entry = self.slot(jid) orelse return;
        const n = @min(ts.len, max_ts);
        @memcpy(entry.ts[0..n], ts[0..n]);
        entry.ts_len = @intCast(n);
    }

    pub fn archive(self: *State, jid: []const u8, ts: []const u8, keep: bool) bool {
        const entry = self.slot(jid) orelse return false;
        entry.keep = keep;
        if (ts.len > 0) self.setBaseline(jid, ts);
        return true;
    }

    pub fn setKeep(self: *State, jid: []const u8, keep: bool) void {
        if (!keep) {
            const index = self.find(jid) orelse return;
            self.entries[index].keep = false;
            return;
        }
        const entry = self.slot(jid) orelse return;
        entry.keep = true;
    }

    fn removeAt(self: *State, index: usize) void {
        var i = index + 1;
        while (i < self.count) : (i += 1) self.entries[i - 1] = self.entries[i];
        self.count -= 1;
    }

    pub fn remove(self: *State, jid: []const u8) void {
        if (self.find(jid)) |index| self.removeAt(index);
    }

    pub fn format(self: *const State, out: []u8) []const u8 {
        var len: usize = 0;
        for (self.entries[0..self.count]) |*entry| {
            const line = if (entry.provider != .whatsapp)
                std.fmt.bufPrint(out[len..], "{s}\t{s}\t{s}{s}\n", .{ @tagName(entry.provider), entry.account[0..entry.account_len], entry.jidSlice(), if (entry.keep) @as([]const u8, "") else "\t0" }) catch break
            else
                std.fmt.bufPrint(out[len..], "{s}\t{d}\t{s}\n", .{ entry.jidSlice(), @intFromBool(entry.keep), entry.tsSlice() }) catch break;
            len += line.len;
        }
        return out[0..len];
    }

    pub fn parse(self: *State, text: []const u8) void {
        self.count = 0;
        var lines = std.mem.tokenizeAny(u8, text, "\r\n");
        while (lines.next()) |line| {
            var fields = std.mem.splitScalar(u8, line, '\t');
            const jid = fields.next() orelse continue;
            if (std.mem.eql(u8, jid, "slack") or std.mem.eql(u8, jid, "telegram") or std.mem.eql(u8, jid, "signal")) {
                const account = fields.next() orelse continue;
                const id = fields.next() orelse continue;
                if (account.len > 32 or id.len == 0 or id.len > max_jid or self.count >= max_entries) continue;
                const entry = &self.entries[self.count];
                entry.* = .{ .provider = std.meta.stringToEnum(@FieldType(Entry, "provider"), jid).?, .keep = !std.mem.eql(u8, fields.next() orelse "1", "0") };
                @memcpy(entry.account[0..account.len], account);
                entry.account_len = @intCast(account.len);
                @memcpy(entry.jid[0..id.len], id);
                entry.jid_len = @intCast(id.len);
                self.count += 1;
                continue;
            }
            const keep = fields.next() orelse continue;
            const ts = fields.next() orelse "";
            const entry = self.slot(jid) orelse continue;
            entry.keep = std.mem.eql(u8, keep, "1");
            const n = @min(ts.len, max_ts);
            @memcpy(entry.ts[0..n], ts[0..n]);
            entry.ts_len = @intCast(n);
            if (std.mem.startsWith(u8, jid, "telegram:") or std.mem.startsWith(u8, jid, "signal:")) {
                entry.provider = if (std.mem.startsWith(u8, jid, "telegram:")) .telegram else .signal;
                entry.keep = true;
            }
        }
    }
};

pub const stamp_len = 20;

pub fn archiveBaseline(out: *[stamp_len]u8, row_ts: []const u8, now_seconds: i64) []const u8 {
    const epoch = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, now_seconds)) };
    const year_day = epoch.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch.getDaySeconds();
    const now = std.fmt.bufPrint(out, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch return row_ts;
    return if (std.mem.order(u8, row_ts, now) == .gt) row_ts else now;
}

pub fn Selection(comptime capacity: usize) type {
    return struct {
        const Self = @This();
        jids: [capacity][max_jid]u8 = undefined,
        lens: [capacity]u8 = [_]u8{0} ** capacity,
        providers: [capacity]u8 = @splat(0),
        accounts: [capacity][32]u8 = undefined,
        account_lens: [capacity]u8 = @splat(0),
        count: usize = 0,

        pub fn clear(self: *Self) void {
            self.count = 0;
        }

        pub fn addKey(self: *Self, key: anytype) void {
            if (key.id.len == 0 or key.id.len > max_jid or self.count >= capacity) return;
            self.providers[self.count] = @intFromEnum(key.provider);
            const account_len = @min(key.account.len, 32);
            @memcpy(self.accounts[self.count][0..account_len], key.account[0..account_len]);
            self.account_lens[self.count] = @intCast(account_len);
            @memcpy(self.jids[self.count][0..key.id.len], key.id);
            self.lens[self.count] = @intCast(key.id.len);
            self.count += 1;
        }

        pub fn atKey(self: *const Self, comptime Key: type, index: usize) Key {
            return .{ .provider = @enumFromInt(self.providers[index]), .account = self.accounts[index][0..self.account_lens[index]], .id = self.at(index) };
        }

        pub fn containsKey(self: *const Self, key: anytype) bool {
            const Key = @TypeOf(key);
            for (0..self.count) |index| if (Key.eql(self.atKey(Key, index), key)) return true;
            return false;
        }

        pub fn add(self: *Self, jid: []const u8) void {
            if (jid.len == 0 or jid.len > max_jid or self.count >= capacity) return;
            self.providers[self.count] = 0;
            self.account_lens[self.count] = 0;
            @memcpy(self.jids[self.count][0..jid.len], jid);
            self.lens[self.count] = @intCast(jid.len);
            self.count += 1;
        }

        pub fn at(self: *const Self, index: usize) []const u8 {
            return self.jids[index][0..self.lens[index]];
        }

        pub fn contains(self: *const Self, jid: []const u8) bool {
            var index: usize = 0;
            while (index < self.count) : (index += 1) {
                if (std.mem.eql(u8, self.at(index), jid)) return true;
            }
            return false;
        }
    };
}

pub fn paneNeedsSwitch(open_jid: []const u8, selected_jid: ?[]const u8) bool {
    const now = selected_jid orelse return true;
    return !std.mem.eql(u8, open_jid, now);
}

test "legacy keep migration matches only bare WhatsApp ids and uses the hub message baseline" {
    const Key = struct { provider: enum { whatsapp, slack, signal, telegram }, account: []const u8, id: []const u8 };
    var legacy = State{};
    legacy.parse("120363000000000001@g.us\t1\t2026-10-10T10:00:00Z\nplain@g.us\t0\told\npersonal:prefixed@g.us\t1\told\n");
    var state = State{};
    const key = Key{ .provider = .whatsapp, .account = "hub-cache", .id = "personal:120363000000000001@g.us" };
    try std.testing.expect(migrateLegacyKeep(&state, &legacy, key, "2026-10-10T11:00:00Z"));
    try std.testing.expect(state.isKept(key.id));
    try std.testing.expectEqualStrings("2026-10-10T11:00:00Z", state.baseline(key.id).?);
    for ([_]Key{
        .{ .provider = .whatsapp, .account = "hub-cache", .id = "personal:plain@g.us" },
        .{ .provider = .whatsapp, .account = "hub-cache", .id = "personal:prefixed@g.us" },
        .{ .provider = .whatsapp, .account = "hub-cache", .id = "personal:unknown@g.us" },
        .{ .provider = .whatsapp, .account = "hub-cache", .id = "120363000000000001@g.us" },
        .{ .provider = .whatsapp, .account = "hub-cache", .id = ":120363000000000001@g.us" },
        .{ .provider = .slack, .account = "hub-cache", .id = "other:120363000000000001@g.us" },
        .{ .provider = .signal, .account = "hub-cache", .id = "other:120363000000000001@g.us" },
        .{ .provider = .telegram, .account = "hub-cache", .id = "other:120363000000000001@g.us" },
    }) |other| try std.testing.expect(!migrateLegacyKeep(&state, &legacy, other, "new"));
    try std.testing.expectEqual(@as(usize, 1), state.count);
    try std.testing.expectEqual(@as(usize, 3), legacy.count);
    try std.testing.expectEqualStrings("2026-10-10T10:00:00Z", legacy.baseline("120363000000000001@g.us").?);
}

test "legacy migration preserves existing hub choices and scopes matches to each account handle" {
    const Key = struct { provider: enum { whatsapp }, account: []const u8, id: []const u8 };
    var legacy = State{};
    try std.testing.expect(legacy.archive("120363000000000001@g.us", "old", true));
    var state = State{};
    const first = Key{ .provider = .whatsapp, .account = "hub-cache", .id = "personal:120363000000000001@g.us" };
    const second = Key{ .provider = .whatsapp, .account = "hub-cache", .id = "business:120363000000000001@g.us" };
    try std.testing.expect(state.archive(first.id, "hub-choice", false));
    try std.testing.expect(!migrateLegacyKeep(&state, &legacy, first, "new"));
    try std.testing.expect(!state.isKept(first.id));
    try std.testing.expectEqualStrings("hub-choice", state.baseline(first.id).?);
    try std.testing.expect(migrateLegacyKeep(&state, &legacy, second, "new"));
    try std.testing.expect(state.isKept(second.id));
    try std.testing.expect(!migrateLegacyKeep(&state, &legacy, second, "newer"));
    try std.testing.expectEqualStrings("new", state.baseline(second.id).?);
    var buffer: [512]u8 = undefined;
    var loaded = State{};
    loaded.parse(state.format(&buffer));
    try std.testing.expect(!migrateLegacyKeep(&loaded, &legacy, first, "newer"));
    try std.testing.expect(!loaded.isKept(first.id));
    try std.testing.expect(loaded.holdKept(second.id, false, "newer"));
    loaded.setKeep(second.id, false);
    try std.testing.expect(!migrateLegacyKeep(&loaded, &legacy, second, "newest"));
    try std.testing.expect(loaded.holdKept(second.id, false, "newest"));
}

test "the baseline is the later of the list row time and the archive moment" {
    var buffer: [stamp_len]u8 = undefined;
    const moment: i64 = 1792775400;
    try std.testing.expectEqualStrings("2026-10-23T17:10:00Z", archiveBaseline(&buffer, "2026-10-23T16:43:39Z", moment));
    try std.testing.expectEqualStrings("2026-10-23T17:10:00Z", archiveBaseline(&buffer, "", moment));
    try std.testing.expectEqualStrings("2026-10-23T18:00:00Z", archiveBaseline(&buffer, "2026-10-23T18:00:00Z", moment));
}

test "state keeps, forgets and round-trips through text" {
    var state = State{};
    state.setBaseline("a@g.us", "2026-10-10T10:00:00Z");
    state.setKeep("b@s.whatsapp.net", true);
    state.setBaseline("b@s.whatsapp.net", "2026-10-10T11:00:00Z");
    try std.testing.expect(state.isKept("b@s.whatsapp.net"));
    try std.testing.expect(!state.isKept("a@g.us"));
    try std.testing.expectEqualStrings("2026-10-10T10:00:00Z", state.baseline("a@g.us").?);

    var buffer: [512]u8 = undefined;
    const text = state.format(&buffer);
    var loaded = State{};
    loaded.parse(text);
    try std.testing.expectEqual(@as(usize, 2), loaded.count);
    try std.testing.expect(loaded.isKept("b@s.whatsapp.net"));
    try std.testing.expectEqualStrings("2026-10-10T11:00:00Z", loaded.baseline("b@s.whatsapp.net").?);

    loaded.setKeep("b@s.whatsapp.net", false);
    try std.testing.expect(!loaded.isKept("b@s.whatsapp.net"));
    loaded.remove("a@g.us");
    try std.testing.expect(loaded.baseline("a@g.us") == null);
}

test "all user archives the provider unarchives are held once per new message" {
    var state = State{};
    try std.testing.expect(state.archive("kept@g.us", "2026-10-10T10:00:00Z", true));
    try std.testing.expect(state.archive("plain@g.us", "2026-10-10T10:00:00Z", false));
    try std.testing.expect(!state.holdKept("kept@g.us", true, "2026-10-10T11:00:00Z"));
    try std.testing.expect(state.holdKept("kept@g.us", false, "2026-10-10T11:00:00Z"));
    try std.testing.expect(!state.holdKept("kept@g.us", false, "2026-10-10T11:00:00Z"));
    try std.testing.expect(state.holdKept("kept@g.us", false, "2026-10-10T12:00:00Z"));
    try std.testing.expect(state.holdKept("plain@g.us", false, "2026-10-10T12:00:00Z"));
    try std.testing.expect(!state.holdKept("plain@g.us", false, "2026-10-10T12:00:00Z"));
    try std.testing.expect(state.holdKept("plain@g.us", false, "2026-10-10T13:00:00Z"));
    try std.testing.expect(!state.holdKept("other@g.us", false, "2026-10-10T12:00:00Z"));
    state.releaseHold("kept@g.us");
    try std.testing.expect(state.holdKept("kept@g.us", false, "2026-10-10T12:00:00Z"));
    var buffer: [512]u8 = undefined;
    var loaded = State{};
    loaded.parse(state.format(&buffer));
    try std.testing.expect(loaded.holdKept("kept@g.us", false, "2026-10-10T12:00:00Z"));
    loaded.remove("kept@g.us");
    try std.testing.expect(!loaded.holdKept("kept@g.us", false, "2026-10-10T13:00:00Z"));
}

test "a full table drops unkept entries first" {
    var state = State{};
    state.setKeep("keep@g.us", true);
    var i: usize = 0;
    var name: [16]u8 = undefined;
    while (i < max_entries + 5) : (i += 1) {
        const jid = std.fmt.bufPrint(&name, "{d}@g.us", .{i}) catch unreachable;
        state.setBaseline(jid, "2026-10-10T10:00:00Z");
    }
    try std.testing.expectEqual(@as(usize, max_entries), state.count);
    try std.testing.expect(state.isKept("keep@g.us"));
}

test "an archived chat keeps its baseline while hundreds of other archived chats are seen" {
    var state = State{};
    try std.testing.expect(state.archive("a@s.whatsapp.net", "2026-10-10T10:00:00Z", false));
    var i: usize = 0;
    var name: [24]u8 = undefined;
    while (i < 430) : (i += 1) {
        const jid = std.fmt.bufPrint(&name, "{d}@s.whatsapp.net", .{i}) catch unreachable;
        state.setBaseline(jid, "0001-01-01T00:00:00Z");
    }
    const base = state.baseline("a@s.whatsapp.net") orelse return error.BaselineLost;
    try std.testing.expectEqualStrings("2026-10-10T10:00:00Z", base);
}

test "select-all snapshot holds exactly the rows shown" {
    var selection = Selection(4){};
    selection.add("a@g.us");
    selection.add("b@s.whatsapp.net");
    try std.testing.expect(selection.contains("a@g.us"));
    try std.testing.expect(!selection.contains("c@g.us"));
    try std.testing.expectEqual(@as(usize, 2), selection.count);
    selection.clear();
    try std.testing.expect(!selection.contains("a@g.us"));
}

test "the pane switches when the open chat left the list" {
    try std.testing.expect(paneNeedsSwitch("a@g.us", "b@g.us"));
    try std.testing.expect(paneNeedsSwitch("a@g.us", null));
    try std.testing.expect(!paneNeedsSwitch("a@g.us", "a@g.us"));
}

test "a full kept table refuses a new archive without changing existing state" {
    var state = State{};
    var name: [16]u8 = undefined;
    for (0..max_entries) |i| {
        const jid = try std.fmt.bufPrint(&name, "{d}@g.us", .{i});
        try std.testing.expect(state.archive(jid, "baseline", true));
    }
    try std.testing.expect(!state.archive("overflow@g.us", "baseline", true));
    try std.testing.expectEqual(@as(usize, max_entries), state.count);
    try std.testing.expect(state.isKept("0@g.us"));
    try std.testing.expect(state.archive("0@g.us", "new-baseline", true));
    try std.testing.expectEqualStrings("new-baseline", state.baseline("0@g.us").?);
}

test "plain archive explicitly replaces the legacy keep flag" {
    var state = State{};
    const jid = "a@g.us";
    try std.testing.expect(state.archive(jid, "2026-10-10T10:00:00Z", true));
    try std.testing.expect(state.archive(jid, "2026-10-10T11:00:00Z", false));
    try std.testing.expect(!state.isKept(jid));
}

test "pending operations hide chats only in the view they are leaving" {
    try std.testing.expect(pendingHidesChat(false, false));
    try std.testing.expect(!pendingHidesChat(true, false));
    try std.testing.expect(pendingHidesChat(true, true));
    try std.testing.expect(!pendingHidesChat(false, true));
}

test "batch progress includes the current operation through the last item" {
    var out: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Archiving 1 of 250", progressStatus(&out, false, 250, 250).?);
    try std.testing.expectEqualStrings("Archiving 12 of 250", progressStatus(&out, false, 250, 239).?);
    try std.testing.expectEqualStrings("Archiving 250 of 250", progressStatus(&out, false, 250, 1).?);
    try std.testing.expectEqualStrings("Unarchiving 2 of 3", progressStatus(&out, true, 3, 2).?);
    try std.testing.expect(progressStatus(&out, false, 250, 0) == null);
    try std.testing.expect(progressStatus(&out, false, 1, 1) == null);
    try std.testing.expect(progressStatus(&out, false, 0, 0) == null);
    try std.testing.expect(progressStatus(&out, false, 2, 3) == null);
    try std.testing.expect(progressStatus(out[0..1], false, 250, 239) == null);
}

test "archive status is Archived" {
    try std.testing.expectEqualStrings("Archived", Action.archive.status());
}

test "local Slack Telegram and Signal archives round trip with provider and account identity" {
    const Key = struct { provider: enum { whatsapp, slack, telegram, signal }, account: []const u8, id: []const u8 };
    for ([_]Key{
        .{ .provider = .slack, .account = "team", .id = "shared" },
        .{ .provider = .telegram, .account = "telegram", .id = "telegram:user:7001" },
        .{ .provider = .signal, .account = "signal", .id = "signal:fixture" },
    }) |key| {
        var state = State{};
        try std.testing.expect(state.setLocalArchived(key, true));
        try std.testing.expect(state.localArchived(key));
        try std.testing.expect(!state.localArchived(Key{ .provider = key.provider, .account = "other", .id = key.id }));
        try std.testing.expect(!state.localArchived(Key{ .provider = .whatsapp, .account = key.account, .id = key.id }));
        var buffer: [512]u8 = undefined;
        var loaded = State{};
        loaded.parse(state.format(&buffer));
        try std.testing.expect(loaded.localArchived(key));
        try std.testing.expectEqual(@as(usize, 1), loaded.count);
        try std.testing.expect(!loaded.holdKept(key.id, false, "new message"));
        try std.testing.expect(loaded.localArchived(key));
        try std.testing.expect(loaded.setLocalArchived(key, false));
        try std.testing.expect(!loaded.localArchived(key));
        state.parse(loaded.format(&buffer));
        try std.testing.expect(!state.localArchived(key));
    }
}

test "old plain Telegram and Signal archives become local regardless of keep or timestamp" {
    const Key = struct { provider: enum { whatsapp, slack, telegram, signal }, account: []const u8, id: []const u8 };
    for ([_]Key{
        .{ .provider = .telegram, .account = "telegram", .id = "telegram:user:7001" },
        .{ .provider = .signal, .account = "signal", .id = "signal:fixture" },
    }) |key| {
        for ([_]bool{ false, true }) |keep| {
            var text: [512]u8 = undefined;
            var state = State{};
            state.parse(try std.fmt.bufPrint(&text, "{s}\t{d}\told\n", .{ key.id, @intFromBool(keep) }));
            try std.testing.expect(state.localArchived(key));
            try std.testing.expect(state.find(key.id) == null);
            try std.testing.expect(!state.holdKept(key.id, false, "newer"));
            var buffer: [512]u8 = undefined;
            var loaded = State{};
            loaded.parse(state.format(&buffer));
            try std.testing.expect(loaded.localArchived(key));
            try std.testing.expect(loaded.setLocalArchived(key, false));
            try std.testing.expect(!loaded.localArchived(key));
            state.parse(loaded.format(&buffer));
            try std.testing.expect(!state.localArchived(key));
        }
    }
}

test "explicit local unarchive overrides phone archived state after restart without affecting another account" {
    const Key = struct { provider: enum { whatsapp, slack, telegram, signal }, account: []const u8, id: []const u8 };
    for ([_]Key{
        .{ .provider = .telegram, .account = "telegram", .id = "telegram:user:7001" },
        .{ .provider = .signal, .account = "signal", .id = "signal:fixture" },
        .{ .provider = .slack, .account = "workspace", .id = "channel" },
    }) |key| {
        var state = State{};
        try std.testing.expect(state.isArchived(key, true));
        try std.testing.expect(state.setLocalUnarchived(key));
        try std.testing.expect(!state.isArchived(key, true));
        try std.testing.expect(!state.localArchived(key));
        var buffer: [512]u8 = undefined;
        var loaded = State{};
        loaded.parse(state.format(&buffer));
        try std.testing.expect(!loaded.isArchived(key, true));
        var other = key;
        other.account = "other";
        try std.testing.expect(loaded.isArchived(other, true));
        try std.testing.expect(loaded.setLocalArchived(key, true));
        try std.testing.expect(loaded.isArchived(key, false));
    }
}
