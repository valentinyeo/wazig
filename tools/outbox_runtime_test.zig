//! Boundary fixture for test_outbox_runtime.py, not a second implementation.
const std = @import("std");
const outbox = @import("outbox.zig");
const Utf8Text = outbox.Str;
const max_pending_sends = 32;
const max_messages = 3;
const max_send_retries = 4;
const file_send_placeholder = "Sending file...";
const max_slack_outbox = 16;
const max_wacli_args = 4;
const wacli_arg_cap = 4095;
const wacli_queue_size = 4;
const WacliJobKind = enum(u8) { chats, groups, messages, reaction, slack_workspace, slack_users, slack_history, slack_replies, slack_send, slack_attach, slack_download, slack_auth, cache_tag };
const WacliJob = struct {
    kind: WacliJobKind = .chats,
    gen: u64 = 0,
    jid: Utf8Text(191) = .{},
    msg_id: Utf8Text(191) = .{},
    extra: Utf8Text(63) = .{},
    started_ms: u64 = 0,
    arg_count: usize = 0,
    args: [max_wacli_args]Utf8Text(wacli_arg_cap) = @splat(.{}),
};
const WacliResult = struct {
    kind: WacliJobKind = .slack_send,
    jid: Utf8Text(191) = .{},
    msg_id: Utf8Text(191) = .{},
    extra: Utf8Text(63) = .{},
    ok: bool = false,
    data: []u8 = &.{},
};
const PendingSend = struct {
    jid: Utf8Text(191) = .{},
    text: Utf8Text(4095) = .{},
    file: Utf8Text(519) = .{},
    reply_to: Utf8Text(191) = .{},
    reply_sender: Utf8Text(191) = .{},
    id: [outbox.id_len]u8 = @splat('0'),
    seq: u64 = 0,
    queued_unix: i64 = 0,
    retries: u8 = 0,
    ambiguous: bool = false,
    completed: bool = false,
    not_before_ms: u64 = 0,
};
const SlackOutbox = struct {
    entry: outbox.Entry = .{},
    inflight: bool = false,
    completed: bool = false,
    not_before_ms: u64 = 0,
};
fn WideText(comptime capacity: usize) type {
    return struct {
        buf: [capacity + 1]u16 = @splat(0),
        len: usize = 0,
        fn set(self: *@This(), _: std.mem.Allocator, text: []const u8) void {
            self.len = std.unicode.utf8ToUtf16Le(self.buf[0..capacity], text) catch 0;
            self.buf[self.len] = 0;
        }
        fn slice(self: *const @This()) []const u16 {
            return self.buf[0..self.len];
        }
    };
}
const Message = struct {
    from_me: bool = true,
    send_state: enum { none, pending, failed } = .pending,
    text: WideText(4095) = .{},
    sender: WideText(159) = .{},
    timestamp: Utf8Text(63) = .{},
    id: Utf8Text(191) = .{},
    time: WideText(15) = .{},
};
const NoLock = struct {
    fn lockUncancelable(_: *@This(), _: std.Io) void {}
    fn unlock(_: *@This(), _: std.Io) void {}
    fn broadcast(_: *@This(), _: std.Io) void {}
    fn mark(_: *@This(), _: []const u8, _: []const u8) bool {
        return true;
    }
};
const TelegramClient = struct {
    fn sendText(_: *@This(), _: i64, _: []const u8) bool {
        return false;
    }
};
const App = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    io: std.Io = std.testing.io,
    outbox_path: []const u8 = "outbox.jsonl",
    outbox_load_failed: bool = false,
    pending_sends: [max_pending_sends]PendingSend = @splat(.{}),
    pending_send_count: usize = 0,
    slack_outbox: [max_slack_outbox]SlackOutbox = @splat(.{}),
    slack_outbox_count: usize = 0,
    send_seq: u64 = 0,
    slack_tokens: ?bool = true,
    slack_bridge: ?bool = null,
    wacli_mutex: NoLock = .{},
    wacli_cond: NoLock = .{},
    wacli_thread: ?bool = true,
    wacli_slack_thread: ?bool = true,
    wacli_queue: [wacli_queue_size]WacliJob = @splat(.{}),
    wacli_queue_len: usize = 0,
    wacli_refresh_again: bool = false,
    wacli_pending: [13]u32 = @splat(0),
    compose: ?usize = 1,
    canvas: ?usize = null,
    hwnd: ?usize = null,
    chat_count: usize = 1,
    selected_chat: usize = 0,
    chats: [1]struct { jid: Utf8Text(191) = .{}, provider: enum { whatsapp, slack, telegram } = .whatsapp } = @splat(.{}),
    reply_to: Utf8Text(191) = .{},
    reply_sender: Utf8Text(191) = .{},
    staged_image: struct { path: Utf8Text(519) = .{}, jid: Utf8Text(191) = .{} } = .{},
    slack_attach: WideText(519) = .{},
    slack_attach_jid: Utf8Text(191) = .{},
    telegram: ?*TelegramClient = null,
    user_viewed: bool = false,
    scroll_y: i32 = 0,
    compose_client_width: i32 = 0,
    compose_client_height: i32 = 0,
    messages: [3]Message = @splat(.{}),
    message_count: usize = 0,
    displayed_jid: Utf8Text(191) = .{},
    slack_log_mutex: NoLock = .{},
    slack_log: NoLock = .{},
    send_child: ?usize = null,
    read_child: ?usize = null,
    archive_child: ?usize = null,
    sync_child: ?usize = null,
};
const media_age = struct {
    fn unixSeconds(_: []const u8) ?i64 {
        return 42;
    }
};
const slack = struct {
    const max_text = 4095;
    fn parseSentTs(_: std.mem.Allocator, _: []const u8) ?[]u8 {
        return null;
    }
};
const win = struct {
    const SYSTEMTIME = struct { wHour: u16 = 0, wMinute: u16 = 0 };
    fn GetLocalTime(_: *SYSTEMTIME) void {}
    const DWORD = u32;
    const LARGE_INTEGER = struct { QuadPart: i64 };
    const INVALID_HANDLE_VALUE: ?usize = 99;
    const GENERIC_WRITE = 1;
    const GENERIC_READ = 2;
    const CREATE_ALWAYS = 3;
    const OPEN_EXISTING = 4;
    const FILE_ATTRIBUTE_NORMAL = 0;
    const FILE_SHARE_READ = 0;
    const MOVEFILE_REPLACE_EXISTING = 1;
    const MOVEFILE_WRITE_THROUGH = 2;
    const ERROR_FILE_NOT_FOUND = 2;
    const TRUE = 1;
    fn CreateFileW(_: [*:0]const u16, access: u32, _: u32, _: ?usize, _: u32, _: u32, _: ?usize) ?usize {
        if (fault == .open) return INVALID_HANDLE_VALUE;
        if (access == GENERIC_READ) {
            read_position = 0;
            return if (exists) 2 else INVALID_HANDLE_VALUE;
        }
        temp_len = 0;
        return 1;
    }
    fn GetLastError() u32 {
        return if (exists) 5 else ERROR_FILE_NOT_FOUND;
    }
    fn GetFileSizeEx(_: ?usize, size: *LARGE_INTEGER) u32 {
        size.QuadPart = @intCast(disk_len);
        return 1;
    }
    fn WriteFile(_: ?usize, bytes: [*]const u8, len: u32, written: *u32, _: ?usize) u32 {
        if (fault == .write) {
            written.* = 0;
            return 0;
        }
        // Force partial writes, exercising the real writer's loop.
        const count = @min(len, 17);
        @memcpy(temp[temp_len..][0..count], bytes[0..count]);
        temp_len += count;
        written.* = count;
        return 1;
    }
    fn ReadFile(_: ?usize, bytes: [*]u8, len: u32, got: *u32, _: ?usize) u32 {
        if (fault == .read and read_position > 0) {
            got.* = 0;
            return 0;
        }
        const count = @min(@min(len, 17), disk_len - read_position);
        @memcpy(bytes[0..count], disk[read_position..][0..count]);
        read_position += count;
        got.* = @intCast(count);
        return 1;
    }
    fn FlushFileBuffers(_: ?usize) u32 {
        flushes += 1;
        return if (fault == .flush) 0 else 1;
    }
    fn CloseHandle(_: ?usize) u32 {
        closes += 1;
        return 1;
    }
    fn DeleteFileW(_: [*:0]const u16) u32 {
        return 1;
    }
    fn MoveFileExW(_: [*:0]const u16, _: [*:0]const u16, flags: u32) u32 {
        if (fault == .rename) return 0;
        try_write_through = flags & MOVEFILE_WRITE_THROUGH != 0;
        @memcpy(disk[0..temp_len], temp[0..temp_len]);
        disk_len = temp_len;
        exists = true;
        return 1;
    }
    fn GetTickCount64() u64 {
        return 1000;
    }
    fn GetWindowTextW(_: usize, dest: []u16, capacity: usize) i32 {
        const len = @min(compose_len, capacity - 1);
        @memcpy(dest[0..len], compose_text[0..len]);
        return @intCast(len);
    }
    fn SetWindowTextW(_: usize, _: [*:0]const u16) u32 {
        compose_len = 0;
        return 1;
    }
    fn InvalidateRect(_: usize, _: ?usize, _: u32) u32 {
        return 1;
    }
};
var fault: enum { none, open, write, flush, rename, read } = .none;
var disk: [outbox.max_entries * outbox.max_line_len]u8 = undefined;
var temp: [outbox.max_entries * outbox.max_line_len]u8 = undefined;
var disk_len: usize = 0;
var temp_len: usize = 0;
var exists = false;
var read_position: usize = 0;
var flushes: usize = 0;
var closes: usize = 0;
var try_write_through = false;
var deleted: usize = 0;
var spawned: usize = 0;
var delivered_same_text = false;
var refreshed: usize = 0;
var compose_text: [4096]u16 = @splat(0);
var compose_len: usize = 0;
fn reset() void {
    fault = .none;
    disk_len = 0;
    temp_len = 0;
    exists = false;
    flushes = 0;
    closes = 0;
    deleted = 0;
    spawned = 0;
    try_write_through = false;
    delivered_same_text = false;
    compose_len = 0;
    refreshed = 0;
}
fn lit(comptime text: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}
fn setStatus(_: *App, _: []const u8) void {}
fn selectedChatIsSlack(a: *App) bool {
    return a.chats[0].provider == .slack;
}
fn selectedChatIsTelegram(a: *App) bool {
    return a.chats[0].provider == .telegram;
}
fn slackConfigured(a: *App) bool {
    return a.slack_tokens != null or a.slack_bridge != null;
}
fn tgSelectedChatIsGroup(_: *App) bool {
    return false;
}
fn tgSelectedChatId(_: *App) ?i64 {
    return 1;
}
fn clearReply(a: *App) void {
    a.reply_to = .{};
    a.reply_sender = .{};
}
fn focusCompose(_: *App) void {}
fn layout(_: *App, _: i32, _: i32) void {}
fn releaseStagedImage(a: *App) void {
    a.staged_image = .{};
}
fn discardStagedImage(a: *App) void {
    releaseStagedImage(a);
}
fn forgetFailedSend(_: *App, _: []const u8, _: []const u8) void {}
fn nowUnixSeconds() i64 {
    return 42;
}
fn mintSendId(_: *App, id: *[outbox.id_len]u8) void {
    std.testing.io.random(id);
    id.* = outbox.hexId(id[0..16].*);
}
fn appendSlackPending(_: *App, _: []const u8, _: []const u8) void {}
fn wacliPumpSync(_: *App) void {}
fn deleteFileUtf8(_: []const u8) void {
    deleted += 1;
}
fn oldestPendingSend(a: *App) ?usize {
    for (a.messages[0..a.message_count], 0..) |*message, index| if (message.send_state == .pending) {
        return index;
    };
    return null;
}
fn removeMessageAt(_: *App, _: usize) void {}
fn formatSlackTime(_: *WideText(15), _: std.mem.Allocator, _: []const u8) void {}
fn mediaBusy(_: *App) bool {
    return false;
}
fn avatarBusy(_: *App) bool {
    return false;
}
fn sentMessageExists(_: *App, _: []const u8, _: []const u8, _: i64) bool {
    return delivered_same_text;
}
fn appendLaunchLog(_: *App, _: []const u8) void {}
fn drainMediaDownloads(_: *App) void {}
fn startSync(_: *App) void {}
fn refreshChats(_: *App) void {}
fn refreshMessages(_: *App) void {
    refreshed += 1;
}
fn refreshGroups(_: *App) void {}
fn refreshSlackWorkspace(_: *App) void {}
fn enqueueCacheTagProbe(_: *App) void {}
fn sampleEntry(number: u8) outbox.Entry {
    var value = outbox.Entry{};
    value.id = outbox.hexId(@splat(number));
    value.jid.set("synthetic-chat");
    value.text.set("synthetic text");
    value.client_msg_id.set(if (number == 1) "client-one" else "client-two");
    return value;
}
fn setCompose(text: []const u8) void {
    compose_len = std.unicode.utf8ToUtf16Le(&compose_text, text) catch unreachable;
}

test "failed atomic journal stages do not acknowledge persistence" {
    for ([_]@TypeOf(fault){ .open, .write, .flush, .rename }) |failure| {
        reset();
        var app = App{};
        app.slack_outbox_count = 1;
        app.slack_outbox[0].entry = sampleEntry(1);
        try std.testing.expect(persistOutbox(&app));
        const old_len = disk_len;
        const old_hash = std.hash.Wyhash.hash(0, disk[0..disk_len]);
        app.slack_outbox[0].entry.text.set("replacement");
        fault = failure;
        try std.testing.expect(!persistOutbox(&app));
        try std.testing.expectEqual(old_len, disk_len);
        try std.testing.expectEqual(old_hash, std.hash.Wyhash.hash(0, disk[0..disk_len]));
    }
    reset();
    var app = App{};
    try std.testing.expect(persistOutbox(&app));
    try std.testing.expect(flushes > 0 and try_write_through);
}

test "failed journal admission preserves composer reply and staged image" {
    reset();
    var app = App{};
    app.chats[0].jid.set("synthetic-chat");
    app.reply_to.set("synthetic-reply");
    setCompose("draft");
    fault = .rename;
    sendMessage(&app);
    try std.testing.expectEqual(@as(usize, 0), app.pending_send_count);
    try std.testing.expect(compose_len > 0 and app.reply_to.len > 0);
    app.staged_image.path.set("synthetic.png");
    app.staged_image.jid = app.chats[0].jid;
    sendMessage(&app);
    try std.testing.expectEqual(@as(usize, 0), app.pending_send_count);
    try std.testing.expect(app.staged_image.path.len > 0 and app.reply_to.len > 0);
    app.chats[0].provider = .slack;
    sendMessage(&app);
    try std.testing.expectEqual(@as(usize, 0), app.slack_outbox_count);
    try std.testing.expect(app.staged_image.path.len > 0 and compose_len > 0);
}

test "completed file stays alive until journal retirement succeeds" {
    reset();
    var app = App{};
    app.pending_send_count = 1;
    app.pending_sends[0].file.set("synthetic.png");
    try std.testing.expect(persistOutbox(&app));
    fault = .rename;
    removeFirstPendingSend(&app);
    try std.testing.expectEqual(@as(usize, 1), app.pending_send_count);
    try std.testing.expect(app.pending_sends[0].completed);
    try std.testing.expectEqual(@as(usize, 0), deleted);
    startNextSend(&app);
    try std.testing.expectEqual(@as(usize, 0), spawned);
    fault = .none;
    removeFirstPendingSend(&app);
    try std.testing.expectEqual(@as(usize, 0), app.pending_send_count);
    try std.testing.expectEqual(@as(usize, 1), deleted);
    try std.testing.expectEqual(@as(usize, 0), disk_len);
}

test "restored WhatsApp sends have unique bubble sequences" {
    reset();
    var app = App{};
    app.slack_outbox_count = 2;
    app.slack_outbox[0].entry = sampleEntry(1);
    app.slack_outbox[1].entry = sampleEntry(2);
    try std.testing.expect(persistOutbox(&app));
    var restored = App{};
    loadOutbox(&restored);
    try std.testing.expect(!restored.outbox_load_failed);
    try std.testing.expectEqual(@as(usize, 2), restored.pending_send_count);
    try std.testing.expect(restored.pending_sends[0].seq > 0);
    try std.testing.expect(restored.pending_sends[1].seq > restored.pending_sends[0].seq);
    // Matching an older repeated text or file caption does not prove delivery.
    delivered_same_text = true;
    startNextSend(&restored);
    try std.testing.expectEqual(@as(usize, 2), restored.pending_send_count);
    try std.testing.expectEqual(@as(usize, 1), spawned);
}

test "partial journal read fails closed and cannot overwrite disk" {
    reset();
    var app = App{};
    app.slack_outbox_count = 1;
    app.slack_outbox[0].entry = sampleEntry(1);
    try std.testing.expect(persistOutbox(&app));
    const saved_len = disk_len;
    fault = .read;
    var restored = App{};
    loadOutbox(&restored);
    try std.testing.expect(restored.outbox_load_failed);
    fault = .none;
    try std.testing.expect(!persistOutbox(&restored));
    try std.testing.expectEqual(saved_len, disk_len);
    startNextSend(&restored);
    try std.testing.expectEqual(@as(usize, 0), spawned);
}

test "disconnected Slack outbox waits without losing entries" {
    reset();
    var app = App{};
    app.slack_tokens = null;
    app.slack_outbox_count = 1;
    app.slack_outbox[0].entry = sampleEntry(1);
    retrySlackOutbox(&app);
    try std.testing.expectEqual(@as(usize, 0), app.wacli_queue_len);
    try std.testing.expect(!app.slack_outbox[0].inflight);
    app.slack_tokens = true;
    retrySlackOutbox(&app);
    try std.testing.expectEqual(@as(usize, 1), app.wacli_queue_len);
    try std.testing.expectEqualStrings(app.slack_outbox[0].entry.idSlice(), app.wacli_queue[0].msg_id.slice());
}

test "refused write cannot be overtaken and full queue preserves writes" {
    reset();
    var app = App{};
    app.slack_outbox_count = 2;
    app.slack_outbox[0].entry = sampleEntry(1);
    app.slack_outbox[1].entry = sampleEntry(2);
    app.wacli_queue_len = app.wacli_queue.len;
    for (&app.wacli_queue) |*job| job.kind = .slack_send;
    app.wacli_pending[@intFromEnum(WacliJobKind.slack_send)] = @intCast(app.wacli_queue_len);
    enqueueSlackOutbox(&app, &app.slack_outbox[0]);
    try std.testing.expectEqual(app.wacli_queue.len, app.wacli_queue_len);
    try std.testing.expect(!app.slack_outbox[0].inflight);
    try std.testing.expect(!wacliEnqueue(&app, .{ .kind = .chats }, false));
    _ = wacliTakeJob(&app, true);
    enqueueSlackOutbox(&app, &app.slack_outbox[1]);
    try std.testing.expect(!app.slack_outbox[1].inflight);
    app.slack_outbox[0].not_before_ms = 0;
    retrySlackOutbox(&app);
    try std.testing.expect(app.slack_outbox[0].inflight and !app.slack_outbox[1].inflight);
}

test "Slack results retire exact ids even after echo and out-of-order admission" {
    reset();
    var app = App{};
    app.slack_outbox_count = 2;
    app.slack_outbox[0].entry = sampleEntry(1);
    app.slack_outbox[1].entry = sampleEntry(2);
    const second_id = app.slack_outbox[1].entry.id;
    retireSlackOutbox(&app, &second_id);
    try std.testing.expectEqual(@as(usize, 1), app.slack_outbox_count);
    try std.testing.expectEqualStrings("client-one", app.slack_outbox[0].entry.client_msg_id.slice());
    retireSlackOutbox(&app, &second_id);
    try std.testing.expectEqual(@as(usize, 1), app.slack_outbox_count);
    fault = .rename;
    const first_id = app.slack_outbox[0].entry.id;
    retireSlackOutbox(&app, &first_id);
    retrySlackOutbox(&app);
    try std.testing.expect(app.slack_outbox[0].completed);
    try std.testing.expectEqual(@as(usize, 0), app.wacli_queue_len);
    fault = .none;
    retrySlackOutbox(&app);
    try std.testing.expectEqual(@as(usize, 0), app.slack_outbox_count);
}

test "failed Slack result never fails a later bubble consumed by a prior echo" {
    reset();
    var app = App{};
    app.slack_outbox_count = 2;
    app.slack_outbox[0].entry = sampleEntry(1);
    app.slack_outbox[1].entry = sampleEntry(2);
    app.displayed_jid.set("synthetic-chat");
    app.message_count = 1;
    app.messages[0].timestamp.set("client-two");
    app.messages[0].text.set(app.allocator, "later draft");
    var result = WacliResult{};
    result.jid.set("synthetic-chat");
    result.extra.set("HttpFailed");
    result.msg_id.set(app.slack_outbox[0].entry.idSlice());
    resolveSlackSend(&app, &result);
    try std.testing.expectEqual(@TypeOf(app.messages[0].send_state).pending, app.messages[0].send_state);
    result.msg_id.set(app.slack_outbox[1].entry.idSlice());
    resolveSlackSend(&app, &result);
    try std.testing.expectEqual(@TypeOf(app.messages[0].send_state).failed, app.messages[0].send_state);
}

test "Slack pasted image reaches Slack journal and preserves borrowed path" {
    reset();
    var app = App{};
    app.chats[0].provider = .slack;
    app.chats[0].jid.set("synthetic-chat");
    app.staged_image.jid = app.chats[0].jid;
    app.staged_image.path.set("synthetic.png");
    sendMessage(&app);
    try std.testing.expectEqual(@as(usize, 0), app.pending_send_count);
    try std.testing.expectEqual(@as(usize, 1), app.slack_outbox_count);
    try std.testing.expectEqualStrings("synthetic.png", app.slack_outbox[0].entry.file.slice());
    try std.testing.expectEqualStrings("synthetic.png", app.wacli_queue[0].args[2].slice());
    try std.testing.expectEqual(outbox.Provider.slack, app.slack_outbox[0].entry.provider);
}

test "multibyte composer text is refused rather than journaled as invalid UTF8" {
    reset();
    var app = App{};
    app.chats[0].provider = .slack;
    compose_len = 3000;
    @memset(compose_text[0..compose_len], 0x00fc);
    sendMessage(&app);
    try std.testing.expectEqual(@as(usize, 0), app.slack_outbox_count);
    try std.testing.expectEqual(@as(usize, 3000), compose_len);
}

test "Slack text is not truncated to the old 512-byte job capacity" {
    reset();
    var app = App{};
    app.chats[0].provider = .slack;
    app.chats[0].jid.set("synthetic-chat");
    const text = [_]u8{'a'} ** 1024;
    setCompose(&text);
    sendMessage(&app);
    try std.testing.expectEqual(@as(usize, 1), app.slack_outbox_count);
    try std.testing.expectEqualStrings(&text, app.wacli_queue[0].args[1].slice());
    try std.testing.expectEqualStrings(app.slack_outbox[0].entry.text.slice(), app.wacli_queue[0].args[1].slice());
}

test "chat read refused by writes retries after the queue drains" {
    reset();
    var app = App{};
    app.wacli_queue_len = app.wacli_queue.len;
    for (&app.wacli_queue) |*job| job.kind = .slack_send;
    try std.testing.expect(!wacliEnqueue(&app, .{ .kind = .messages }, true));
    try std.testing.expect(app.wacli_refresh_again);
    retryWacliRefreshes(&app);
    try std.testing.expectEqual(@as(usize, 0), refreshed);
    while (wacliTakeJob(&app, true) != null) {}
    retryWacliRefreshes(&app);
    try std.testing.expectEqual(@as(usize, 1), refreshed);
    try std.testing.expect(!app.wacli_refresh_again);
}

test "restored pending bubble is not hidden by a matching old text" {
    reset();
    var app = App{};
    app.chats[0].jid.set("synthetic-chat");
    app.message_count = 1;
    app.messages[0].send_state = .none;
    app.messages[0].text.set(app.allocator, "synthetic text");
    var pending = PendingSend{};
    pending.from_disk = true;
    pending.jid = app.chats[0].jid;
    pending.text.set("synthetic text");
    pending.queued_unix = 42;
    appendWhatsAppPending(&app, &pending, true);
    try std.testing.expectEqual(@as(usize, 2), app.message_count);
    try std.testing.expectEqual(@TypeOf(app.messages[1].send_state).pending, app.messages[1].send_state);
}
