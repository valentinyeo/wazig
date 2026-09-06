// Slack provider core: pure helpers over Slack Web API / Socket Mode JSON.
// No Windows calls here, so the unit tests run on the CI host. The WinHTTP
// transport and token storage live in slack_win.zig (Windows only).
const std = @import("std");

pub const max_text = 4095;

pub const Provider = enum(u8) { whatsapp = 0, slack = 1 };
pub const max_channel_id = 31;
pub const max_user_id = 31;

/// Numeric order of Slack timestamps ("1740000000.000123"). Seconds compare
/// numerically, then the fraction compares by zero-padded width. Malformed
/// values fall back to lexicographic order so sorting never breaks.
pub fn compareTs(a: []const u8, b: []const u8) std.math.Order {
    const left = splitTs(a);
    const right = splitTs(b);
    const by_seconds = std.math.order(left.seconds, right.seconds);
    if (by_seconds != .eq) return by_seconds;
    return std.math.order(left.fraction, right.fraction);
}

const TsParts = struct { seconds: u64 = 0, fraction: u64 = 0 };

fn splitTs(value: []const u8) TsParts {
    var parts = TsParts{};
    const dot = std.mem.indexOfScalar(u8, value, '.') orelse value.len;
    parts.seconds = std.fmt.parseInt(u64, value[0..dot], 10) catch return .{};
    if (dot < value.len) {
        const digits = value[dot + 1 ..];
        var fraction: u64 = 0;
        var consumed: usize = 0;
        // Pad the fraction to a fixed width so "1234.5" and "1234.05" order
        // by value instead of by digit count.
        for (digits) |character| {
            if (consumed >= 9) break;
            if (character < '0' or character > '9') break;
            fraction = fraction * 10 + (character - '0');
            consumed += 1;
        }
        while (consumed < 9) : (consumed += 1) fraction *= 10;
        parts.fraction = fraction;
    }
    return parts;
}

/// True when a Socket Mode envelope must be acknowledged (has envelope_id).
/// The payload slice borrows the caller's buffer.
pub const Kind = enum { ack, events, hello, other };

pub const Envelope = struct {
    kind: Kind,
    envelope_id: []const u8 = "",
    event_type: []const u8 = "",
    subtype: []const u8 = "",
    channel: []const u8 = "",
    ts: []const u8 = "",
    thread_ts: []const u8 = "",
    user: []const u8 = "",
    bot_id: []const u8 = "",
    text: []const u8 = "",
    file_id: []const u8 = "",
    file_url: []const u8 = "",
    file_name: []const u8 = "",
    file_mime: []const u8 = "",
    file_size: i64 = 0,
};

pub const classification_error = error{OutOfMemory};

/// Classify a raw Socket Mode message. Returned slices stay valid until
/// `arena` is freed (JSON parsing may copy into it); copy anything that must
/// outlive the envelope.
pub fn classifyEnvelope(arena: std.mem.Allocator, text: []const u8) classification_error!?Envelope {
    const root_value = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
    const root = switch (root_value) {
        .object => |object| object,
        else => return null,
    };
    var envelope = Envelope{ .kind = .other };
    if (objectString(root, "envelope_id")) |envelope_id| {
        envelope.envelope_id = envelope_id;
        envelope.kind = .ack;
    }
    if (objectString(root, "type")) |top_type| {
        if (std.mem.eql(u8, top_type, "hello")) {
            envelope.kind = .hello;
            return envelope;
        }
    }
    const payload_value = root.get("payload") orelse return envelope;
    const payload = switch (payload_value) {
        .object => |object| object,
        else => return envelope,
    };
    const payload_type = objectString(payload, "type") orelse return envelope;
    if (!std.mem.eql(u8, payload_type, "events_api")) return envelope;
    const event_value = payload.get("event") orelse return envelope;
    var event = switch (event_value) {
        .object => |object| object,
        else => return envelope,
    };
    envelope.kind = .events;
    envelope.event_type = objectString(event, "type") orelse "";
    const subtype = objectString(event, "subtype") orelse "";
    envelope.subtype = subtype;
    // Edited messages carry the new body one level down.
    if (std.mem.eql(u8, subtype, "message_changed")) {
        if (event.get("message")) |inner_value| {
            if (inner_value == .object) event = inner_value.object;
        }
    }
    envelope.channel = objectString(event, "channel") orelse "";
    envelope.ts = objectString(event, "ts") orelse "";
    envelope.thread_ts = objectString(event, "thread_ts") orelse "";
    envelope.user = objectString(event, "user") orelse "";
    envelope.bot_id = objectString(event, "bot_id") orelse "";
    envelope.text = objectString(event, "text") orelse "";
    if (event.get("files")) |files_value| {
        if (files_value == .array and files_value.array.items.len > 0) {
            const file_value = files_value.array.items[0];
            if (file_value == .object) {
                const file = file_value.object;
                envelope.file_id = objectString(file, "id") orelse "";
                envelope.file_url = objectString(file, "url_private_download") orelse objectString(file, "url_private") orelse "";
                envelope.file_name = objectString(file, "name") orelse "";
                envelope.file_mime = objectString(file, "mimetype") orelse "";
                envelope.file_size = switch (file.get("size") orelse std.json.Value{ .integer = 0 }) {
                    .integer => |size| size,
                    else => 0,
                };
            }
        }
    }
    return envelope;
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

pub fn objectStringField(object: std.json.ObjectMap, key: []const u8) []const u8 {
    return objectString(object, key) orelse "";
}

/// One conversations.history item (already filtered to real messages).
pub const HistoryItem = struct {
    ts: []const u8 = "",
    user: []const u8 = "",
    text: []const u8 = "",
    thread_ts: []const u8 = "",
    reply_count: i64 = 0,
    subtype: []const u8 = "",
    file_id: []const u8 = "",
    file_url: []const u8 = "",
    file_name: []const u8 = "",
    file_mime: []const u8 = "",
    file_size: i64 = 0,
};

/// Extract displayable fields from a history item. Messages with a subtype
/// other than bot_message or message_changed are join/leave/reminder noise
/// and are reported as skippable.
pub fn readHistoryItem(value: std.json.Value) ?HistoryItem {
    var item = HistoryItem{};
    var object = switch (value) {
        .object => |object| object,
        else => return null,
    };
    item.subtype = objectString(object, "subtype") orelse "";
    if (std.mem.eql(u8, item.subtype, "message_changed")) {
        const inner = object.get("message") orelse return null;
        object = switch (inner) {
            .object => |inner_object| inner_object,
            else => return null,
        };
    } else if (item.subtype.len > 0 and !std.mem.eql(u8, item.subtype, "bot_message")) {
        return null;
    }
    item.ts = objectString(object, "ts") orelse return null;
    item.user = objectString(object, "user") orelse "";
    item.text = objectString(object, "text") orelse "";
    item.thread_ts = objectString(object, "thread_ts") orelse "";
    item.reply_count = switch (object.get("reply_count") orelse std.json.Value{ .integer = 0 }) {
        .integer => |count| count,
        else => 0,
    };
    if (object.get("files")) |files_value| {
        if (files_value == .array and files_value.array.items.len > 0) {
            const file_value = files_value.array.items[0];
            if (file_value == .object) {
                const file = file_value.object;
                item.file_id = objectString(file, "id") orelse "";
                item.file_url = objectString(file, "url_private_download") orelse objectString(file, "url_private") orelse "";
                item.file_name = objectString(file, "name") orelse "";
                item.file_mime = objectString(file, "mimetype") orelse "";
                item.file_size = switch (file.get("size") orelse std.json.Value{ .integer = 0 }) {
                    .integer => |size| size,
                    else => 0,
                };
            }
        }
    }
    return item;
}

/// Pull {"ok":true,"url":"wss://..."} into connection parts. Slices borrow
/// the response buffer.
pub const WsEndpoint = struct { host: []const u8, path_query: []const u8 };

pub fn parseWsUrl(arena: std.mem.Allocator, response: []const u8) ?WsEndpoint {
    const root_value = std.json.parseFromSliceLeaky(std.json.Value, arena, response, .{}) catch return null;
    const root = switch (root_value) {
        .object => |object| object,
        else => return null,
    };
    switch (root.get("ok") orelse return null) {
        .bool => |ok| if (!ok) return null,
        else => return null,
    }
    const url = objectString(root, "url") orelse return null;
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return null;
    const secure = std.mem.eql(u8, url[0..scheme_end], "wss");
    if (!secure and !std.mem.eql(u8, url[0..scheme_end], "ws")) return null;
    var rest = url[scheme_end + 3 ..];
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const host = rest[0..path_start];
    const path_query = rest[path_start..];
    _ = &rest;
    if (host.len == 0 or path_query.len < 2) return null;
    return .{ .host = host, .path_query = path_query };
}

/// Value for the Retry-After header of a raw WinHTTP header block, in
/// seconds. Missing or malformed values mean "retry soon" (null).
pub fn parseRetryAfter(headers: []const u8) ?u64 {
    const marker = "Retry-After:";
    const index = std.ascii.indexOfIgnoreCase(headers, marker) orelse return null;
    const line_end = std.mem.indexOfScalarPos(u8, headers, index, '\r') orelse headers.len;
    const text = std.mem.trim(u8, headers[index + marker.len .. line_end], " \t");
    if (text.len == 0 or text.len > 10) return null;
    return std.fmt.parseInt(u64, text, 10) catch null;
}

/// Escape a UTF-8 string for embedding in a JSON request body.
pub fn escapeJson(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (text) |character| {
        switch (character) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (character < 0x20) {
                    var buffer: [8]u8 = undefined;
                    const rendered = std.fmt.bufPrint(&buffer, "\\u{x:0>4}", .{character}) catch unreachable;
                    try out.appendSlice(allocator, rendered);
                } else {
                    try out.append(allocator, character);
                }
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

pub fn buildAckBody(allocator: std.mem.Allocator, envelope_id: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"envelope_id\":\"{s}\"}}", .{envelope_id});
}

pub const ReplyTo = struct {
    channel_id: []const u8,
    text: []const u8,
    thread_ts: []const u8 = "",
};

pub fn buildPostMessageBody(allocator: std.mem.Allocator, reply: ReplyTo) ![]u8 {
    const escaped = try escapeJson(allocator, reply.text);
    defer allocator.free(escaped);
    if (reply.thread_ts.len == 0) {
        return std.fmt.allocPrint(allocator, "{{\"channel\":\"{s}\",\"text\":\"{s}\"}}", .{ reply.channel_id, escaped });
    }
    return std.fmt.allocPrint(allocator, "{{\"channel\":\"{s}\",\"text\":\"{s}\",\"thread_ts\":\"{s}\"}}", .{ reply.channel_id, escaped, reply.thread_ts });
}

pub fn buildCompleteUploadBody(allocator: std.mem.Allocator, file_id: []const u8, channel_id: []const u8, thread_ts: []const u8, caption: []const u8) ![]u8 {
    const escaped_caption = try escapeJson(allocator, caption);
    defer allocator.free(escaped_caption);
    if (thread_ts.len == 0 and escaped_caption.len == 0) {
        return std.fmt.allocPrint(allocator, "{{\"files\":[{{\"id\":\"{s}\"}}],\"channel_id\":\"{s}\"}}", .{ file_id, channel_id });
    }
    if (thread_ts.len == 0) {
        return std.fmt.allocPrint(allocator, "{{\"files\":[{{\"id\":\"{s}\"}}],\"channel_id\":\"{s}\",\"initial_comment\":\"{s}\"}}", .{ file_id, channel_id, escaped_caption });
    }
    return std.fmt.allocPrint(allocator, "{{\"files\":[{{\"id\":\"{s}\"}}],\"channel_id\":\"{s}\",\"thread_ts\":\"{s}\",\"initial_comment\":\"{s}\"}}", .{ file_id, channel_id, thread_ts, escaped_caption });
}

pub const UploadGrant = struct { upload_url: []const u8, file_id: []const u8 };

/// Read files.getUploadURLExternal response {upload_url, file_id}. Both
/// strings are duplicated into `allocator`; the caller owns and frees them.
pub fn parseUploadGrant(allocator: std.mem.Allocator, response: []const u8) ?UploadGrant {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const upload_url = objectString(root, "upload_url") orelse return null;
    const file_id = objectString(root, "file_id") orelse return null;
    if (upload_url.len == 0 or file_id.len == 0) return null;
    const url_copy = allocator.dupe(u8, upload_url) catch return null;
    const id_copy = allocator.dupe(u8, file_id) catch {
        allocator.free(url_copy);
        return null;
    };
    return .{ .upload_url = url_copy, .file_id = id_copy };
}

/// Read files.info response and return the download URL; the caller owns
/// the duplicated string.
pub fn parseFileInfo(allocator: std.mem.Allocator, response: []const u8) ?[]const u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const file = switch (root.get("file") orelse return null) {
        .object => |object| object,
        else => return null,
    };
    const url = objectString(file, "url_private_download") orelse objectString(file, "url_private") orelse return null;
    return allocator.dupe(u8, url) catch null;
}

/// True when the response body parses as a Slack object with ok == true.
/// Substring checks fail both on echoed text and whitespace variants.
pub fn responseIsOk(allocator: std.mem.Allocator, body: []const u8) bool {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return false;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return false,
    };
    return switch (root.get("ok") orelse return false) {
        .bool => |flag| flag,
        .string => |text| std.mem.eql(u8, text, "true"),
        else => false,
    };
}

/// Percent-encode a query value (Slack cursors are base64 with +/=).
pub fn percentEncode(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (text) |character| {
        const unreserved = (character >= 'a' and character <= 'z') or
            (character >= 'A' and character <= 'Z') or
            (character >= '0' and character <= '9') or
            character == '-' or character == '_' or character == '.';
        if (unreserved) {
            try out.append(allocator, character);
        } else {
            var buffer: [4]u8 = undefined;
            const rendered = std.fmt.bufPrint(&buffer, "%{X:0>2}", .{character}) catch unreachable;
            try out.appendSlice(allocator, rendered);
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Read {"url_private_download": ...} straight off a message file object.
pub fn fileDownloadUrl(file: std.json.ObjectMap) []const u8 {
    return objectString(file, "url_private_download") orelse objectString(file, "url_private") orelse "";
}

/// Strip path separators and control characters from a remote file name and
/// cap the length, so remote names can never escape the media cache.
pub fn sanitizeFilename(dest: []u8, name: []const u8) []const u8 {
    var out_len: usize = 0;
    for (name) |character| {
        if (out_len >= dest.len) break;
        const safe = (character >= 'a' and character <= 'z') or
            (character >= 'A' and character <= 'Z') or
            (character >= '0' and character <= '9') or
            character == '.' or character == '-' or character == '_';
        dest[out_len] = if (safe) character else '_';
        out_len += 1;
    }
    return dest[0..out_len];
}

/// Exactly-once record for Socket Mode deliveries. Slack redelivers events
/// after reconnects; without this the same message lands twice.
pub const Log = struct {
    pub const entry_max_channel = 40;
    pub const entry_max_ts = 40;
    const Entry = struct {
        channel: [entry_max_channel]u8 = undefined,
        channel_len: u8 = 0,
        ts: [entry_max_ts]u8 = undefined,
        ts_len: u8 = 0,
    };
    const capacity = 512;

    entries: [capacity]Entry = [_]Entry{.{}} ** capacity,
    head: usize = 0,
    count: usize = 0,

    /// Returns true the first time a (channel, ts) pair is seen.
    pub fn mark(self: *Log, channel: []const u8, ts: []const u8) bool {
        if (channel.len == 0 or ts.len == 0 or channel.len > entry_max_channel or ts.len > entry_max_ts) return true;
        var index: usize = 0;
        while (index < self.count) : (index += 1) {
            const entry = &self.entries[(self.head + capacity - 1 - index) % capacity];
            if (entry.channel_len == channel.len and entry.ts_len == ts.len and
                std.mem.eql(u8, entry.channel[0..entry.channel_len], channel) and
                std.mem.eql(u8, entry.ts[0..entry.ts_len], ts)) return false;
        }
        const slot = &self.entries[self.head];
        self.head = (self.head + 1) % capacity;
        @memcpy(slot.channel[0..channel.len], channel);
        slot.channel_len = @intCast(channel.len);
        @memcpy(slot.ts[0..ts.len], ts);
        slot.ts_len = @intCast(ts.len);
        if (self.count < capacity) self.count += 1;
        return true;
    }
};

test "compareTs orders numerically, then by fraction" {
    try std.testing.expectEqual(std.math.Order.lt, compareTs("1740000000.000100", "1740000001.000000"));
    try std.testing.expectEqual(std.math.Order.lt, compareTs("1740000000.5", "1740000000.51"));
    try std.testing.expectEqual(std.math.Order.gt, compareTs("1740000000.5", "1740000000.05"));
    try std.testing.expectEqual(std.math.Order.eq, compareTs("1740000000.000123", "1740000000.000123"));
    try std.testing.expectEqual(std.math.Order.gt, compareTs("999", "20"));
}

test "classifyEnvelope reads ack, hello and message events" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ack = (try classifyEnvelope(arena.allocator(), "{\"envelope_id\":\"e.1\",\"payload\":{\"type\":\"events_api\"}}")).?;
    try std.testing.expectEqual(Kind.ack, ack.kind);
    try std.testing.expectEqualStrings("e.1", ack.envelope_id);
    const hello = (try classifyEnvelope(arena.allocator(), "{\"type\":\"hello\",\"num_connections\":1}")).?;
    try std.testing.expectEqual(Kind.hello, hello.kind);
    const text = "{\"type\":\"ignored\",\"payload\":{\"type\":\"events_api\",\"event\":{\"type\":\"message\",\"channel\":\"C123\",\"ts\":\"1740000000.000100\",\"user\":\"U1\",\"text\":\"hi \\\"there\\\"\",\"files\":[{\"id\":\"F1\",\"url_private_download\":\"https://files.slack.com/x\",\"mimetype\":\"image/png\",\"size\":10}]}}}";
    const event = (try classifyEnvelope(arena.allocator(), text)).?;
    try std.testing.expectEqual(Kind.events, event.kind);
    try std.testing.expectEqualStrings("C123", event.channel);
    try std.testing.expectEqualStrings("1740000000.000100", event.ts);
    try std.testing.expectEqualStrings("hi \"there\"", event.text);
    try std.testing.expectEqualStrings("F1", event.file_id);
    try std.testing.expectEqualStrings("https://files.slack.com/x", event.file_url);
}

test "classifyEnvelope unwraps edited messages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text = "{\"payload\":{\"type\":\"events_api\",\"event\":{\"type\":\"message\",\"subtype\":\"message_changed\",\"channel\":\"C1\",\"message\":{\"user\":\"U2\",\"ts\":\"7.1\",\"text\":\"edited\"}}}}";
    const event = (try classifyEnvelope(arena.allocator(), text)).?;
    try std.testing.expectEqualStrings("edited", event.text);
    try std.testing.expectEqualStrings("7.1", event.ts);
    try std.testing.expectEqualStrings("message_changed", event.subtype);
}

test "readHistoryItem filters noise and reads files" {
    const good = "{\"ts\":\"5.1\",\"user\":\"U1\",\"text\":\"a\",\"reply_count\":3,\"thread_ts\":\"5.1\",\"files\":[{\"id\":\"F9\",\"url_private\":\"https://f/priv\",\"name\":\"report.pdf\",\"mimetype\":\"application/pdf\",\"size\":4096}]}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, good, .{});
    defer parsed.deinit();
    const item = readHistoryItem(parsed.value).?;
    try std.testing.expectEqualStrings("5.1", item.ts);
    try std.testing.expectEqual(@as(i64, 3), item.reply_count);
    try std.testing.expectEqualStrings("https://f/priv", item.file_url);
    try std.testing.expectEqualStrings("report.pdf", item.file_name);

    const noise = "{\"ts\":\"5.2\",\"subtype\":\"channel_join\",\"user\":\"U1\"}";
    var parsed_noise = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, noise, .{});
    defer parsed_noise.deinit();
    try std.testing.expectEqual(@as(?HistoryItem, null), readHistoryItem(parsed_noise.value));

    const bot = "{\"ts\":\"5.3\",\"subtype\":\"bot_message\",\"text\":\"from bot\"}";
    var parsed_bot = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, bot, .{});
    defer parsed_bot.deinit();
    const bot_item = readHistoryItem(parsed_bot.value).?;
    try std.testing.expectEqualStrings("from bot", bot_item.text);
}

test "parseWsUrl extracts host and path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const url = parseWsUrl(arena.allocator(), "{\"ok\":true,\"url\":\"wss://wss-primary.slack.com/link/?ticket=abc&app_id=A1\"}").?;
    try std.testing.expectEqualStrings("wss-primary.slack.com", url.host);
    try std.testing.expectEqualStrings("/link/?ticket=abc&app_id=A1", url.path_query);
    try std.testing.expectEqual(@as(?WsEndpoint, null), parseWsUrl(arena.allocator(), "{\"ok\":false,\"error\":\"invalid_auth\"}"));
}

test "parseRetryAfter reads the header" {
    try std.testing.expectEqual(@as(?u64, 30), parseRetryAfter("HTTP/1.1 429 Too Many Requests\r\nRetry-After: 30\r\n\r\n"));
    try std.testing.expectEqual(@as(?u64, null), parseRetryAfter("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"));
}

test "escapeJson escapes quotes and control characters" {
    const out = try escapeJson(std.testing.allocator, "a\"b\\c\nd\te\x01");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("a\\\"b\\\\c\\nd\\te\\u0001", out);
}

test "request bodies carry channel, text and thread_ts" {
    const plain = try buildPostMessageBody(std.testing.allocator, .{ .channel_id = "C1", .text = "hi" });
    defer std.testing.allocator.free(plain);
    try std.testing.expectEqualStrings("{\"channel\":\"C1\",\"text\":\"hi\"}", plain);
    const threaded = try buildPostMessageBody(std.testing.allocator, .{ .channel_id = "C1", .text = "a\"b", .thread_ts = "5.1" });
    defer std.testing.allocator.free(threaded);
    try std.testing.expectEqualStrings("{\"channel\":\"C1\",\"text\":\"a\\\"b\",\"thread_ts\":\"5.1\"}", threaded);
    const upload = try buildCompleteUploadBody(std.testing.allocator, "F1", "C1", "", "");
    defer std.testing.allocator.free(upload);
    try std.testing.expectEqualStrings("{\"files\":[{\"id\":\"F1\"}],\"channel_id\":\"C1\"}", upload);
    const upload_caption = try buildCompleteUploadBody(std.testing.allocator, "F1", "C1", "5.1", "see \"this\"");
    defer std.testing.allocator.free(upload_caption);
    try std.testing.expectEqualStrings("{\"files\":[{\"id\":\"F1\"}],\"channel_id\":\"C1\",\"thread_ts\":\"5.1\",\"initial_comment\":\"see \\\"this\\\"\"}", upload_caption);
    const encoded = try percentEncode(std.testing.allocator, "a+b/c=d");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("a%2Bb%2Fc%3Dd", encoded);
}

test "sanitizeFilename strips separators and traversal" {
    var buffer: [64]u8 = undefined;
    const clean = sanitizeFilename(&buffer, "..\\..\\evil/../invoice #2.pdf");
    try std.testing.expect(std.mem.indexOfScalar(u8, clean, '/') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, clean, '\\') == null);
    try std.testing.expectEqualStrings(".._.._evil_.._invoice__2.pdf", clean);
}

test "Log is exactly-once per channel and ts" {
    var log = Log{};
    try std.testing.expect(log.mark("C1", "5.1"));
    try std.testing.expect(!log.mark("C1", "5.1"));
    try std.testing.expect(log.mark("C1", "5.2"));
    try std.testing.expect(log.mark("C2", "5.1"));
    // The ring forgets the oldest entry once full.
    var buffer: [16]u8 = undefined;
    var index: usize = 0;
    while (index < Log.capacity) : (index += 1) {
        const key = std.fmt.bufPrint(&buffer, "{d}", .{index}) catch unreachable;
        _ = log.mark("K", key);
    }
    try std.testing.expect(log.mark("C1", "5.1"));
}
