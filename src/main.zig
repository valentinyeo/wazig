const std = @import("std");

const avatar = @import("avatar.zig");
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("COBJMACROS", "1");
    @cInclude("windows.h");
    @cInclude("windowsx.h");
    @cInclude("commctrl.h");
    @cInclude("dwmapi.h");
    @cInclude("shellapi.h");
    @cInclude("shobjidl.h");
    @cInclude("wincodec.h");
    @cInclude("mfplay.h");
    @cInclude("winhttp.h");
});

const max_chats = 256;
const max_groups = 1024;
const max_messages = 100;
const timer_refresh = 1;
const timer_search = 2;
const timer_animation = 3;
const id_search = 1008;
const id_chats = 1016;
const id_canvas = 1024;
const id_compose = 1032;
const id_send = 1040;
const id_status = 1048;
const id_dictate = 1056;
const emoji_picker = @import("emoji_picker.zig");
const webp_detect = @import("webp.zig");
const webp = @cImport({
    @cInclude("src/webp/decode.h");
});
const update = @import("update.zig");
const picker_emojis = emoji_picker.picker_emojis;
const picker_base = emoji_picker.picker_base;
const pickerEmojiForCommand = emoji_picker.pickerEmojiForCommand;
const id_emoji = 1064;
const command_search = 2001;
const command_compose = 2002;
const command_unread = 2003;
const command_refresh = 2004;
const command_sync = 2005;
const command_quit = 2006;
const command_archive = 2007;
const command_archived = 2008;
const command_dictate = 2009;
const reaction_like = 3001;
const reaction_love = 3002;
const reaction_laugh = 3003;
const reaction_surprised = 3004;
const reaction_sad = 3005;
const reaction_thanks = 3006;
const reaction_remove = 3007;

const timer_update_check = 4;
const timer_update_restart = 5;
const wm_update_ready = win.WM_APP + 1;
const update_check_interval_ms: u32 = 4 * 60 * 60 * 1000;
const update_restart_delay_ms: u32 = 10 * 1000;
const update_max_asset_bytes: usize = 256 * 1024 * 1024;

const color_bg = rgb(11, 20, 26);
const color_panel = rgb(17, 27, 33);
const color_raised = rgb(32, 44, 51);
const color_selected = rgb(42, 57, 66);
const color_text = rgb(233, 237, 239);
const color_muted = rgb(134, 150, 160);
const color_accent = rgb(0, 168, 132);
const color_incoming = rgb(32, 44, 51);
const color_outgoing = rgb(0, 92, 75);

fn rgb(r: u8, g: u8, b: u8) win.COLORREF {
    return @as(win.COLORREF, r) | (@as(win.COLORREF, g) << 8) | (@as(win.COLORREF, b) << 16);
}

// Palette readable on the dark incoming bubble; FNV-1a over the sender JID
// keeps each person's color stable across sessions.
const sender_palette = [_]win.COLORREF{
    rgb(101, 195, 245), // light blue
    rgb(73, 209, 189), // teal
    rgb(250, 173, 92), // orange
    rgb(191, 149, 244), // violet
    rgb(246, 131, 184), // pink
    rgb(134, 213, 118), // green
    rgb(122, 222, 230), // cyan
    rgb(238, 216, 110), // gold
};

fn senderColor(jid: []const u8) win.COLORREF {
    var hash: u32 = 0x811c9dc5;
    for (jid) |byte| {
        hash ^= byte;
        hash = hash *% 0x01000193;
    }
    return sender_palette[hash % sender_palette.len];
}

fn WideText(comptime capacity: usize) type {
    return struct {
        buf: [capacity + 1]u16 = [_]u16{0} ** (capacity + 1),
        len: usize = 0,

        fn set(self: *@This(), allocator: std.mem.Allocator, text: []const u8) void {
            self.len = 0;
            self.buf[0] = 0;
            const converted = std.unicode.utf8ToUtf16LeAllocZ(allocator, text) catch return;
            defer allocator.free(converted);
            self.len = @min(converted.len, capacity);
            @memcpy(self.buf[0..self.len], converted[0..self.len]);
            self.buf[self.len] = 0;
        }

        fn slice(self: *const @This()) []const u16 {
            return self.buf[0..self.len];
        }

        fn ptr(self: *const @This()) [*:0]const u16 {
            return @ptrCast(&self.buf);
        }
    };
}

fn Utf8Text(comptime capacity: usize) type {
    return struct {
        buf: [capacity + 1]u8 = [_]u8{0} ** (capacity + 1),
        len: usize = 0,

        fn set(self: *@This(), text: []const u8) void {
            self.len = @min(text.len, capacity);
            @memcpy(self.buf[0..self.len], text[0..self.len]);
            self.buf[self.len] = 0;
        }

        fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

const Chat = struct {
    jid: Utf8Text(191) = .{},
    name: WideText(159) = .{},
    kind: WideText(31) = .{},
    timestamp: Utf8Text(47) = .{},
    time: WideText(15) = .{},
    unread_count: i64 = 0,
    unread: bool = false,
    pinned: bool = false,
    archived: bool = false,
};

const Group = struct {
    jid: Utf8Text(191) = .{},
    name: Utf8Text(255) = .{},
};

const Message = struct {
    id: Utf8Text(191) = .{},
    sender_jid: Utf8Text(191) = .{},
    sender: WideText(159) = .{},
    text: WideText(4095) = .{},
    time: WideText(15) = .{},
    media_type: Utf8Text(31) = .{},
    mime_type: Utf8Text(95) = .{},
    local_path: WideText(519) = .{},
    filename: WideText(259) = .{},
    reaction_to: Utf8Text(191) = .{},
    reaction: WideText(31) = .{},
    from_me: bool = false,
    revoked: bool = false,
    bitmap: ?win.HBITMAP = null,
    bitmap_width: i32 = 0,
    bitmap_height: i32 = 0,
    gif_frame_count: u32 = 0,
    gif_frame_index: u32 = 0,
    media_hit: win.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    bubble_hit: win.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    instance: win.HINSTANCE,
    wacli_path: []u8,
    hwnd: ?win.HWND = null,
    search: ?win.HWND = null,
    chats_hwnd: ?win.HWND = null,
    canvas: ?win.HWND = null,
    compose: ?win.HWND = null,
    send: ?win.HWND = null,
    dictate: ?win.HWND = null,
    emoji_btn: ?win.HWND = null,
    status: ?win.HWND = null,
    font: ?win.HFONT = null,
    font_small: ?win.HFONT = null,
    font_bold: ?win.HFONT = null,
    font_emoji: ?win.HFONT = null,
    brush_bg: ?win.HBRUSH = null,
    brush_panel: ?win.HBRUSH = null,
    brush_raised: ?win.HBRUSH = null,
    chats: [max_chats]Chat = [_]Chat{.{}} ** max_chats,
    chat_count: usize = 0,
    groups: [max_groups]Group = [_]Group{.{}} ** max_groups,
    group_count: usize = 0,
    messages: [max_messages]Message = [_]Message{.{}} ** max_messages,
    message_count: usize = 0,
    selected_chat: usize = 0,
    selected_message: ?usize = null,
    scroll_y: i32 = 0,
    max_scroll: i32 = 0,
    unread_only: bool = false,
    show_archived: bool = false,
    group_refresh_ticks: u8 = 0,
    deepgram_configured: bool = false,
    sync_child: ?std.process.Child = null,
    media_child: ?std.process.Child = null,
    media_attempts: [512]u64 = [_]u64{0} ** 512,
    media_attempt_count: usize = 0,
    wic_factory: [*c]win.IWICImagingFactory = null,
    player_window: ?win.HWND = null,
    mf_player: ?*win.IMFPMediaPlayer = null,
    audio_window: ?win.HWND = null,
    audio_player: ?*win.IMFPMediaPlayer = null,
    audio_rate: f64 = 1.0,
    audio_message_id: Utf8Text(191) = .{},
    displayed_jid: Utf8Text(191) = .{},
    displayed_timestamp: Utf8Text(47) = .{},
    played: [2048]u64 = [_]u64{0} ** 2048,
    played_count: usize = 0,
    played_path: []u8 = &.{},
    tooltips: ?win.HWND = null,
};

var app_ptr: ?*App = null;

fn lit(comptime text: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

fn loword(value: usize) u16 {
    return @truncate(value & 0xffff);
}

fn hiword(value: usize) u16 {
    return @truncate((value >> 16) & 0xffff);
}

fn controlId(id: usize) win.HMENU {
    return winHandle(win.HMENU, id);
}

fn winHandle(comptime Handle: type, value: usize) Handle {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}

fn setFont(hwnd: ?win.HWND, font: ?win.HFONT) void {
    if (hwnd) |window| {
        _ = win.SendMessageW(window, win.WM_SETFONT, if (font) |value| @intFromPtr(value) else 0, 1);
    }
}

fn addTooltip(tt: win.HWND, tool: ?win.HWND, text: [*:0]const u16) void {
    const target = tool orelse return;
    var info = win.TOOLINFOW{
        .cbSize = @sizeOf(win.TOOLINFOW),
        .uFlags = win.TTF_IDISHWND | win.TTF_SUBCLASS,
        .hwnd = win.GetParent(target),
        .uId = @intFromPtr(target),
        .lpszText = @constCast(text),
    };
    _ = win.SendMessageW(tt, win.TTM_ADDTOOLW, 0, @as(win.LPARAM, @bitCast(@intFromPtr(&info))));
}

fn createTooltips(a: *App, hwnd: win.HWND) void {
    const tt = win.CreateWindowExW(
        win.WS_EX_TOPMOST,
        lit("tooltips_class32"),
        null,
        win.WS_POPUP | win.TTS_NOPREFIX,
        0,
        0,
        0,
        0,
        hwnd,
        null,
        a.instance,
        null,
    ) orelse return;
    a.tooltips = tt;
    // TTM_SETMAXWIDTH (WM_USER + 24); not exposed by the commctrl.h import
    _ = win.SendMessageW(tt, 0x400 + 24, 0, 260);
    addTooltip(tt, a.search, lit("Search chats  Ctrl+F or /"));
    addTooltip(tt, a.chats_hwnd, lit("Chats  ↑/↓ or J/K move · Enter to compose"));
    addTooltip(tt, a.canvas, lit("Messages  Ctrl+Tab select · right-click to react"));
    addTooltip(tt, a.compose, lit("Message box  Enter sends · Shift+Enter new line"));
    addTooltip(tt, a.dictate, lit("Dictate  Ctrl+D"));
    addTooltip(tt, a.send, lit("Send message  Enter"));
    addTooltip(tt, a.emoji_btn, lit("Emoji menu"));
}

fn getString(object: std.json.ObjectMap, key: []const u8) []const u8 {
    const value = object.get(key) orelse return "";
    return switch (value) {
        .string => |text| text,
        else => "",
    };
}

fn getBool(object: std.json.ObjectMap, key: []const u8) bool {
    const value = object.get(key) orelse return false;
    return switch (value) {
        .bool => |flag| flag,
        else => false,
    };
}

fn getInt(object: std.json.ObjectMap, key: []const u8) i64 {
    const value = object.get(key) orelse return 0;
    return switch (value) {
        .integer => |number| number,
        else => 0,
    };
}

fn runWacli(a: *App, argv: []const []const u8) !std.json.Parsed(std.json.Value) {
    const result = try std.process.run(a.allocator, a.io, .{
        .argv = argv,
        .stdout_limit = .limited(8 * 1024 * 1024),
        .stderr_limit = .limited(256 * 1024),
        .create_no_window = true,
    });
    defer {
        a.allocator.free(result.stdout);
        a.allocator.free(result.stderr);
    }
    const exit_ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!exit_ok) return error.WacliFailed;
    return std.json.parseFromSlice(std.json.Value, a.allocator, result.stdout, .{});
}

fn timestampPart(timestamp: []const u8, start: usize, length: usize) ?u16 {
    if (start + length > timestamp.len) return null;
    var value: u16 = 0;
    for (timestamp[start .. start + length]) |character| {
        if (character < '0' or character > '9') return null;
        value = value * 10 + character - '0';
    }
    return value;
}

fn formatTime(target: *WideText(15), allocator: std.mem.Allocator, timestamp: []const u8) void {
    if (timestamp.len < 16) {
        target.set(allocator, "");
        return;
    }
    if (timestamp.len >= 19) {
        var utc = std.mem.zeroes(win.SYSTEMTIME);
        utc.wYear = timestampPart(timestamp, 0, 4) orelse 0;
        utc.wMonth = timestampPart(timestamp, 5, 2) orelse 0;
        utc.wDay = timestampPart(timestamp, 8, 2) orelse 0;
        utc.wHour = timestampPart(timestamp, 11, 2) orelse 0;
        utc.wMinute = timestampPart(timestamp, 14, 2) orelse 0;
        utc.wSecond = timestampPart(timestamp, 17, 2) orelse 0;
        var local = std.mem.zeroes(win.SYSTEMTIME);
        if (utc.wYear > 0 and win.SystemTimeToTzSpecificLocalTime(null, &utc, &local) != 0) {
            var buffer: [6]u8 = undefined;
            const rendered = std.fmt.bufPrint(&buffer, "{d:0>2}:{d:0>2}", .{ local.wHour, local.wMinute }) catch timestamp[11..16];
            target.set(allocator, rendered);
            return;
        }
    }
    target.set(allocator, timestamp[11..16]);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var matched = true;
        for (needle, 0..) |character, index| {
            if (std.ascii.toLower(haystack[start + index]) != std.ascii.toLower(character)) {
                matched = false;
                break;
            }
        }
        if (matched) return true;
    }
    return false;
}

fn groupName(a: *const App, jid: []const u8) ?[]const u8 {
    for (a.groups[0..a.group_count]) |*group| {
        if (std.mem.eql(u8, group.jid.slice(), jid) and group.name.len > 0) return group.name.slice();
    }
    return null;
}

fn refreshGroups(a: *App) void {
    const args = [_][]const u8{ a.wacli_path, "--json", "--read-only", "groups", "list", "--limit", "1000" };
    var parsed = runWacli(a, &args) catch return;
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |object| object,
        else => return,
    };
    const data_value = root.get("data") orelse return;
    const data = switch (data_value) {
        .array => |items| items,
        else => return,
    };
    a.group_count = 0;
    for (data.items) |item| {
        if (a.group_count >= max_groups) break;
        const object = switch (item) {
            .object => |value| value,
            else => continue,
        };
        var group = Group{};
        group.jid.set(getString(object, "JID"));
        group.name.set(getString(object, "Name"));
        if (group.jid.len == 0 or group.name.len == 0) continue;
        a.groups[a.group_count] = group;
        a.group_count += 1;
    }
}

fn refreshChats(a: *App) void {
    var query_wide: [256]u16 = [_]u16{0} ** 256;
    const query_len = if (a.search) |search| @as(usize, @intCast(win.GetWindowTextW(search, &query_wide, query_wide.len))) else 0;
    const query_utf8 = if (query_len > 0) std.unicode.utf16LeToUtf8Alloc(a.allocator, query_wide[0..query_len]) catch null else null;
    defer if (query_utf8) |query| a.allocator.free(query);

    var args: [12][]const u8 = undefined;
    var count: usize = 0;
    args[count] = a.wacli_path;
    count += 1;
    args[count] = "--json";
    count += 1;
    args[count] = "--read-only";
    count += 1;
    args[count] = "chats";
    count += 1;
    args[count] = "list";
    count += 1;
    args[count] = "--limit";
    count += 1;
    args[count] = "250";
    count += 1;
    args[count] = if (a.show_archived) "--archived" else "--no-archived";
    count += 1;
    if (a.unread_only) {
        args[count] = "--unread";
        count += 1;
    }

    var selected_jid: [192]u8 = [_]u8{0} ** 192;
    var selected_len: usize = 0;
    if (a.selected_chat < a.chat_count) {
        selected_len = a.chats[a.selected_chat].jid.len;
        @memcpy(selected_jid[0..selected_len], a.chats[a.selected_chat].jid.slice());
    }

    var parsed = runWacli(a, args[0..count]) catch {
        setStatus(a, "Unable to read chats from wacli");
        return;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const data_value = root.get("data") orelse return;
    const data = switch (data_value) {
        .array => |items| items,
        else => return,
    };
    a.chat_count = 0;
    for (data.items) |item| {
        if (a.chat_count >= max_chats) break;
        const object = switch (item) {
            .object => |o| o,
            else => continue,
        };
        var chat = Chat{};
        const jid = getString(object, "jid");
        const raw_name = getString(object, "name");
        const display_name = groupName(a, jid) orelse raw_name;
        if (query_utf8) |query| {
            if (!containsIgnoreCase(display_name, query) and !containsIgnoreCase(jid, query)) continue;
        }
        chat.jid.set(jid);
        chat.name.set(a.allocator, display_name);
        chat.kind.set(a.allocator, if (std.mem.endsWith(u8, jid, "@g.us")) "Group" else getString(object, "kind"));
        chat.timestamp.set(getString(object, "last_message_ts"));
        formatTime(&chat.time, a.allocator, chat.timestamp.slice());
        chat.unread = getBool(object, "unread");
        chat.unread_count = getInt(object, "unread_count");
        chat.pinned = getBool(object, "pinned");
        chat.archived = getBool(object, "archived");
        a.chats[a.chat_count] = chat;
        a.chat_count += 1;
    }
    var i: usize = 1;
    while (i < a.chat_count) : (i += 1) {
        var j = i;
        while (j > 0 and std.mem.order(u8, a.chats[j - 1].timestamp.slice(), a.chats[j].timestamp.slice()) == .lt) : (j -= 1) {
            const temporary = a.chats[j - 1];
            a.chats[j - 1] = a.chats[j];
            a.chats[j] = temporary;
        }
    }

    a.selected_chat = 0;
    if (selected_len > 0) {
        for (a.chats[0..a.chat_count], 0..) |chat, index| {
            if (std.mem.eql(u8, selected_jid[0..selected_len], chat.jid.slice())) {
                a.selected_chat = index;
                break;
            }
        }
    }
    if (a.chats_hwnd) |list| {
        _ = win.SendMessageW(list, win.WM_SETREDRAW, 0, 0);
        _ = win.SendMessageW(list, win.LB_RESETCONTENT, 0, 0);
        for (a.chats[0..a.chat_count]) |*chat| {
            _ = win.SendMessageW(list, win.LB_ADDSTRING, 0, @bitCast(@intFromPtr(chat.name.ptr())));
        }
        if (a.chat_count > 0) _ = win.SendMessageW(list, win.LB_SETCURSEL, a.selected_chat, 0);
        _ = win.SendMessageW(list, win.WM_SETREDRAW, 1, 0);
        _ = win.InvalidateRect(list, null, win.TRUE);
    }
    var status_buffer: [64]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buffer, "{d} chats", .{a.chat_count}) catch "Chats loaded";
    setStatus(a, status);
}

fn clearMessages(a: *App) void {
    for (a.messages[0..a.message_count]) |*message| {
        if (message.bitmap) |bitmap| _ = win.DeleteObject(bitmap);
    }
    a.message_count = 0;
    a.selected_message = null;
}

fn messagesAreCurrent(a: *const App) bool {
    if (a.chat_count == 0 or a.selected_chat >= a.chat_count) return a.displayed_jid.len == 0;
    const chat = &a.chats[a.selected_chat];
    return std.mem.eql(u8, a.displayed_jid.slice(), chat.jid.slice()) and
        std.mem.eql(u8, a.displayed_timestamp.slice(), chat.timestamp.slice());
}

fn isImage(message: *const Message) bool {
    return std.ascii.eqlIgnoreCase(message.media_type.slice(), "image") or
        std.ascii.eqlIgnoreCase(message.media_type.slice(), "sticker");
}

fn isVideo(message: *const Message) bool {
    return std.ascii.eqlIgnoreCase(message.media_type.slice(), "video");
}

fn isAudio(message: *const Message) bool {
    return std.ascii.eqlIgnoreCase(message.media_type.slice(), "audio") or
        std.mem.startsWith(u8, message.mime_type.slice(), "audio/");
}

fn wasPlayed(a: *App, id: []const u8) bool {
    const hash = std.hash.Wyhash.hash(0, id);
    for (a.played[0..@min(a.played_count, a.played.len)]) |entry| if (entry == hash) return true;
    return false;
}

fn loadPlayed(a: *App) void {
    if (a.played_path.len == 0) return;
    const contents = std.Io.Dir.readFileAlloc(.cwd(), a.io, a.played_path, a.allocator, std.Io.Limit.limited(128 * 1024)) catch return;
    defer a.allocator.free(contents);
    var lines = std.mem.tokenizeAny(u8, contents, "\r\n");
    while (lines.next()) |line| {
        if (a.played_count >= a.played.len) break;
        a.played[a.played_count] = std.fmt.parseInt(u64, line, 16) catch continue;
        a.played_count += 1;
    }
}

fn markPlayed(a: *App, id: []const u8) void {
    if (id.len == 0 or wasPlayed(a, id)) return;
    const hash = std.hash.Wyhash.hash(0, id);
    // ponytail: fixed 2048-entry ring; once full, oldest entries are overwritten and fall back to unplayed
    a.played[a.played_count % a.played.len] = hash;
    a.played_count += 1;
    if (a.played_path.len == 0) return;
    var buffer: [40]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{x}\n", .{hash}) catch return;
    var contents = std.ArrayList(u8).empty;
    defer contents.deinit(a.allocator);
    if (std.Io.Dir.readFileAlloc(.cwd(), a.io, a.played_path, a.allocator, std.Io.Limit.limited(128 * 1024))) |existing| {
        defer a.allocator.free(existing);
        contents.appendSlice(a.allocator, existing) catch return;
    } else |_| {}
    contents.appendSlice(a.allocator, line) catch return;
    std.Io.Dir.writeFile(.cwd(), a.io, .{ .sub_path = a.played_path, .data = contents.items }) catch return;
}

fn isGif(message: *const Message) bool {
    return std.ascii.eqlIgnoreCase(message.mime_type.slice(), "image/gif");
}

fn ensureVideoBitmap(message: *Message) void {
    var factory: [*c]win.IShellItemImageFactory = null;
    if (win.SHCreateItemFromParsingName(message.local_path.ptr(), null, &win.IID_IShellItemImageFactory, @ptrCast(&factory)) < 0 or factory == null) return;
    defer _ = factory.*.lpVtbl.*.Release.?(factory);
    var bitmap: win.HBITMAP = null;
    const requested = win.SIZE{ .cx = 420, .cy = 250 };
    if (factory.*.lpVtbl.*.GetImage.?(factory, requested, win.SIIGBF_THUMBNAILONLY | win.SIIGBF_BIGGERSIZEOK, &bitmap) < 0 or bitmap == null) return;
    var details = std.mem.zeroes(win.BITMAP);
    if (win.GetObjectW(bitmap, @sizeOf(win.BITMAP), &details) == 0 or details.bmWidth <= 0 or details.bmHeight <= 0) {
        _ = win.DeleteObject(bitmap);
        return;
    }
    message.bitmap = bitmap;
    message.bitmap_width = details.bmWidth;
    message.bitmap_height = details.bmHeight;
}

fn fillBitmapFromSource(a: *App, message: *Message, source: [*c]win.IWICBitmapSource, source_width: win.UINT, source_height: win.UINT) void {
    var target_width: win.UINT = @min(source_width, 420);
    var target_height: win.UINT = @intCast(@max(1, @divTrunc(@as(u64, source_height) * target_width, source_width)));
    if (target_height > 250) {
        target_height = 250;
        target_width = @intCast(@max(1, @divTrunc(@as(u64, source_width) * target_height, source_height)));
    }

    var converter: [*c]win.IWICFormatConverter = null;
    if (a.wic_factory.*.lpVtbl.*.CreateFormatConverter.?(a.wic_factory, &converter) < 0 or converter == null) return;
    defer _ = converter.*.lpVtbl.*.Release.?(converter);
    if (converter.*.lpVtbl.*.Initialize.?(
        converter,
        source,
        &win.GUID_WICPixelFormat32bppPBGRA,
        win.WICBitmapDitherTypeNone,
        null,
        0,
        win.WICBitmapPaletteTypeCustom,
    ) < 0) return;

    var scaler: [*c]win.IWICBitmapScaler = null;
    if (a.wic_factory.*.lpVtbl.*.CreateBitmapScaler.?(a.wic_factory, &scaler) < 0 or scaler == null) return;
    defer _ = scaler.*.lpVtbl.*.Release.?(scaler);
    if (scaler.*.lpVtbl.*.Initialize.?(scaler, @ptrCast(converter), target_width, target_height, win.WICBitmapInterpolationModeFant) < 0) return;

    const stride: win.UINT = target_width * 4;
    const byte_count: win.UINT = stride * target_height;
    const pixels = a.allocator.alloc(u8, byte_count) catch return;
    defer a.allocator.free(pixels);
    if (scaler.*.lpVtbl.*.CopyPixels.?(@ptrCast(scaler), null, stride, byte_count, pixels.ptr) < 0) return;

    var info = std.mem.zeroes(win.BITMAPINFO);
    info.bmiHeader.biSize = @sizeOf(win.BITMAPINFOHEADER);
    info.bmiHeader.biWidth = @intCast(target_width);
    info.bmiHeader.biHeight = -@as(win.LONG, @intCast(target_height));
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = win.BI_RGB;
    var bits: ?*anyopaque = null;
    const bitmap = win.CreateDIBSection(null, &info, win.DIB_RGB_COLORS, &bits, null, 0) orelse return;
    if (bits == null) {
        _ = win.DeleteObject(bitmap);
        return;
    }
    const destination: [*]u8 = @ptrCast(bits.?);
    @memcpy(destination[0..byte_count], pixels);
    message.bitmap = bitmap;
    message.bitmap_width = @intCast(target_width);
    message.bitmap_height = @intCast(target_height);
}

// Windows WIC has no WebP codec, so stickers (WebP files) would never render.
// Decode them with the vendored libwebp; for animated stickers this returns the
// first frame. ponytail: frames are not animated on screen; use WebPAnimDecoder
// (vendor src/demux) if stickers should move later.
fn ensureWebPBitmap(a: *App, message: *Message) void {
    // local_path is a wide Windows path; convert once for std.fs.
    const path_utf8 = std.unicode.utf16LeToUtf8Alloc(a.allocator, message.local_path.slice()) catch return;
    defer a.allocator.free(path_utf8);
    const data = std.Io.Dir.readFileAlloc(.cwd(), a.io, path_utf8, a.allocator, std.Io.Limit.limited(32 * 1024 * 1024)) catch return;
    defer a.allocator.free(data);
    if (!webp_detect.isWebPBytes(data)) return;
    var width: c_int = 0;
    var height: c_int = 0;
    const pixels = webp.WebPDecodeRGBA(data.ptr, data.len, &width, &height) orelse return;
    defer webp.WebPFree(pixels);
    if (width <= 0 or height <= 0) return;

    // Wrap the decoded pixels as a WIC bitmap so the shared convert/scale/DIB
    // path can be reused.
    var wic_bitmap: [*c]win.IWICBitmap = null;
    const create_hr = a.wic_factory.*.lpVtbl.*.CreateBitmapFromMemory.?(
        a.wic_factory,
        @intCast(width),
        @intCast(height),
        &win.GUID_WICPixelFormat32bppRGBA,
        @intCast(@as(u32, @intCast(width)) * 4),
        @intCast(@as(u32, @intCast(width)) * @as(u32, @intCast(height)) * 4),
        pixels,
        &wic_bitmap,
    );
    if (create_hr < 0 or wic_bitmap == null) return;
    defer _ = wic_bitmap.*.lpVtbl.*.Release.?(wic_bitmap);
    fillBitmapFromSource(a, message, @ptrCast(wic_bitmap), @intCast(width), @intCast(height));
}

fn ensureBitmap(a: *App, message: *Message) void {
    if (message.bitmap != null or message.local_path.len == 0) return;
    if (isVideo(message)) {
        ensureVideoBitmap(message);
        return;
    }
    if (!isImage(message) or a.wic_factory == null) return;
    var decoder: [*c]win.IWICBitmapDecoder = null;
    const decoder_hr = a.wic_factory.*.lpVtbl.*.CreateDecoderFromFilename.?(
        a.wic_factory,
        message.local_path.ptr(),
        null,
        win.GENERIC_READ,
        win.WICDecodeMetadataCacheOnLoad,
        &decoder,
    );
    if (decoder_hr < 0 or decoder == null) {
        ensureWebPBitmap(a, message);
        return;
    }
    defer _ = decoder.*.lpVtbl.*.Release.?(decoder);

    var frame_count: win.UINT = 0;
    if (decoder.*.lpVtbl.*.GetFrameCount.?(decoder, &frame_count) < 0 or frame_count == 0) return;
    message.gif_frame_count = if (isGif(message)) frame_count else 1;
    if (message.gif_frame_index >= message.gif_frame_count) message.gif_frame_index = 0;
    var frame: [*c]win.IWICBitmapFrameDecode = null;
    if (decoder.*.lpVtbl.*.GetFrame.?(decoder, message.gif_frame_index, &frame) < 0 or frame == null) return;
    defer _ = frame.*.lpVtbl.*.Release.?(frame);
    var source_width: win.UINT = 0;
    var source_height: win.UINT = 0;
    if (frame.*.lpVtbl.*.GetSize.?(@ptrCast(frame), &source_width, &source_height) < 0 or source_width == 0 or source_height == 0) return;

    fillBitmapFromSource(a, message, @ptrCast(frame), source_width, source_height);
}

fn downloadMedia(a: *App, message_index: usize, automatic: bool) void {
    if (message_index >= a.message_count or a.selected_chat >= a.chat_count) return;
    if (a.media_child != null) return;
    const message = &a.messages[message_index];
    if (message.media_type.len == 0 or message.id.len == 0) return;
    setStatus(a, if (automatic)
        (if (isVideo(message)) "Downloading video..." else "Downloading image...")
    else
        "Downloading attachment...");
    if (a.hwnd) |hwnd| _ = win.UpdateWindow(hwnd);
    stopSync(a);
    const chat = &a.chats[a.selected_chat];
    const args = [_][]const u8{ a.wacli_path, "--json", "media", "download", "--chat", chat.jid.slice(), "--id", message.id.slice() };
    const child = std.process.spawn(a.io, .{
        .argv = &args,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch {
        setStatus(a, "Could not start attachment download");
        startSync(a);
        return;
    };
    a.media_child = child;
}

fn mediaWasAttempted(a: *App, id: []const u8) bool {
    const hash = std.hash.Wyhash.hash(0, id);
    for (a.media_attempts[0..a.media_attempt_count]) |attempt| if (attempt == hash) return true;
    if (a.media_attempt_count >= a.media_attempts.len) a.media_attempt_count = 0;
    a.media_attempts[a.media_attempt_count] = hash;
    a.media_attempt_count += 1;
    return false;
}

fn autoDownloadNextMedia(a: *App) void {
    if (a.media_child != null) return;
    for (a.messages[0..a.message_count], 0..) |*message, index| {
        if ((!isImage(message) and !isVideo(message)) or message.local_path.len > 0 or message.id.len == 0) continue;
        if (mediaWasAttempted(a, message.id.slice())) continue;
        downloadMedia(a, index, true);
        return;
    }
}

fn checkMediaDownload(a: *App) void {
    if (a.media_child) |*child| {
        const handle = child.id orelse return;
        var code: win.DWORD = 0;
        if (win.GetExitCodeProcess(handle, &code) == 0 or code == win.STILL_ACTIVE) return;
        _ = child.wait(a.io) catch {};
        a.media_child = null;
        startSync(a);
        refreshMessages(a);
        setStatus(a, if (code == 0) "Attachment downloaded" else "Download failed or the attachment expired");
    }
}

fn openMedia(a: *App, message: *const Message) void {
    if (message.local_path.len == 0) return;
    const result = win.ShellExecuteW(a.hwnd.?, lit("open"), message.local_path.ptr(), null, null, win.SW_SHOWNORMAL);
    if (@intFromPtr(result) <= 32) setStatus(a, "Windows could not open the attachment");
}

fn clampPlayerSize(width: u32, height: u32) [2]u32 {
    const max_width: u32 = 800;
    const max_height: u32 = 450;
    if (width == 0 or height == 0) return .{ 640, 360 };
    var w: u64 = width;
    var h: u64 = height;
    if (w > max_width) {
        h = @max(1, h * max_width / w);
        w = max_width;
    }
    if (h > max_height) {
        w = @max(1, w * max_height / h);
        h = max_height;
    }
    return .{ @intCast(w), @intCast(h) };
}

fn playerCallbackQueryInterface(_: [*c]win.IMFPMediaPlayerCallback, riid: [*c]const win.GUID, ppv_object: [*c]?*anyopaque) callconv(.c) win.HRESULT {
    if (ppv_object != null and riid != null) {
        const iid_callback = win.GUID{ .Data1 = 0x766c8ffb, .Data2 = 0x5fdb, .Data3 = 0x4fea, .Data4 = .{ 0xa2, 0x8d, 0xb9, 0x12, 0x99, 0x6f, 0x51, 0xbd } };
        const g = riid.*;
        const is_unknown = g.Data1 == 0 and g.Data2 == 0 and g.Data3 == 0 and g.Data4[0] == 0 and g.Data4[1] == 0 and g.Data4[2] == 0 and g.Data4[3] == 0xc0 and g.Data4[4] == 0 and g.Data4[5] == 0 and g.Data4[6] == 0 and g.Data4[7] == 0x46;
        const is_callback = g.Data1 == iid_callback.Data1 and g.Data2 == iid_callback.Data2 and g.Data3 == iid_callback.Data3 and std.mem.eql(u8, &g.Data4, &iid_callback.Data4);
        if (is_unknown or is_callback) {
            ppv_object.* = @ptrCast(&player_callback);
            _ = playerCallbackAddRef(&player_callback);
            return 0;
        }
        ppv_object.* = null;
    }
    return win.E_NOINTERFACE;
}

fn playerCallbackAddRef(_: [*c]win.IMFPMediaPlayerCallback) callconv(.c) win.ULONG {
    player_callback_refs += 1;
    return player_callback_refs;
}

fn playerCallbackRelease(_: [*c]win.IMFPMediaPlayerCallback) callconv(.c) win.ULONG {
    if (player_callback_refs > 0) player_callback_refs -= 1;
    return player_callback_refs;
}

fn playerCallbackEvent(_: [*c]win.IMFPMediaPlayerCallback, event: [*c]win.MFP_EVENT_HEADER) callconv(.c) void {
    if (event == null) return;
    if (event.*.eEventType == win.MFP_EVENT_TYPE_ERROR) {
        if (app_ptr) |a| {
            if (a.player_window) |hwnd| _ = win.SetWindowTextW(hwnd, lit("Messages · Video (playback failed)"));
            if (a.audio_window) |hwnd| _ = win.SetWindowTextW(hwnd, lit("Messages · Voice note (playback failed)"));
        }
    }
}

var player_callback = win.IMFPMediaPlayerCallback{ .lpVtbl = &player_callback_vtable };
var player_callback_vtable = win.IMFPMediaPlayerCallbackVtbl{
    .QueryInterface = playerCallbackQueryInterface,
    .AddRef = playerCallbackAddRef,
    .Release = playerCallbackRelease,
    .OnMediaPlayerEvent = playerCallbackEvent,
};
var player_callback_refs: u32 = 1;

var player_class_registered: bool = false;

fn closePlayer(a: *App) void {
    if (a.mf_player) |player| {
        _ = player.lpVtbl.*.Shutdown.?(player);
        _ = player.lpVtbl.*.Release.?(player);
        a.mf_player = null;
    }
    if (a.player_window) |hwnd| {
        a.player_window = null;
        _ = win.DestroyWindow(hwnd);
    }
}

fn playerProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    const a = app_ptr orelse return win.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        win.WM_KEYDOWN => {
            if (wparam == 27) { // escape
                closePlayer(a);
                return 0;
            }
        },
        win.WM_CLOSE => {
            closePlayer(a);
            return 0;
        },
        win.WM_DESTROY => {
            if (a.player_window != null and a.player_window.? == hwnd) a.player_window = null;
            if (a.mf_player) |player| {
                _ = player.lpVtbl.*.Shutdown.?(player);
                _ = player.lpVtbl.*.Release.?(player);
                a.mf_player = null;
            }
            return 0;
        },
        else => {},
    }
    return win.DefWindowProcW(hwnd, message, wparam, lparam);
}

// LoadImageW with the name argument passed as an integer (MAKEINTRESOURCE),
// avoiding translate-c's aligned LPCWSTR pointer for resource ids.
extern "user32" fn LoadImageW(instance: win.HINSTANCE, icon_name: usize, icon_type: u32, cx: i32, cy: i32, load_flags: u32) callconv(.c) win.HICON;

fn LoadAppIcon(instance: win.HINSTANCE, cx: i32, cy: i32, flags: u32) win.HICON {
    return LoadImageW(instance, 1, win.IMAGE_ICON, cx, cy, flags);
}

fn playVideoInline(a: *App, message: *const Message) void {
    if (message.local_path.len == 0) return;
    if (a.player_window) |hwnd| {
        _ = win.SetForegroundWindow(hwnd);
        return;
    }
    const size = clampPlayerSize(@intCast(@max(message.bitmap_width, 0)), @intCast(@max(message.bitmap_height, 0)));
    var rect = win.RECT{ .left = 0, .top = 0, .right = @intCast(size[0]), .bottom = @intCast(size[1]) };
    _ = win.AdjustWindowRect(&rect, win.WS_OVERLAPPEDWINDOW, 0);
    const width = rect.right - rect.left;
    const height = rect.bottom - rect.top;

    if (!player_class_registered) {
        var class = win.WNDCLASSEXW{
            .cbSize = @sizeOf(win.WNDCLASSEXW),
            .style = win.CS_HREDRAW | win.CS_VREDRAW,
            .lpfnWndProc = playerProc,
            .hInstance = a.instance,
            .hCursor = win.LoadCursorW(null, @ptrFromInt(32512)),
            .hbrBackground = win.CreateSolidBrush(color_bg),
            .lpszClassName = lit("MessagesVideoPlayer"),
            .hIcon = LoadAppIcon(a.instance, 0, 0, win.LR_DEFAULTSIZE | win.LR_SHARED),
            .hIconSm = LoadAppIcon(a.instance, win.GetSystemMetrics(win.SM_CXSMICON), win.GetSystemMetrics(win.SM_CYSMICON), win.LR_SHARED),
        };
        if (win.RegisterClassExW(&class) == 0) {
            setStatus(a, "Could not open the video player");
            return;
        }
        player_class_registered = true;
    }
    const hwnd = win.CreateWindowExW(
        0,
        lit("MessagesVideoPlayer"),
        lit("Messages · Video"),
        win.WS_OVERLAPPEDWINDOW,
        win.CW_USEDEFAULT,
        win.CW_USEDEFAULT,
        width,
        height,
        a.hwnd orelse null,
        null,
        a.instance,
        null,
    ) orelse {
        setStatus(a, "Could not open the video player");
        return;
    };
    a.player_window = hwnd;
    var player: ?*win.IMFPMediaPlayer = null;
    const hr = win.MFPCreateMediaPlayer(message.local_path.ptr(), 1, win.MFP_OPTION_NONE, &player_callback, hwnd, &player);
    if (hr < 0 or player == null) {
        setStatus(a, "Video playback is not available for this file");
        a.player_window = null;
        _ = win.DestroyWindow(hwnd);
        return;
    }
    a.mf_player = player;
    _ = win.ShowWindow(hwnd, win.SW_SHOW);
}

// Voice notes play in-app through Media Foundation MFPlay so the speed buttons
// (1x / 1.5x / 2x) keep the original pitch; the external player the app used to
// shell out to shifts pitch up and makes voices sound high ("mouse voice").
// Shares player_callback and the MFPlay infrastructure with the video player.
const audio_rates = [3]f64{ 1.0, 1.5, 2.0 };
const audio_button_width: i32 = 92;
const audio_button_height: i32 = 32;
const audio_client_width: i32 = 340;
const audio_client_height: i32 = 108;

fn audioButtonRect(index: usize) win.RECT {
    return .{
        .left = 16 + @as(i32, @intCast(index)) * (audio_button_width + 12),
        .top = 60,
        .right = 16 + @as(i32, @intCast(index)) * (audio_button_width + 12) + audio_button_width,
        .bottom = 60 + audio_button_height,
    };
}

fn audioButtonAt(x: i32, y: i32) ?usize {
    for (audio_rates, 0..) |_, index| {
        const rect = audioButtonRect(index);
        if (x >= rect.left and x <= rect.right and y >= rect.top and y <= rect.bottom) return index;
    }
    return null;
}

fn fileUrl(buffer: []u16, path: []const u16) [:0]const u16 {
    const prefix = [_]u16{ 'f', 'i', 'l', 'e', ':', '/', '/', '/' };
    @memcpy(buffer[0..prefix.len], &prefix);
    var n = prefix.len;
    for (path) |c| {
        if (n + 1 >= buffer.len) break;
        buffer[n] = if (c == '\\') '/' else c;
        n += 1;
    }
    buffer[n] = 0;
    return buffer[0..n :0];
}

fn setAudioRate(a: *App, rate: f64) void {
    a.audio_rate = rate;
    if (a.audio_player) |player| _ = player.lpVtbl.*.SetRate.?(player, @floatCast(rate));
    if (a.audio_window) |hwnd| _ = win.InvalidateRect(hwnd, null, win.TRUE);
}

fn closeAudioPlayer(a: *App) void {
    if (a.audio_player) |player| {
        _ = player.lpVtbl.*.Shutdown.?(player);
        _ = player.lpVtbl.*.Release.?(player);
        a.audio_player = null;
    }
    if (a.audio_window) |hwnd| {
        a.audio_window = null;
        _ = win.DestroyWindow(hwnd);
    }
    a.audio_rate = 1.0;
}

fn drawAudioPlayer(hwnd: win.HWND, a: *App) void {
    var paint: win.PAINTSTRUCT = undefined;
    const hdc = win.BeginPaint(hwnd, &paint);
    defer _ = win.EndPaint(hwnd, &paint);
    var client: win.RECT = undefined;
    _ = win.GetClientRect(hwnd, &client);
    _ = win.FillRect(hdc, &client, a.brush_bg.?);
    _ = win.SetBkMode(hdc, win.TRANSPARENT);
    _ = win.SelectObject(hdc, @ptrCast(a.font_bold.?));
    _ = win.SetTextColor(hdc, color_text);
    var title_rect = win.RECT{ .left = 16, .top = 14, .right = client.right - 16, .bottom = 44 };
    _ = win.DrawTextW(hdc, lit("Voice note"), -1, &title_rect, win.DT_LEFT | win.DT_SINGLELINE | win.DT_VCENTER);
    for (audio_rates, 0..) |rate, index| {
        const rect = audioButtonRect(index);
        const current = a.audio_rate == rate;
        const brush = win.CreateSolidBrush(if (current) color_accent else color_panel) orelse continue;
        const old_brush = win.SelectObject(hdc, brush);
        const pen = win.CreatePen(win.PS_SOLID, 1, if (current) color_accent else color_muted);
        const old_pen = win.SelectObject(hdc, @ptrCast(pen));
        _ = win.RoundRect(hdc, rect.left, rect.top, rect.right, rect.bottom, 12, 12);
        _ = win.SelectObject(hdc, old_brush);
        _ = win.SelectObject(hdc, old_pen);
        _ = win.DeleteObject(brush);
        if (pen) |dead_pen| _ = win.DeleteObject(dead_pen);
        _ = win.SelectObject(hdc, @ptrCast(if (current) a.font_bold.? else a.font.?));
        _ = win.SetTextColor(hdc, if (current) color_bg else color_muted);
        const label: [*:0]const u16 = switch (index) {
            0 => lit("1x"),
            1 => lit("1.5x"),
            else => lit("2x"),
        };
        _ = win.DrawTextW(hdc, label, -1, @ptrCast(@constCast(&rect)), win.DT_CENTER | win.DT_SINGLELINE | win.DT_VCENTER);
    }
}

fn audioProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    const a = app_ptr orelse return win.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        win.WM_PAINT => {
            drawAudioPlayer(hwnd, a);
            return 0;
        },
        win.WM_ERASEBKGND => return 1,
        win.WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @bitCast(loword(@as(usize, @bitCast(lparam)))));
            const y: i32 = @as(i16, @bitCast(hiword(@as(usize, @bitCast(lparam)))));
            if (audioButtonAt(x, y)) |index| setAudioRate(a, audio_rates[index]);
            return 0;
        },
        win.WM_KEYDOWN => {
            const rates_keys = [_]win.WPARAM{ '1', '2', '3' };
            for (rates_keys, 0..) |key, index| {
                if (wparam == key) {
                    setAudioRate(a, audio_rates[index]);
                    return 0;
                }
            }
            if (wparam == 27) { // escape
                closeAudioPlayer(a);
                return 0;
            }
        },
        win.WM_CLOSE => {
            closeAudioPlayer(a);
            return 0;
        },
        win.WM_DESTROY => {
            if (a.audio_window != null and a.audio_window.? == hwnd) a.audio_window = null;
            if (a.audio_player) |player| {
                _ = player.lpVtbl.*.Shutdown.?(player);
                _ = player.lpVtbl.*.Release.?(player);
                a.audio_player = null;
            }
            return 0;
        },
        else => {},
    }
    return win.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn playVoiceNote(a: *App, message: *const Message) void {
    if (message.local_path.len == 0) return;
    if (a.audio_message_id.len > 0 and std.mem.eql(u8, a.audio_message_id.slice(), message.id.slice())) {
        closeAudioPlayer(a);
        return;
    }
    closeAudioPlayer(a);
    var rect = win.RECT{ .left = 0, .top = 0, .right = audio_client_width, .bottom = audio_client_height };
    _ = win.AdjustWindowRect(&rect, win.WS_CAPTION | win.WS_SYSMENU, 0);

    if (!audio_class_registered) {
        var class = win.WNDCLASSEXW{
            .cbSize = @sizeOf(win.WNDCLASSEXW),
            .style = win.CS_HREDRAW | win.CS_VREDRAW,
            .lpfnWndProc = audioProc,
            .hInstance = a.instance,
            .hCursor = win.LoadCursorW(null, @ptrFromInt(32512)),
            .hbrBackground = win.CreateSolidBrush(color_bg),
            .lpszClassName = lit("MessagesVoicePlayer"),
            .hIconSm = null,
        };
        if (win.RegisterClassExW(&class) == 0) {
            setStatus(a, "Could not open the voice player");
            return;
        }
        audio_class_registered = true;
    }
    const hwnd = win.CreateWindowExW(
        0,
        lit("MessagesVoicePlayer"),
        lit("Messages · Voice note"),
        win.WS_CAPTION | win.WS_SYSMENU,
        win.CW_USEDEFAULT,
        win.CW_USEDEFAULT,
        rect.right - rect.left,
        rect.bottom - rect.top,
        a.hwnd orelse null,
        null,
        a.instance,
        null,
    ) orelse {
        setStatus(a, "Could not open the voice player");
        return;
    };
    a.audio_window = hwnd;
    a.audio_rate = 1.0;
    a.audio_message_id.set(message.id.slice());
    var url_buffer: [560]u16 = [_]u16{0} ** 560;
    const url = fileUrl(&url_buffer, message.local_path.slice());
    var player: ?*win.IMFPMediaPlayer = null;
    const hr = win.MFPCreateMediaPlayer(url.ptr, 1, win.MFP_OPTION_NONE, &player_callback, hwnd, &player);
    if (hr < 0 or player == null) {
        closeAudioPlayer(a);
        setStatus(a, "Voice playback is not available for this file");
        openMedia(a, message);
        return;
    }
    a.audio_player = player;
    _ = win.ShowWindow(hwnd, win.SW_SHOW);
}

var audio_class_registered: bool = false;

fn advanceGifs(a: *App) void {
    var changed = false;
    for (a.messages[0..a.message_count]) |*message| {
        if (!isGif(message) or message.gif_frame_count <= 1) continue;
        const hit = message.bubble_hit;
        if (hit.right <= hit.left or hit.bottom <= hit.top) continue;
        if (message.bitmap) |bitmap| _ = win.DeleteObject(bitmap);
        message.bitmap = null;
        message.gif_frame_index = (message.gif_frame_index + 1) % message.gif_frame_count;
        ensureBitmap(a, message);
        changed = true;
    }
    if (changed) {
        if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.FALSE);
    }
}

fn refreshMessages(a: *App) void {
    if (a.chat_count == 0 or a.selected_chat >= a.chat_count) {
        clearMessages(a);
        a.displayed_jid.set("");
        a.displayed_timestamp.set("");
        return;
    }
    const chat = &a.chats[a.selected_chat];
    if (chat.unread or chat.unread_count > 0) {
        const read_args = [_][]const u8{ a.wacli_path, "--json", "chats", "mark-read", "--chat", chat.jid.slice() };
        if (runWacli(a, &read_args)) |parsed_read| {
            parsed_read.deinit();
            chat.unread = false;
            chat.unread_count = 0;
            if (a.chats_hwnd) |list| _ = win.InvalidateRect(list, null, win.FALSE);
        } else |_| {}
    }
    const args = [_][]const u8{
        a.wacli_path, "--json", "--read-only", "messages", "list", "--chat", chat.jid.slice(), "--limit", "80",
    };
    var parsed = runWacli(a, &args) catch {
        setStatus(a, "Unable to read messages from wacli");
        return;
    };
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const data_value = root.get("data") orelse return;
    const data_object = switch (data_value) {
        .object => |o| o,
        else => return,
    };
    const list_value = data_object.get("messages") orelse return;
    const list = switch (list_value) {
        .array => |items| items,
        else => return,
    };
    var selected_id = Utf8Text(191){};
    if (a.selected_message) |selected| {
        if (selected < a.message_count) selected_id.set(a.messages[selected].id.slice());
    }
    clearMessages(a);
    a.selected_message = null;
    const take = @min(list.items.len, max_messages);
    var source_index = take;
    while (source_index > 0) {
        source_index -= 1;
        const object = switch (list.items[source_index]) {
            .object => |o| o,
            else => continue,
        };
        var message = Message{};
        message.id.set(getString(object, "MsgID"));
        message.sender_jid.set(getString(object, "SenderJID"));
        message.sender.set(a.allocator, if (getBool(object, "FromMe")) "You" else getString(object, "SenderName"));
        var text = getString(object, "DisplayText");
        if (text.len == 0) text = getString(object, "Text");
        message.revoked = getBool(object, "Revoked");
        if (message.revoked) text = "Message deleted";
        message.text.set(a.allocator, text);
        message.from_me = getBool(object, "FromMe");
        message.media_type.set(getString(object, "MediaType"));
        message.mime_type.set(getString(object, "MimeType"));
        message.local_path.set(a.allocator, getString(object, "LocalPath"));
        message.filename.set(a.allocator, getString(object, "Filename"));
        message.reaction_to.set(getString(object, "ReactionToID"));
        message.reaction.set(a.allocator, getString(object, "ReactionEmoji"));
        formatTime(&message.time, a.allocator, getString(object, "Timestamp"));
        a.messages[a.message_count] = message;
        a.message_count += 1;
    }
    var reaction_index: usize = 0;
    while (reaction_index < a.message_count) {
        const reaction_to = a.messages[reaction_index].reaction_to.slice();
        if (reaction_to.len == 0) {
            reaction_index += 1;
            continue;
        }
        for (a.messages[0..a.message_count]) |*target| {
            if (std.mem.eql(u8, target.id.slice(), reaction_to)) {
                target.reaction = a.messages[reaction_index].reaction;
                break;
            }
        }
        var shift = reaction_index;
        while (shift + 1 < a.message_count) : (shift += 1) a.messages[shift] = a.messages[shift + 1];
        a.message_count -= 1;
    }
    if (selected_id.len > 0) {
        for (a.messages[0..a.message_count], 0..) |*message, index| {
            if (std.mem.eql(u8, selected_id.slice(), message.id.slice())) {
                a.selected_message = index;
                break;
            }
        }
    }
    a.scroll_y = 0;
    a.displayed_jid.set(chat.jid.slice());
    a.displayed_timestamp.set(chat.timestamp.slice());
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.TRUE);
}

fn startSync(a: *App) void {
    if (a.sync_child != null) return;
    const child = std.process.spawn(a.io, .{
        .argv = &.{ a.wacli_path, "--events", "sync", "--follow", "--max-reconnect", "0" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch {
        setStatus(a, "Could not start live sync");
        return;
    };
    a.sync_child = child;
    setStatus(a, "Live sync running");
}

fn stopSync(a: *App) void {
    if (a.sync_child) |*child| child.kill(a.io);
    a.sync_child = null;
}

fn checkSync(a: *App) void {
    if (a.media_child != null) return;
    if (a.sync_child) |*child| {
        if (child.id) |handle| {
            var code: win.DWORD = 0;
            if (win.GetExitCodeProcess(handle, &code) != 0 and code != win.STILL_ACTIVE) {
                _ = child.wait(a.io) catch {};
                a.sync_child = null;
                startSync(a);
            }
        }
    } else startSync(a);
}

fn setStatus(a: *App, text: []const u8) void {
    if (a.status) |status| {
        var wide_text = WideText(255){};
        wide_text.set(a.allocator, text);
        _ = win.SetWindowTextW(status, wide_text.ptr());
    }
}

fn sendMessage(a: *App) void {
    if (a.compose == null or a.chat_count == 0) return;
    var wide_buffer: [4096]u16 = [_]u16{0} ** 4096;
    const length: usize = @intCast(win.GetWindowTextW(a.compose.?, &wide_buffer, wide_buffer.len));
    if (length == 0) return;
    const text = std.unicode.utf16LeToUtf8Alloc(a.allocator, wide_buffer[0..length]) catch return;
    defer a.allocator.free(text);
    setStatus(a, "Sending...");
    const chat = &a.chats[a.selected_chat];
    const args = [_][]const u8{ a.wacli_path, "--json", "send", "text", "--to", chat.jid.slice(), "--message", text };
    var parsed = runWacli(a, &args) catch {
        setStatus(a, "Send failed");
        return;
    };
    parsed.deinit();
    _ = win.SetWindowTextW(a.compose.?, lit(""));
    setStatus(a, "Sent");
    refreshChats(a);
    refreshMessages(a);
}

fn selectChat(a: *App, delta: i32) void {
    if (a.chat_count == 0) return;
    var next: i32 = @intCast(a.selected_chat);
    next = std.math.clamp(next + delta, 0, @as(i32, @intCast(a.chat_count - 1)));
    a.selected_chat = @intCast(next);
    if (a.chats_hwnd) |list| {
        _ = win.SendMessageW(list, win.LB_SETCURSEL, a.selected_chat, 0);
        _ = win.SendMessageW(list, win.LB_SETTOPINDEX, if (a.selected_chat > 3) a.selected_chat - 3 else 0, 0);
    }
    refreshMessages(a);
}

fn scrollToSelectedMessage(a: *App) void {
    const selected = a.selected_message orelse return;
    const canvas = a.canvas orelse return;
    const hdc = win.GetDC(canvas) orelse return;
    defer _ = win.ReleaseDC(canvas, hdc);
    var client: win.RECT = undefined;
    _ = win.GetClientRect(canvas, &client);
    const bubble_width = std.math.clamp(@divTrunc((client.right - client.left) * 7, 10), 280, 620);
    var total_height: i32 = 18;
    for (a.messages[0..a.message_count], 0..) |*message, index| total_height += measureMessage(hdc, a, message, bubble_width, showSenderName(a, index)) + 8;
    a.max_scroll = @max(0, total_height - (client.bottom - client.top));
    var y = client.bottom - 14 + a.scroll_y;
    var index = a.message_count;
    while (index > 0) {
        index -= 1;
        const height = measureMessage(hdc, a, &a.messages[index], bubble_width, showSenderName(a, index));
        y -= height + 8;
        if (index != selected) continue;
        if (y < client.top + 8) a.scroll_y += client.top + 8 - y;
        if (y + height > client.bottom - 8) a.scroll_y -= y + height - (client.bottom - 8);
        a.scroll_y = std.math.clamp(a.scroll_y, 0, a.max_scroll);
        break;
    }
}

fn selectMessage(a: *App, delta: i32) void {
    if (a.message_count == 0) return;
    if (a.selected_message) |selected| {
        var next = @as(i32, @intCast(selected)) + delta;
        if (next < 0) next = @intCast(a.message_count - 1);
        if (next >= a.message_count) next = 0;
        a.selected_message = @intCast(next);
    } else {
        a.selected_message = a.message_count - 1;
    }
    scrollToSelectedMessage(a);
    if (a.canvas) |canvas| {
        _ = win.SetFocus(canvas);
        _ = win.InvalidateRect(canvas, null, win.TRUE);
    }
}

fn reactionForCommand(command: u16) ?[]const u8 {
    return switch (command) {
        reaction_like => "👍",
        reaction_love => "❤️",
        reaction_laugh => "😂",
        reaction_surprised => "😮",
        reaction_sad => "😢",
        reaction_thanks => "🙏",
        reaction_remove => "",
        else => null,
    };
}

fn reactToSelected(a: *App, command: u16) void {
    const emoji = reactionForCommand(command) orelse return;
    const selected = a.selected_message orelse {
        setStatus(a, "Select a message with Ctrl+Tab or right-click");
        return;
    };
    if (selected >= a.message_count or a.selected_chat >= a.chat_count) return;
    const message = &a.messages[selected];
    const chat = &a.chats[a.selected_chat];
    var args: [14][]const u8 = undefined;
    var count: usize = 0;
    for ([_][]const u8{ a.wacli_path, "--json", "send", "react", "--to", chat.jid.slice(), "--id", message.id.slice(), "--reaction", emoji }) |argument| {
        args[count] = argument;
        count += 1;
    }
    if (std.mem.endsWith(u8, chat.jid.slice(), "@g.us") and message.sender_jid.len > 0) {
        args[count] = "--sender";
        count += 1;
        args[count] = message.sender_jid.slice();
        count += 1;
    }
    setStatus(a, if (emoji.len == 0) "Removing reaction..." else "Adding reaction...");
    var parsed = runWacli(a, args[0..count]) catch {
        setStatus(a, "Reaction failed");
        return;
    };
    parsed.deinit();
    message.reaction.set(a.allocator, emoji);
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.TRUE);
    setStatus(a, if (emoji.len == 0) "Reaction removed" else "Reaction sent");
}

fn insertEmoji(a: *App, emoji: []const u8) void {
    if (a.compose) |compose| {
        var wide = WideText(31){};
        wide.set(a.allocator, emoji);
        if (wide.len == 0) return;
        const length = win.GetWindowTextLengthW(compose);
        _ = win.SendMessageW(compose, win.EM_SETSEL, @bitCast(@as(isize, length)), @bitCast(@as(isize, length)));
        _ = win.SendMessageW(compose, win.EM_REPLACESEL, win.TRUE, @bitCast(@intFromPtr(wide.ptr())));
        _ = win.SendMessageW(compose, win.EM_SCROLLCARET, 0, 0);
        _ = win.SetFocus(compose);
    }
}

fn openEmojiMenu(a: *App) void {
    const menu = win.CreatePopupMenu() orelse return;
    defer _ = win.DestroyMenu(menu);
    for (picker_emojis, 0..) |emoji, index| {
        var wide = WideText(31){};
        wide.set(a.allocator, emoji);
        if (wide.len == 0) continue;
        _ = win.AppendMenuW(menu, win.MF_STRING, picker_base + index, wide.ptr());
    }
    var rect: win.RECT = undefined;
    if (a.hwnd) |hwnd| _ = win.GetWindowRect(hwnd, &rect);
    const choice = win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_NONOTIFY, rect.right - 232, rect.bottom - 110, 0, a.hwnd.?, null);
    if (choice == 0) return;
    if (pickerEmojiForCommand(@intCast(choice))) |emoji| insertEmoji(a, emoji);
}

fn addReactionItems(menu: win.HMENU) void {
    _ = win.AppendMenuW(menu, win.MF_STRING, reaction_like, lit("👍  Like"));
    _ = win.AppendMenuW(menu, win.MF_STRING, reaction_love, lit("❤️  Love"));
    _ = win.AppendMenuW(menu, win.MF_STRING, reaction_laugh, lit("😂  Laugh"));
    _ = win.AppendMenuW(menu, win.MF_STRING, reaction_surprised, lit("😮  Surprised"));
    _ = win.AppendMenuW(menu, win.MF_STRING, reaction_sad, lit("😢  Sad"));
    _ = win.AppendMenuW(menu, win.MF_STRING, reaction_thanks, lit("🙏  Thanks"));
    _ = win.AppendMenuW(menu, win.MF_SEPARATOR, 0, null);
    _ = win.AppendMenuW(menu, win.MF_STRING, reaction_remove, lit("Remove reaction"));
}

fn openReactionMenu(a: *App, x: i32, y: i32) void {
    const menu = win.CreatePopupMenu() orelse return;
    defer _ = win.DestroyMenu(menu);
    addReactionItems(menu);
    const choice = win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_NONOTIFY, x, y, 0, a.hwnd.?, null);
    reactToSelected(a, @intCast(choice));
}

fn archiveSelectedChat(a: *App) void {
    if (a.chat_count == 0 or a.selected_chat >= a.chat_count) return;
    const chat = &a.chats[a.selected_chat];
    const should_unarchive = a.show_archived or chat.archived;
    const args = [_][]const u8{ a.wacli_path, "--json", "chats", if (should_unarchive) "unarchive" else "archive", "--chat", chat.jid.slice() };
    setStatus(a, if (should_unarchive) "Unarchiving chat..." else "Archiving chat...");
    // The live sync process holds the wacli store lock for its lifetime, and
    // chat-state commands like archive have no send-style IPC delegate, so the
    // sync child must be stopped or the archive call fails on the lock.
    stopSync(a);
    var parsed = runWacli(a, &args) catch {
        startSync(a);
        setStatus(a, if (should_unarchive) "Could not unarchive chat" else "Could not archive chat");
        return;
    };
    parsed.deinit();
    startSync(a);
    refreshChats(a);
    refreshMessages(a);
    setStatus(a, if (should_unarchive) "Chat unarchived" else "Chat archived");
}

fn openCommandMenu(a: *App) void {
    const menu = win.CreatePopupMenu() orelse return;
    defer _ = win.DestroyMenu(menu);
    _ = win.AppendMenuW(menu, win.MF_STRING, command_search, lit("Search chats          Ctrl+F or /"));
    _ = win.AppendMenuW(menu, win.MF_STRING, command_compose, lit("Compose message               C"));
    _ = win.AppendMenuW(menu, win.MF_STRING, command_dictate, lit("Dictate                     Ctrl+D"));
    _ = win.AppendMenuW(menu, win.MF_STRING, command_unread, lit("Toggle unread chats           U"));
    _ = win.AppendMenuW(menu, win.MF_STRING, command_archive, if (a.show_archived) lit("Unarchive selected chat       E") else lit("Archive selected chat         E"));
    const archived_flags: win.UINT = @intCast(win.MF_STRING | (if (a.show_archived) win.MF_CHECKED else 0));
    _ = win.AppendMenuW(menu, archived_flags, command_archived, lit("Show archived chats"));
    const reactions = win.CreatePopupMenu();
    if (reactions) |reaction_menu| {
        addReactionItems(reaction_menu);
        _ = win.AppendMenuW(menu, win.MF_POPUP, @intFromPtr(reaction_menu), lit("React to selected message"));
    }
    _ = win.AppendMenuW(menu, win.MF_SEPARATOR, 0, null);
    _ = win.AppendMenuW(menu, win.MF_STRING, command_refresh, lit("Refresh                       R"));
    _ = win.AppendMenuW(menu, win.MF_STRING, command_sync, lit("Restart live sync             S"));
    _ = win.AppendMenuW(menu, win.MF_SEPARATOR, 0, null);
    _ = win.AppendMenuW(menu, win.MF_STRING, command_quit, lit("Quit                          Q"));
    var rect: win.RECT = undefined;
    _ = win.GetWindowRect(a.hwnd.?, &rect);
    const choice = win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_NONOTIFY, rect.left + 100, rect.top + 80, 0, a.hwnd.?, null);
    runCommand(a, @intCast(choice));
}

fn runCommand(a: *App, command: u16) void {
    switch (command) {
        command_search => {
            if (a.search) |search| _ = win.SetFocus(search);
        },
        command_compose => {
            if (a.compose) |compose| _ = win.SetFocus(compose);
        },
        command_unread => {
            a.unread_only = !a.unread_only;
            refreshChats(a);
            refreshMessages(a);
        },
        command_archive => archiveSelectedChat(a),
        command_archived => {
            a.show_archived = !a.show_archived;
            refreshChats(a);
            refreshMessages(a);
        },
        command_dictate => {
            setStatus(a, if (a.deepgram_configured) "Deepgram is configured; audio capture is the next step" else "Set DEEPGRAM_API_KEY to enable dictation");
        },
        command_refresh => {
            refreshGroups(a);
            refreshChats(a);
            refreshMessages(a);
        },
        command_sync => {
            stopSync(a);
            startSync(a);
        },
        command_quit => {
            if (a.hwnd) |hwnd| _ = win.PostMessageW(hwnd, win.WM_CLOSE, 0, 0);
        },
        else => reactToSelected(a, command),
    }
}

fn layout(a: *App, width: i32, height: i32) void {
    const left_width = std.math.clamp(@divTrunc(width, 3), 280, 390);
    const header_height: i32 = 62;
    const search_height: i32 = 48;
    const status_height: i32 = 26;
    const compose_height: i32 = 66;
    if (a.search) |hwnd| _ = win.MoveWindow(hwnd, 12, header_height + 8, left_width - 24, 34, win.TRUE);
    if (a.chats_hwnd) |hwnd| _ = win.MoveWindow(hwnd, 0, header_height + search_height, left_width, height - header_height - search_height - status_height, win.TRUE);
    if (a.status) |hwnd| _ = win.MoveWindow(hwnd, 12, height - status_height, left_width - 24, status_height, win.TRUE);
    if (a.canvas) |hwnd| _ = win.MoveWindow(hwnd, left_width + 1, header_height, width - left_width - 1, height - header_height - compose_height, win.TRUE);
    if (a.compose) |hwnd| _ = win.MoveWindow(hwnd, left_width + 14, height - compose_height + 11, width - left_width - 258, 44, win.TRUE);
    if (a.emoji_btn) |hwnd| _ = win.MoveWindow(hwnd, width - 236, height - compose_height + 11, 44, 44, win.TRUE);
    if (a.dictate) |hwnd| _ = win.MoveWindow(hwnd, width - 184, height - compose_height + 11, 92, 44, win.TRUE);
    if (a.send) |hwnd| _ = win.MoveWindow(hwnd, width - 82, height - compose_height + 11, 68, 44, win.TRUE);
}

fn drawChat(a: *App, item: *win.DRAWITEMSTRUCT) void {
    if (item.itemID == @as(win.UINT, @bitCast(@as(c_int, -1)))) return;
    const index: usize = @intCast(item.itemID);
    if (index >= a.chat_count) return;
    const chat = &a.chats[index];
    const selected = (item.itemState & win.ODS_SELECTED) != 0;
    const background = win.CreateSolidBrush(if (selected) color_selected else color_panel) orelse return;
    defer _ = win.DeleteObject(background);
    _ = win.FillRect(item.hDC, &item.rcItem, background);
    _ = win.SetBkMode(item.hDC, win.TRANSPARENT);

    const avatar_brush = win.CreateSolidBrush(rgb(59, 74, 84)) orelse return;
    defer _ = win.DeleteObject(avatar_brush);
    const old_brush = win.SelectObject(item.hDC, avatar_brush);
    const old_pen = win.SelectObject(item.hDC, win.GetStockObject(win.NULL_PEN));
    _ = win.Ellipse(item.hDC, item.rcItem.left + 12, item.rcItem.top + 10, item.rcItem.left + 54, item.rcItem.top + 52);
    _ = win.SelectObject(item.hDC, old_brush);
    _ = win.SelectObject(item.hDC, old_pen);

    if (chat.name.len > 0) {
        _ = win.SelectObject(item.hDC, @ptrCast(a.font_bold.?));
        _ = win.SetTextColor(item.hDC, color_text);
        var avatar_rect = win.RECT{ .left = item.rcItem.left + 12, .top = item.rcItem.top + 10, .right = item.rcItem.left + 54, .bottom = item.rcItem.top + 52 };
        _ = win.DrawTextW(item.hDC, @ptrCast(chat.name.buf[0..chat.name.len].ptr), @intCast(avatar.initial(chat.name.buf[0..chat.name.len]).len), &avatar_rect, win.DT_CENTER | win.DT_SINGLELINE | win.DT_VCENTER);
    }

    _ = win.SelectObject(item.hDC, @ptrCast(a.font_bold.?));
    _ = win.SetTextColor(item.hDC, color_text);
    var name_rect = win.RECT{ .left = item.rcItem.left + 66, .top = item.rcItem.top + 10, .right = item.rcItem.right - 54, .bottom = item.rcItem.top + 34 };
    _ = win.DrawTextW(item.hDC, chat.name.ptr(), @intCast(chat.name.len), &name_rect, win.DT_LEFT | win.DT_SINGLELINE | win.DT_END_ELLIPSIS | win.DT_VCENTER);
    _ = win.SelectObject(item.hDC, @ptrCast(a.font_small.?));
    _ = win.SetTextColor(item.hDC, color_muted);
    var time_rect = win.RECT{ .left = item.rcItem.right - 52, .top = item.rcItem.top + 10, .right = item.rcItem.right - 10, .bottom = item.rcItem.top + 32 };
    _ = win.DrawTextW(item.hDC, chat.time.ptr(), @intCast(chat.time.len), &time_rect, win.DT_RIGHT | win.DT_SINGLELINE | win.DT_VCENTER);
    var kind_rect = win.RECT{ .left = item.rcItem.left + 66, .top = item.rcItem.top + 35, .right = item.rcItem.right - 42, .bottom = item.rcItem.top + 56 };
    _ = win.DrawTextW(item.hDC, chat.kind.ptr(), @intCast(chat.kind.len), &kind_rect, win.DT_LEFT | win.DT_SINGLELINE | win.DT_END_ELLIPSIS);

    if (chat.unread or chat.unread_count > 0) {
        const unread_brush = win.CreateSolidBrush(color_accent) orelse return;
        defer _ = win.DeleteObject(unread_brush);
        const previous = win.SelectObject(item.hDC, unread_brush);
        _ = win.Ellipse(item.hDC, item.rcItem.right - 30, item.rcItem.top + 36, item.rcItem.right - 12, item.rcItem.top + 54);
        _ = win.SelectObject(item.hDC, previous);
    }
}

// Consecutive messages from the same sender hide the name header to save space.
fn showSenderName(a: *App, index: usize) bool {
    if (index == 0) return true;
    const message = &a.messages[index];
    const previous = &a.messages[index - 1];
    if (message.sender_jid.len > 0 and previous.sender_jid.len > 0)
        return !std.mem.eql(u8, message.sender_jid.slice(), previous.sender_jid.slice());
    return !std.mem.eql(u16, message.sender.slice(), previous.sender.slice());
}

fn measureMessage(hdc: win.HDC, a: *App, message: *const Message, width: i32, show_sender: bool) i32 {
    _ = win.SelectObject(hdc, @ptrCast(a.font.?));
    var rect = win.RECT{ .left = 0, .top = 0, .right = width - 28, .bottom = 0 };
    const text = if (message.text.len > 0) message.text.ptr() else lit(" ");
    const len: c_int = if (message.text.len > 0) @intCast(message.text.len) else 1;
    _ = win.DrawTextW(hdc, text, len, &rect, win.DT_CALCRECT | win.DT_WORDBREAK | win.DT_NOPREFIX);
    const header_height: i32 = if (show_sender) 42 else 22;
    var height = (rect.bottom - rect.top) + header_height;
    if (message.bitmap_height > 0) {
        height += message.bitmap_height + 8;
        if (isVideo(message)) height += 18;
    } else if (message.media_type.len > 0) height += 54;
    if (message.reaction.len > 0) height += 18;
    const min_height: i32 = if (show_sender) 58 else 38;
    return @max(height, min_height);
}

fn drawSenderAvatar(hdc: win.HDC, a: *App, x: i32, top: i32, message: *const Message) void {
    // Seed the color from the jid; fall back to the first name code unit when
    // the jid is missing (both are stable per person).
    const seed = if (message.sender_jid.len > 0)
        message.sender_jid.slice()
    else
        std.mem.asBytes(&message.sender.buf[0])[0..2];
    const tint = avatar.colorFor(seed);
    const circle_brush = win.CreateSolidBrush(rgb(tint.r, tint.g, tint.b)) orelse return;
    defer _ = win.DeleteObject(circle_brush);
    const old_brush = win.SelectObject(hdc, circle_brush);
    const old_pen = win.SelectObject(hdc, win.GetStockObject(win.NULL_PEN));
    _ = win.Ellipse(hdc, x, top, x + 30, top + 30);
    _ = win.SelectObject(hdc, old_brush);
    _ = win.SelectObject(hdc, old_pen);
    const initial = avatar.initial(message.sender.slice());
    _ = win.SelectObject(hdc, @ptrCast(a.font_bold.?));
    _ = win.SetTextColor(hdc, color_text);
    var rect = win.RECT{ .left = x, .top = top, .right = x + 30, .bottom = top + 30 };
    _ = win.DrawTextW(hdc, @ptrCast(initial.ptr), @intCast(initial.len), &rect, win.DT_CENTER | win.DT_SINGLELINE | win.DT_VCENTER);
}

fn drawCanvas(hwnd: win.HWND, a: *App) void {
    var paint: win.PAINTSTRUCT = undefined;
    const hdc = win.BeginPaint(hwnd, &paint);
    defer _ = win.EndPaint(hwnd, &paint);
    var client: win.RECT = undefined;
    _ = win.GetClientRect(hwnd, &client);
    _ = win.FillRect(hdc, &client, a.brush_bg.?);
    _ = win.SetBkMode(hdc, win.TRANSPARENT);
    const available_width = client.right - client.left;
    const bubble_width = std.math.clamp(@divTrunc(available_width * 7, 10), 280, 620);
    const chat_jid = if (a.displayed_jid.len > 0) a.displayed_jid.slice() else a.chats[a.selected_chat].jid.slice();
    const in_group = avatar.isGroupJid(chat_jid);
    var total_height: i32 = 18;
    for (a.messages[0..a.message_count], 0..) |*message, index| total_height += measureMessage(hdc, a, message, bubble_width, showSenderName(a, index)) + 8;
    a.max_scroll = @max(0, total_height - (client.bottom - client.top));
    a.scroll_y = std.math.clamp(a.scroll_y, 0, a.max_scroll);
    var y = client.bottom - 14 + a.scroll_y;
    var index = a.message_count;
    while (index > 0) {
        index -= 1;
        const message = &a.messages[index];
        message.media_hit = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        message.bubble_hit = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        const show_sender = showSenderName(a, index);
        const estimated_height = measureMessage(hdc, a, message, bubble_width, show_sender);
        y -= estimated_height + 8;
        if (y > client.bottom or y + estimated_height < client.top) continue;
        ensureBitmap(a, message);
        const height = measureMessage(hdc, a, message, bubble_width, show_sender);
        y -= height - estimated_height;
        if (y > client.bottom or y + height < client.top) continue;
        const left: i32 = if (message.from_me) client.right - bubble_width - 24 else if (in_group) 62 else 24;
        const right = left + bubble_width;
        message.bubble_hit = .{ .left = left, .top = y, .right = right, .bottom = y + height };
        const brush = win.CreateSolidBrush(if (message.from_me) color_outgoing else color_incoming) orelse continue;
        const old_brush = win.SelectObject(hdc, brush);
        const selected = if (a.selected_message) |selected_index| selected_index == index else false;
        const selection_pen = if (selected) win.CreatePen(win.PS_SOLID, 2, color_accent) else null;
        const old_pen = win.SelectObject(hdc, if (selection_pen) |pen| @ptrCast(pen) else win.GetStockObject(win.NULL_PEN));
        _ = win.RoundRect(hdc, left, y, right, y + height, 18, 18);
        _ = win.SelectObject(hdc, old_brush);
        _ = win.SelectObject(hdc, old_pen);
        if (selection_pen) |pen| _ = win.DeleteObject(pen);
        _ = win.DeleteObject(brush);

        var text_top = y + 8;
        if (in_group and !message.from_me and message.sender.len > 0) drawSenderAvatar(hdc, a, left - 38, y + 8, message);
        if (show_sender) {
            _ = win.SelectObject(hdc, @ptrCast(a.font_bold.?));
            const in_group_thread = std.mem.endsWith(u8, a.chats[a.selected_chat].jid.slice(), "@g.us");
            _ = win.SetTextColor(hdc, if (message.from_me)
                color_text
            else if (in_group_thread)
                senderColor(if (message.sender_jid.len > 0) message.sender_jid.slice() else "unknown")
            else
                rgb(83, 189, 235));
            var sender_rect = win.RECT{ .left = left + 12, .top = y + 8, .right = right - 52, .bottom = y + 28 };
            _ = win.DrawTextW(hdc, message.sender.ptr(), @intCast(message.sender.len), &sender_rect, win.DT_LEFT | win.DT_SINGLELINE | win.DT_END_ELLIPSIS);
            text_top = y + 28;
        }
        if (message.bitmap) |bitmap| {
            const image_left = left + @divTrunc(bubble_width - message.bitmap_width, 2);
            const image_top = text_top + 4;
            const memory_dc = win.CreateCompatibleDC(hdc);
            if (memory_dc != null) {
                const previous = win.SelectObject(memory_dc, @ptrCast(bitmap));
                _ = win.BitBlt(hdc, image_left, image_top, message.bitmap_width, message.bitmap_height, memory_dc, 0, 0, win.SRCCOPY);
                _ = win.SelectObject(memory_dc, previous);
                _ = win.DeleteDC(memory_dc);
            }
            message.media_hit = .{ .left = image_left, .top = image_top, .right = image_left + message.bitmap_width, .bottom = image_top + message.bitmap_height };
            if (isVideo(message)) {
                const center_x = image_left + @divTrunc(message.bitmap_width, 2);
                const center_y = image_top + @divTrunc(message.bitmap_height, 2);
                const button_brush = win.CreateSolidBrush(color_bg) orelse null;
                const button_pen = win.CreatePen(win.PS_SOLID, 2, color_accent);
                const old_pen2 = win.SelectObject(hdc, button_pen);
                const old_brush2 = win.SelectObject(hdc, if (button_brush) |bb| @ptrCast(bb) else win.GetStockObject(win.BLACK_BRUSH));
                _ = win.Ellipse(hdc, center_x - 26, center_y - 26, center_x + 26, center_y + 26);
                _ = win.SelectObject(hdc, old_brush2);
                _ = win.SelectObject(hdc, old_pen2);
                if (button_pen) |pen| _ = win.DeleteObject(pen);
                if (button_brush) |dead_brush| _ = win.DeleteObject(dead_brush);
                _ = win.SelectObject(hdc, @ptrCast(a.font_bold.?));
                _ = win.SetTextColor(hdc, color_text);
                var play_rect = win.RECT{ .left = center_x - 26, .top = center_y - 26, .right = center_x + 26, .bottom = center_y + 26 };
                _ = win.DrawTextW(hdc, lit("▶"), -1, &play_rect, win.DT_CENTER | win.DT_SINGLELINE | win.DT_VCENTER);
            }
            text_top += message.bitmap_height + 8;
            if (isVideo(message)) {
                _ = win.SelectObject(hdc, @ptrCast(a.font_small.?));
                _ = win.SetTextColor(hdc, color_muted);
                var hint_rect = win.RECT{ .left = left + 12, .top = text_top, .right = right - 12, .bottom = text_top + 18 };
                _ = win.DrawTextW(hdc, lit("click to play · right-click to open in your player"), -1, &hint_rect, win.DT_CENTER | win.DT_SINGLELINE);
                text_top += 18;
            }
        } else if (message.media_type.len > 0) {
            _ = win.SelectObject(hdc, @ptrCast(a.font_small.?));
            var media_rect = win.RECT{ .left = left + 12, .top = text_top + 4, .right = right - 12, .bottom = text_top + 46 };
            const local = message.local_path.len > 0;
            const played = local and isAudio(message) and wasPlayed(a, message.id.slice());
            _ = win.SetTextColor(hdc, if (played) color_muted else color_accent);
            const label = if (isAudio(message))
                (if (local)
                    (if (played) lit("Voice note · played") else lit("Voice note · click to play"))
                else
                    lit("Voice note · click to download"))
            else if (isVideo(message))
                (if (local) lit("Video · click to play · right-click to open") else lit("Video · click to download"))
            else if (isImage(message))
                (if (local) lit("Image · click to open") else lit("Image · click to download"))
            else
                (if (local) lit("Attachment · click to open") else lit("Attachment · click to download"));
            _ = win.DrawTextW(hdc, label, -1, &media_rect, win.DT_CENTER | win.DT_SINGLELINE | win.DT_VCENTER);
            message.media_hit = media_rect;
            text_top += 54;
        }
        _ = win.SelectObject(hdc, @ptrCast(a.font.?));
        _ = win.SetTextColor(hdc, color_text);
        const footer_height: i32 = if (message.reaction.len > 0) 32 else 18;
        var text_rect = win.RECT{ .left = left + 12, .top = text_top, .right = right - 12, .bottom = y + height - footer_height };
        const text = if (message.text.len > 0) message.text.ptr() else lit(" ");
        const len: c_int = if (message.text.len > 0) @intCast(message.text.len) else 1;
        _ = win.DrawTextW(hdc, text, len, &text_rect, win.DT_LEFT | win.DT_WORDBREAK | win.DT_NOPREFIX);
        if (message.reaction.len > 0) {
            _ = win.SelectObject(hdc, @ptrCast(a.font_emoji.?));
            _ = win.SetTextColor(hdc, color_text);
            var reaction_rect = win.RECT{ .left = left + 12, .top = y + height - 30, .right = left + 52, .bottom = y + height - 6 };
            _ = win.DrawTextW(hdc, message.reaction.ptr(), @intCast(message.reaction.len), &reaction_rect, win.DT_LEFT | win.DT_SINGLELINE | win.DT_VCENTER);
        }
        _ = win.SelectObject(hdc, @ptrCast(a.font_small.?));
        _ = win.SetTextColor(hdc, color_muted);
        var time_rect = win.RECT{ .left = right - 52, .top = y + height - 20, .right = right - 10, .bottom = y + height - 5 };
        _ = win.DrawTextW(hdc, message.time.ptr(), @intCast(message.time.len), &time_rect, win.DT_RIGHT | win.DT_SINGLELINE);
    }
}

fn canvasProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    const a = app_ptr orelse return win.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        win.WM_PAINT => {
            drawCanvas(hwnd, a);
            return 0;
        },
        win.WM_ERASEBKGND => return 1,
        win.WM_MOUSEWHEEL => {
            const delta: i16 = @bitCast(hiword(wparam));
            a.scroll_y = std.math.clamp(a.scroll_y + @divTrunc(@as(i32, delta), 2), 0, a.max_scroll);
            _ = win.InvalidateRect(hwnd, null, win.TRUE);
            return 0;
        },
        win.WM_LBUTTONUP => {
            const x: i32 = @as(i16, @bitCast(loword(@as(usize, @bitCast(lparam)))));
            const y: i32 = @as(i16, @bitCast(hiword(@as(usize, @bitCast(lparam)))));
            for (a.messages[0..a.message_count], 0..) |*item, index| {
                const media = item.media_hit;
                const bubble = item.bubble_hit;
                if (x >= media.left and x <= media.right and y >= media.top and y <= media.bottom) {
                    a.selected_message = index;
                    if (isVideo(item)) {
                        if (item.local_path.len > 0) playVideoInline(a, item) else downloadMedia(a, index, false);
                    } else if (isAudio(item)) {
                        if (item.local_path.len > 0) {
                            playVoiceNote(a, item);
                            markPlayed(a, item.id.slice());
                            _ = win.InvalidateRect(hwnd, null, win.TRUE);
                        } else downloadMedia(a, index, false);
                    } else if (item.local_path.len > 0) {
                        openMedia(a, item);
                    } else {
                        downloadMedia(a, index, false);
                    }
                    break;
                }
                if (x >= bubble.left and x <= bubble.right and y >= bubble.top and y <= bubble.bottom) {
                    a.selected_message = index;
                    _ = win.InvalidateRect(hwnd, null, win.TRUE);
                    break;
                }
            }
            return 0;
        },
        win.WM_RBUTTONUP => {
            const x: i32 = @as(i16, @bitCast(loword(@as(usize, @bitCast(lparam)))));
            const y: i32 = @as(i16, @bitCast(hiword(@as(usize, @bitCast(lparam)))));
            for (a.messages[0..a.message_count], 0..) |*item, index| {
                const media = item.media_hit;
                const bubble = item.bubble_hit;
                if (x >= media.left and x <= media.right and y >= media.top and y <= media.bottom) {
                    a.selected_message = index;
                    if ((isVideo(item) or isAudio(item)) and item.local_path.len > 0) {
                        openMedia(a, item);
                        return 0;
                    }
                }
                if (x >= bubble.left and x <= bubble.right and y >= bubble.top and y <= bubble.bottom) {
                    a.selected_message = index;
                    _ = win.InvalidateRect(hwnd, null, win.TRUE);
                    var point = win.POINT{ .x = x, .y = y };
                    _ = win.ClientToScreen(hwnd, &point);
                    openReactionMenu(a, point.x, point.y);
                    break;
                }
            }
            return 0;
        },
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn mainProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    const a = app_ptr orelse return win.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        wm_update_ready => {
            if (wparam != 0) {
                setStatus(a, "Update installed - restarting in 10 seconds");
                _ = win.SetTimer(hwnd, timer_update_restart, update_restart_delay_ms, null);
            }
            return 0;
        },
        win.WM_CREATE => {
            a.hwnd = hwnd;
            a.brush_bg = win.CreateSolidBrush(color_bg);
            a.brush_panel = win.CreateSolidBrush(color_panel);
            a.brush_raised = win.CreateSolidBrush(color_raised);
            // Body text uses Segoe UI: IBM Plex Sans has no emoji glyphs and no font-linking entry, so GDI renders emoji as tofu.
            a.font = win.CreateFontW(-17, 0, 0, 0, win.FW_NORMAL, 0, 0, 0, win.DEFAULT_CHARSET, win.OUT_DEFAULT_PRECIS, win.CLIP_DEFAULT_PRECIS, win.CLEARTYPE_QUALITY, win.DEFAULT_PITCH, lit("Segoe UI"));
            a.font_small = win.CreateFontW(-13, 0, 0, 0, win.FW_NORMAL, 0, 0, 0, win.DEFAULT_CHARSET, win.OUT_DEFAULT_PRECIS, win.CLIP_DEFAULT_PRECIS, win.CLEARTYPE_QUALITY, win.DEFAULT_PITCH, lit("IBM Plex Sans"));
            a.font_bold = win.CreateFontW(-16, 0, 0, 0, win.FW_SEMIBOLD, 0, 0, 0, win.DEFAULT_CHARSET, win.OUT_DEFAULT_PRECIS, win.CLIP_DEFAULT_PRECIS, win.CLEARTYPE_QUALITY, win.DEFAULT_PITCH, lit("IBM Plex Sans"));
            a.font_emoji = win.CreateFontW(-20, 0, 0, 0, win.FW_NORMAL, 0, 0, 0, win.DEFAULT_CHARSET, win.OUT_DEFAULT_PRECIS, win.CLIP_DEFAULT_PRECIS, win.CLEARTYPE_QUALITY, win.DEFAULT_PITCH, lit("Segoe UI Emoji"));
            a.search = win.CreateWindowExW(0, lit("EDIT"), null, win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.ES_AUTOHSCROLL, 0, 0, 0, 0, hwnd, controlId(id_search), a.instance, null);
            a.chats_hwnd = win.CreateWindowExW(0, lit("LISTBOX"), null, win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.WS_VSCROLL | win.LBS_NOTIFY | win.LBS_OWNERDRAWFIXED | win.LBS_NOINTEGRALHEIGHT, 0, 0, 0, 0, hwnd, controlId(id_chats), a.instance, null);
            a.canvas = win.CreateWindowExW(0, lit("WacliMessageCanvas"), null, win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP, 0, 0, 0, 0, hwnd, controlId(id_canvas), a.instance, null);
            a.compose = win.CreateWindowExW(0, lit("EDIT"), null, win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.WS_VSCROLL, 0, 0, 0, 0, hwnd, controlId(id_compose), a.instance, null);
            a.dictate = win.CreateWindowExW(0, lit("BUTTON"), lit("Dictate"), win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.BS_PUSHBUTTON, 0, 0, 0, 0, hwnd, controlId(id_dictate), a.instance, null);
            a.send = win.CreateWindowExW(0, lit("BUTTON"), lit("Send"), win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.BS_PUSHBUTTON, 0, 0, 0, 0, hwnd, controlId(id_send), a.instance, null);
            a.emoji_btn = win.CreateWindowExW(0, lit("BUTTON"), lit("😊"), win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.BS_PUSHBUTTON, 0, 0, 0, 0, hwnd, controlId(id_emoji), a.instance, null);
            a.status = win.CreateWindowExW(0, lit("STATIC"), lit("Loading..."), win.WS_CHILD | win.WS_VISIBLE | win.SS_LEFT, 0, 0, 0, 0, hwnd, controlId(id_status), a.instance, null);
            setFont(a.search, a.font);
            setFont(a.chats_hwnd, a.font);
            setFont(a.compose, a.font);
            setFont(a.dictate, a.font_bold);
            setFont(a.send, a.font_bold);
            setFont(a.emoji_btn, a.font_emoji);
            setFont(a.status, a.font_small);
            createTooltips(a, hwnd);
            if (a.search) |search| _ = win.SendMessageW(search, win.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(lit("Search chats  Ctrl+F"))));
            if (a.chats_hwnd) |list| _ = win.SendMessageW(list, win.LB_SETITEMHEIGHT, 0, 64);
            _ = win.SetTimer(hwnd, timer_refresh, 3000, null);
            _ = win.SetTimer(hwnd, timer_animation, 120, null);
            _ = win.SetTimer(hwnd, timer_update_check, update_check_interval_ms, null);
            refreshGroups(a);
            refreshChats(a);
            refreshMessages(a);
            startSync(a);
            startUpdateCheck(hwnd);
            return 0;
        },
        win.WM_SIZE => {
            layout(a, @intCast(loword(@bitCast(lparam))), @intCast(hiword(@bitCast(lparam))));
            return 0;
        },
        win.WM_PAINT => {
            var paint: win.PAINTSTRUCT = undefined;
            const hdc = win.BeginPaint(hwnd, &paint);
            var client: win.RECT = undefined;
            _ = win.GetClientRect(hwnd, &client);
            _ = win.FillRect(hdc, &client, a.brush_bg.?);
            const left_width = std.math.clamp(@divTrunc(client.right, 3), 280, 390);
            var left_rect = win.RECT{ .left = 0, .top = 0, .right = left_width, .bottom = client.bottom };
            _ = win.FillRect(hdc, &left_rect, a.brush_panel.?);
            var header_rect = win.RECT{ .left = 0, .top = 0, .right = client.right, .bottom = 62 };
            _ = win.FillRect(hdc, &header_rect, a.brush_raised.?);
            var composer_rect = win.RECT{ .left = left_width + 1, .top = client.bottom - 66, .right = client.right, .bottom = client.bottom };
            _ = win.FillRect(hdc, &composer_rect, a.brush_raised.?);
            _ = win.SetBkMode(hdc, win.TRANSPARENT);
            _ = win.SetTextColor(hdc, color_text);
            _ = win.SelectObject(hdc, @ptrCast(a.font_bold.?));
            var title_rect = win.RECT{ .left = 18, .top = 18, .right = left_width - 18, .bottom = 48 };
            _ = win.DrawTextW(hdc, if (a.show_archived) lit("Archived") else lit("Messages"), -1, &title_rect, win.DT_LEFT | win.DT_SINGLELINE);
            if (a.chat_count > 0 and a.selected_chat < a.chat_count) {
                var chat_rect = win.RECT{ .left = left_width + 20, .top = 18, .right = client.right - 18, .bottom = 48 };
                const selected = &a.chats[a.selected_chat];
                _ = win.DrawTextW(hdc, selected.name.ptr(), @intCast(selected.name.len), &chat_rect, win.DT_LEFT | win.DT_SINGLELINE | win.DT_END_ELLIPSIS);
            }
            _ = win.EndPaint(hwnd, &paint);
            return 0;
        },
        win.WM_ERASEBKGND => return 1,
        win.WM_DRAWITEM => {
            const item: *win.DRAWITEMSTRUCT = winHandle(*win.DRAWITEMSTRUCT, @as(usize, @bitCast(lparam)));
            if (item.CtlID == id_chats) drawChat(a, item);
            return 1;
        },
        win.WM_COMMAND => {
            const id = loword(wparam);
            const notification = hiword(wparam);
            if (id == id_chats and notification == win.LBN_SELCHANGE) {
                const selected = win.SendMessageW(a.chats_hwnd.?, win.LB_GETCURSEL, 0, 0);
                if (selected >= 0) {
                    a.selected_chat = @intCast(selected);
                    refreshMessages(a);
                    _ = win.InvalidateRect(hwnd, null, win.TRUE);
                }
            } else if (id == id_send and notification == win.BN_CLICKED) {
                sendMessage(a);
            } else if (id == id_dictate and notification == win.BN_CLICKED) {
                runCommand(a, command_dictate);
            } else if (id == id_emoji and notification == win.BN_CLICKED) {
                openEmojiMenu(a);
            } else if (id == id_search and notification == win.EN_CHANGE) {
                _ = win.KillTimer(hwnd, timer_search);
                _ = win.SetTimer(hwnd, timer_search, 240, null);
            }
            return 0;
        },
        win.WM_TIMER => {
            if (wparam == timer_refresh) {
                checkMediaDownload(a);
                if (a.media_child == null) {
                    checkSync(a);
                    a.group_refresh_ticks += 1;
                    if (a.group_refresh_ticks >= 20) {
                        refreshGroups(a);
                        a.group_refresh_ticks = 0;
                    }
                    refreshChats(a);
                    if (!messagesAreCurrent(a)) refreshMessages(a);
                    autoDownloadNextMedia(a);
                }
            } else if (wparam == timer_search) {
                _ = win.KillTimer(hwnd, timer_search);
                refreshChats(a);
                refreshMessages(a);
            } else if (wparam == timer_animation) {
                advanceGifs(a);
            } else if (wparam == timer_update_check) {
                startUpdateCheck(hwnd);
            } else if (wparam == timer_update_restart) {
                _ = win.KillTimer(hwnd, timer_update_restart);
                relaunchIntoUpdate(a);
            }
            return 0;
        },
        win.WM_CTLCOLORSTATIC, win.WM_CTLCOLOREDIT, win.WM_CTLCOLORLISTBOX => {
            const hdc: win.HDC = winHandle(win.HDC, wparam);
            _ = win.SetTextColor(hdc, color_text);
            _ = win.SetBkColor(hdc, color_raised);
            const control_value: usize = @bitCast(lparam);
            if (a.status) |status| {
                if (control_value == @intFromPtr(status)) return @bitCast(@intFromPtr(a.brush_panel.?));
            }
            return @bitCast(@intFromPtr(a.brush_raised.?));
        },
        win.WM_CLOSE => {
            _ = win.DestroyWindow(hwnd);
            return 0;
        },
        win.WM_DESTROY => {
            closePlayer(a);
            closeAudioPlayer(a);
            _ = win.KillTimer(hwnd, timer_refresh);
            _ = win.KillTimer(hwnd, timer_search);
            _ = win.KillTimer(hwnd, timer_animation);
            if (a.media_child) |*child| child.kill(a.io);
            a.media_child = null;
            stopSync(a);
            clearMessages(a);
            if (a.font) |font| _ = win.DeleteObject(font);
            if (a.font_small) |font| _ = win.DeleteObject(font);
            if (a.font_bold) |font| _ = win.DeleteObject(font);
            if (a.font_emoji) |font| _ = win.DeleteObject(font);
            if (a.brush_bg) |brush| _ = win.DeleteObject(brush);
            if (a.brush_panel) |brush| _ = win.DeleteObject(brush);
            if (a.brush_raised) |brush| _ = win.DeleteObject(brush);
            win.PostQuitMessage(0);
            return 0;
        },
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn handleKeyboard(a: *App, message: *const win.MSG) bool {
    if (message.message != win.WM_KEYDOWN and message.message != win.WM_SYSKEYDOWN) return false;
    const key: u32 = @intCast(message.wParam);
    const focus = win.GetFocus();
    const control = win.GetKeyState(win.VK_CONTROL) < 0;
    const shift = win.GetKeyState(win.VK_SHIFT) < 0;
    const alt = win.GetKeyState(win.VK_MENU) < 0;
    if (control and key == 'F') {
        if (a.search) |search| {
            _ = win.SetFocus(search);
            _ = win.SendMessageW(search, win.EM_SETSEL, 0, @bitCast(@as(isize, -1)));
        }
        return true;
    }
    if (control and key == 'K') {
        openCommandMenu(a);
        return true;
    }
    if (control and key == 'D') {
        runCommand(a, command_dictate);
        return true;
    }
    if (control and key == win.VK_TAB) {
        selectMessage(a, if (shift) -1 else 1);
        return true;
    }
    if (a.compose) |compose| {
        if (focus == compose) {
            if (key == win.VK_RETURN and !shift) {
                sendMessage(a);
                return true;
            }
            if (key == win.VK_ESCAPE) {
                if (a.chats_hwnd) |list| _ = win.SetFocus(list);
                return true;
            }
            return false;
        }
    }
    if (a.search) |search| {
        if (focus == search) {
            if (key == win.VK_DOWN or key == win.VK_UP) {
                if (a.chats_hwnd) |list| _ = win.SetFocus(list);
                selectChat(a, if (key == win.VK_DOWN) 1 else -1);
                return true;
            }
            if (key == win.VK_RETURN) {
                if (a.compose) |compose| _ = win.SetFocus(compose);
                return true;
            }
            if (key == win.VK_ESCAPE) {
                if (a.chats_hwnd) |list| _ = win.SetFocus(list);
                return true;
            }
            return false;
        }
    }
    if (key == win.VK_DOWN or key == 'J' or (control and key == 'J')) {
        selectChat(a, 1);
        return true;
    }
    if (key == win.VK_UP or key == 'K' or (control and key == 'K')) {
        selectChat(a, -1);
        return true;
    }
    if (key == win.VK_RETURN or key == 'C') {
        if (a.compose) |compose| _ = win.SetFocus(compose);
        return true;
    }
    if (key == win.VK_OEM_2) {
        if (a.search) |search| {
            _ = win.SetFocus(search);
            _ = win.SendMessageW(search, win.EM_SETSEL, 0, @bitCast(@as(isize, -1)));
        }
        return true;
    }
    if (key == 'E') {
        runCommand(a, command_archive);
        return true;
    }
    if (key == 'U') {
        runCommand(a, command_unread);
        return true;
    }
    if (key == 'R') {
        runCommand(a, command_refresh);
        return true;
    }
    if (key == 'Q') {
        runCommand(a, command_quit);
        return true;
    }
    if (alt and (key == win.VK_DOWN or key == win.VK_UP)) {
        selectChat(a, if (key == win.VK_DOWN) 1 else -1);
        return true;
    }
    return false;
}

fn findWacli(init: std.process.Init, allocator: std.mem.Allocator) ![]u8 {
    const local = init.environ_map.get("LOCALAPPDATA") orelse return error.MissingLocalAppData;
    return std.fs.path.join(allocator, &.{ local, "Programs", "wacli", "wacli.exe" });
}

fn findPlayedPath(init: std.process.Init, allocator: std.mem.Allocator) []u8 {
    const local = init.environ_map.get("LOCALAPPDATA") orelse return &.{};
    const dir = std.fs.path.join(allocator, &.{ local, "Messages" }) catch return &.{};
    std.Io.Dir.createDirPath(.cwd(), init.io, dir) catch {};
    const path = std.fs.path.join(allocator, &.{ dir, "played.txt" }) catch {
        allocator.free(dir);
        return &.{};
    };
    allocator.free(dir);
    return path;
}

fn bundledFilePath(comptime filename: []const u8) WideText(519) {
    var result = WideText(519){};
    const length: usize = @intCast(win.GetModuleFileNameW(null, &result.buf, result.buf.len));
    if (length == 0 or length >= result.buf.len) return result;
    var base = length;
    while (base > 0 and result.buf[base - 1] != '\\' and result.buf[base - 1] != '/') base -= 1;
    const name = std.mem.span(lit(filename));
    if (base + name.len > 519) return WideText(519){};
    @memcpy(result.buf[base .. base + name.len], name);
    result.len = base + name.len;
    result.buf[result.len] = 0;
    return result;
}

pub fn main(init: std.process.Init) !void {
    const instance = win.GetModuleHandleW(null) orelse return error.NoModuleHandle;
    const wacli_path = try findWacli(init, init.gpa);
    defer init.gpa.free(wacli_path);
    var app = App{ .allocator = init.gpa, .io = init.io, .instance = instance, .wacli_path = wacli_path, .deepgram_configured = init.environ_map.get("DEEPGRAM_API_KEY") != null };
    app.played_path = findPlayedPath(init, init.gpa);
    loadPlayed(&app);
    app_ptr = &app;
    defer app_ptr = null;

    _ = win.SetProcessDpiAwarenessContext(win.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    var plex_regular = bundledFilePath("IBMPlexSans-Regular.ttf");
    var plex_semibold = bundledFilePath("IBMPlexSans-SemiBold.ttf");
    const regular_loaded = win.AddFontResourceExW(plex_regular.ptr(), win.FR_PRIVATE, null) > 0;
    const semibold_loaded = win.AddFontResourceExW(plex_semibold.ptr(), win.FR_PRIVATE, null) > 0;
    defer {
        if (regular_loaded) _ = win.RemoveFontResourceExW(plex_regular.ptr(), win.FR_PRIVATE, null);
        if (semibold_loaded) _ = win.RemoveFontResourceExW(plex_semibold.ptr(), win.FR_PRIVATE, null);
    }
    _ = win.CoInitializeEx(null, win.COINIT_APARTMENTTHREADED);
    defer win.CoUninitialize();
    _ = win.CoCreateInstance(
        &win.CLSID_WICImagingFactory,
        null,
        win.CLSCTX_INPROC_SERVER,
        &win.IID_IWICImagingFactory,
        @ptrCast(&app.wic_factory),
    );
    defer {
        if (app.wic_factory != null) _ = app.wic_factory.*.lpVtbl.*.Release.?(app.wic_factory);
    }
    var controls = win.INITCOMMONCONTROLSEX{ .dwSize = @sizeOf(win.INITCOMMONCONTROLSEX), .dwICC = win.ICC_STANDARD_CLASSES };
    _ = win.InitCommonControlsEx(&controls);

    const cursor = win.LoadCursorW(null, @ptrFromInt(32512));
    // Resource id 1 in assets/app.rc; same icon serves the title bar and taskbar.
    const icon_big = LoadAppIcon(instance, 0, 0, win.LR_DEFAULTSIZE | win.LR_SHARED);
    const small_cx = win.GetSystemMetrics(win.SM_CXSMICON);
    const small_cy = win.GetSystemMetrics(win.SM_CYSMICON);
    const icon_small = LoadAppIcon(instance, small_cx, small_cy, win.LR_SHARED);
    var canvas_class = win.WNDCLASSEXW{
        .cbSize = @sizeOf(win.WNDCLASSEXW),
        .style = win.CS_HREDRAW | win.CS_VREDRAW,
        .lpfnWndProc = canvasProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = icon_big,
        .hCursor = cursor,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = lit("WacliMessageCanvas"),
        .hIconSm = icon_small,
    };
    if (win.RegisterClassExW(&canvas_class) == 0) return error.RegisterCanvasClassFailed;

    var main_class = win.WNDCLASSEXW{
        .cbSize = @sizeOf(win.WNDCLASSEXW),
        .style = win.CS_HREDRAW | win.CS_VREDRAW,
        .lpfnWndProc = mainProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = icon_big,
        .hCursor = cursor,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = lit("MessagesZig"),
        .hIconSm = icon_small,
    };
    if (win.RegisterClassExW(&main_class) == 0) return error.RegisterMainClassFailed;

    const hwnd = win.CreateWindowExW(
        0,
        lit("MessagesZig"),
        lit("Messages"),
        win.WS_OVERLAPPEDWINDOW | win.WS_CLIPCHILDREN,
        win.CW_USEDEFAULT,
        win.CW_USEDEFAULT,
        1160,
        760,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    var dark: win.BOOL = win.TRUE;
    _ = win.DwmSetWindowAttribute(hwnd, 20, &dark, @sizeOf(win.BOOL));
    _ = win.ShowWindow(hwnd, win.SW_SHOW);
    _ = win.UpdateWindow(hwnd);
    if (app.chats_hwnd) |list| _ = win.SetFocus(list);

    var message: win.MSG = undefined;
    while (win.GetMessageW(&message, null, 0, 0) > 0) {
        if (handleKeyboard(&app, &message)) continue;
        _ = win.TranslateMessage(&message);
        _ = win.DispatchMessageW(&message);
    }
}

// Self-update (WAZI-27): checks GitHub Releases for a newer version, downloads
// and verifies the release archive, then swaps the running executable in place
// and relaunches. All work happens on a detached worker thread; the UI only
// receives a wm_update_ready message once a new version is installed.
const UpdateContext = struct {
    io: std.Io,
    hwnd: win.HWND,
};

const UpdateOutcome = enum { none, installed };

fn startUpdateCheck(hwnd: win.HWND) void {
    const a = app_ptr orelse return;
    const ctx = std.heap.page_allocator.create(UpdateContext) catch return;
    ctx.* = .{ .io = a.io, .hwnd = hwnd };
    const thread = std.Thread.spawn(.{}, updateThreadMain, .{ctx}) catch {
        std.heap.page_allocator.destroy(ctx);
        return;
    };
    thread.detach();
}

fn updateThreadMain(ctx: *UpdateContext) void {
    defer std.heap.page_allocator.destroy(ctx);
    // ponytail: updates are authenticated only by HTTPS plus GitHub's own asset
    // digest; a code-signing certificate would be needed to authenticate the
    // publisher itself. Upgrade path: verify an Authenticode signature here.
    const outcome = performUpdate(ctx.io) catch .none;
    if (outcome == .installed) _ = win.PostMessageW(ctx.hwnd, wm_update_ready, 1, 0);
}

fn utf8ToWide(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

fn wideToUtf8(allocator: std.mem.Allocator, wide: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide);
}

fn httpGet(allocator: std.mem.Allocator, host: [*:0]const u16, path: [*:0]const u16, headers: [*:0]const u16, max_bytes: usize) ![]u8 {
    const session = win.WinHttpOpen(lit("Messages updater"), win.WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, null, null, 0) orelse return error.UpdateNetwork;
    defer _ = win.WinHttpCloseHandle(session);
    _ = win.WinHttpSetTimeouts(session, 15000, 15000, 60000, 60000);
    const connection = win.WinHttpConnect(session, host, win.INTERNET_DEFAULT_HTTPS_PORT, 0) orelse return error.UpdateNetwork;
    defer _ = win.WinHttpCloseHandle(connection);
    const request = win.WinHttpOpenRequest(connection, lit("GET"), path, null, null, null, win.WINHTTP_FLAG_SECURE) orelse return error.UpdateNetwork;
    defer _ = win.WinHttpCloseHandle(request);
    var policy = win.WINHTTP_OPTION_REDIRECT_POLICY_DISALLOW_HTTPS_TO_HTTP;
    _ = win.WinHttpSetOption(request, win.WINHTTP_OPTION_REDIRECT_POLICY, &policy, @sizeOf(@TypeOf(policy)));
    _ = win.WinHttpAddRequestHeaders(request, headers, std.math.maxInt(win.DWORD), win.WINHTTP_ADDREQ_FLAG_ADD);
    if (win.WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == 0) return error.UpdateNetwork;
    if (win.WinHttpReceiveResponse(request, null) == 0) return error.UpdateNetwork;
    var status: win.DWORD = 0;
    var status_size: win.DWORD = @sizeOf(win.DWORD);
    if (win.WinHttpQueryHeaders(request, win.WINHTTP_QUERY_STATUS_CODE | win.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null) == 0 or status != 200) {
        return error.UpdateHttpStatus;
    }
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    var chunk: [16384]u8 = undefined;
    while (true) {
        var read: win.DWORD = 0;
        if (win.WinHttpReadData(request, &chunk, chunk.len, &read) == 0) return error.UpdateNetwork;
        if (read == 0) break;
        if (body.items.len + read > max_bytes) return error.UpdateTooLarge;
        try body.appendSlice(allocator, chunk[0..read]);
    }
    return body.toOwnedSlice(allocator);
}

fn httpGetUrl(allocator: std.mem.Allocator, url_wide: []const u16, headers: [*:0]const u16, max_bytes: usize) ![]u8 {
    var components: win.URL_COMPONENTSW = std.mem.zeroes(win.URL_COMPONENTSW);
    components.dwStructSize = @sizeOf(win.URL_COMPONENTSW);
    var host_buf: [256]u16 = undefined;
    var path_buf: [2048]u16 = undefined;
    components.lpszHostName = &host_buf;
    components.dwHostNameLength = host_buf.len;
    components.lpszUrlPath = &path_buf;
    components.dwUrlPathLength = path_buf.len;
    if (win.WinHttpCrackUrl(url_wide.ptr, @intCast(url_wide.len), 0, &components) == 0) return error.UpdateBadUrl;
    if (components.nScheme != win.INTERNET_SCHEME_HTTPS) return error.UpdateBadUrl;
    if (components.dwHostNameLength == 0 or components.dwHostNameLength >= host_buf.len) return error.UpdateBadUrl;
    // Downloads only ever come from GitHub release hosts.
    const host_utf8 = try wideToUtf8(allocator, host_buf[0..components.dwHostNameLength]);
    defer allocator.free(host_utf8);
    const github_suffixes = [_][]const u8{ "api.github.com", "objects.githubusercontent.com", "github.com" };
    var host_allowed = false;
    for (github_suffixes) |allowed| {
        if (std.mem.eql(u8, host_utf8, allowed)) host_allowed = true;
    }
    if (!host_allowed) return error.UpdateBadUrl;
    if (components.dwUrlPathLength >= path_buf.len) return error.UpdateBadUrl;
    host_buf[components.dwHostNameLength] = 0;
    path_buf[components.dwUrlPathLength] = 0;
    return httpGet(
        allocator,
        host_buf[0..components.dwHostNameLength :0].ptr,
        path_buf[0..components.dwUrlPathLength :0].ptr,
        headers,
        max_bytes,
    );
}

fn performUpdate(io: std.Io) !UpdateOutcome {
    const allocator = std.heap.page_allocator;
    const current = update.parseVersion(update.app_version) orelse return error.UpdateBadVersion;

    // One updater at a time across every running copy of the app.
    const mutex = win.CreateMutexW(null, win.FALSE, lit("Local\\MessagesUpdateMutex")) orelse return error.UpdateMutexFailed;
    defer _ = win.CloseHandle(mutex);
    if (win.WaitForSingleObject(mutex, 0) != win.WAIT_OBJECT_0) return .none;
    defer _ = win.ReleaseMutex(mutex);

    var exe_wide_buf: [519]u16 = undefined;
    const exe_len: usize = @intCast(win.GetModuleFileNameW(null, &exe_wide_buf, exe_wide_buf.len));
    if (exe_len == 0 or exe_len >= exe_wide_buf.len) return error.UpdateNoExePath;
    const exe_path = try wideToUtf8(allocator, exe_wide_buf[0..exe_len]);
    defer allocator.free(exe_path);
    const exe_dir = std.fs.path.dirname(exe_path) orelse return error.UpdateNoExePath;

    var local_buf: [256]u16 = undefined;
    const local_len: usize = @intCast(win.GetEnvironmentVariableW(lit("LOCALAPPDATA"), &local_buf, local_buf.len));
    if (local_len == 0 or local_len >= local_buf.len) return error.UpdateNoLocalAppData;
    const local_dir = try wideToUtf8(allocator, local_buf[0..local_len]);
    defer allocator.free(local_dir);
    const update_root = try std.fmt.allocPrint(allocator, "{s}\\Wazig\\update", .{local_dir});
    defer allocator.free(update_root);

    const cwd = std.Io.Dir.cwd();
    // Fresh staging area; also clears leftovers from any earlier attempt.
    cwd.deleteTree(io, update_root) catch {};
    const root = try cwd.createDirPathOpen(io, update_root, .{});
    defer root.close(io);

    // A .old backup left by a completed earlier swap is safe to drop now.
    {
        const exe_old = try std.fmt.allocPrint(allocator, "{s}\\Messages.exe.old", .{exe_dir});
        defer allocator.free(exe_old);
        const exe_old_wide = try utf8ToWide(allocator, exe_old);
        defer allocator.free(exe_old_wide);
        _ = win.DeleteFileW(exe_old_wide.ptr);
    }

    const api_headers = try utf8ToWide(allocator, "User-Agent: Messages updater\r\nAccept: application/vnd.github+json\r\n");
    defer allocator.free(api_headers);
    const json = try httpGet(allocator, lit("api.github.com"), lit("/repos/valentinyeo/wazig/releases/latest"), api_headers.ptr, 4 * 1024 * 1024);
    defer allocator.free(json);

    var parsed: std.json.Parsed(std.json.Value) = undefined;
    const asset = (try update.pickAsset(allocator, json, &parsed)) orelse return .none;
    defer parsed.deinit();
    if (!update.isNewer(asset.tag, current)) return .none;

    const asset_url = try utf8ToWide(allocator, asset.url);
    defer allocator.free(asset_url);
    const download_headers = try utf8ToWide(allocator, "User-Agent: Messages updater\r\n");
    defer allocator.free(download_headers);
    const body = try httpGetUrl(allocator, asset_url, download_headers.ptr, update_max_asset_bytes);
    defer allocator.free(body);
    if (asset.size != 0 and body.len != asset.size) return error.UpdateSizeMismatch;
    if (!update.digestMatches(body, asset.digest)) return error.UpdateDigestMismatch;

    // Save the verified archive; the std.zip extractor needs a seekable file.
    {
        const zip_file = try root.createFile(io, "Messages.zip", .{});
        defer zip_file.close(io);
        var buffer: [64 * 1024]u8 = undefined;
        var zip_writer = zip_file.writer(io, &buffer);
        try zip_writer.interface.writeAll(body);
        try zip_writer.interface.flush();
    }
    const stage = try root.createDirPathOpen(io, "stage", .{});
    defer stage.close(io);
    // Bound the archive before trusting it: entry count and decompressed size.
    {
        const scan_file = try root.openFile(io, "Messages.zip", .{});
        defer scan_file.close(io);
        var scan_buffer: [64 * 1024]u8 align(16) = undefined;
        var scan_reader = scan_file.reader(io, &scan_buffer);
        var scan = try std.zip.Iterator.init(&scan_reader);
        var entry_count: u64 = 0;
        var total_uncompressed: u64 = 0;
        while (try scan.next()) |entry| {
            entry_count += 1;
            if (entry_count > 4096) return error.UpdateZipTooLarge;
            total_uncompressed += entry.uncompressed_size;
            if (entry.uncompressed_size > 512 * 1024 * 1024 or total_uncompressed > 512 * 1024 * 1024) return error.UpdateZipTooLarge;
        }
    }
    var diagnostics: std.zip.Diagnostics = .{ .allocator = allocator };
    defer diagnostics.deinit();
    {
        const zip_file = try root.openFile(io, "Messages.zip", .{});
        defer zip_file.close(io);
        var buffer: [64 * 1024]u8 align(16) = undefined;
        var zip_reader = zip_file.reader(io, &buffer);
        try std.zip.extract(stage, &zip_reader, .{ .diagnostics = &diagnostics });
    }

    const inner_root = if (diagnostics.root_dir.len > 0) diagnostics.root_dir else "";
    const new_exe_rel = try std.fmt.allocPrint(allocator, "{s}/Messages.exe", .{inner_root});
    defer allocator.free(new_exe_rel);
    _ = try stage.statFile(io, new_exe_rel, .{});

    // Swap: rename the running exe aside (always allowed on Windows), copy the
    // new files in, and roll the rename back if any copy fails.
    const exe_old = try std.fmt.allocPrint(allocator, "{s}\\Messages.exe.old", .{exe_dir});
    defer allocator.free(exe_old);
    const exe_old_wide = try utf8ToWide(allocator, exe_old);
    defer allocator.free(exe_old_wide);
    const exe_wide = try utf8ToWide(allocator, exe_path);
    defer allocator.free(exe_wide);
    if (win.MoveFileExW(exe_wide.ptr, exe_old_wide.ptr, win.MOVEFILE_REPLACE_EXISTING) == 0) return error.UpdateSwapFailed;
    const stage_path = try std.fmt.allocPrint(allocator, "{s}\\stage", .{update_root});
    defer allocator.free(stage_path);
    if (installStagedFiles(io, allocator, stage, stage_path, inner_root, exe_dir)) {
        _ = win.DeleteFileW(exe_old_wide.ptr); // best effort; a leftover is removed on next start
        return .installed;
    }
    // Rollback: restore the old executable over the partially copied install.
    _ = win.MoveFileExW(exe_old_wide.ptr, exe_wide.ptr, win.MOVEFILE_REPLACE_EXISTING);
    return error.UpdateCopyFailed;
}

/// Copies every staged file (below `inner_root` inside `stage_path`) into
/// `exe_dir`. Returns false when any copy fails; files copied before the
/// failure stay in place but the caller restores the renamed backup over the
/// main executable.
fn installStagedFiles(io: std.Io, allocator: std.mem.Allocator, stage: std.Io.Dir, stage_path: []const u8, inner_root: []const u8, exe_dir: []const u8) bool {
    var walker = stage.walk(allocator) catch return false;
    defer walker.deinit();
    while (walker.next(io) catch return false) |entry| {
        if (entry.kind != .file) continue;
        const relative = if (inner_root.len > 0 and std.mem.startsWith(u8, entry.path, inner_root))
            entry.path[inner_root.len + 1 ..]
        else
            entry.path;
        // Never install anything that escapes the application directory.
        var components = std.mem.splitScalar(u8, relative, '/');
        while (components.next()) |component| {
            if (std.mem.eql(u8, component, "..")) return false;
        }
        var windows_relative_buf: [512]u8 = undefined;
        if (relative.len >= windows_relative_buf.len) return false;
        for (relative, 0..) |c, i| windows_relative_buf[i] = if (c == '/') '\\' else c;
        const windows_relative = windows_relative_buf[0..relative.len];
        const destination = std.fmt.allocPrint(allocator, "{s}\\{s}", .{ exe_dir, windows_relative }) catch return false;
        defer allocator.free(destination);
        if (std.fs.path.dirname(destination)) |parent| {
            // Create every missing ancestor; archive entries may nest arbitrarily.
            var depth: usize = 0;
            while (depth < parent.len) : (depth += 1) {
                if (parent[depth] == '\\') {
                    const prefix_wide = utf8ToWide(allocator, parent[0..depth]) catch return false;
                    defer allocator.free(prefix_wide);
                    _ = win.CreateDirectoryW(prefix_wide.ptr, null); // exists already is fine
                }
            }
            const parent_wide = utf8ToWide(allocator, parent) catch return false;
            defer allocator.free(parent_wide);
            _ = win.CreateDirectoryW(parent_wide.ptr, null); // exists already is fine
        }
        const source = std.fmt.allocPrint(allocator, "{s}\\{s}", .{ stage_path, entry.path }) catch return false;
        defer allocator.free(source);
        const source_wide = utf8ToWide(allocator, source) catch return false;
        defer allocator.free(source_wide);
        const destination_wide = utf8ToWide(allocator, destination) catch return false;
        defer allocator.free(destination_wide);
        if (win.CopyFileW(source_wide.ptr, destination_wide.ptr, win.FALSE) == 0) return false;
    }
    return true;
}

fn relaunchIntoUpdate(a: *App) void {
    var exe_buf: [519]u16 = undefined;
    const exe_len: usize = @intCast(win.GetModuleFileNameW(null, &exe_buf, exe_buf.len));
    if (exe_len == 0 or exe_len >= exe_buf.len) {
        setStatus(a, "Update installed - restart the app to finish");
        return;
    }
    exe_buf[exe_len] = 0;
    var startup: win.STARTUPINFOW = std.mem.zeroes(win.STARTUPINFOW);
    startup.cb = @sizeOf(win.STARTUPINFOW);
    var process: win.PROCESS_INFORMATION = std.mem.zeroes(win.PROCESS_INFORMATION);
    if (win.CreateProcessW(exe_buf[0..exe_len :0].ptr, null, null, null, win.FALSE, 0, null, null, &startup, &process) != 0) {
        _ = win.PostQuitMessage(0);
    } else {
        setStatus(a, "Update installed - restart the app to finish");
    }
}

test clampPlayerSize {
    const small = clampPlayerSize(320, 240);
    try std.testing.expectEqual(@as(u32, 320), small[0]);
    try std.testing.expectEqual(@as(u32, 240), small[1]);
    const wide = clampPlayerSize(1920, 1080);
    try std.testing.expectEqual(@as(u32, 800), wide[0]);
    try std.testing.expectEqual(@as(u32, 450), wide[1]);
    const tall = clampPlayerSize(1080, 1920);
    try std.testing.expect(@as(u32, 450) == tall[1]);
    try std.testing.expect(@as(u32, 253) == tall[0]);
    const empty = clampPlayerSize(0, 0);
    try std.testing.expectEqual(@as(u32, 640), empty[0]);
}

test audioButtonRect {
    const first = audioButtonRect(0);
    try std.testing.expectEqual(@as(i32, 16), first.left);
    try std.testing.expectEqual(@as(i32, 108), first.right);
    const third = audioButtonRect(2);
    try std.testing.expectEqual(@as(i32, 316), third.right);
    try std.testing.expect(audioButtonAt(110, 76) == null);
    try std.testing.expectEqual(@as(usize, 1), audioButtonAt(120, 76).?);
    try std.testing.expectEqual(@as(usize, 2), audioButtonAt(260, 76).?);
}

test fileUrl {
    var buffer: [560]u16 = [_]u16{0} ** 560;
    const url = fileUrl(&buffer, &.{ 'C', ':', '\\', 'U', 's', 'e', 'r', 's' });
    const utf8 = try std.unicode.utf16LeToUtf8Alloc(std.testing.allocator, url);
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqualStrings("file:///C:/Users", utf8);
}
