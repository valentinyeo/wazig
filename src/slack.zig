// Slack provider core: pure helpers over Slack Web API / Socket Mode JSON.
// No Windows calls here, so the unit tests run on the CI host. The WinHTTP
// transport and token storage live in slack_win.zig (Windows only).
const std = @import("std");

pub const max_text = 4095;

pub const Provider = enum(u8) { whatsapp = 0, slack = 1 };
pub const max_channel_id = 31;
pub const max_user_id = 31;

/// A new message resurfaces an archived chat (WAZI-62): the chat comes back
/// unless the message is my own. A chat missing from the current list counts
/// as archived, because the inbox read filters archived chats out.
pub fn resurfacesChat(from_me: bool, visible: bool, archived: bool) bool {
    return !from_me and (!visible or archived);
}

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
    client_msg_id: []const u8 = "",
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
    envelope.client_msg_id = objectString(event, "client_msg_id") orelse "";
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

/// Whole unix seconds of a Slack ts ("1740000000.000123"), or null when the
/// value is empty, malformed or out of range.
pub fn tsSeconds(ts: []const u8) ?i64 {
    const dot = std.mem.indexOfScalar(u8, ts, '.') orelse ts.len;
    const seconds = std.fmt.parseInt(i64, ts[0..dot], 10) catch return null;
    if (seconds <= 0 or seconds > 100_000_000_000) return null;
    return seconds;
}

fn numberField(object: std.json.ObjectMap, key: []const u8) ?i64 {
    return switch (object.get(key) orelse return null) {
        .integer => |value| value,
        .float => |value| if (value >= 0 and value < 1e15) @intFromFloat(value) else null,
        .number_string, .string => |text| std.fmt.parseInt(i64, text, 10) catch null,
        else => null,
    };
}

/// Best recency for a conversations.list entry, in unix seconds: the newest
/// message (`latest.ts`) when the listing carries it, else `updated` (ms),
/// else `created` (seconds). 0 when none is usable.
pub fn conversationSeconds(object: std.json.ObjectMap) i64 {
    if (object.get("latest")) |latest| switch (latest) {
        .object => |latest_object| if (tsSeconds(objectStringField(latest_object, "ts"))) |seconds| return seconds,
        else => {},
    };
    if (numberField(object, "updated")) |updated| {
        // Slack sends `updated` in milliseconds; tolerate a seconds value.
        const seconds = if (updated > 100_000_000_000) @divTrunc(updated, 1000) else updated;
        if (seconds > 0) return seconds;
    }
    if (numberField(object, "created")) |created| if (created > 0) return created;
    return 0;
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
    // A shared/forwarded message ("is_share"/"is_msg_unfurl") renders as a
    // quote block above the body.
    share_sender: []const u8 = "",
    share_text: []const u8 = "",
    // A link unfurl (or other attachment) fills in for an empty body.
    link_title: []const u8 = "",
    link_text: []const u8 = "",
    link_fallback: []const u8 = "",
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
                item.file_name = objectString(file, "name") orelse objectString(file, "title") orelse "";
                item.file_mime = objectString(file, "mimetype") orelse "";
                item.file_size = switch (file.get("size") orelse std.json.Value{ .integer = 0 }) {
                    .integer => |size| size,
                    else => 0,
                };
            }
        }
    }
    // Slack messages with empty `text` and an `attachments` array are either
    // a shared/forwarded message (quote block) or a link unfurl (fills the
    // body). A message can carry several attachments; take the first share
    // and the first attachment with any content, whichever comes first of
    // each kind, so a body with any text never renders blank.
    if (object.get("attachments")) |attachments_value| {
        if (attachments_value == .array) {
            for (attachments_value.array.items) |attachment_value| {
                if (attachment_value != .object) continue;
                const attachment = attachment_value.object;
                if (boolField(attachment, "is_share") or boolField(attachment, "is_msg_unfurl")) {
                    if (item.share_text.len > 0 or item.share_sender.len > 0) continue;
                    item.share_sender = objectStringField(attachment, "author_name");
                    const text = objectStringField(attachment, "text");
                    item.share_text = if (text.len > 0) text else objectStringField(attachment, "fallback");
                } else {
                    if (item.link_title.len > 0 or item.link_text.len > 0 or item.link_fallback.len > 0) continue;
                    const title = objectStringField(attachment, "title");
                    const text = objectStringField(attachment, "text");
                    const fallback = objectStringField(attachment, "fallback");
                    if (title.len == 0 and text.len == 0 and fallback.len == 0) continue;
                    item.link_title = title;
                    item.link_text = text;
                    item.link_fallback = fallback;
                }
            }
        }
    }
    return item;
}

fn boolField(object: std.json.ObjectMap, key: []const u8) bool {
    return switch (object.get(key) orelse return false) {
        .bool => |value| value,
        else => false,
    };
}

/// The message body Wazig shows: the message's own text, else the shared
/// file's name, else a compact line built from a link-unfurl/other
/// attachment. Never blank when the item carries any recoverable text.
pub fn historyItemBody(item: HistoryItem, buffer: []u8) []const u8 {
    if (item.text.len > 0) return item.text;
    if (item.file_name.len > 0) return item.file_name;
    if (item.link_title.len > 0 or item.link_text.len > 0 or item.link_fallback.len > 0)
        return attachmentSummary(buffer, item.link_title, item.link_text, item.link_fallback);
    return "";
}

/// Compact one-line summary for a link-unfurl/other attachment, used only
/// when the message's own text is empty. Prefers "title: text", falls back
/// to whichever half is present, then to Slack's plain-text fallback. Writes
/// into `buffer` and returns the slice actually used; truncates rather than
/// dropping content when the combined text overflows the buffer, and never
/// splits a multi-byte UTF-8 character at the cut point.
pub fn attachmentSummary(buffer: []u8, title: []const u8, text: []const u8, fallback: []const u8) []const u8 {
    if (buffer.len == 0) return "";
    if (title.len > 0 and text.len > 0) {
        const separator = ": ";
        if (title.len + separator.len < buffer.len) {
            const title_end = utf8Boundary(title, title.len);
            @memcpy(buffer[0..title_end], title[0..title_end]);
            var offset = title_end;
            @memcpy(buffer[offset..][0..separator.len], separator);
            offset += separator.len;
            const remaining = buffer.len - offset;
            const text_end = utf8Boundary(text, remaining);
            @memcpy(buffer[offset..][0..text_end], text[0..text_end]);
            return buffer[0 .. offset + text_end];
        }
        // Not enough room for the separator: show what fits of the title alone.
        return truncateInto(buffer, title);
    }
    if (title.len > 0) return truncateInto(buffer, title);
    if (text.len > 0) return truncateInto(buffer, text);
    return truncateInto(buffer, fallback);
}

/// The largest n <= max such that text[0..n] does not split a multi-byte
/// UTF-8 character (a continuation byte, 0b10xxxxxx, never starts a rune).
fn utf8Boundary(text: []const u8, max: usize) usize {
    var n = @min(max, text.len);
    while (n > 0 and n < text.len and (text[n] & 0xC0) == 0x80) n -= 1;
    return n;
}

fn truncateInto(buffer: []u8, text: []const u8) []const u8 {
    const n = utf8Boundary(text, buffer.len);
    @memcpy(buffer[0..n], text[0..n]);
    return buffer[0..n];
}

/// A callback for resolving a Slack user id ("U123") to a display name, used
/// by `convertMrkdwn` for `<@U123>` mentions. A plain function pointer can't
/// close over the caller's user list, so the caller (the app, which owns the
/// user table) is passed through as an opaque context.
pub const UserLookup = struct {
    context: *anyopaque,
    lookupFn: *const fn (context: *anyopaque, user_id: []const u8) ?[]const u8,

    pub fn find(self: UserLookup, user_id: []const u8) ?[]const u8 {
        return self.lookupFn(self.context, user_id);
    }
};

/// Convert raw Slack mrkdwn markup to the plain display text Wazig shows in
/// a message bubble:
///   `<url|label>`      -> the url (Wazig's link detection only recognizes
///                         visible URL text, so the label is dropped in
///                         favor of keeping the link clickable)
///   `<url>`             -> the url, unchanged
///   `<@U123>`           -> `@<name>`, resolved through `users`; falls back
///   `<@U123|name>`         to `@<given name>`, then to the raw id
///   `<#C123|name>`      -> `#<name>`
///   `<!here>` etc.      -> `@here` / `@channel` / `@everyone`
///   `<!subteam^ID|@g>`  -> `@g`
///   `<!date^...|text>`  -> `text` (the fallback)
/// HTML entities (`&amp;` `&lt;` `&gt;`) are decoded in a second pass, after
/// the angle-bracket markup is resolved, so a literal `&lt;` in the source
/// text can never be mistaken for the start of markup. Writes into `buffer`
/// and returns the slice used; truncates rather than splitting a multi-byte
/// UTF-8 character when the result does not fit.
pub fn convertMrkdwn(buffer: []u8, text: []const u8, users: ?UserLookup) []const u8 {
    var stage1: [max_text + 1]u8 = undefined;
    var stage1_len: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '<') {
            if (std.mem.indexOfScalarPos(u8, text, index, '>')) |close| {
                const token = text[index + 1 .. close];
                var token_buffer: [max_text + 1]u8 = undefined;
                const rendered = renderMrkdwnToken(&token_buffer, token, users);
                stage1_len = appendClamped(&stage1, stage1_len, rendered);
                index = close + 1;
                continue;
            }
        }
        const rune_len = @min(utf8RuneLen(text[index]), text.len - index);
        stage1_len = appendClamped(&stage1, stage1_len, text[index..][0..rune_len]);
        index += rune_len;
    }
    return decodeHtmlEntities(buffer, stage1[0..stage1_len]);
}

/// Render the content of a single `<...>` Slack markup token (excluding the
/// angle brackets). Unrecognized or malformed tokens pass through as their
/// raw content so nothing silently disappears.
fn renderMrkdwnToken(dest: []u8, token: []const u8, users: ?UserLookup) []const u8 {
    if (token.len == 0) return copyClamped(dest, "<>");
    switch (token[0]) {
        '@' => {
            const rest = token[1..];
            const pipe = std.mem.indexOfScalar(u8, rest, '|');
            const user_id = if (pipe) |p| rest[0..p] else rest;
            const given_name = if (pipe) |p| rest[p + 1 ..] else null;
            if (users) |lookup| {
                if (lookup.find(user_id)) |resolved_name| return copyClampedPrefixed(dest, "@", resolved_name);
            }
            if (given_name) |name| return copyClampedPrefixed(dest, "@", name);
            return copyClamped(dest, user_id);
        },
        '#' => {
            const rest = token[1..];
            const pipe = std.mem.indexOfScalar(u8, rest, '|');
            const shown = if (pipe) |p| rest[p + 1 ..] else rest;
            return copyClampedPrefixed(dest, "#", shown);
        },
        '!' => {
            const rest = token[1..];
            const pipe = std.mem.indexOfScalar(u8, rest, '|');
            const kind = if (pipe) |p| rest[0..p] else rest;
            const label = if (pipe) |p| rest[p + 1 ..] else null;
            if (std.mem.eql(u8, kind, "here")) return copyClamped(dest, "@here");
            if (std.mem.eql(u8, kind, "channel")) return copyClamped(dest, "@channel");
            if (std.mem.eql(u8, kind, "everyone")) return copyClamped(dest, "@everyone");
            if (label) |l| return copyClamped(dest, l);
            return copyClamped(dest, kind);
        },
        else => {
            const pipe = std.mem.indexOfScalar(u8, token, '|');
            const url = if (pipe) |p| token[0..p] else token;
            return copyClamped(dest, url);
        },
    }
}

/// The byte length of the UTF-8 rune starting at `byte`. Falls back to 1 for
/// an invalid lead byte so callers always make forward progress.
fn utf8RuneLen(byte: u8) usize {
    if (byte & 0x80 == 0) return 1;
    if (byte & 0xE0 == 0xC0) return 2;
    if (byte & 0xF0 == 0xE0) return 3;
    if (byte & 0xF8 == 0xF0) return 4;
    return 1;
}

fn copyClamped(dest: []u8, text: []const u8) []const u8 {
    const n = utf8Boundary(text, @min(text.len, dest.len));
    @memcpy(dest[0..n], text[0..n]);
    return dest[0..n];
}

fn copyClampedPrefixed(dest: []u8, prefix: []const u8, text: []const u8) []const u8 {
    if (prefix.len >= dest.len) return copyClamped(dest, prefix);
    @memcpy(dest[0..prefix.len], prefix);
    const remaining = dest[prefix.len..];
    const n = utf8Boundary(text, @min(text.len, remaining.len));
    @memcpy(remaining[0..n], text[0..n]);
    return dest[0 .. prefix.len + n];
}

/// Append as much of `text` as fits after `dest[0..dest_len]`, without
/// splitting a multi-byte UTF-8 character, and return the new length.
fn appendClamped(dest: []u8, dest_len: usize, text: []const u8) usize {
    if (dest_len >= dest.len) return dest_len;
    const remaining = dest.len - dest_len;
    const n = utf8Boundary(text, @min(text.len, remaining));
    @memcpy(dest[dest_len..][0..n], text[0..n]);
    return dest_len + n;
}

fn decodeHtmlEntities(buffer: []u8, text: []const u8) []const u8 {
    var out_len: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (std.mem.startsWith(u8, text[index..], "&amp;")) {
            out_len = appendClamped(buffer, out_len, "&");
            index += 5;
            continue;
        }
        if (std.mem.startsWith(u8, text[index..], "&lt;")) {
            out_len = appendClamped(buffer, out_len, "<");
            index += 4;
            continue;
        }
        if (std.mem.startsWith(u8, text[index..], "&gt;")) {
            out_len = appendClamped(buffer, out_len, ">");
            index += 4;
            continue;
        }
        const rune_len = @min(utf8RuneLen(text[index]), text.len - index);
        out_len = appendClamped(buffer, out_len, text[index..][0..rune_len]);
        index += rune_len;
    }
    return buffer[0..out_len];
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
    // WAZI-61: correlates our optimistic bubble with Slack's echo.
    client_msg_id: []const u8 = "",
};

pub fn buildPostMessageBody(allocator: std.mem.Allocator, reply: ReplyTo) ![]u8 {
    const escaped = try escapeJson(allocator, reply.text);
    defer allocator.free(escaped);
    if (reply.thread_ts.len == 0 and reply.client_msg_id.len == 0) {
        return std.fmt.allocPrint(allocator, "{{\"channel\":\"{s}\",\"text\":\"{s}\"}}", .{ reply.channel_id, escaped });
    }
    if (reply.thread_ts.len == 0) {
        return std.fmt.allocPrint(allocator, "{{\"channel\":\"{s}\",\"text\":\"{s}\",\"client_msg_id\":\"{s}\"}}", .{ reply.channel_id, escaped, reply.client_msg_id });
    }
    if (reply.client_msg_id.len == 0) {
        return std.fmt.allocPrint(allocator, "{{\"channel\":\"{s}\",\"text\":\"{s}\",\"thread_ts\":\"{s}\"}}", .{ reply.channel_id, escaped, reply.thread_ts });
    }
    return std.fmt.allocPrint(allocator, "{{\"channel\":\"{s}\",\"text\":\"{s}\",\"thread_ts\":\"{s}\",\"client_msg_id\":\"{s}\"}}", .{ reply.channel_id, escaped, reply.thread_ts, reply.client_msg_id });
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

/// Copy the message ts out of a chat.postMessage response body, so the
/// optimistic bubble can adopt Slack's authoritative timestamp. Returns a
/// heap slice; null when the body has no usable ts.
pub fn parseSentTs(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{}) catch return null;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return null,
    };
    const ts = switch (root.get("ts") orelse return null) {
        .string => |text| text,
        else => return null,
    };
    if (ts.len == 0 or ts.len > 40) return null;
    return allocator.dupe(u8, ts) catch null;
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

/// True when the host is slack.com itself or a subdomain of slack.com or
/// slack-edge.com. The leading dot is required, so "evilslack.com" fails.
pub fn isSlackFileHost(host: []const u8) bool {
    if (std.mem.eql(u8, host, "slack.com")) return true;
    if (std.mem.endsWith(u8, host, ".slack.com")) return true;
    if (std.mem.endsWith(u8, host, ".slack-edge.com")) return true;
    return false;
}

/// A bridge host is a bare lowercase hostname: letters, digits, dots and
/// hyphens only. No scheme, path, port, credentials or spaces.
pub fn isValidBridgeHost(host: []const u8) bool {
    if (host.len == 0) return false;
    for (host) |character| {
        const valid = (character >= 'a' and character <= 'z') or
            (character >= '0' and character <= '9') or
            character == '.' or character == '-';
        if (!valid) return false;
    }
    return true;
}

/// A bridge key is copied straight into an Authorization header, so it must be
/// printable ASCII with no space, CR or LF that could smuggle in new headers.
pub fn isValidBridgeKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |character| {
        if (character < 0x20 or character > 0x7E) return false;
        if (character == ' ') return false;
    }
    return true;
}

/// Build the local bridge file path ("/file?url=<encoded>") for an original
/// Slack file URL, percent-encoding the URL as a query value.
pub fn bridgeFilePath(allocator: std.mem.Allocator, original_url: []const u8) ![]u8 {
    const encoded = try percentEncode(allocator, original_url);
    defer allocator.free(encoded);
    return std.fmt.allocPrint(allocator, "/file?url={s}", .{encoded});
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

/// One conversations.list entry, borrowed from the parsed JSON. DMs carry
/// the other person's user id instead of a name; the caller maps it.
pub const WorkspaceChannel = struct {
    id: []const u8,
    name: []const u8,
    user: []const u8,
    is_im: bool,
    seconds: i64,
};

/// Read one conversations.list entry; null when it has no id, or when it is
/// a channel the user has not joined. Unjoined public channels are most of a
/// large workspace; listing them used to fill the chat table before the DMs,
/// which Slack returns last, ever got a slot.
pub fn workspaceChannel(object: std.json.ObjectMap) ?WorkspaceChannel {
    const id = objectStringField(object, "id");
    if (id.len == 0) return null;
    if (id[0] != 'D') {
        if (object.get("is_member")) |member| switch (member) {
            .bool => |joined| if (!joined) return null,
            else => {},
        };
    }
    return .{
        .id = id,
        .name = objectStringField(object, "name"),
        .user = objectStringField(object, "user"),
        .is_im = id[0] == 'D',
        .seconds = conversationSeconds(object),
    };
}

/// response_metadata.next_cursor, or "" on the last page.
pub fn nextCursor(root: std.json.ObjectMap) []const u8 {
    const metadata = switch (root.get("response_metadata") orelse return "") {
        .object => |object| object,
        else => return "",
    };
    return objectStringField(metadata, "next_cursor");
}

/// Hard stop for list pagination, so a server that keeps returning a cursor
/// can never loop forever (50 pages of 200 is 10,000 entries).
pub const max_list_pages = 50;

/// Fetch another page only when the cursor fits a job argument and the page
/// cap is not reached.
pub fn wantsNextPage(cursor: []const u8, pages_done: u32, max_cursor_len: usize) bool {
    return cursor.len > 0 and cursor.len <= max_cursor_len and pages_done < max_list_pages;
}

/// Launch-log lines from the minute poll repeat at most once per 10 minutes
/// per job kind, and at once when what they say changes (another error, a
/// different chat count), so the poll cannot flood the log.
pub const log_repeat_interval_ms: u64 = 10 * 60 * 1000;

pub fn logDue(last_logged_ms: u64, last_hash: u64, now_ms: u64, hash: u64) bool {
    if (last_logged_ms == 0 or hash != last_hash) return true;
    return now_ms -| last_logged_ms >= log_repeat_interval_ms;
}

/// "slack: workspace failed: NetworkFailed (HTTP 200)". Only the job kind,
/// the error name and the status: never a token or message text.
pub fn formatJobFailure(buffer: []u8, kind: []const u8, error_name: []const u8, http_status: u32) []const u8 {
    if (http_status == 0) return std.fmt.bufPrint(buffer, "slack: {s} failed: {s}", .{ kind, error_name }) catch "slack: job failed";
    return std.fmt.bufPrint(buffer, "slack: {s} failed: {s} (HTTP {d})", .{ kind, error_name, http_status }) catch "slack: job failed";
}

test "compareTs orders numerically, then by fraction" {
    try std.testing.expectEqual(std.math.Order.lt, compareTs("1740000000.000100", "1740000001.000000"));
    try std.testing.expectEqual(std.math.Order.lt, compareTs("1740000000.5", "1740000000.51"));
    try std.testing.expectEqual(std.math.Order.gt, compareTs("1740000000.5", "1740000000.05"));
    try std.testing.expectEqual(std.math.Order.eq, compareTs("1740000000.000123", "1740000000.000123"));
    try std.testing.expectEqual(std.math.Order.gt, compareTs("999", "20"));
}

test "resurfacesChat pulls archived chats back except for my own messages" {
    try std.testing.expect(resurfacesChat(false, false, false));
    try std.testing.expect(resurfacesChat(false, true, true));
    try std.testing.expect(!resurfacesChat(false, true, false));
    try std.testing.expect(!resurfacesChat(true, false, false));
    try std.testing.expect(!resurfacesChat(true, true, true));
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

test "readHistoryItem reads a shared/forwarded message as a quote" {
    const shared =
        \\{"ts":"5.4","user":"U1","text":"","attachments":[{"is_share":true,"is_msg_unfurl":true,"author_name":"Jane","fallback":"Jane: hi there","from_url":"https://x.slack.com/archives/C1/p1","text":"hi there, this is the shared body"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, shared, .{});
    defer parsed.deinit();
    const item = readHistoryItem(parsed.value).?;
    try std.testing.expectEqualStrings("", item.text);
    try std.testing.expectEqualStrings("Jane", item.share_sender);
    try std.testing.expectEqualStrings("hi there, this is the shared body", item.share_text);
    try std.testing.expectEqualStrings("", item.link_title);
}

test "readHistoryItem falls back to attachment fallback when text is empty" {
    const shared =
        \\{"ts":"5.5","user":"U1","text":"","attachments":[{"is_share":true,"author_name":"Jane","fallback":"Jane: hi there","text":""}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, shared, .{});
    defer parsed.deinit();
    const item = readHistoryItem(parsed.value).?;
    try std.testing.expectEqualStrings("Jane: hi there", item.share_text);
}

test "readHistoryItem reads a link unfurl attachment" {
    const unfurl =
        \\{"ts":"5.6","user":"U1","text":"","attachments":[{"title":"Example Page","title_link":"https://example.com","text":"A short description","service_name":"example.com","image_url":"https://example.com/img.png","fallback":"Example Page"}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, unfurl, .{});
    defer parsed.deinit();
    const item = readHistoryItem(parsed.value).?;
    try std.testing.expectEqualStrings("", item.share_sender);
    try std.testing.expectEqualStrings("Example Page", item.link_title);
    try std.testing.expectEqualStrings("A short description", item.link_text);
    try std.testing.expectEqualStrings("Example Page", item.link_fallback);
}

test "attachmentSummary builds a compact line, falling back as needed" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("Example Page: A short description", attachmentSummary(&buffer, "Example Page", "A short description", "Example Page"));
    try std.testing.expectEqualStrings("Example Page", attachmentSummary(&buffer, "Example Page", "", "fallback text"));
    try std.testing.expectEqualStrings("A short description", attachmentSummary(&buffer, "", "A short description", "fallback text"));
    try std.testing.expectEqualStrings("fallback text", attachmentSummary(&buffer, "", "", "fallback text"));
    try std.testing.expectEqualStrings("", attachmentSummary(&buffer, "", "", ""));
}

test "attachmentSummary truncates instead of splitting a multi-byte character" {
    // "caf" + e-acute (2 bytes) landing right at the buffer's last byte: a
    // byte-count cut would keep only the lead byte of the accented e and
    // produce invalid UTF-8.
    var buffer: [4]u8 = undefined;
    const out = attachmentSummary(&buffer, "", "caf\u{e9}", "fallback");
    try std.testing.expect(std.unicode.utf8ValidateSlice(out));
    try std.testing.expectEqualStrings("caf", out);

    // The combined "title: text" overflows the buffer: truncate the whole
    // thing rather than discarding it for the fallback.
    var small: [10]u8 = undefined;
    const combined = attachmentSummary(&small, "Title", "a whole lot of text that will not fit", "fallback");
    try std.testing.expect(std.unicode.utf8ValidateSlice(combined));
    try std.testing.expectEqualStrings("Title: a w", combined);
}

test "historyItemBody falls back from text to file name to attachment summary" {
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("hi", historyItemBody(.{ .text = "hi", .file_name = "report.pdf" }, &buffer));
    try std.testing.expectEqualStrings("report.pdf", historyItemBody(.{ .file_name = "report.pdf" }, &buffer));
    try std.testing.expectEqualStrings("Example Page: A short description", historyItemBody(.{ .link_title = "Example Page", .link_text = "A short description" }, &buffer));
    try std.testing.expectEqualStrings("", historyItemBody(.{}, &buffer));
}

const TestUser = struct { id: []const u8, name: []const u8 };

fn testUserLookup(context: *anyopaque, user_id: []const u8) ?[]const u8 {
    const table: *const [1]TestUser = @ptrCast(@alignCast(context));
    for (table) |entry| {
        if (std.mem.eql(u8, entry.id, user_id)) return entry.name;
    }
    return null;
}

test "convertMrkdwn shows the url instead of the label, since links are detected from visible url text" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://www.tempdrop.com/",
        convertMrkdwn(&buffer, "<https://www.tempdrop.com/|tempdrop.com>", null),
    );
    try std.testing.expectEqualStrings(
        "New device: https://www.tempdrop.com/",
        convertMrkdwn(&buffer, "New device: <https://www.tempdrop.com/|tempdrop.com>", null),
    );
}

test "convertMrkdwn keeps a bare url" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://www.linkedin.com/posts/x?utm_source=share&utm_medium=member_desktop&rcm=y",
        convertMrkdwn(&buffer, "<https://www.linkedin.com/posts/x?utm_source=share&amp;utm_medium=member_desktop&amp;rcm=y>", null),
    );
}

test "convertMrkdwn resolves a user mention, falls back to the given name, then the raw id" {
    var buffer: [256]u8 = undefined;
    var table = [1]TestUser{.{ .id = "U4A59H6UT", .name = "Jane Doe" }};
    const lookup = UserLookup{ .context = @ptrCast(&table), .lookupFn = testUserLookup };
    try std.testing.expectEqualStrings(
        "@Jane Doe this guy finally finished...",
        convertMrkdwn(&buffer, "<@U4A59H6UT> this guy finally finished...", lookup),
    );
    try std.testing.expectEqualStrings("@Bob", convertMrkdwn(&buffer, "<@U999|Bob>", lookup));
    try std.testing.expectEqualStrings("U999", convertMrkdwn(&buffer, "<@U999>", lookup));
    try std.testing.expectEqualStrings("U999", convertMrkdwn(&buffer, "<@U999>", null));
}

test "convertMrkdwn converts channel mentions, special mentions and subteam/date tokens" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("#general", convertMrkdwn(&buffer, "<#C123|general>", null));
    try std.testing.expectEqualStrings("@here", convertMrkdwn(&buffer, "<!here>", null));
    try std.testing.expectEqualStrings("@channel", convertMrkdwn(&buffer, "<!channel>", null));
    try std.testing.expectEqualStrings("@everyone", convertMrkdwn(&buffer, "<!everyone>", null));
    try std.testing.expectEqualStrings("@dev-team", convertMrkdwn(&buffer, "<!subteam^S123|@dev-team>", null));
    try std.testing.expectEqualStrings("Feb 18th, 2014", convertMrkdwn(&buffer, "<!date^1392734382^{date}|Feb 18th, 2014>", null));
    // Slack's older clients send a label alongside here/channel/everyone too.
    try std.testing.expectEqualStrings("@here", convertMrkdwn(&buffer, "<!here|here>", null));
    try std.testing.expectEqualStrings("@channel", convertMrkdwn(&buffer, "<!channel|channel>", null));
}

test "convertMrkdwn never truncates within the app's max message length" {
    var buffer: [max_text + 1]u8 = undefined;
    var long_text: [2000]u8 = undefined;
    @memset(&long_text, 'a');
    const result = convertMrkdwn(&buffer, &long_text, null);
    try std.testing.expectEqual(@as(usize, 2000), result.len);
    try std.testing.expect(std.mem.allEqual(u8, result, 'a'));
}

test "convertMrkdwn decodes html entities only after angle-bracket markup is resolved" {
    var buffer: [256]u8 = undefined;
    // An escaped `&lt;` must never turn into a live `<...>` token.
    try std.testing.expectEqualStrings("<@U1> is not a mention", convertMrkdwn(&buffer, "&lt;@U1&gt; is not a mention", null));
    try std.testing.expectEqualStrings("Tom & Jerry", convertMrkdwn(&buffer, "Tom &amp; Jerry", null));
}

test "convertMrkdwn leaves bold, italic and code markers alone" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqualStrings("*bold* _italic_ `code`", convertMrkdwn(&buffer, "*bold* _italic_ `code`", null));
}

test "readHistoryItem reads a file with no text as the body via its name" {
    const files_only =
        \\{"ts":"5.7","user":"U1","text":"","files":[{"id":"F1","url_private":"https://f/priv","name":"report.pdf","mimetype":"application/pdf","size":10}]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, files_only, .{});
    defer parsed.deinit();
    const item = readHistoryItem(parsed.value).?;
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("report.pdf", historyItemBody(item, &buffer));
}

test "readHistoryItem picks the first attachment of each kind out of several" {
    const mixed =
        \\{"ts":"5.8","user":"U1","text":"","attachments":[
        \\{"title":"","text":"","fallback":""},
        \\{"is_share":true,"author_name":"Jane","text":"shared body"},
        \\{"title":"Second link","text":"ignored, not first"}
        \\]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, mixed, .{});
    defer parsed.deinit();
    const item = readHistoryItem(parsed.value).?;
    try std.testing.expectEqualStrings("Jane", item.share_sender);
    try std.testing.expectEqualStrings("shared body", item.share_text);
    try std.testing.expectEqualStrings("Second link", item.link_title);
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

test "parseSentTs extracts the message timestamp" {
    const allocator = std.testing.allocator;
    const ts = parseSentTs(allocator, "{\"ok\":true,\"channel\":\"C1\",\"ts\":\"1757000000.000300\"}") orelse return error.TestUnexpectedResult;
    defer allocator.free(ts);
    try std.testing.expectEqualStrings("1757000000.000300", ts);
    try std.testing.expect(parseSentTs(allocator, "{\"ok\":false,\"error\":\"rate_limited\"}") == null);
    try std.testing.expect(parseSentTs(allocator, "not json") == null);
}

test "postMessage body carries client_msg_id when set" {
    const allocator = std.testing.allocator;
    const with_id = try buildPostMessageBody(allocator, .{ .channel_id = "C1", .text = "hi", .thread_ts = "", .client_msg_id = "wz1-2" });
    defer allocator.free(with_id);
    try std.testing.expectEqualStrings("{\"channel\":\"C1\",\"text\":\"hi\",\"client_msg_id\":\"wz1-2\"}", with_id);
}

test "isSlackFileHost matches only slack file hosts" {
    try std.testing.expect(isSlackFileHost("slack.com"));
    try std.testing.expect(isSlackFileHost("files.slack.com"));
    try std.testing.expect(isSlackFileHost("cdn.slack-edge.com"));
    try std.testing.expect(!isSlackFileHost("evilslack.com"));
    try std.testing.expect(!isSlackFileHost("slack.com.evil.com"));
    try std.testing.expect(!isSlackFileHost(""));
}

test "isValidBridgeHost accepts bare hostnames only" {
    try std.testing.expect(isValidBridgeHost("slack-bridge.crolab.org"));
    try std.testing.expect(!isValidBridgeHost("https://x.com"));
    try std.testing.expect(!isValidBridgeHost("a b"));
    try std.testing.expect(!isValidBridgeHost("a:1"));
    try std.testing.expect(!isValidBridgeHost("a/b"));
    try std.testing.expect(!isValidBridgeHost(""));
}

test "isValidBridgeKey rejects header injection" {
    try std.testing.expect(isValidBridgeKey("xoxb-1234567890-abcDEF"));
    try std.testing.expect(!isValidBridgeKey("token\ninjected"));
    try std.testing.expect(!isValidBridgeKey("token value"));
    try std.testing.expect(!isValidBridgeKey(""));
}

test "bridgeFilePath percent-encodes the original url" {
    const allocator = std.testing.allocator;
    const path = try bridgeFilePath(allocator, "https://files.slack.com/x?y=1");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/file?url=https%3A%2F%2Ffiles.slack.com%2Fx%3Fy%3D1", path);
}

test "conversationSeconds prefers latest.ts, then updated ms, then created" {
    const cases = [_]struct { json: []const u8, want: i64 }{
        .{ .json = "{\"latest\":{\"ts\":\"1740000500.000100\"},\"updated\":1740000000123,\"created\":1600000000}", .want = 1740000500 },
        .{ .json = "{\"updated\":1740000000123,\"created\":1600000000}", .want = 1740000000 },
        .{ .json = "{\"latest\":null,\"created\":1600000000}", .want = 1600000000 },
        .{ .json = "{\"updated\":1740000000}", .want = 1740000000 },
        .{ .json = "{\"id\":\"D1\"}", .want = 0 },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(case.want, conversationSeconds(parsed.value.object));
    }
}

test "tsSeconds rejects empty and malformed ts" {
    try std.testing.expectEqual(@as(?i64, 1740000000), tsSeconds("1740000000.000123"));
    try std.testing.expectEqual(@as(?i64, null), tsSeconds(""));
    try std.testing.expectEqual(@as(?i64, null), tsSeconds("abc.1"));
}

// Shaped like a real conversations.list page: channels with names, a DM with
// only a user id, an entry without an id, and a next_cursor.
const workspace_fixture =
    \\{"ok":true,"channels":[
    \\{"id":"C0001","name":"general","is_channel":true,"is_im":false,"created":1700000000,"updated":1750000000123,"purpose":{"value":"x"}},
    \\{"id":"G0002","name":"private-team","is_group":true,"created":1700000001},
    \\{"id":"D0003","is_im":true,"user":"U0042","created":1700000002},
    \\{"name":"no-id"}
    \\],"warning":"superfluous_charset","response_metadata":{"next_cursor":"dGVhbTpDMDYxRkE1UEI="}}
;

test "workspace page yields every channel with an id, DMs by user, and the next cursor" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, workspace_fixture, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    var ids: [4][]const u8 = undefined;
    var count: usize = 0;
    for (root.get("channels").?.array.items) |item| {
        const channel = workspaceChannel(item.object) orelse continue;
        ids[count] = channel.id;
        count += 1;
        if (channel.is_im) {
            try std.testing.expectEqualStrings("U0042", channel.user);
            try std.testing.expectEqualStrings("", channel.name);
        }
    }
    // The empty view came from zero channels reaching the list: every entry
    // with an id must survive parsing.
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("C0001", ids[0]);
    try std.testing.expectEqualStrings("D0003", ids[2]);
    try std.testing.expectEqual(@as(i64, 1750000000), workspaceChannel(root.get("channels").?.array.items[0].object).?.seconds);
    try std.testing.expectEqualStrings("dGVhbTpDMDYxRkE1UEI=", nextCursor(root));
}

test "a last page has no cursor, and pagination stops at the cap" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"ok\":true,\"members\":[],\"response_metadata\":{\"next_cursor\":\"\"}}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("", nextCursor(parsed.value.object));
    try std.testing.expect(!wantsNextPage("", 1, 512));
    try std.testing.expect(wantsNextPage("abc", 1, 512));
    // A server that never stops sending cursors must not loop forever.
    try std.testing.expect(!wantsNextPage("abc", max_list_pages, 512));
    // A cursor too long for a job argument would be cut and refetch page 1.
    try std.testing.expect(!wantsNextPage("abcd", 1, 3));
}

test "poll log lines are rate limited, but a new error or count logs at once" {
    const hash_a: u64 = 1;
    const hash_b: u64 = 2;
    try std.testing.expect(logDue(0, 0, 5_000, hash_a));
    // Same error on the next minute poll: quiet.
    try std.testing.expect(!logDue(5_000, hash_a, 65_000, hash_a));
    // A different error is news: log it at once.
    try std.testing.expect(logDue(5_000, hash_a, 65_000, hash_b));
    try std.testing.expect(logDue(5_000, hash_a, 5_000 + log_repeat_interval_ms, hash_a));
}

test "failure line names kind, error and status only" {
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings("slack: workspace failed: NetworkFailed (HTTP 200)", formatJobFailure(&buffer, "workspace", "NetworkFailed", 200));
    try std.testing.expectEqualStrings("slack: users failed: OutOfMemory", formatJobFailure(&buffer, "users", "OutOfMemory", 0));
}

test "workspaceChannel skips unjoined channels but keeps DMs and joined channels" {
    const raw =
        \\{"channels":[
        \\{"id":"C1","name":"general","is_member":true},
        \\{"id":"C2","name":"random","is_member":false},
        \\{"id":"D1","user":"U1","is_im":true},
        \\{"id":"G1","name":"mpdm-a--b-1","is_mpim":true,"is_member":true}
        \\]}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const items = parsed.value.object.get("channels").?.array.items;
    try std.testing.expect(workspaceChannel(items[0].object) != null);
    try std.testing.expect(workspaceChannel(items[1].object) == null);
    try std.testing.expect(workspaceChannel(items[2].object).?.is_im);
    try std.testing.expect(workspaceChannel(items[3].object) != null);
}
