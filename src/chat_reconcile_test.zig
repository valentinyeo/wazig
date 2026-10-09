//! Host harness for the actual UI read/retry handlers extracted by build.zig.
//! Windows painting, disk I/O and the queue are stubbed; decisions, JSON
//! validation and result generation guards are production code.
const std = @import("std");
const chat_reconcile = @import("chat_reconcile");

fn Utf8Text(comptime capacity: usize) type {
    return struct {
        data: [capacity]u8 = undefined,
        len: usize = 0,
        fn set(self: *@This(), text: []const u8) void {
            self.len = @min(text.len, capacity);
            @memcpy(self.data[0..self.len], text[0..self.len]);
        }
        fn slice(self: *const @This()) []const u8 {
            return self.data[0..self.len];
        }
    };
}
const Provider = enum { whatsapp, slack, telegram };
const Chat = struct {
    jid: Utf8Text(191) = .{},
    timestamp: Utf8Text(47) = .{},
    provider: Provider = .whatsapp,
};
const WacliJobKind = enum { messages, chats };
const WacliJob = struct {
    kind: WacliJobKind = .messages,
    gen: u64 = 0,
    jid: Utf8Text(191) = .{},
    msg_id: Utf8Text(191) = .{},
    extra: Utf8Text(63) = .{},
    started_ms: u64 = 0,
};
const WacliResult = struct {
    kind: WacliJobKind = .messages,
    gen: u64 = 0,
    jid: Utf8Text(191) = .{},
    msg_id: Utf8Text(191) = .{},
    extra: Utf8Text(63) = .{},
    started_ms: u64 = 0,
    ok: bool = true,
    data: []const u8 = "{\"data\":{\"messages\":[]}}",
};
const App = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    chats: [2]Chat = .{ .{}, .{} },
    chat_count: usize = 1,
    selected_chat: usize = 0,
    user_viewed: bool = true,
    chat_selection_pending: bool = false,
    displayed_jid: Utf8Text(191) = .{},
    displayed_timestamp: Utf8Text(47) = .{},
    messages_gen: u64 = 0,
    chats_gen: u64 = 1,
    chats_read_attempts: u32 = 0,
    chats_read_retry_ticks: u32 = 0,
    slack_history_hash: u64 = 0,
    msg_read_last_jid: Utf8Text(191) = .{},
    msg_read_attempts: u32 = 0,
    msg_read_retry_ticks: u32 = 0,
    wacli_path: []const u8 = "wacli.exe",
    pending: u32 = 0,
    queued: u32 = 0,
    last_job: WacliJob = .{},
    painted: u32 = 0,
    cached: u32 = 0,
};
fn fixture() App {
    var a = App{};
    a.chats[0].jid.set("a@g.us");
    a.chats[0].timestamp.set("2026-09-06T13:30:00");
    a.displayed_jid = a.chats[0].jid;
    a.displayed_timestamp = a.chats[0].timestamp;
    return a;
}
fn clearMessages(_: *App) void {}
fn cancelSlackMark(_: *App) void {}
fn stopAudio(_: *App) void {}
fn refreshTelegramMessages(_: *App) void {}
fn refreshSlackHistory(_: *App) void {}
fn msgCacheGet(_: *App, _: []const u8) ?[]const u8 {
    return null;
}
fn loadMsgCacheDisk(_: *App, _: []const u8) ?[]u8 {
    return null;
}
fn wacliPendingGet(a: *App, _: WacliJobKind) u32 {
    return a.pending;
}
fn wacliJobArgs(_: *WacliJob, _: []const []const u8) void {}
fn wacliEnqueue(a: *App, job: WacliJob, _: bool) void {
    a.pending += 1;
    a.queued += 1;
    a.last_job = job;
}
fn msgCacheStore(a: *App, _: []const u8, _: []const u8) void {
    a.cached += 1;
}
fn applyChats(a: *App, raw: []const u8) bool {
    // Only chat-list painting is stubbed: supply the fresh row's stamp.
    a.chats[0].timestamp.set(raw);
    return true;
}
fn saveChatsCache(_: *App, _: []const u8) void {}
fn setStatus(_: *App, _: []const u8) void {}
fn appendLaunchLog(_: *App, _: []const u8) void {}

// Generated below: refreshMessages, reconcileOpenChat, scheduleMessageReadRetry,
// the worker's job-to-result copy, the chats/messages result handlers, and the JSON
// validation/stamp portions of applyMessageData. The latter's rendering body
// alone is replaced, so the host never calls Windows APIs.

test "fresh sidebar row triggers one generation-guarded read" {
    var a = fixture();
    const chats = WacliResult{ .kind = .chats, .gen = a.chats_gen, .data = "2026-09-06T13:34:39" };
    deliverChats(&a, &chats);
    deliverChats(&a, &chats);
    try std.testing.expectEqual(@as(u32, 1), a.queued);
    try std.testing.expectEqual(@as(u64, 1), a.last_job.gen);
}

test "failed and malformed reads retry but a valid empty conversation succeeds" {
    var a = fixture();
    refreshMessages(&a);
    var result = resultFor(a.last_job);
    result.ok = false;
    deliver(&a, &result);
    try std.testing.expectEqual(@as(u32, 2), a.msg_read_retry_ticks);
    tick(&a);
    try std.testing.expectEqual(@as(u32, 1), a.queued);
    tick(&a);
    try std.testing.expectEqual(@as(u32, 2), a.queued);
    result = resultFor(a.last_job);
    result.data = "{\"data\":{}}";
    deliver(&a, &result);
    try std.testing.expectEqual(@as(u32, 4), a.msg_read_retry_ticks);
    try std.testing.expectEqual(@as(u32, 0), a.cached);
    for (0..4) |_| tick(&a);
    result = resultFor(a.last_job);
    deliver(&a, &result);
    try std.testing.expectEqual(@as(u32, 0), a.msg_read_attempts);
    try std.testing.expectEqual(@as(u32, 0), a.msg_read_retry_ticks);
    try std.testing.expectEqual(@as(u32, 1), a.cached);
}

test "retry budget stops after two retries" {
    var a = fixture();
    refreshMessages(&a);
    for (0..3) |_| {
        var result = resultFor(a.last_job);
        result.ok = false;
        deliver(&a, &result);
        for (0..4) |_| tick(&a);
    }
    try std.testing.expectEqual(@as(u32, 3), a.queued);
    try std.testing.expectEqual(@as(u32, 0), a.msg_read_retry_ticks);
}

test "leaving WhatsApp or clearing selection resets a spent budget" {
    inline for (.{ Provider.slack, Provider.telegram }) |provider| {
        var a = fixture();
        refreshMessages(&a);
        a.pending = 0;
        a.msg_read_attempts = 2;
        a.chats[0].provider = provider;
        refreshMessages(&a);
        a.chats[0].provider = .whatsapp;
        refreshMessages(&a);
        var result = resultFor(a.last_job);
        result.ok = false;
        deliver(&a, &result);
        try std.testing.expectEqual(@as(u32, 2), a.msg_read_retry_ticks);
    }
    var a = fixture();
    refreshMessages(&a);
    a.msg_read_attempts = 2;
    a.chat_count = 0;
    refreshMessages(&a);
    try std.testing.expectEqual(@as(u32, 0), a.msg_read_attempts);
}

test "stale success and failure never paint, cache or consume retry budget" {
    var a = fixture();
    refreshMessages(&a);
    var old = resultFor(a.last_job);
    a.chats[1].jid.set("b@g.us");
    a.chat_count = 2;
    a.selected_chat = 1;
    refreshMessages(&a);
    deliver(&a, &old);
    try std.testing.expectEqual(@as(u32, 0), a.painted);
    try std.testing.expectEqual(@as(u32, 0), a.cached);
    // A stale same-chat generation is rejected as well.
    a.selected_chat = 0;
    refreshMessages(&a);
    old.ok = false;
    deliver(&a, &old);
    try std.testing.expectEqual(@as(u32, 0), a.msg_read_attempts);
}

test "reconciliation respects provider, selection and user-view guards" {
    var a = fixture();
    a.chats[0].timestamp.set("2026-09-06T13:34:39");
    a.user_viewed = false;
    reconcileOpenChat(&a);
    a.user_viewed = true;
    a.chat_selection_pending = true;
    reconcileOpenChat(&a);
    a.chat_selection_pending = false;
    a.chats[0].provider = .slack;
    reconcileOpenChat(&a);
    try std.testing.expectEqual(@as(u32, 0), a.queued);
}
