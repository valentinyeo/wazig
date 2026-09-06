//! Pure JSON event parsing for the TDLib td_json_client API. No Windows APIs,
//! no C linkage: unit tests run on any host. telegram.zig feeds raw JSON from
//! td_json_client_receive in and applies the parsed events to its state.

const std = @import("std");

pub const MediaKind = enum { none, photo, voice, sticker, video, document, other };

pub const AuthState = enum {
    unknown,
    wait_parameters,
    wait_phone,
    wait_code,
    wait_password,
    wait_registration,
    wait_email,
    logging_out,
    ready,
    closed,
};

pub const ChatInfo = struct {
    id: i64 = 0,
    title: []u8 = &.{},
    unread_count: i32 = 0,
    is_group: bool = false,
    is_channel: bool = false,
    last_date: i64 = 0,

    pub fn deinit(self: *ChatInfo, allocator: std.mem.Allocator) void {
        if (self.title.len > 0) allocator.free(self.title);
        self.title = &.{};
    }
};

pub const Msg = struct {
    chat_id: i64 = 0,
    id: i64 = 0,
    from_me: bool = false,
    sending: bool = false,
    failed: bool = false,
    sender_name: []u8 = &.{},
    text: []u8 = &.{},
    timestamp: []u8 = &.{},
    media_kind: MediaKind = .none,
    file_id: i32 = 0,
    local_path: []u8 = &.{},
    mime: []u8 = &.{},
    duration_ms: i32 = 0,
    animated_sticker: bool = false,

    pub fn deinit(self: *Msg, allocator: std.mem.Allocator) void {
        if (self.sender_name.len > 0) allocator.free(self.sender_name);
        if (self.text.len > 0) allocator.free(self.text);
        if (self.timestamp.len > 0) allocator.free(self.timestamp);
        if (self.local_path.len > 0) allocator.free(self.local_path);
        if (self.mime.len > 0) allocator.free(self.mime);
        self.* = .{};
    }
};

pub const FileUpdate = struct {
    file_id: i32 = 0,
    local_path: []u8 = &.{},
    downloading: bool = false,
};

pub const Connection = enum { unknown, connecting, ready, failed };

pub const Event = union(enum) {
    auth: struct { state: AuthState, error_text: []u8 = &.{} },
    chat: ChatInfo,
    /// One message from a history response, a new-message update, or a send
    /// success/failure. `history_done` marks the end of a getChatHistory batch.
    message: Msg,
    history_done,
    deleted: struct { chat_id: i64, message_id: i64 },
    file: FileUpdate,
    conn: Connection,
    chats_synced,
    ignored,

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .auth => |auth| if (auth.error_text.len > 0) allocator.free(auth.error_text),
            .chat => |*chat| chat.deinit(allocator),
            .message => |*msg| msg.deinit(allocator),
            .file => |file| if (file.local_path.len > 0) allocator.free(file.local_path),
            else => {},
        }
    }
};

// TDLib numbers that can exceed 2^53 (Telegram chat ids, chat order) arrive as
// JSON strings in the tdlib output; ids inside "message_ids" arrays are plain
// numbers. std.json parses integers into .integer exactly, and string ids we
// parse with std.fmt, so 64-bit ids stay exact either way.

fn getString(object: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = object.get(key) orelse return "";
    return switch (value) {
        .string => |s| s,
        else => "",
    };
}

fn getInt(object: std.json.ObjectMap, key: []const u8) i64 {
    const value = object.get(key) orelse return 0;
    return switch (value) {
        .integer => |i| i,
        .string => |s| std.fmt.parseInt(i64, s, 10) catch 0,
        else => 0,
    };
}

fn getId(object: std.json.ObjectMap, key: []const u8) i64 {
    // Telegram ids arrive either as numbers or as strings; both must stay exact.
    return getInt(object, key);
}

fn dupe(allocator: std.mem.Allocator, text: []const u8) []u8 {
    return allocator.dupe(u8, text) catch &.{};
}

/// Formats a Unix timestamp as "YYYY-MM-DD HH:MM:SS" (UTC) so Telegram chats
/// sort identically to the wacli `last_message_ts` strings.
pub fn formatTimestamp(buffer: *[20]u8, unix_seconds: i64) []const u8 {
    const epoch_seconds = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, unix_seconds)) };
    const day = epoch_seconds.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    const text = std.fmt.bufPrint(buffer, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch return "";
    return text;
}

fn parseAuthState(type_name: []const u8) AuthState {
    const map = std.StaticStringMap(AuthState).initComptime(.{
        .{ "authorizationStateWaitTdlibParameters", .wait_parameters },
        .{ "authorizationStateWaitPhoneNumber", .wait_phone },
        .{ "authorizationStateWaitCode", .wait_code },
        .{ "authorizationStateWaitPassword", .wait_password },
        .{ "authorizationStateWaitRegistration", .wait_registration },
        .{ "authorizationStateWaitEmailAddress", .wait_email },
        .{ "authorizationStateWaitEmailCode", .wait_email },
        .{ "authorizationStateLoggingOut", .logging_out },
        .{ "authorizationStateReady", .ready },
        .{ "authorizationStateClosed", .closed },
        .{ "authorizationStateClosing", .closed },
    });
    return map.get(type_name) orelse .unknown;
}

fn parseSenderName(object: std.json.ObjectMap) []const u8 {
    const sender = object.get("sender_id") orelse return "";
    switch (sender) {
        .object => |sender_object| {
            const sender_type = getString(sender_object, "@type");
            if (std.mem.eql(u8, sender_type, "messageSenderUser")) {
                const user = sender_object.get("user_id");
                if (user) |user_value| {
                    switch (user_value) {
                        .integer => |id| {
                            var buffer: [24]u8 = undefined;
                            const text = std.fmt.bufPrint(&buffer, "user {d}", .{id}) catch return "";
                            // Names arrive later via user updates; the id is a
                            // safe placeholder until then.
                            _ = text;
                            return "user";
                        },
                        else => {},
                    }
                }
                return "user";
            }
            return "group";
        },
        else => return "",
    }
}

fn fileOf(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .object => |file| if (std.mem.eql(u8, getString(file, "@type"), "file")) file else null,
        else => null,
    };
}

fn fileIdOf(object: std.json.ObjectMap, key: []const u8) i32 {
    const file = fileOf(object, key) orelse return 0;
    const id = getInt(file, "id");
    if (id == 0 or id > std.math.maxInt(i32)) return 0;
    return @intCast(id);
}

fn localPathOf(file: std.json.ObjectMap) []const u8 {
    const local = file.get("local") orelse return "";
    switch (local) {
        .object => |local_object| return getString(local_object, "path"),
        else => return "",
    }
}

fn mimeOf(object: std.json.ObjectMap) []const u8 {
    if (fileOf(object, "voice")) |voice| return getString(voice, "mime_type");
    if (fileOf(object, "sticker")) |sticker| return getString(sticker, "mime_type");
    if (fileOf(object, "document")) |document| return getString(document, "mime_type");
    if (fileOf(object, "video")) |video| return getString(video, "mime_type");
    return "";
}

fn parseContent(allocator: std.mem.Allocator, message_object: std.json.ObjectMap, msg: *Msg) void {
    const content_value = message_object.get("content") orelse return;
    const content = switch (content_value) {
        .object => |c| c,
        else => return,
    };
    const mime = mimeOf(content);
    if (mime.len > 0) msg.mime = dupe(allocator, mime);
    const content_type = getString(content, "@type");
    if (std.mem.eql(u8, content_type, "messageText")) {
        const text = content.get("text") orelse return;
        switch (text) {
            .object => |text_object| msg.text = dupe(allocator, getString(text_object, "text")),
            else => {},
        }
        return;
    }
    if (std.mem.eql(u8, content_type, "messagePhoto")) {
        msg.media_kind = .photo;
        msg.text = dupe(allocator, getString(content, "caption"));
        // Download the largest variant: TDLib sorts sizes ascending, so the
        // last entry with a file is the biggest.
        if (content.get("photo")) |sizes| {
            switch (sizes) {
                .array => |items| {
                    var index = items.items.len;
                    while (index > 0) : (index -= 1) {
                        switch (items.items[index - 1]) {
                            .object => |size| {
                                msg.file_id = fileIdOf(size, "photo");
                                if (msg.file_id != 0) break;
                            },
                            else => {},
                        }
                    }
                },
                else => {},
            }
        }
        return;
    }
    if (std.mem.eql(u8, content_type, "messageVoiceNote")) {
        msg.media_kind = .voice;
        const seconds = getInt(content, "duration");
        msg.duration_ms = @intCast(seconds * 1000);
        msg.file_id = fileIdOf(content, "voice");
        return;
    }
    if (std.mem.eql(u8, content_type, "messageSticker")) {
        msg.media_kind = .sticker;
        msg.animated_sticker = getBool(content, "is_animated") or getBool(content, "is_video");
        msg.file_id = fileIdOf(content, "sticker");
        return;
    }
    if (std.mem.eql(u8, content_type, "messageVideo")) {
        msg.media_kind = .video;
        msg.file_id = fileIdOf(content, "video");
        return;
    }
    if (std.mem.eql(u8, content_type, "messageDocument")) {
        const document = switch (content.get("document") orelse return) {
            .object => |d| d,
            else => return,
        };
        msg.media_kind = .document;
        if (msg.text.len == 0) msg.text = dupe(allocator, getString(document, "file_name"));
        msg.file_id = fileIdOf(document, "document");
        return;
    }
    msg.media_kind = .other;
}

fn getBool(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |b| b,
        else => false,
    };
}

pub fn parseMessage(allocator: std.mem.Allocator, value: std.json.Value) !?Msg {
    const message_object = switch (value) {
        .object => |o| o,
        else => return null,
    };
    if (!std.mem.eql(u8, getString(message_object, "@type"), "message")) return null;
    var msg = Msg{};
    errdefer msg.deinit(allocator);
    msg.chat_id = getId(message_object, "chat_id");
    msg.id = getId(message_object, "id");
    msg.from_me = getBool(message_object, "is_outgoing");
    if (message_object.get("sending_state")) |sending| {
        msg.sending = true;
        switch (sending) {
            .object => |sending_object| {
                if (std.mem.eql(u8, getString(sending_object, "@type"), "messageSendingStateFailed")) msg.failed = true;
            },
            else => {},
        }
    }
    const sender_name = parseSenderName(message_object);
    if (msg.from_me) {
        msg.sender_name = dupe(allocator, "You");
    } else if (sender_name.len > 0) {
        msg.sender_name = dupe(allocator, sender_name);
    }
    const date = getInt(message_object, "date");
    if (date != 0) {
        var timestamp_buffer: [20]u8 = undefined;
        const timestamp = formatTimestamp(&timestamp_buffer, date);
        msg.timestamp = dupe(allocator, timestamp);
    }
    parseContent(allocator, message_object, &msg);
    return msg;
}

fn parseFileUpdate(allocator: std.mem.Allocator, object: std.json.ObjectMap) !Event {
    const file = object;
    var update = FileUpdate{ .file_id = @intCast(@min(getInt(file, "id"), std.math.maxInt(i32))) };
    const local = file.get("local") orelse return .ignored;
    switch (local) {
        .object => |local_object| {
            update.downloading = getInt(local_object, "is_downloading_active") != 0;
            const path = getString(local_object, "path");
            const completed = getInt(local_object, "is_downloading_completed") != 0;
            if (completed and path.len > 0) update.local_path = dupe(allocator, path);
        },
        else => {},
    }
    return .{ .file = update };
}

fn parseChat(allocator: std.mem.Allocator, object: std.json.ObjectMap) !Event {
    var info = ChatInfo{};
    errdefer info.deinit(allocator);
    info.id = getId(object, "id");
    if (info.id == 0) return .ignored;
    info.title = dupe(allocator, getString(object, "title"));
    const chat_type = object.get("type") orelse return .{ .chat = info };
    switch (chat_type) {
        .object => |type_object| {
            const type_name = getString(type_object, "@type");
            if (std.mem.eql(u8, type_name, "chatTypeBasicGroup") or
                std.mem.eql(u8, type_name, "chatTypeSupergroup")) info.is_group = true;
            if (std.mem.eql(u8, type_name, "chatTypeSupergroup") and getBool(type_object, "is_channel"))
                info.is_channel = true;
        },
        else => {},
    }
    info.unread_count = @intCast(getInt(object, "unread_count"));
    if (object.get("last_message")) |last| {
        switch (last) {
            .object => |last_object| info.last_date = getInt(last_object, "date"),
            else => {},
        }
    }
    return .{ .chat = info };
}

/// Parses one raw JSON string from td_json_client_receive. Returns .ignored
/// for everything the app does not consume. Caller owns the returned event
/// and must call event.deinit(allocator).
pub fn parseEvent(allocator: std.mem.Allocator, json_text: []const u8) !Event {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return .ignored;
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |o| o,
        else => return .ignored,
    };
    const type_name = getString(object, "@type");
    if (std.mem.startsWith(u8, type_name, "authorizationState")) {
        const state = parseAuthState(type_name);
        // authorizationStateWaitOtherDeviceConfirmation and error payloads
        // carry no secrets worth keeping; only error messages surface.
        return .{ .auth = .{ .state = state } };
    }
    if (std.mem.eql(u8, type_name, "error")) {
        const message = getString(object, "message");
        const safe = if (std.mem.indexOf(u8, message, "phone") != null or
            std.mem.indexOf(u8, message, "code") != null) "Telegram rejected the input" else message;
        return .{ .auth = .{ .state = .unknown, .error_text = dupe(allocator, safe) } };
    }
    if (std.mem.eql(u8, type_name, "updateAuthorizationState")) {
        const inner = object.get("authorization_state") orelse return .ignored;
        switch (inner) {
            .object => |inner_object| {
                const state = parseAuthState(getString(inner_object, "@type"));
                return .{ .auth = .{ .state = state } };
            },
            else => return .ignored,
        }
    }
    if (std.mem.eql(u8, type_name, "updateNewChat") or std.mem.eql(u8, type_name, "updateChatLastMessage") or
        std.mem.eql(u8, type_name, "updateChatReadInbox"))
    {
        const chat_value = object.get("chat") orelse {
            // updateChatReadInbox carries unread_count on the top level.
            if (std.mem.eql(u8, type_name, "updateChatReadInbox")) {
                const info = ChatInfo{ .id = getId(object, "chat_id"), .unread_count = @intCast(getInt(object, "unread_count")) };
                return .{ .chat = info };
            }
            return .ignored;
        };
        switch (chat_value) {
            .object => |chat_object| return parseChat(allocator, chat_object),
            else => return .ignored,
        }
    }
    if (std.mem.eql(u8, type_name, "chats")) {
        return .chats_synced;
    }
    if (std.mem.eql(u8, type_name, "updateNewMessage") or std.mem.eql(u8, type_name, "updateMessageSendSucceeded") or
        std.mem.eql(u8, type_name, "updateMessageSendFailed") or std.mem.eql(u8, type_name, "message"))
    {
        const message_value = if (std.mem.eql(u8, type_name, "message"))
            parsed.value
        else
            object.get("message") orelse return .ignored;
        if (try parseMessage(allocator, message_value)) |msg| return .{ .message = msg };
        return .ignored;
    }
    if (std.mem.eql(u8, type_name, "messages")) {
        // getChatHistory response. Individual messages are emitted by the
        // caller via parseHistoryMessage; here we only signal the batch end.
        return .history_done;
    }
    if (std.mem.eql(u8, type_name, "updateDeleteMessages")) {
        const chat_id = getId(object, "chat_id");
        const ids = object.get("message_ids") orelse return .ignored;
        switch (ids) {
            .array => |items| {
                if (items.items.len == 0) return .ignored;
                const first = switch (items.items[0]) {
                    .integer => |i| i,
                    else => return .ignored,
                };
                return .{ .deleted = .{ .chat_id = chat_id, .message_id = first } };
            },
            else => return .ignored,
        }
    }
    if (std.mem.eql(u8, type_name, "updateFile")) {
        const file_value = object.get("file") orelse return .ignored;
        switch (file_value) {
            .object => |file_object| return parseFileUpdate(allocator, file_object),
            else => return .ignored,
        }
    }
    if (std.mem.eql(u8, type_name, "updateConnectionState")) {
        const state = object.get("state") orelse return .ignored;
        switch (state) {
            .object => |state_object| {
                const state_type = getString(state_object, "@type");
                if (std.mem.eql(u8, state_type, "connectionStateReady")) return .{ .conn = .ready };
                if (std.mem.eql(u8, state_type, "connectionStateConnecting") or
                    std.mem.eql(u8, state_type, "connectionStateConnectingToProxy") or
                    std.mem.eql(u8, state_type, "connectionStateUpdating")) return .{ .conn = .connecting };
                return .{ .conn = .failed };
            },
            else => return .ignored,
        }
    }
    return .ignored;
}

/// Parses one raw JSON string into zero or more events: a getChatHistory
/// "messages" batch becomes one .message event per entry plus .history_done.
/// Caller owns every event and must call deinit on each.
pub fn parseEventBatch(allocator: std.mem.Allocator, json_text: []const u8) !std.ArrayList(Event) {
    var list = std.ArrayList(Event).empty;
    errdefer {
        for (list.items) |*event| event.deinit(allocator);
        list.deinit(allocator);
    }
    var probe = std.json.parseFromSlice(std.json.Value, allocator, json_text, .{}) catch return list;
    defer probe.deinit();
    const root_type = switch (probe.value) {
        .object => |o| getString(o, "@type"),
        else => "",
    };
    if (std.mem.eql(u8, root_type, "messages")) {
        const items = switch (probe.value) {
            .object => |o| o.get("messages") orelse std.json.Value{ .null = {} },
            else => std.json.Value{ .null = {} },
        };
        switch (items) {
            .array => |array| {
                for (array.items) |item| {
                    if (try parseMessage(allocator, item)) |msg| {
                        try list.append(allocator, .{ .message = msg });
                    }
                }
            },
            else => {},
        }
        try list.append(allocator, .history_done);
        return list;
    }
    const event = try parseEvent(allocator, json_text);
    try list.append(allocator, event);
    return list;
}

pub fn parseHistoryMessage(allocator: std.mem.Allocator, value: std.json.Value) !?Msg {
    return parseMessage(allocator, value);
}

test "parses wait phone auth update" {
    const event = try parseEvent(std.testing.allocator, "{\"@type\":\"updateAuthorizationState\",\"authorization_state\":{\"@type\":\"authorizationStateWaitPhoneNumber\"}}");
    var moved = event;
    defer moved.deinit(std.testing.allocator);
    try std.testing.expectEqual(AuthState.wait_phone, event.auth.state);
}

test "parses text message with timestamp" {
    const event = try parseEvent(std.testing.allocator,
        \\{"@type":"updateNewMessage","message":{"@type":"message","id":42,"chat_id":100,"is_outgoing":false,"date":1767139200,"sender_id":{"@type":"messageSenderUser","user_id":7},"content":{"@type":"messageText","text":{"@type":"formattedText","text":"hello"}}}}
    );
    var moved = event;
    defer moved.deinit(std.testing.allocator);
    const msg = event.message;
    try std.testing.expectEqual(@as(i64, 42), msg.id);
    try std.testing.expectEqualStrings("hello", msg.text);
    try std.testing.expectEqualStrings("2025-12-31 00:00:00", msg.timestamp);
}

test "parses voice note with file id and duration" {
    const event = try parseEvent(std.testing.allocator,
        \\{"@type":"updateNewMessage","message":{"@type":"message","id":9,"chat_id":5,"date":1767139200,"content":{"@type":"messageVoiceNote","duration":12,"voice":{"@type":"file","id":777,"mime_type":"audio/ogg","local":{"@type":"localFile","path":""}}}}}
    );
    var moved = event;
    defer moved.deinit(std.testing.allocator);
    const msg = event.message;
    try std.testing.expectEqual(MediaKind.voice, msg.media_kind);
    try std.testing.expectEqual(@as(i32, 777), msg.file_id);
    try std.testing.expectEqual(@as(i32, 12000), msg.duration_ms);
    try std.testing.expectEqualStrings("audio/ogg", msg.mime);
}

test "parses group chat" {
    const event = try parseEvent(std.testing.allocator,
        \\{"@type":"updateNewChat","chat":{"@type":"chat","id":-1001234567890,"title":"Team","unread_count":3,"type":{"@type":"chatTypeSupergroup","is_channel":false}}}
    );
    var moved = event;
    defer moved.deinit(std.testing.allocator);
    const chat = event.chat;
    try std.testing.expectEqual(@as(i64, -1001234567890), chat.id);
    try std.testing.expectEqualStrings("Team", chat.title);
    try std.testing.expect(chat.is_group);
    try std.testing.expect(!chat.is_channel);
    try std.testing.expectEqual(@as(i32, 3), chat.unread_count);
}

test "formats timestamps" {
    var buffer: [20]u8 = undefined;
    try std.testing.expectEqualStrings("2026-09-06 13:34:39", formatTimestamp(&buffer, 1788701679));
}

test "error messages are sanitized" {
    const event = try parseEvent(std.testing.allocator, "{\"@type\":\"error\",\"code\":400,\"message\":\"PHONE_CODE_INVALID: the code you entered\"}");
    var moved = event;
    defer moved.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Telegram rejected the input", event.auth.error_text);
}
