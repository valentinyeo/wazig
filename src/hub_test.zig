const std = @import("std");
const hub = @import("hub.zig");
const bridge = @import("wa_hub.zig");

const chat = "fixture/account:room +/";
const client_id = "fixture-client-id";

test "IGSH-531 configured switch and unconfigured direct fallback" {
    try std.testing.expect(hub.igsh_531_hub_provider);
    try std.testing.expect(!hub.selected(""));
    try std.testing.expect(!hub.selected(" \t\r\n"));
    try std.testing.expect(hub.selected("configured-origin"));
}

test "IGSH-531 opaque chat handles are encoded without parsing source identities" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const list = try hub.chats(allocator, true, 500);
    try std.testing.expectEqualStrings("/v1/wazig/chats?archived=true&limit=500", list.path);
    try std.testing.expectEqualStrings("/v1/wazig/chats?archived=true&limit=800", (try hub.chats(allocator, true, 800)).path);
    const history = try hub.messages(allocator, chat, 80, "cursor+/");
    try std.testing.expectEqualStrings("/v1/wazig/messages?chat=fixture%2Faccount%3Aroom%20%2B%2F&limit=80&before=cursor%2B%2F", history.path);
    const media = try hub.binary(allocator, chat, "media/id");
    try std.testing.expectEqualStrings("/v1/wazig/media/fixture%2Faccount%3Aroom%20%2B%2F/media%2Fid", media.path);
    try std.testing.expectError(error.InvalidId, hub.messages(allocator, "", 80, ""));
    try std.testing.expectError(error.InvalidId, hub.binary(allocator, "bad\nhandle", "id"));
}

test "IGSH-681 older page cursor joins the oldest id and its RFC3339 timestamp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cursor = try hub.beforeCursor(allocator, "personal:ABC", "2026-10-01T11:58:41Z");
    try std.testing.expectEqualStrings("personal:ABC:2026-10-01T11:58:41Z", cursor);
    const request = try hub.messages(allocator, chat, hub.older_limit, cursor);
    try std.testing.expectEqualStrings("/v1/wazig/messages?chat=fixture%2Faccount%3Aroom%20%2B%2F&limit=80&before=personal%3AABC%3A2026-10-01T11%3A58%3A41Z", request.path);
    try std.testing.expectError(error.InvalidId, hub.beforeCursor(allocator, "", "2026-10-01T11:58:41Z"));
    try std.testing.expectError(error.InvalidId, hub.beforeCursor(allocator, "ABC", ""));
    try std.testing.expectError(error.InvalidId, hub.beforeCursor(allocator, "AB\nC", "2026-10-01T11:58:41Z"));
}

test "IGSH-681 older rows merge behind the loaded rows without repeating a MsgID" {
    const allocator = std.testing.allocator;
    var loaded = try std.json.parseFromSlice(std.json.Value, allocator, "{\"data\":{\"messages\":[{\"MsgID\":\"C\"},{\"MsgID\":\"B\"}]}}", .{ .allocate = .alloc_always });
    defer loaded.deinit();
    var page = try std.json.parseFromSlice(std.json.Value, allocator, "{\"data\":{\"messages\":[{\"MsgID\":\"B\"},{\"MsgID\":\"A\"},{\"MsgID\":\"A\"},{\"Text\":\"no id\"}]}}", .{ .allocate = .alloc_always });
    defer page.deinit();
    var rows: std.ArrayList(std.json.Value) = .empty;
    defer rows.deinit(allocator);
    const added = try hub.unite(allocator, hub.messageRows(loaded.value).?, hub.messageRows(page.value).?, &rows);
    try std.testing.expectEqual(@as(usize, 1), added);
    try std.testing.expectEqual(@as(usize, 3), rows.items.len);
    for (rows.items, [_][]const u8{ "C", "B", "A" }) |row, id| {
        try std.testing.expectEqualStrings(id, row.object.get("MsgID").?.string);
    }
}

test "IGSH-681 an empty page or a page of known rows adds nothing" {
    const allocator = std.testing.allocator;
    var loaded = try std.json.parseFromSlice(std.json.Value, allocator, "{\"data\":{\"messages\":[{\"MsgID\":\"B\"}]}}", .{ .allocate = .alloc_always });
    defer loaded.deinit();
    var empty = try std.json.parseFromSlice(std.json.Value, allocator, "{\"data\":{\"messages\":[]}}", .{ .allocate = .alloc_always });
    defer empty.deinit();
    var repeat = try std.json.parseFromSlice(std.json.Value, allocator, "{\"data\":{\"messages\":[{\"MsgID\":\"B\"}]}}", .{ .allocate = .alloc_always });
    defer repeat.deinit();
    var without_rows = try std.json.parseFromSlice(std.json.Value, allocator, "{\"data\":{}}", .{ .allocate = .alloc_always });
    defer without_rows.deinit();
    var rows: std.ArrayList(std.json.Value) = .empty;
    defer rows.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), try hub.unite(allocator, hub.messageRows(loaded.value).?, hub.messageRows(empty.value).?, &rows));
    rows.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), try hub.unite(allocator, hub.messageRows(loaded.value).?, hub.messageRows(repeat.value).?, &rows));
    try std.testing.expectEqual(@as(usize, 1), rows.items.len);
    try std.testing.expect(hub.messageRows(without_rows.value) == null);
}

test "IGSH-531 writes carry escaped text persisted id read watermark and archive state" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const send = try hub.send(allocator, chat, "Fixture \"message\"\n", "quoted-id", client_id);
    const retry = try hub.send(allocator, chat, "Fixture \"message\"\n", "quoted-id", client_id);
    try std.testing.expectEqualStrings("POST", send.method);
    try std.testing.expectEqualStrings("/v1/wazig/send", send.path);
    try std.testing.expectEqualStrings(send.body, retry.body);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, send.body, .{});
    try std.testing.expectEqualStrings(chat, value.object.get("chat").?.string);
    try std.testing.expectEqualStrings(client_id, value.object.get("client_id").?.string);
    try std.testing.expectEqualStrings("Fixture \"message\"\n", value.object.get("text").?.string);
    try std.testing.expect(value.object.get("account") == null);
    const read = try hub.markRead(allocator, chat, "last-message");
    const read_value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, read.body, .{});
    try std.testing.expectEqualStrings("/v1/wazig/mark-read", read.path);
    try std.testing.expectEqualStrings("last-message", read_value.object.get("message_id").?.string);
    for ([_]bool{ true, false }) |archived| {
        const request = try hub.archive(allocator, chat, archived);
        const body = try std.json.parseFromSliceLeaky(std.json.Value, allocator, request.body, .{});
        try std.testing.expectEqualStrings("/v1/wazig/archive", request.path);
        try std.testing.expectEqual(archived, body.object.get("archived").?.bool);
    }
    const reaction = try hub.react(allocator, chat, "message-id", "", client_id);
    try std.testing.expectEqualStrings("/v1/wazig/react", reaction.path);
    try std.testing.expectError(error.InvalidSend, hub.send(allocator, chat, "text", "", ""));
}

test "IGSH-531 aggregate rows retain network labels reject collisions and remove backend paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    for ([_][]const u8{ "whatsapp", "slack", "telegram", "signal" }) |provider| {
        const raw = try std.fmt.allocPrint(allocator, "[{{\"jid\":\"opaque\",\"provider\":\"{s}\",\"name\":\"Fixture\"}}]", .{provider});
        const normalized = try hub.normalize(allocator, raw, .chats, "");
        const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, normalized, .{});
        try std.testing.expectEqualStrings(provider, @tagName(hub.sourceProvider(value.object.get("data").?.array.items[0].object).?));
    }
    try std.testing.expectError(error.BadProvider, hub.normalize(allocator, "[{\"jid\":\"opaque\",\"provider\":\"unknown\"}]", .chats, ""));
    try std.testing.expectError(error.DuplicateId, hub.normalize(allocator, "[{\"jid\":\"same\",\"provider\":\"slack\"},{\"jid\":\"same\",\"provider\":\"telegram\"}]", .chats, ""));
    try std.testing.expectError(error.BadResponse, hub.normalize(allocator, "{}", .messages, chat));
    try std.testing.expectError(error.WrongChat, hub.normalize(allocator, "[{\"MsgID\":\"id\",\"ChatJID\":\"other\"}]", .messages, chat));
    const normalized = try hub.normalize(allocator, "[{\"MsgID\":\"id\",\"ChatJID\":\"opaque\",\"Text\":\"Fixture\",\"LocalPath\":\"backend-path\",\"local_path\":\"backend-path\"}]", .messages, "opaque");
    try std.testing.expect(std.mem.indexOf(u8, normalized, "backend-path") == null);
    const file = try hub.sendFile(allocator, chat, "caption", "quote", client_id, "fixture.ogg", "OggSfixture", true, "0123456789abcdef0123456789abcdef");
    try std.testing.expectEqualStrings("/v1/wazig/send", file.path);
    try std.testing.expect(std.mem.indexOf(u8, file.body, "name=\"ptt\"\r\n\r\ntrue\r\n") != null);
}

test "IGSH-683 same-account lid rows join the phone chat and other mismatches stay rejected" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const phone = "personal:15550000002@s.whatsapp.net";
    const mixed = "[{\"MsgID\":\"a\",\"ChatJID\":\"personal:15550000002@s.whatsapp.net\",\"Text\":\"phone\"},{\"MsgID\":\"b\",\"ChatJID\":\"personal:99990000000001@lid\",\"Text\":\"lid\"}]";
    const normalized = try hub.normalize(allocator, mixed, .messages, phone);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, normalized, .{});
    const rows = value.object.get("data").?.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    for (rows) |row| try std.testing.expectEqualStrings(phone, row.object.get("ChatJID").?.string);
    try std.testing.expectEqualStrings("lid", rows[1].object.get("Text").?.string);
    const bare = try hub.normalize(allocator, "[{\"MsgID\":\"a\",\"ChatJID\":\"99990000000001@lid\"}]", .messages, "15550000002@s.whatsapp.net");
    try std.testing.expect(std.mem.indexOf(u8, bare, "\"ChatJID\":\"15550000002@s.whatsapp.net\"") != null);
    try std.testing.expectError(error.WrongChat, hub.normalize(allocator, "[{\"MsgID\":\"b\",\"ChatJID\":\"business:99990000000001@lid\"}]", .messages, phone));
    try std.testing.expectError(error.WrongChat, hub.normalize(allocator, "[{\"MsgID\":\"b\",\"ChatJID\":\"99990000000001@lid\"}]", .messages, phone));
    try std.testing.expectError(error.WrongChat, hub.normalize(allocator, "[{\"MsgID\":\"b\",\"ChatJID\":\"business:99990000000001@lid\"}]", .messages, phone));
    try std.testing.expectError(error.WrongChat, hub.normalize(allocator, "[{\"MsgID\":\"b\",\"ChatJID\":\"personal:15550000003@s.whatsapp.net\"}]", .messages, phone));
    try std.testing.expectError(error.WrongChat, hub.normalize(allocator, "[{\"MsgID\":\"b\",\"ChatJID\":\"personal:99990000000001@lid\"}]", .messages, "personal:120363000000000001@g.us"));
    try std.testing.expectError(error.WrongChat, hub.normalize(allocator, "[{\"MsgID\":\"b\",\"ChatJID\":\"personal:99990000000002@lid\"}]", .messages, "personal:99990000000001@lid"));
}

test "IGSH-531 live updates use bounded validated SSE and resume ids" {
    var sse = hub.Sse{};
    const frame = "id: 7\ndata: {\"id\":7,\"kind\":\"msg\",\"chat\":\"opaque\"}\n\n";
    var seen = false;
    for (frame) |byte| {
        if (try sse.push(byte)) |complete| {
            var event = (try sse.parse(std.testing.allocator, complete)).?;
            defer event.deinit();
            try std.testing.expectEqualStrings("opaque", event.value.chat);
            seen = true;
        }
    }
    try std.testing.expect(seen);
    try std.testing.expectEqualStrings("/v1/wazig/events", hub.events(sse.lastId()).path);
    try std.testing.expectEqualStrings("7", hub.events(sse.lastId()).last_event_id);
    try std.testing.expectError(error.BadEventId, sse.parse(std.testing.allocator, "id: 8\ndata: {\"id\":9,\"kind\":\"reset\"}\n\n"));
    try std.testing.expectEqualStrings("7", sse.lastId());
    try std.testing.expectEqual(.pending, try bridge.mediaState(202));
    try std.testing.expectEqual(.ready, try bridge.mediaState(200));
    try std.testing.expectError(error.HttpFailed, bridge.mediaState(401));
}

test "IGSH-592 hub provider views partition parsed rows without trusting opaque handles" {
    const View = @import("messenger_view.zig").View;
    const Provider = @import("transport.zig").Provider;
    const raw =
        \\[
        \\  {"jid":"opaque-first","provider":"slack"},
        \\  {"jid":"opaque-second","provider":"whatsapp"},
        \\  {"jid":"unknown","provider":"other"},
        \\  {"jid":"missing"},
        \\  {"jid":"invalid","provider":42}
        \\]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const rows = parsed.value.array.items;
    var counts = [_]usize{0} ** 3;
    for ([_]View{ .slack, .whatsapp, .all }, 0..) |view, index| {
        for (rows) |row| {
            if (hub.providerForView(row.object, view)) |provider| {
                try std.testing.expect(view == .all or std.mem.eql(u8, @tagName(view), @tagName(provider)));
                counts[index] += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(?Provider, .slack), hub.providerForView(rows[0].object, .slack));
    try std.testing.expectEqual(@as(?Provider, null), hub.providerForView(rows[0].object, .whatsapp));
    try std.testing.expectEqual(@as(?Provider, .whatsapp), hub.providerForView(rows[1].object, .whatsapp));
    try std.testing.expectEqual(@as(?Provider, null), hub.providerForView(rows[1].object, .slack));
    try std.testing.expectEqual(@as(usize, 1), counts[0]);
    try std.testing.expectEqual(@as(usize, 1), counts[1]);
    try std.testing.expectEqual(@as(usize, 2), counts[2]);
    try std.testing.expectEqual(counts[2], counts[0] + counts[1]);
}

test "IGSH-592 hub Telegram rows remain exclusive to Telegram and all views" {
    const Provider = @import("transport.zig").Provider;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"provider\":\"telegram\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?Provider, .telegram), hub.providerForView(parsed.value.object, .telegram));
    try std.testing.expectEqual(@as(?Provider, .telegram), hub.providerForView(parsed.value.object, .all));
    try std.testing.expectEqual(@as(?Provider, null), hub.providerForView(parsed.value.object, .slack));
    try std.testing.expectEqual(@as(?Provider, null), hub.providerForView(parsed.value.object, .whatsapp));
}

test "hub source accounts retain per-account view labels independently of cache namespace" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"provider\":\"whatsapp\",\"account\":\"wa-b\",\"account_name\":\"Account B\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("wa-b", hub.sourceAccount(parsed.value.object, "hub-cache"));
    const views = @import("messenger_view.zig");
    const key = @import("chat_key.zig").Key{ .provider = .whatsapp, .account = hub.sourceAccount(parsed.value.object, "hub-cache"), .id = "shared-contact" };
    try std.testing.expect(views.accountMatches(.whatsapp, "wa-b", key));
    try std.testing.expect(!views.accountMatches(.whatsapp, "wa-a", key));
}

test "real hub prefixed jids without account produce four views without changing routing identity" {
    const views = @import("messenger_view.zig");
    const chat_key = @import("chat_key.zig");
    const raw =
        \\[
        \\  {"provider":"whatsapp","jid":"personal:0000000000@s.whatsapp.net"},
        \\  {"provider":"whatsapp","jid":"business:0000000000@s.whatsapp.net"},
        \\  {"provider":"slack","jid":"slack:T0ABC123:C0000000000","team_name":"Alpha Workspace"},
        \\  {"provider":"slack","jid":"slack:T0DEF456:C0000000000"}
        \\]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    var known: std.ArrayList(views.Account) = .empty;
    defer known.deinit(std.testing.allocator);
    var routing: [4]chat_key.Stored = @splat(.{});
    for (parsed.value.array.items, 0..) |row, index| {
        try std.testing.expect(row.object.get("account") == null);
        const provider = hub.sourceProvider(row.object).?;
        const jid = row.object.get("jid").?.string;
        try views.appendUnique(std.testing.allocator, &known, hub.accountView(row.object, "hub-cache", "", "", null).?);
        routing[index].set(.{ .provider = provider, .account = hub.sourceAccount(row.object, "hub-cache"), .id = jid });
        try std.testing.expectEqualStrings("hub-cache", routing[index].key().account);
        try std.testing.expectEqualStrings(jid, routing[index].key().id);
    }
    try std.testing.expectEqual(@as(usize, 4), known.items.len);
    try std.testing.expectEqualStrings("WhatsApp personal", known.items[0].labelText());
    try std.testing.expectEqualStrings("WhatsApp business", known.items[1].labelText());
    try std.testing.expectEqualStrings("Slack Alpha Workspace", known.items[2].labelText());
    try std.testing.expectEqualStrings("Slack T0DEF456", known.items[3].labelText());
    try std.testing.expect(!chat_key.Key.eql(routing[0].key(), routing[1].key()));
    for (known.items, 0..) |view, index| {
        var count: usize = 0;
        for (parsed.value.array.items) |row| {
            const key = chat_key.Key{ .provider = hub.sourceProvider(row.object).?, .account = hub.viewAccount(row.object, "hub-cache"), .id = row.object.get("jid").?.string };
            if (views.accountMatches(views.providerView(view.key.provider), view.key.key().account, key)) count += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), count);
        try std.testing.expect(views.accountMatches(views.providerView(view.key.provider), view.key.key().account, .{ .provider = routing[index].provider, .account = view.key.key().account, .id = routing[index].key().id }));
    }
    const request = try hub.send(std.testing.allocator, routing[0].key().id, "Synthetic message", "", client_id);
    defer std.testing.allocator.free(request.body);
    var body = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, request.body, .{});
    defer body.deinit();
    try std.testing.expectEqualStrings(routing[0].key().id, body.value.object.get("chat").?.string);
    try std.testing.expect(body.value.object.get("account") == null);
}

test "hub workspace labels use supplied names then cached names then team ids" {
    const raw =
        \\[ {"provider":"slack","jid":"slack:T0ABC123:C1","team_name":"Alpha Workspace"},
        \\  {"provider":"slack","jid":"slack:T0DEF456:C1"},
        \\  {"provider":"slack","jid":"slack:T0DEF456:C2","team_name":""},
        \\  {"provider":"whatsapp","jid":"personal:0000000000@s.whatsapp.net","team_name":"Not Slack"} ]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const rows = parsed.value.array.items;
    const supplied = hub.accountView(rows[0].object, "hub-cache", "Old Workspace", "", null).?;
    try std.testing.expectEqualStrings("Slack Alpha Workspace", supplied.labelText());
    for (rows[1..3]) |row| {
        const fallback = hub.accountView(row.object, "hub-cache", "", "", null).?;
        try std.testing.expectEqualStrings("Slack T0DEF456", fallback.labelText());
        const cached = hub.accountView(row.object, "hub-cache", "Beta Workspace", "", null).?;
        try std.testing.expectEqualStrings("Slack Beta Workspace", cached.labelText());
    }
    const whatsapp = hub.accountView(rows[3].object, "hub-cache", "Not Slack", "", null).?;
    try std.testing.expectEqualStrings("WhatsApp personal", whatsapp.labelText());
    const direct = @import("messenger_view.zig").Account.init(.slack, "T0ABC123", "Direct Workspace");
    try std.testing.expectEqualStrings("Slack Direct Workspace", direct.labelText());
}

test "hub duplicate rows retain named views and direct sign-in names win" {
    const raw =
        \\[ {"provider":"slack","jid":"slack:T0ABC123:C1","team_name":"Alpha Workspace"},
        \\  {"provider":"slack","jid":"slack:T0ABC123:C2"},
        \\  {"provider":"slack","jid":"slack:T0ABC123:C3","team_name":""},
        \\  {"provider":"slack","jid":"slack:T0ABC123:C4","team_name":"Beta Workspace"} ]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const rows = parsed.value.array.items;
    var view = hub.accountView(rows[0].object, "hub-cache", "", "", null).?;
    view.selected.set(.{ .provider = .slack, .account = "hub-cache", .id = "slack:T0ABC123:C1" });
    for (rows[1..3]) |row| {
        view = hub.accountView(row.object, "hub-cache", "", "", view).?;
        try std.testing.expectEqualStrings("Slack Alpha Workspace", view.labelText());
        try std.testing.expectEqualStrings("slack:T0ABC123:C1", view.selected.key().id);
    }
    view = hub.accountView(rows[3].object, "hub-cache", "Alpha Workspace", "", view).?;
    try std.testing.expectEqualStrings("Slack Beta Workspace", view.labelText());
    var direct: ?@import("messenger_view.zig").Account = null;
    for (rows) |row| {
        direct = hub.accountView(row.object, "hub-cache", "Cached Workspace", "Direct Workspace", direct);
        try std.testing.expectEqualStrings("Slack Direct Workspace", direct.?.labelText());
    }
}

test "hub view accounts prefer explicit accounts and safely fall back for unprefixed handles" {
    const rows =
        \\[
        \\  {"provider":"whatsapp","account":"explicit","jid":"personal:0000000000@s.whatsapp.net"},
        \\  {"provider":"slack","account":"hub-cache","jid":"slack:T0ABC123:C0000000000"},
        \\  {"provider":"whatsapp","jid":"0000000000@s.whatsapp.net"},
        \\  {"provider":"whatsapp","jid":"personal:opaque"},
        \\  {"provider":"whatsapp","jid":":contact@example.invalid"},
        \\  {"provider":"slack","jid":"slack:T0ABC123"},
        \\  {"provider":"slack","jid":"slack::channel"},
        \\  {"provider":"slack","jid":"slack:T0ABC123:"},
        \\  {"provider":"telegram","jid":"telegram:opaque"},
        \\  {"provider":"telegram","jid":"opaque"}
        \\]
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, rows, .{});
    defer parsed.deinit();
    for (parsed.value.array.items, 0..) |row, index| {
        try std.testing.expectEqualStrings(if (index == 0) "explicit" else if (index == 8) "telegram" else "hub-cache", hub.viewAccount(row.object, "hub-cache"));
    }
}

test "IGSH-696 Telegram chat avatars require the switch and unified hub without changing other providers" {
    try std.testing.expect(hub.igsh_696_telegram_avatars);
    for ([_]bool{ false, true }) |enabled| {
        for ([_]bool{ false, true }) |unified| {
            try std.testing.expect(hub.chatAvatarEnabled(.whatsapp, unified, enabled));
            try std.testing.expectEqual(enabled and unified, hub.chatAvatarEnabled(.telegram, unified, enabled));
            try std.testing.expect(!hub.chatAvatarEnabled(.slack, unified, enabled));
            try std.testing.expect(!hub.chatAvatarEnabled(.signal, unified, enabled));
        }
    }
}

test "IGSH-696 Telegram avatar requests preserve and escape opaque user group channel and bot handles" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const handles = [_][]const u8{ "telegram:user:1001", "telegram:chat:2001", "telegram:group:2002", "telegram:channel:3001", "telegram:bot:4001", "telegram:opaque +/" };
    const paths = [_][]const u8{
        "/v1/wazig/avatar/telegram%3Auser%3A1001",
        "/v1/wazig/avatar/telegram%3Achat%3A2001",
        "/v1/wazig/avatar/telegram%3Agroup%3A2002",
        "/v1/wazig/avatar/telegram%3Achannel%3A3001",
        "/v1/wazig/avatar/telegram%3Abot%3A4001",
        "/v1/wazig/avatar/telegram%3Aopaque%20%2B%2F",
    };
    for (handles, paths) |handle, path| {
        const request = try hub.binary(allocator, handle, null);
        try std.testing.expectEqualStrings("GET", request.method);
        try std.testing.expectEqualStrings(path, request.path);
    }
    try std.testing.expectError(error.InvalidId, hub.binary(allocator, "telegram:user:bad\nhandle", null));
}

test "IGSH-604 workspace icon route escapes team IDs and rejects invalid IDs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expect(hub.igsh_604_workspace_icons);
    const request = try hub.workspaceIcon(allocator, "fixture +/team?");
    try std.testing.expectEqualStrings("GET", request.method);
    try std.testing.expectEqualStrings("/v1/wazig/workspace-icon/fixture%20%2B%2Fteam%3F", request.path);
    for ([_][]const u8{ "", "bad\nteam", "bad\x7fteam", "bad\xffteam", "bad:team", ".", "..", &([_]u8{'a'} ** 192) }) |invalid| {
        try std.testing.expectError(error.InvalidId, hub.workspaceIcon(allocator, invalid));
    }
    const key = hub.workspaceAvatarKey("slack:fixture-team:fixture-channel").?;
    try std.testing.expectEqualStrings("slack:fixture-team:", key);
    try std.testing.expectEqualStrings(key, hub.workspaceAvatarKey("slack:fixture-team:other-channel").?);
    try std.testing.expect(!std.mem.eql(u8, key, hub.workspaceAvatarKey("slack:other-team:fixture-channel").?));
    for ([_][]const u8{ "slack::channel", "slack:team:", "slack:team", "other:team:channel", "slack:bad\nteam:channel" }) |invalid| {
        try std.testing.expect(hub.workspaceAvatarKey(invalid) == null);
    }
}

test "IGSH-604 provider badge chooses cached workspace icon fallback and green WhatsApp mark" {
    try std.testing.expectEqual(.workspace_icon, hub.providerBadge(.slack, true, true));
    try std.testing.expectEqual(.letter_s, hub.providerBadge(.slack, false, true));
    try std.testing.expectEqual(.whatsapp_mark, hub.providerBadge(.whatsapp, false, true));
    try std.testing.expectEqual(.telegram_mark, hub.providerBadge(.telegram, false, true));
    try std.testing.expectEqual(.letter_s, hub.providerBadge(.slack, true, false));
    try std.testing.expectEqual(.letter_w, hub.providerBadge(.whatsapp, true, false));
    try std.testing.expectEqual(.letter_t, hub.providerBadge(.telegram, true, false));
}

test "Signal rows have a fixed account and an exclusive provider view" {
    const allocator = std.testing.allocator;
    const raw = "[{\"provider\":\"signal\",\"jid\":\"signal:fixture-contact\",\"kind\":\"direct\"},{\"provider\":\"signal\",\"jid\":\"signal:group:fixture-group\",\"account\":\"ignored\",\"kind\":\"group\"}]";
    const normalized = try hub.normalize(allocator, raw, .chats, "");
    defer allocator.free(normalized);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, normalized, .{});
    defer parsed.deinit();
    for (parsed.value.object.get("data").?.array.items) |row| {
        try std.testing.expectEqual(@import("transport.zig").Provider.signal, hub.sourceProvider(row.object).?);
        try std.testing.expectEqualStrings("signal", hub.viewAccount(row.object, "cache"));
        try std.testing.expectEqual(@as(?@import("transport.zig").Provider, .signal), hub.providerForView(row.object, .signal));
        try std.testing.expectEqual(@as(?@import("transport.zig").Provider, null), hub.providerForView(row.object, .slack));
    }
}

test "Signal send rejection preserves rate limit and captcha reasons only for matching status" {
    const allocator = std.testing.allocator;
    const limited = "{\"error\":\"signal rate limited\",\"retry_after\":30}";
    const captcha = "{\"error\":\"signal captcha required\"}";
    try std.testing.expectEqualStrings("signal rate limited", hub.signalSendFailure(allocator, 429, limited).?);
    try std.testing.expectEqualStrings("signal captcha required", hub.signalSendFailure(allocator, 403, captcha).?);
    try std.testing.expect(hub.signalSendFailure(allocator, 200, limited) == null);
    try std.testing.expect(hub.signalSendFailure(allocator, 403, limited) == null);
    try std.testing.expect(hub.signalSendFailure(allocator, 429, captcha) == null);
    try std.testing.expect(hub.signalSendFailure(allocator, 429, "invalid") == null);
    try std.testing.expect(hub.signalSendFailure(allocator, 429, "[]") == null);
}

test "Signal read receipts retain incoming author and timestamp rather than an empty id" {
    const allocator = std.testing.allocator;
    const raw = "[{\"MsgID\":\"fixture-self:3000\",\"ChatJID\":\"signal:fixture-contact\",\"FromMe\":true},{\"MsgID\":\"fixture-reaction:2001\",\"ChatJID\":\"signal:fixture-contact\",\"FromMe\":false,\"ReactionToID\":\"fixture-sender:2000\"},{\"MsgID\":\"fixture-sender:2000\",\"ChatJID\":\"signal:fixture-contact\",\"FromMe\":false}]";
    const normalized = try hub.normalize(allocator, raw, .messages, "signal:fixture-contact");
    defer allocator.free(normalized);
    const id = try hub.readMessageId(allocator, normalized);
    defer allocator.free(id);
    try std.testing.expectEqualStrings("fixture-sender:2000", id);
    try std.testing.expectError(error.NoIncomingMessage, hub.readMessageId(allocator, "{\"data\":{\"messages\":[]}}"));
}

test "Signal provider mark shares the workspace badge switch and retains letter fallback" {
    try std.testing.expectEqual(.signal_mark, hub.providerBadge(.signal, false, true));
    try std.testing.expectEqual(.signal_mark, hub.providerBadge(.signal, true, true));
    try std.testing.expectEqual(.letter_s, hub.providerBadge(.signal, false, false));
    try std.testing.expectEqual(.letter_s, hub.providerBadge(.signal, true, false));
}

test "Telegram user group channel ids retain their opaque hub identity and fixed view" {
    const allocator = std.testing.allocator;
    const raw = "[{\"provider\":\"telegram\",\"jid\":\"telegram:user:1001\"},{\"provider\":\"telegram\",\"jid\":\"telegram:chat:2001\",\"account\":\"ignored\"},{\"provider\":\"telegram\",\"jid\":\"telegram:channel:3001\"}]";
    const normalized = try hub.normalize(allocator, raw, .chats, "");
    defer allocator.free(normalized);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, normalized, .{});
    defer parsed.deinit();
    for (parsed.value.object.get("data").?.array.items, [_][]const u8{ "telegram:user:1001", "telegram:chat:2001", "telegram:channel:3001" }) |row, id| {
        try std.testing.expectEqualStrings(id, row.object.get("jid").?.string);
        try std.testing.expectEqual(@import("transport.zig").Provider.telegram, hub.sourceProvider(row.object).?);
        try std.testing.expectEqualStrings("telegram", hub.viewAccount(row.object, "cache"));
        try std.testing.expectEqual(@as(?@import("transport.zig").Provider, .telegram), hub.providerForView(row.object, .telegram));
        try std.testing.expect(hub.providerForView(row.object, .signal) == null);
        const request = try hub.messages(allocator, id, 80, "1000");
        defer allocator.free(request.path);
        try std.testing.expect(std.mem.indexOf(u8, request.path, "%3A") != null);
        try std.testing.expect(std.mem.endsWith(u8, request.path, "&before=1000"));
    }
    const view = @import("messenger_view.zig").Account.init(.telegram, "telegram", "");
    try std.testing.expectEqualStrings("Telegram", view.labelText());
    const messages = try hub.normalize(allocator, "[{\"MsgID\":\"1001\",\"ChatJID\":\"telegram:user:1001\",\"FromMe\":false,\"quoted_msg_id\":\"1000\"}]", .messages, "telegram:user:1001");
    defer allocator.free(messages);
    const incoming = try hub.readMessageId(allocator, messages);
    defer allocator.free(incoming);
    try std.testing.expectEqualStrings("1001", incoming);
}

test "Telegram provider mark shares the badge switch and retains letter fallback" {
    try std.testing.expectEqual(.telegram_mark, hub.providerBadge(.telegram, false, true));
    try std.testing.expectEqual(.telegram_mark, hub.providerBadge(.telegram, true, true));
    try std.testing.expectEqual(.letter_t, hub.providerBadge(.telegram, false, false));
    try std.testing.expectEqual(.letter_t, hub.providerBadge(.telegram, true, false));
}

test "Telegram rate limit text requires matching status and exact hub reason" {
    const allocator = std.testing.allocator;
    const limited = "{\"error\":\"telegram rate limited\",\"retry_after\":30}";
    try std.testing.expectEqualStrings("telegram rate limited", hub.telegramSendFailure(allocator, 429, limited).?);
    for ([_]u32{ 200, 401, 403, 502 }) |status| try std.testing.expect(hub.telegramSendFailure(allocator, status, limited) == null);
    for ([_][]const u8{ "invalid", "[]", "{}", "{\"error\":\"signal rate limited\"}" }) |raw| try std.testing.expect(hub.telegramSendFailure(allocator, 429, raw) == null);
}

test "Telegram saved flag survives normalization and is never inferred from an id" {
    const allocator = std.testing.allocator;
    const raw = "[{\"provider\":\"telegram\",\"jid\":\"telegram:user:9001\",\"saved\":true},{\"provider\":\"telegram\",\"jid\":\"telegram:user:1001\",\"saved\":false},{\"provider\":\"telegram\",\"jid\":\"telegram:chat:2001\"},{\"provider\":\"telegram\",\"jid\":\"telegram:channel:3001\",\"saved\":\"true\"},{\"provider\":\"signal\",\"jid\":\"signal:fixture\",\"saved\":true}]";
    const normalized = try hub.normalize(allocator, raw, .chats, "");
    defer allocator.free(normalized);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, normalized, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("data").?.array.items;
    try std.testing.expect(hub.savedMessages(rows[0].object));
    for (rows[1..]) |row| try std.testing.expect(!hub.savedMessages(row.object));
}

test "Slack thread metadata survives unified normalization and sends retain parent identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const raw =
        \\[{"MsgID":"1740000000.000100","ChatJID":"fixture","reply_count":30,"latest_reply":"1740000030.000100"},
        \\ {"MsgID":"1740000001.000100","ChatJID":"fixture","thread_ts":"1740000000.000100","quoted_msg_id":"ordinary-quote"}]
    ;
    const normalized = try hub.normalize(allocator, raw, .messages, "fixture");
    const value = try std.json.parseFromSliceLeaky(std.json.Value, allocator, normalized, .{});
    const rows = value.object.get("data").?.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(i64, 30), rows[0].object.get("reply_count").?.integer);
    try std.testing.expectEqualStrings("1740000030.000100", rows[0].object.get("latest_reply").?.string);
    try std.testing.expectEqualStrings("1740000000.000100", rows[1].object.get("thread_ts").?.string);
    try std.testing.expectEqualStrings("ordinary-quote", rows[1].object.get("quoted_msg_id").?.string);
    const request = try hub.send(allocator, "fixture", "Synthetic thread reply", "1740000000.000100", "fixture-client");
    const body = try std.json.parseFromSliceLeaky(std.json.Value, allocator, request.body, .{});
    try std.testing.expectEqualStrings("1740000000.000100", body.object.get("reply_to").?.string);
}

test "Archive merges inbox candidates for local archives without changing provider flags" {
    const archived = "[{\"provider\":\"whatsapp\",\"jid\":\"fixture-wa\",\"archived\":true},{\"provider\":\"signal\",\"jid\":\"fixture-signal\",\"archived\":true}]";
    const inbox = "[{\"provider\":\"slack\",\"account\":\"fixture-team\",\"jid\":\"fixture-channel\",\"archived\":false,\"unread_count\":3},{\"provider\":\"whatsapp\",\"jid\":\"fixture-inbox\",\"archived\":false}]";
    const raw = try hub.archivedChats(std.testing.allocator, archived, inbox);
    defer std.testing.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("data").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), rows.len);
    try std.testing.expectEqualStrings("fixture-wa", rows[0].object.get("jid").?.string);
    try std.testing.expect(rows[0].object.get("archived").?.bool);
    try std.testing.expectEqualStrings("fixture-signal", rows[1].object.get("jid").?.string);
    try std.testing.expectEqualStrings("fixture-channel", rows[2].object.get("jid").?.string);
    try std.testing.expect(!rows[2].object.get("archived").?.bool);
    try std.testing.expectEqual(@as(i64, 3), rows[2].object.get("unread_count").?.integer);
    try std.testing.expectEqualStrings("fixture-inbox", rows[3].object.get("jid").?.string);
    try std.testing.expect(!rows[3].object.get("archived").?.bool);
}

test "IGSH-670 account scoped emoji routes and Giphy attachment media" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try std.testing.expectEqualStrings("/v1/wazig/slack/emoji?account=fixture-team", (try hub.slackEmoji(allocator, "fixture-team", null)).path);
    try std.testing.expectEqualStrings("/v1/wazig/slack/emoji/media?account=fixture-team&name=custom%2Bname", (try hub.slackEmoji(allocator, "fixture-team", "custom+name")).path);
    try std.testing.expectError(error.InvalidId, hub.slackEmoji(allocator, "..", null));
    const raw =
        \\[{"MsgID":"gif","ChatJID":"slack:fixture-team:channel","Text":"Synthetic Giphy","attachments":[{"service_name":"Giphy","image_url":"https://example.invalid/animation.gif","image_mimetype":"image/gif"}],"reactions":[{"name":"tea","count":1},{"name":"custom_fixture","count":2}],"SlackEmojiPaths":{"custom_fixture":"untrusted-local-path"}}]
    ;
    const normalized = try hub.normalize(allocator, raw, .messages, "slack:fixture-team:channel");
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, normalized, .{});
    defer parsed.deinit();
    const row = hub.messageRows(parsed.value).?[0].object;
    try std.testing.expectEqualStrings("image", row.get("MediaType").?.string);
    try std.testing.expectEqualStrings("image/gif", row.get("MimeType").?.string);
    try std.testing.expectEqualStrings("🍵 1  :custom_fixture: 2", row.get("ReactionEmoji").?.string);
    try std.testing.expect(!row.contains("SlackEmojiPaths"));
}

test "hub Archive keeps a provider-unarchived Telegram candidate and deduplicates archived rows" {
    const archived = "[{\"provider\":\"telegram\",\"account\":\"telegram\",\"jid\":\"telegram:user:7001\",\"archived\":true}]";
    const inbox = "[{\"provider\":\"telegram\",\"account\":\"telegram\",\"jid\":\"telegram:user:7001\",\"archived\":false},{\"provider\":\"telegram\",\"account\":\"telegram\",\"jid\":\"telegram:user:7002\",\"archived\":false}]";
    const raw = try hub.archivedChats(std.testing.allocator, archived, inbox);
    defer std.testing.allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, raw, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("data").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expect(rows[0].object.get("archived").?.bool);
    try std.testing.expectEqualStrings("telegram:user:7002", rows[1].object.get("jid").?.string);
    try std.testing.expect(!rows[1].object.get("archived").?.bool);
    const request = try hub.archive(std.testing.allocator, "telegram:user:7002", true);
    defer std.testing.allocator.free(request.body);
    try std.testing.expectEqualStrings("/v1/wazig/archive", request.path);
    try std.testing.expectEqualStrings("{\"chat\":\"telegram:user:7002\",\"archived\":true}", request.body);
}

test "Show archived keeps provider flagged Slack rows available to the existing archived-only command" {
    const allocator = std.testing.allocator;
    const raw = try hub.archivedChats(allocator, "[{\"provider\":\"slack\",\"account\":\"workspace\",\"jid\":\"channel\",\"archived\":true}]", "[]");
    defer allocator.free(raw);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();
    const rows = parsed.value.object.get("data").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expect(rows[0].object.get("archived").?.bool);
    try std.testing.expectEqualStrings("slack", rows[0].object.get("provider").?.string);
}
