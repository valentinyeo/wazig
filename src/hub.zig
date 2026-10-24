const std = @import("std");
const bridge = @import("wa_hub.zig");
const transport = @import("transport.zig");
const messenger_view = @import("messenger_view.zig");

pub const igsh_531_hub_provider = true;
pub const igsh_604_workspace_icons = true;
pub const igsh_696_telegram_avatars = true;
pub const Request = bridge.Request;
pub const Rows = bridge.Rows;
pub const Sse = bridge.Sse;

pub fn selected(url: []const u8) bool {
    return igsh_531_hub_provider and std.mem.trim(u8, url, " \t\r\n").len > 0;
}

pub fn chats(allocator: std.mem.Allocator, archived: bool, limit: usize) !Request {
    return .{ .path = try std.fmt.allocPrint(allocator, "/v1/wazig/chats?archived={s}&limit={d}", .{ if (archived) "true" else "false", limit }) };
}

pub fn messages(allocator: std.mem.Allocator, chat: []const u8, limit: usize, before: []const u8) !Request {
    try validId(chat);
    const c = try bridge.encode(allocator, chat);
    defer allocator.free(c);
    const b = try bridge.encode(allocator, before);
    defer allocator.free(b);
    return .{ .path = try std.fmt.allocPrint(allocator, "/v1/wazig/messages?chat={s}&limit={d}&before={s}", .{ c, limit, b }) };
}

pub const older_limit: usize = 80;

pub fn beforeCursor(allocator: std.mem.Allocator, msg_id: []const u8, timestamp: []const u8) ![]u8 {
    try validId(msg_id);
    try validId(timestamp);
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ msg_id, timestamp });
}

pub fn messageRows(root: std.json.Value) ?[]const std.json.Value {
    if (root != .object) return null;
    const data = root.object.get("data") orelse return null;
    if (data != .object) return null;
    const rows = data.object.get("messages") orelse return null;
    return if (rows == .array) rows.array.items else null;
}

pub fn unite(allocator: std.mem.Allocator, first: []const std.json.Value, second: []const std.json.Value, out: *std.ArrayList(std.json.Value)) !usize {
    try out.appendSlice(allocator, first);
    var added: usize = 0;
    for (second) |row| {
        const id = rowId(row);
        if (id.len == 0) continue;
        var known = false;
        for (out.items) |existing| {
            if (std.mem.eql(u8, rowId(existing), id)) {
                known = true;
                break;
            }
        }
        if (known) continue;
        try out.append(allocator, row);
        added += 1;
    }
    return added;
}

fn rowId(row: std.json.Value) []const u8 {
    return if (row == .object) string(row.object, "MsgID") else "";
}

pub fn send(allocator: std.mem.Allocator, chat: []const u8, text: []const u8, reply_to: []const u8, client_id: []const u8) !Request {
    try validWrite(chat, client_id);
    return .{ .method = "POST", .path = "/v1/wazig/send", .body = try std.json.Stringify.valueAlloc(allocator, .{ .chat = chat, .text = text, .reply_to = reply_to, .client_id = client_id }, .{}) };
}

pub fn sendFile(allocator: std.mem.Allocator, chat: []const u8, text: []const u8, reply_to: []const u8, client_id: []const u8, filename: []const u8, bytes: []const u8, ptt: bool, boundary: []const u8) !Request {
    try validWrite(chat, client_id);
    var request = try bridge.sendFile(allocator, .{ .provider = .whatsapp, .account = "hub", .id = chat }, text, reply_to, client_id, filename, bytes, ptt, boundary);
    request.path = "/v1/wazig/send";
    return request;
}

pub fn markRead(allocator: std.mem.Allocator, chat: []const u8, message_id: []const u8) !Request {
    try validId(chat);
    return .{ .method = "POST", .path = "/v1/wazig/mark-read", .body = try std.json.Stringify.valueAlloc(allocator, .{ .chat = chat, .message_id = message_id }, .{}) };
}

pub fn archive(allocator: std.mem.Allocator, chat: []const u8, archived: bool) !Request {
    try validId(chat);
    return .{ .method = "POST", .path = "/v1/wazig/archive", .body = try std.json.Stringify.valueAlloc(allocator, .{ .chat = chat, .archived = archived }, .{}) };
}

pub fn react(allocator: std.mem.Allocator, chat: []const u8, msg: []const u8, emoji: []const u8, client_id: []const u8) !Request {
    try validWrite(chat, client_id);
    try validId(msg);
    return .{ .method = "POST", .path = "/v1/wazig/react", .body = try std.json.Stringify.valueAlloc(allocator, .{ .chat = chat, .msg = msg, .emoji = emoji, .client_id = client_id }, .{}) };
}

pub fn binary(allocator: std.mem.Allocator, chat: []const u8, message_id: ?[]const u8) !Request {
    try validId(chat);
    const c = try bridge.encode(allocator, chat);
    defer allocator.free(c);
    if (message_id) |id| {
        try validId(id);
        const m = try bridge.encode(allocator, id);
        defer allocator.free(m);
        return .{ .path = try std.fmt.allocPrint(allocator, "/v1/wazig/media/{s}/{s}", .{ c, m }) };
    }
    return .{ .path = try std.fmt.allocPrint(allocator, "/v1/wazig/avatar/{s}", .{c}) };
}

pub fn slackEmoji(allocator: std.mem.Allocator, account: []const u8, name: ?[]const u8) !Request {
    try validTeam(account);
    const encoded = try bridge.encode(allocator, account);
    defer allocator.free(encoded);
    if (name) |value| {
        try validId(value);
        const emoji = try bridge.encode(allocator, value);
        defer allocator.free(emoji);
        return .{ .path = try std.fmt.allocPrint(allocator, "/v1/wazig/slack/emoji/media?account={s}&name={s}", .{ encoded, emoji }) };
    }
    return .{ .path = try std.fmt.allocPrint(allocator, "/v1/wazig/slack/emoji?account={s}", .{encoded}) };
}

pub fn slackAttachment(row: *std.json.ObjectMap, allocator: std.mem.Allocator) !void {
    if (row.get("reactions")) |_| {
        if (string(row.*, "ReactionEmoji").len == 0) {
            const slack = @import("slack.zig");
            var reactions: [slack.max_reactions]slack.Reaction = undefined;
            const count = slack.readReactions(row.*, &reactions);
            var buffer: [4096]u8 = undefined;
            const rendered = slack.formatReactions(&buffer, reactions[0..count]);
            try row.put(allocator, "ReactionEmoji", .{ .string = try allocator.dupe(u8, rendered) });
        }
    }
    if (string(row.*, "MediaType").len > 0) return;
    const attachments = row.get("attachments") orelse return;
    if (attachments != .array) return;
    for (attachments.array.items) |value| {
        if (value != .object) continue;
        const url = string(value.object, "image_url");
        if (url.len == 0) continue;
        const mime = string(value.object, "image_mimetype");
        try row.put(allocator, "MediaType", .{ .string = "image" });
        const gif = std.mem.indexOf(u8, url, ".gif") != null or std.ascii.eqlIgnoreCase(string(value.object, "service_name"), "Giphy");
        try row.put(allocator, "MimeType", .{ .string = if (mime.len > 0) mime else if (gif) "image/gif" else "image/png" });
        try row.put(allocator, "Filename", .{ .string = if (gif) "attachment.gif" else "attachment.png" });
        break;
    }
}

pub fn workspaceIcon(allocator: std.mem.Allocator, team: []const u8) !Request {
    try validTeam(team);
    const encoded = try bridge.encode(allocator, team);
    defer allocator.free(encoded);
    return .{ .path = try std.fmt.allocPrint(allocator, "/v1/wazig/workspace-icon/{s}", .{encoded}) };
}

pub fn workspaceAvatarKey(chat: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, chat, "slack:")) return null;
    const end = std.mem.indexOfScalarPos(u8, chat, 6, ':') orelse return null;
    if (end + 1 >= chat.len) return null;
    const team = chat[6..end];
    validTeam(team) catch return null;
    return chat[0 .. end + 1];
}

fn validTeam(team: []const u8) !void {
    try validId(team);
    if (std.mem.indexOfScalar(u8, team, ':') != null or std.mem.eql(u8, team, ".") or std.mem.eql(u8, team, "..")) return error.InvalidId;
}

pub fn chatAvatarEnabled(provider: transport.Provider, unified: bool, enabled: bool) bool {
    return provider == .whatsapp or (enabled and unified and provider == .telegram);
}

pub const Badge = enum { workspace_icon, whatsapp_mark, signal_mark, telegram_mark, letter_s, letter_w, letter_t };

pub fn providerBadge(provider: transport.Provider, cached_icon: bool, enabled: bool) Badge {
    return switch (provider) {
        .slack => if (enabled and cached_icon) .workspace_icon else .letter_s,
        .whatsapp => if (enabled) .whatsapp_mark else .letter_w,
        .telegram => if (enabled) .telegram_mark else .letter_t,
        .signal => if (enabled) .signal_mark else .letter_s,
    };
}

pub fn events(last_event_id: []const u8) Request {
    return .{ .path = "/v1/wazig/events", .last_event_id = last_event_id };
}

pub fn normalize(allocator: std.mem.Allocator, raw: []const u8, kind: Rows, chat: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len > 500) return error.BadResponse;
    for (parsed.value.array.items, 0..) |*item, index| {
        if (item.* != .object) return error.BadResponse;
        const id_field: []const u8 = if (kind == .messages) "MsgID" else "jid";
        const id = string(item.object, id_field);
        try validId(id);
        for (parsed.value.array.items[0..index]) |previous| {
            if (std.mem.eql(u8, string(previous.object, id_field), id)) return error.DuplicateId;
        }
        if (kind == .chats) {
            _ = sourceProvider(item.object) orelse return error.BadProvider;
        } else if (kind == .messages) {
            const row_chat = string(item.object, "ChatJID");
            if (!std.mem.eql(u8, row_chat, chat)) {
                if (!lidAlias(row_chat, chat)) return error.WrongChat;
                try item.object.put(allocator, "ChatJID", .{ .string = chat });
            }
            if (std.mem.startsWith(u8, chat, "slack:")) try slackAttachment(&item.object, allocator);
            _ = item.object.swapRemove("SlackEmojiPaths");
            _ = item.object.swapRemove("LocalPath");
            _ = item.object.swapRemove("local_path");
        }
    }
    return if (kind == .messages)
        std.json.Stringify.valueAlloc(allocator, .{ .success = true, .data = .{ .messages = parsed.value } }, .{})
    else
        std.json.Stringify.valueAlloc(allocator, .{ .success = true, .data = parsed.value }, .{});
}

pub fn archivedChats(allocator: std.mem.Allocator, archived_raw: []const u8, inbox_raw: []const u8) ![]u8 {
    const archived = try normalize(allocator, archived_raw, .chats, "");
    defer allocator.free(archived);
    const inbox = try normalize(allocator, inbox_raw, .chats, "");
    defer allocator.free(inbox);
    var archived_rows = try std.json.parseFromSlice(std.json.Value, allocator, archived, .{});
    defer archived_rows.deinit();
    var inbox_rows = try std.json.parseFromSlice(std.json.Value, allocator, inbox, .{});
    defer inbox_rows.deinit();
    var rows: std.ArrayList(std.json.Value) = .empty;
    defer rows.deinit(allocator);
    for (archived_rows.value.object.get("data").?.array.items) |row| {
        try rows.append(allocator, row);
    }
    for (inbox_rows.value.object.get("data").?.array.items) |row| {
        var known = false;
        for (rows.items) |existing| {
            if (std.mem.eql(u8, string(existing.object, "jid"), string(row.object, "jid"))) {
                known = true;
                break;
            }
        }
        if (!known) try rows.append(allocator, row);
    }
    return std.json.Stringify.valueAlloc(allocator, .{ .success = true, .data = rows.items }, .{});
}

fn accountPrefix(id: []const u8) []const u8 {
    const colon = std.mem.indexOfScalar(u8, id, ':') orelse return "";
    return id[0..colon];
}

fn lidAlias(row_chat: []const u8, chat: []const u8) bool {
    if (!std.mem.endsWith(u8, row_chat, "@lid") or !std.mem.endsWith(u8, chat, "@s.whatsapp.net")) return false;
    return std.mem.eql(u8, accountPrefix(row_chat), accountPrefix(chat));
}

pub fn sourceProvider(row: std.json.ObjectMap) ?transport.Provider {
    return std.meta.stringToEnum(transport.Provider, string(row, "provider"));
}

pub fn sourceAccount(row: std.json.ObjectMap, fallback: []const u8) []const u8 {
    const account = string(row, "account");
    return if (account.len > 0) account else fallback;
}

pub fn viewAccount(row: std.json.ObjectMap, fallback: []const u8) []const u8 {
    if (sourceProvider(row) == .signal and std.mem.startsWith(u8, string(row, "jid"), "signal:")) return "signal";
    if (sourceProvider(row) == .telegram and std.mem.startsWith(u8, string(row, "jid"), "telegram:")) return "telegram";
    const account = string(row, "account");
    if (account.len > 0) return account;
    const jid = string(row, "jid");
    const provider = sourceProvider(row) orelse return fallback;
    if (provider == .whatsapp) {
        const colon = std.mem.indexOfScalar(u8, jid, ':') orelse return fallback;
        if (colon > 0 and std.mem.indexOfScalar(u8, jid[colon + 1 ..], '@') != null) return jid[0..colon];
    } else if (provider == .slack and std.mem.startsWith(u8, jid, "slack:")) {
        const rest = jid["slack:".len..];
        const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return fallback;
        if (colon > 0 and colon + 1 < rest.len) return rest[0..colon];
    }
    return fallback;
}

pub fn workspaceName(row: std.json.ObjectMap) []const u8 {
    return if (sourceProvider(row) == .slack) string(row, "team_name") else "";
}

pub fn accountView(row: std.json.ObjectMap, fallback: []const u8, cached_name: []const u8, direct_name: []const u8, existing: ?messenger_view.Account) ?messenger_view.Account {
    const provider = sourceProvider(row) orelse return null;
    const account = viewAccount(row, fallback);
    const supplied = workspaceName(row);
    const name = if (provider != .slack) "" else if (direct_name.len > 0) direct_name else if (supplied.len > 0) supplied else cached_name;
    if (provider == .slack and name.len == 0) if (existing) |view| return view;
    var view = messenger_view.Account.init(provider, account, name);
    if (existing) |previous| view.selected = previous.selected;
    return view;
}

pub fn providerForView(row: std.json.ObjectMap, view: messenger_view.View) ?transport.Provider {
    const provider = sourceProvider(row) orelse return null;
    return if (messenger_view.includes(view, provider)) provider else null;
}

fn string(row: std.json.ObjectMap, name: []const u8) []const u8 {
    const value = row.get(name) orelse return "";
    return if (value == .string) value.string else "";
}

fn validId(id: []const u8) !void {
    if (id.len == 0 or id.len > 191 or !std.unicode.utf8ValidateSlice(id)) return error.InvalidId;
    for (id) |byte| if (byte < 32 or byte == 127) return error.InvalidId;
}

fn validWrite(chat: []const u8, client_id: []const u8) !void {
    try validId(chat);
    if (client_id.len == 0 or client_id.len > 128) return error.InvalidSend;
}

pub fn signalSendFailure(allocator: std.mem.Allocator, status: u32, raw: []const u8) ?[]const u8 {
    if (status != 429 and status != 403) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const reason = string(parsed.value.object, "error");
    if (status == 429 and std.mem.eql(u8, reason, "signal rate limited")) return "signal rate limited";
    if (status == 403 and std.mem.eql(u8, reason, "signal captcha required")) return "signal captcha required";
    return null;
}

pub fn readMessageId(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const data = parsed.value.object.get("data") orelse return error.BadResponse;
    if (data != .object) return error.BadResponse;
    const rows = data.object.get("messages") orelse return error.BadResponse;
    if (rows != .array) return error.BadResponse;
    for (rows.array.items) |row| {
        if (row != .object or string(row.object, "ReactionToID").len > 0) continue;
        const from_me = row.object.get("FromMe") orelse continue;
        if (from_me != .bool or from_me.bool) continue;
        const id = string(row.object, "MsgID");
        try validId(id);
        return allocator.dupe(u8, id);
    }
    return error.NoIncomingMessage;
}

pub fn telegramSendFailure(allocator: std.mem.Allocator, status: u32, raw: []const u8) ?[]const u8 {
    if (status != 429) return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    if (std.mem.eql(u8, string(parsed.value.object, "error"), "telegram rate limited")) return "telegram rate limited";
    return null;
}

pub fn savedMessages(row: std.json.ObjectMap) bool {
    if (sourceProvider(row) != .telegram) return false;
    const saved = row.get("saved") orelse return false;
    return saved == .bool and saved.bool;
}
