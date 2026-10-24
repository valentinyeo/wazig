const std = @import("std");
const chat_key = @import("chat_key.zig");
const read_state = @import("read_state.zig");
const media_age = @import("media_age.zig");
const max_pending_reads = 8;

fn Utf8Text(comptime capacity: usize) type {
    return struct {
        data: [capacity]u8 = undefined,
        len: usize = 0,
        fn set(self: *@This(), text: []const u8) void {
            self.len = @min(text.len, capacity);
            @memcpy(self.data[0..self.len], text[0..self.len]);
        }
        pub fn slice(self: *const @This()) []const u8 {
            return self.data[0..self.len];
        }
    };
}
const Provider = enum { whatsapp, slack, telegram };
const Chat = struct {
    account: Utf8Text(32) = .{},
    provider: Provider = .whatsapp,
    jid: Utf8Text(191) = .{},
    timestamp: Utf8Text(47) = .{},
    unread: bool = false,
    unread_count: i64 = 0,
    provider_unread: bool = true,
};
const Message = struct {
    timestamp: Utf8Text(47) = .{},
    send_state: enum { none, pending, failed } = .none,
};
const WacliJobKind = enum { unread_probe };
const WacliJob = struct {
    provider: Provider = .whatsapp,
    account: Utf8Text(32) = .{},
    kind: WacliJobKind,
    jid: Utf8Text(191) = .{},
    extra: Utf8Text(63) = .{},
    msg_id: Utf8Text(191) = .{},
};
const WacliResult = struct {
    provider: Provider = .whatsapp,
    account: Utf8Text(32) = .{},
    ok: bool = true,
    jid: Utf8Text(191) = .{},
    extra: Utf8Text(63) = .{},
    msg_id: Utf8Text(191) = .{},
    data: []const u8,
};
const App = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    io: void = {},
    read_child: ?child_process.Child = null,
    send_child: ?u8 = null,
    archive_child: ?u8 = null,
    pending_archive_count: usize = 0,
    read_backoff_until: [max_pending_reads]u64 = [_]u64{0} ** max_pending_reads,
    read_spawn_failures: u32 = 0,
    read_started_ms: u64 = 0,
    read_state: read_state.State = .{},
    cache_tag: Utf8Text(32) = .{},
    startup_probe_pending: bool = false,
    chats: [2]Chat = .{ .{}, .{} },
    chat_count: usize = 1,
    selected_chat: usize = 0,
    user_viewed: bool = true,
    read_queue_dead: bool = false,
    displayed_provider: @TypeOf((Chat{}).provider) = .whatsapp,
    displayed_account: Utf8Text(32) = .{},
    displayed_jid: Utf8Text(191) = .{},
    messages: [2]Message = .{ .{}, .{} },
    message_count: usize = 1,
    pending_reads: [max_pending_reads]Utf8Text(191) = [_]Utf8Text(191){.{}} ** max_pending_reads,
    read_retries: [max_pending_reads]u8 = [_]u8{0} ** max_pending_reads,
    pending_read_count: usize = 0,
    chats_hwnd: ?usize = null,
    unread_only: bool = false,
    include_archived: bool = false,
    chat_view: enum { all, whatsapp } = .whatsapp,
    wacli_path: []const u8 = "wacli.exe",
    pending: u32 = 0,
    queued: u32 = 0,
    last_job: WacliJob = .{ .kind = .unread_probe },
    persisted: u32 = 0,
    refreshed: u32 = 0,
};
const win = struct {
    const TRUE = 1;
    const FALSE = 0;
    const LB_GETITEMRECT = 0x198;
    const LB_ERR = -1;
    const RECT = struct { left: i32, top: i32, right: i32, bottom: i32 };
    var row_paints: usize = 0;
    var last_row: usize = 0;
    fn SendMessageW(_: usize, message: u32, index: usize, data: isize) isize {
        std.debug.assert(message == LB_GETITEMRECT);
        last_row = index;
        const row: *RECT = @ptrFromInt(@as(usize, @bitCast(data)));
        row.* = .{ .left = 0, .top = @intCast(index * 64), .right = 380, .bottom = @intCast((index + 1) * 64) };
        return 0;
    }
    fn GetTickCount64() u64 {
        return 100_000;
    }
    fn InvalidateRect(_: usize, rect: ?*const RECT, erase: i32) i32 {
        std.debug.assert(rect != null and erase == FALSE);
        row_paints += 1;
        return 1;
    }
};
fn persistReadState(a: *App) void {
    if (a.read_state.dirty) a.persisted += 1;
    a.read_state.dirty = false;
}
fn persistPendingReads(_: *App) void {}
const child_process = struct {
    const Child = struct {};
    const SpawnOptions = struct {
        argv: []const []const u8,
        stdin: enum { ignore },
        stdout: enum { ignore },
        stderr: enum { ignore },
        create_no_window: bool,
    };
    var sync_stopped = false;
    var correct_args = false;
    fn spawn(_: void, options: SpawnOptions) !Child {
        std.debug.assert(sync_stopped);
        const args = options.argv;
        correct_args = args.len == 8 and std.mem.eql(u8, args[2], "--lock-wait") and
            std.mem.eql(u8, args[3], "70s") and std.mem.eql(u8, args[5], "mark-read") and
            std.mem.eql(u8, args[6], "--chat");
        std.debug.assert(correct_args);
        return .{};
    }
};
fn stopSync(_: *App, _: []const u8) void {
    child_process.sync_stopped = true;
}
fn startSync(_: *App) void {}
fn sendReadyPending(_: *App) bool {
    return false;
}
fn avatarBusy(_: *App) bool {
    return false;
}
fn mediaBusy(_: *App) bool {
    return false;
}
fn setStatus(_: *App, _: []const u8) void {}
fn refreshChats(a: *App) void {
    a.refreshed += 1;
}
fn wacliPendingGet(a: *App, _: WacliJobKind) u32 {
    return a.pending;
}
fn wacliJobArgs(_: *WacliJob, args: []const []const u8) void {
    std.debug.assert(std.mem.eql(u8, args[2], "--read-only"));
    std.debug.assert(std.mem.eql(u8, args[7], "--from-them"));
    std.debug.assert(std.mem.eql(u8, args[9], "1"));
}
fn wacliEnqueue(a: *App, job: WacliJob, _: bool) void {
    a.last_job = job;
    a.pending += 1;
    a.queued += 1;
}
fn fixture() App {
    win.row_paints = 0;
    child_process.sync_stopped = false;
    child_process.correct_args = false;
    var a: App = .{};
    a.cache_tag.set("0123456789abcdef");
    a.chats[0].jid.set("test@g.us");
    a.chats[0].timestamp.set("2026-10-16T12:00:00Z");
    a.messages[0].timestamp = a.chats[0].timestamp;
    a.displayed_jid = a.chats[0].jid;
    return a;
}
fn incomingResult(a: *App) WacliResult {
    return .{ .jid = a.last_job.jid, .extra = a.last_job.extra, .msg_id = a.last_job.msg_id, .data = "{\"data\":{\"messages\":[{\"Timestamp\":\"2026-10-16T12:00:01Z\",\"FromMe\":false}]}}" };
}

test "view persists its actual message boundary even with a full or dead receipt queue" {
    var a = fixture();
    defer a.read_state.deinit(a.allocator);
    a.pending_read_count = max_pending_reads;
    markChatRead(&a);
    try std.testing.expectEqual(@as(u32, 1), a.persisted);
    try std.testing.expect(!a.read_state.needsProbe(a.cache_tag.slice(), a.chats[0].jid.slice(), media_age.unixSeconds(a.chats[0].timestamp.slice()).?, true));
    a.pending_read_count = 0;
    markChatRead(&a);
    try std.testing.expectEqual(@as(usize, 1), a.pending_read_count);
    a.read_queue_dead = true;
    a.messages[0].timestamp.set("2026-10-16T12:00:01Z");
    markChatRead(&a);
    try std.testing.expectEqual(@as(u32, 2), a.persisted);
}

test "a new incoming dot is not hidden by an older pending read, and probes coalesce" {
    var a = fixture();
    defer a.read_state.deinit(a.allocator);
    markChatRead(&a);
    a.chats[0].timestamp.set("2026-10-16T12:00:01Z");
    queueUnreadProbe(&a, &a.chats[0]);
    queueUnreadProbe(&a, &a.chats[0]);
    try std.testing.expectEqual(@as(u32, 1), a.queued);
    const result = incomingResult(&a);
    a.pending = 0;
    applyUnreadProbe(&a, &result);
    try std.testing.expect(a.chats[0].unread);
    try std.testing.expectEqual(@as(usize, 1), a.pending_read_count);
    try std.testing.expectEqual(@as(u32, 1), a.queued);
}

test "startup and stale account probes cannot change another account's dots" {
    var a = fixture();
    defer a.read_state.deinit(a.allocator);
    a.startup_probe_pending = true;
    queueUnreadProbe(&a, &a.chats[0]);
    try std.testing.expectEqual(@as(u32, 0), a.queued);
    a.startup_probe_pending = false;
    queueUnreadProbe(&a, &a.chats[0]);
    const result = incomingResult(&a);
    a.cache_tag.set("fedcba9876543210");
    a.pending = 0;
    applyUnreadProbe(&a, &result);
    try std.testing.expect(!a.chats[0].unread);
    try std.testing.expectEqual(@as(u32, 1), a.queued);
}

test "unviewed or mismatched content cannot advance the selected chat watermark" {
    var a = fixture();
    defer a.read_state.deinit(a.allocator);
    a.user_viewed = false;
    markChatRead(&a);
    a.user_viewed = true;
    a.displayed_jid.set("other@g.us");
    markChatRead(&a);
    try std.testing.expectEqual(@as(u32, 0), a.persisted);
}

test "mark-read uses wacli 0.18.1 arguments only after pausing sync" {
    var a = fixture();
    defer a.read_state.deinit(a.allocator);
    markChatRead(&a);
    try std.testing.expect(child_process.sync_stopped);
    try std.testing.expect(child_process.correct_args);
    try std.testing.expect(a.read_child != null);
}

test "marking an already read chat leaves the list alone while a changed dot dirties only its row" {
    var a = fixture();
    defer a.read_state.deinit(a.allocator);
    a.chats_hwnd = 1;
    markChatRead(&a);
    try std.testing.expectEqual(@as(usize, 0), win.row_paints);
    a.chats[0].unread = true;
    a.chats[0].unread_count = 1;
    markChatRead(&a);
    try std.testing.expectEqual(@as(usize, 1), win.row_paints);
    try std.testing.expectEqual(@as(usize, 0), win.last_row);
    markChatRead(&a);
    try std.testing.expectEqual(@as(usize, 1), win.row_paints);
}
