const std = @import("std");
const audio = @import("audio.zig");
const avatar = @import("avatar.zig");
const dictation = @import("dictation.zig");

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
    @cInclude("mfapi.h");
    @cInclude("mfidl.h");
    @cInclude("mfreadwrite.h");
    @cInclude("winhttp.h");
});

const app_version = "0.9.7";
const update = @import("update.zig");

const max_chats = 256;
const max_groups = 1024;
const max_messages = 100;
const max_pending_sends = 32;
const max_pending_reads = 8;
const max_avatars = 256;
const timer_refresh = 1;
const timer_search = 2;
const timer_animation = 3;
const timer_chat_select = 4;
const timer_update_check = 5;
const timer_update_restart = 6;
const wm_update_ready = win.WM_APP + 2;
const update_check_interval_ms: u32 = 4 * 60 * 60 * 1000;
const update_restart_delay_ms: u32 = 10 * 1000;
const update_max_asset_bytes: usize = 256 * 1024 * 1024;
const id_search = 1008;
const id_chats = 1016;
const id_canvas = 1024;
const id_compose = 1032;
const id_send = 1040;
const id_status = 1048;
const id_dictate = 1056;
const id_palette_edit = 1064;
const id_palette_list = 1072;
const id_emoji = 1080;
const command_search = 2001;
const command_compose = 2002;
const command_unread = 2003;
const command_refresh = 2004;
const command_sync = 2005;
const command_quit = 2006;
const command_archive = 2007;
const command_archived = 2008;
const command_dictate = 2009;
const command_font_smaller = 2010;
const command_font_larger = 2011;
const command_font_reset = 2012;
const command_dictation_auto = 2013;
const command_dictation_english = 2014;
const command_dictation_german = 2015;
const command_speed_1 = 2016;
const command_speed_150 = 2017;
const command_speed_200 = 2018;
const command_copy_text = 2019;
const command_copy_link = 2020;
const command_copy_selection = 2021;
const command_copy_transcript = 2022;
const reaction_like = 3001;
const reaction_love = 3002;
const reaction_laugh = 3003;
const reaction_surprised = 3004;
const reaction_sad = 3005;
const reaction_thanks = 3006;
const reaction_remove = 3007;
const emoji_picker = @import("emoji_picker.zig");
const picker_emojis = emoji_picker.picker_emojis;
const picker_base = emoji_picker.picker_base;
const pickerEmojiForCommand = emoji_picker.pickerEmojiForCommand;

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

const PendingSend = struct {
    jid: Utf8Text(191) = .{},
    text: Utf8Text(4095) = .{},
};

const LinkSpan = struct {
    rect: win.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    url: WideText(519) = .{},
};

const WordSpan = struct {
    rect: win.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    start: u32 = 0,
    len: u32 = 0,
};

const PendingArchive = struct {
    jid: Utf8Text(191) = .{},
    should_unarchive: bool = false,
};

const AvatarEntry = struct {
    jid: Utf8Text(191) = .{},
    path: WideText(519) = .{},
    bitmap: ?win.HBITMAP = null,
    status: enum { unknown, loading, ready, unavailable } = .unknown,
};

const PaletteItem = struct {
    label: WideText(63) = .{},
    shortcut: WideText(15) = .{},
    command: u16 = 0,
    url: WideText(519) = .{},
};

const max_palette_items = 16;
const palette_width: i32 = 540;
const palette_row_height: i32 = 40;
const palette_edit_zone: i32 = 64;
const palette_max_rows = 10;

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
    gif_reader: [*c]win.IMFSourceReader = null,
    transcript: WideText(2047) = .{},
    transcript_state: enum { none, loading, ready, failed } = .none,
    links: [8]LinkSpan = [_]LinkSpan{.{}} ** 8,
    link_count: usize = 0,
    word_rects: [256]WordSpan = [_]WordSpan{.{}} ** 256,
    word_count: usize = 0,
    transcript_expanded: bool = false,
    toggle_hit: win.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    media_hit: win.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
    bubble_hit: win.RECT = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 },
};

const App = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    instance: win.HINSTANCE,
    wacli_path: []u8,
    avatar_dir: []u8,
    hwnd: ?win.HWND = null,
    search: ?win.HWND = null,
    chats_hwnd: ?win.HWND = null,
    canvas: ?win.HWND = null,
    compose: ?win.HWND = null,
    send: ?win.HWND = null,
    emoji_btn: ?win.HWND = null,
    dictate: ?win.HWND = null,
    tooltips: ?win.HWND = null,
    status: ?win.HWND = null,
    palette: ?win.HWND = null,
    palette_edit: ?win.HWND = null,
    palette_list: ?win.HWND = null,
    palette_items: [max_palette_items]PaletteItem = [_]PaletteItem{.{}} ** max_palette_items,
    palette_item_count: usize = 0,
    palette_matches: [max_palette_items]usize = [_]usize{0} ** max_palette_items,
    palette_match_count: usize = 0,
    palette_selected: usize = 0,
    palette_ever_active: bool = false,
    user_viewed: bool = false,
    chat_selection_pending: bool = false,
    last_chat_count: usize = std.math.maxInt(usize),
    font: ?win.HFONT = null,
    font_small: ?win.HFONT = null,
    font_bold: ?win.HFONT = null,
    font_emoji: ?win.HFONT = null,
    font_underline: ?win.HFONT = null,
    palette_links_mode: bool = false,
    font_scale: i32 = 80,
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
    archive_child: ?std.process.Child = null,
    pending_archives: [max_pending_sends]PendingArchive = [_]PendingArchive{.{}} ** max_pending_sends,
    pending_archive_count: usize = 0,
    group_refresh_ticks: u8 = 0,
    deepgram_configured: bool = false,
    deepgram_key: []const u8 = "",
    dictation_session: ?*dictation.Session = null,
    dictation_language: dictation.Language = .automatic,
    last_dictation_state: dictation.State = .idle,
    sync_child: ?std.process.Child = null,
    sync_job: ?win.HANDLE = null,
    audio_player: ?*audio.Player = null,
    audio_state: enum { empty, ready, playing, paused } = .empty,
    audio_playing_id: Utf8Text(191) = .{},
    audio_position_ms: i64 = 0,
    audio_duration_ms: i64 = 0,
    media_child: ?std.process.Child = null,
    read_child: ?std.process.Child = null,
    read_spawn_failures: u32 = 0,
    read_started_ms: u64 = 0,
    pending_reads: [max_pending_reads]Utf8Text(191) = [_]Utf8Text(191){.{}} ** max_pending_reads,
    pending_read_count: usize = 0,
    pending_download_jid: Utf8Text(191) = .{},
    pending_download_id: Utf8Text(191) = .{},
    send_child: ?std.process.Child = null,
    pending_sends: [max_pending_sends]PendingSend = [_]PendingSend{.{}} ** max_pending_sends,
    pending_send_count: usize = 0,
    media_attempts: [512]u64 = [_]u64{0} ** 512,
    media_attempt_count: usize = 0,
    avatar_session: ?*avatar.Session = null,
    transcribe_session: ?*dictation.FileSession = null,
    sel_message: ?usize = null,
    sel_anchor_word: usize = 0,
    sel_focus_word: usize = 0,
    text_dragging: bool = false,
    drag_moved: bool = false,
    drag_origin: win.POINT = .{ .x = 0, .y = 0 },
    openrouter_session: ?*dictation.TextSession = null,
    openrouter_active_id: Utf8Text(191) = .{},
    openrouter_key: []const u8 = "",
    openrouter_model: []const u8 = "openai/gpt-5.6-luna",
    openrouter_configured: bool = false,
    openrouter_attempts: [512]u64 = [_]u64{0} ** 512,
    openrouter_attempt_count: usize = 0,
    transcribe_active_id: Utf8Text(191) = .{},
    transcribe_attempts: [512]u64 = [_]u64{0} ** 512,
    transcribe_attempt_count: usize = 0,
    last_alt_g_ms: u64 = 0,
    avatars: [max_avatars]AvatarEntry = [_]AvatarEntry{.{}} ** max_avatars,
    avatar_count: usize = 0,
    avatar_active_index: ?usize = null,
    wic_factory: [*c]win.IWICImagingFactory = null,
    displayed_jid: Utf8Text(191) = .{},
    displayed_timestamp: Utf8Text(47) = .{},
    store_watch_path: WideText(519) = .{},
    last_store_write: u64 = 0,
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

fn loadRegistryString(allocator: std.mem.Allocator, name: [*:0]const u16) ?[]const u8 {
    var wide: [1024]u16 = undefined;
    var size: win.DWORD = @intCast(wide.len * 2);
    const result = win.RegGetValueW(winHandle(win.HKEY, 0x80000001), lit("Software\\Messages"), name, win.RRF_RT_REG_SZ, null, &wide, &size);
    if (result != win.ERROR_SUCCESS or size < 2) return null;
    const char_count = (size - 1) / 2;
    return std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..char_count]) catch null;
}

fn loadFontScale() i32 {
    var value: win.DWORD = 80;
    var size: win.DWORD = @sizeOf(win.DWORD);
    const result = win.RegGetValueW(winHandle(win.HKEY, 0x80000001), lit("Software\\Messages"), lit("FontScale"), win.RRF_RT_REG_DWORD, null, &value, &size);
    if (result != win.ERROR_SUCCESS) return 80;
    return std.math.clamp(@as(i32, @intCast(value)), 60, 160);
}

fn loadDictationLanguage() dictation.Language {
    var value: win.DWORD = 0;
    var size: win.DWORD = @sizeOf(win.DWORD);
    const result = win.RegGetValueW(winHandle(win.HKEY, 0x80000001), lit("Software\\Messages"), lit("DictationLanguage"), win.RRF_RT_REG_DWORD, null, &value, &size);
    if (result != win.ERROR_SUCCESS or value > 2) return .automatic;
    return @enumFromInt(value);
}

fn saveDictationLanguage(language: dictation.Language) void {
    var key: win.HKEY = null;
    var disposition: win.DWORD = 0;
    if (win.RegCreateKeyExW(winHandle(win.HKEY, 0x80000001), lit("Software\\Messages"), 0, null, 0, win.KEY_SET_VALUE, null, &key, &disposition) != win.ERROR_SUCCESS) return;
    defer _ = win.RegCloseKey(key);
    const value: win.DWORD = @intFromEnum(language);
    _ = win.RegSetValueExW(key, lit("DictationLanguage"), 0, win.REG_DWORD, @ptrCast(&value), @sizeOf(win.DWORD));
}

fn saveFontScale(scale: i32) void {
    var key: win.HKEY = null;
    var disposition: win.DWORD = 0;
    if (win.RegCreateKeyExW(winHandle(win.HKEY, 0x80000001), lit("Software\\Messages"), 0, null, 0, win.KEY_SET_VALUE, null, &key, &disposition) != win.ERROR_SUCCESS) return;
    defer _ = win.RegCloseKey(key);
    const value: win.DWORD = @intCast(scale);
    _ = win.RegSetValueExW(key, lit("FontScale"), 0, win.REG_DWORD, @ptrCast(&value), @sizeOf(win.DWORD));
}

fn scaledFontHeight(base: i32, scale: i32) i32 {
    return -@divTrunc(base * scale + 50, 100);
}

fn recreateFonts(a: *App) void {
    const old_font = a.font;
    const old_small = a.font_small;
    const old_bold = a.font_bold;
    const old_underline = a.font_underline;
    a.font = win.CreateFontW(scaledFontHeight(17, a.font_scale), 0, 0, 0, win.FW_NORMAL, 0, 0, 0, win.DEFAULT_CHARSET, win.OUT_DEFAULT_PRECIS, win.CLIP_DEFAULT_PRECIS, win.CLEARTYPE_QUALITY, win.DEFAULT_PITCH, lit("IBM Plex Sans"));
    a.font_small = win.CreateFontW(scaledFontHeight(13, a.font_scale), 0, 0, 0, win.FW_NORMAL, 0, 0, 0, win.DEFAULT_CHARSET, win.OUT_DEFAULT_PRECIS, win.CLIP_DEFAULT_PRECIS, win.CLEARTYPE_QUALITY, win.DEFAULT_PITCH, lit("IBM Plex Sans"));
    a.font_bold = win.CreateFontW(scaledFontHeight(16, a.font_scale), 0, 0, 0, win.FW_SEMIBOLD, 0, 0, 0, win.DEFAULT_CHARSET, win.OUT_DEFAULT_PRECIS, win.CLIP_DEFAULT_PRECIS, win.CLEARTYPE_QUALITY, win.DEFAULT_PITCH, lit("IBM Plex Sans"));
    a.font_emoji = win.CreateFontW(scaledFontHeight(16, a.font_scale), 0, 0, 0, win.FW_NORMAL, 0, 0, 0, win.DEFAULT_CHARSET, win.OUT_DEFAULT_PRECIS, win.CLIP_DEFAULT_PRECIS, win.CLEARTYPE_QUALITY, win.DEFAULT_PITCH, lit("Segoe UI Emoji"));
    a.font_underline = win.CreateFontW(scaledFontHeight(17, a.font_scale), 0, 0, 0, win.FW_NORMAL, 0, 1, 0, win.DEFAULT_CHARSET, win.OUT_DEFAULT_PRECIS, win.CLIP_DEFAULT_PRECIS, win.CLEARTYPE_QUALITY, win.DEFAULT_PITCH, lit("IBM Plex Sans"));
    setFont(a.search, a.font);
    setFont(a.chats_hwnd, a.font);
    setFont(a.compose, a.font);
    setFont(a.dictate, a.font_bold);
    setFont(a.send, a.font_bold);
    setFont(a.emoji_btn, a.font_emoji);
    setFont(a.status, a.font_small);
    setFont(a.palette_edit, a.font);
    setFont(a.palette_list, a.font);
    if (old_font) |font| _ = win.DeleteObject(font);
    if (old_small) |font| _ = win.DeleteObject(font);
    if (old_bold) |font| _ = win.DeleteObject(font);
    if (old_underline) |font| _ = win.DeleteObject(font);
    if (a.hwnd) |hwnd| _ = win.InvalidateRect(hwnd, null, win.TRUE);
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.TRUE);
}

fn changeFontScale(a: *App, delta: i32) void {
    const next = std.math.clamp(a.font_scale + delta, 60, 160);
    if (next == a.font_scale) return;
    a.font_scale = next;
    recreateFonts(a);
    saveFontScale(next);
    var buffer: [48]u8 = undefined;
    setStatus(a, std.fmt.bufPrint(&buffer, "Font size {d}%", .{next}) catch "Font size changed");
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

fn runWacliExclusive(a: *App, argv: []const []const u8) !std.json.Parsed(std.json.Value) {
    stopSync(a);
    defer if (a.media_child == null) startSync(a);
    return runWacli(a, argv);
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
    // A mark-read write may still be queued or running: keep those chats
    // shown as read until the write lands and the next refresh reflects it.
    for (a.chats[0..a.chat_count]) |*chat| {
        var queued: usize = 0;
        while (queued < a.pending_read_count) : (queued += 1) {
            if (std.mem.eql(u8, a.pending_reads[queued].slice(), chat.jid.slice())) {
                chat.unread = false;
                chat.unread_count = 0;
            }
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
    if (a.chat_count != a.last_chat_count) {
        a.last_chat_count = a.chat_count;
        const status = std.fmt.bufPrint(&status_buffer, "{d} chats", .{a.chat_count}) catch "Chats loaded";
        setStatus(a, status);
    }
}

fn markChatRead(a: *App) void {
    if (!a.user_viewed or a.selected_chat >= a.chat_count) return;
    const chat = &a.chats[a.selected_chat];
    if (!chat.unread and chat.unread_count == 0) return;
    // Clear the badge once the request is queued or already in flight; if
    // the queue is full, keep the unread state so the next view retries.
    var already_queued = false;
    var index: usize = 0;
    while (index < a.pending_read_count) : (index += 1) {
        if (std.mem.eql(u8, a.pending_reads[index].slice(), chat.jid.slice())) already_queued = true;
    }
    if (already_queued or a.pending_read_count < a.pending_reads.len) {
        if (!already_queued) {
            a.pending_reads[a.pending_read_count].set(chat.jid.slice());
            a.pending_read_count += 1;
        }
        chat.unread = false;
        chat.unread_count = 0;
        if (a.chats_hwnd) |list| _ = win.InvalidateRect(list, null, win.TRUE);
    }
    startNextMarkRead(a);
}

fn removeFirstPendingRead(a: *App) void {
    if (a.pending_read_count == 0) return;
    var index: usize = 1;
    while (index < a.pending_read_count) : (index += 1) a.pending_reads[index - 1] = a.pending_reads[index];
    a.pending_read_count -= 1;
}

// The mark-read write used to run on the UI thread with the sync child
// stopped, so opening any unread chat froze the window for as long as the
// store lock took. Run it as a background job like sends and archives.
fn startNextMarkRead(a: *App) void {
    if (a.read_child != null or a.pending_read_count == 0) return;
    if (a.media_child != null or a.send_child != null or a.pending_send_count > 0 or
        a.archive_child != null or a.pending_archive_count > 0 or avatarBusy(a)) return;
    stopSync(a);
    const child = std.process.spawn(a.io, .{
        .argv = &.{ a.wacli_path, "--json", "--lock-wait", "10s", "chats", "mark-read", "--chat", a.pending_reads[0].slice() },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch {
        // Give up after repeated spawn failures: drop the queue, restore
        // the real unread badges via refreshChats, and let live sync run so
        // a broken wacli cannot keep the app's sync permanently stopped.
        a.read_spawn_failures += 1;
        if (a.read_spawn_failures >= 3) {
            a.pending_read_count = 0;
            a.read_spawn_failures = 0;
            startSync(a);
            refreshChats(a);
            setStatus(a, "Could not mark chats as read; unread badges restored");
        } else setStatus(a, "Could not start mark as read; retrying");
        return;
    };
    a.read_spawn_failures = 0;
    a.read_child = child;
    a.read_started_ms = win.GetTickCount64();
}

// The mark-read child gates every other background job, so a hung wacli must
// not wedge the app: the lock wait is capped at 10s, so 30s means it is stuck.
const read_timeout_ms: u64 = 30_000;

fn checkMarkRead(a: *App) void {
    if (a.read_child) |*child| {
        const handle = child.id orelse return;
        var code: win.DWORD = 0;
        if (win.GetExitCodeProcess(handle, &code) == 0 or code == win.STILL_ACTIVE) {
            if (win.GetTickCount64() - a.read_started_ms <= read_timeout_ms) return;
            _ = child.kill(a.io);
            code = 1;
        }
        _ = child.wait(a.io) catch {};
        a.read_child = null;
        removeFirstPendingRead(a);
        // Drain the queue back-to-back before restarting live sync, which
        // stays suspended while reads are pending.
        if (a.pending_read_count > 0) {
            startNextMarkRead(a);
            return;
        }
        // Release any sends or archives that queued up while the store was
        // held, then bring live sync back. startSync skips itself while a
        // write job is running.
        startNextSend(a);
        startNextArchive(a);
        startSync(a);
        refreshChats(a);
        setStatus(a, if (code == 0) "Chat marked as read" else "Mark as read failed");
        // After the status above so a queued download's own message shows.
        retryPendingDownload(a);
    } else startNextMarkRead(a);
}

// A manual download clicked while a mark-read job held the store waits here;
// start it once no read job or download is running and its message is on
// screen (the request is dropped if the user switched chats meanwhile).
fn retryPendingDownload(a: *App) void {
    if (a.pending_download_id.len == 0 or a.read_child != null or a.pending_read_count > 0 or
        a.media_child != null) return;
    if (a.selected_chat >= a.chat_count) return;
    if (!std.mem.eql(u8, a.pending_download_jid.slice(), a.chats[a.selected_chat].jid.slice())) {
        a.pending_download_jid.set("");
        a.pending_download_id.set("");
        return;
    }
    var found: ?usize = null;
    for (a.messages[0..a.message_count], 0..) |*message, index| {
        if (std.mem.eql(u8, message.id.slice(), a.pending_download_id.slice())) found = index;
    }
    a.pending_download_jid.set("");
    a.pending_download_id.set("");
    if (found) |index| downloadMedia(a, index, false);
}

fn clearMessages(a: *App) void {
    for (a.messages[0..a.message_count]) |*message| {
        if (message.bitmap) |bitmap| _ = win.DeleteObject(bitmap);
        if (message.gif_reader != null) _ = message.gif_reader.*.lpVtbl.*.Release.?(message.gif_reader);
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
    return std.ascii.eqlIgnoreCase(message.media_type.slice(), "video") or
        std.ascii.eqlIgnoreCase(message.media_type.slice(), "gif");
}

fn isAudio(message: *const Message) bool {
    return std.ascii.eqlIgnoreCase(message.media_type.slice(), "audio");
}

fn ensureAudioPlayer(a: *App) ?*audio.Player {
    if (a.audio_player) |player| return player;
    a.audio_player = audio.Player.create(a.allocator, a.io) catch null;
    return a.audio_player;
}

fn stopAudio(a: *App) void {
    if (a.audio_state == .empty) return;
    a.audio_state = .empty;
    a.audio_playing_id.set("");
    a.audio_position_ms = 0;
    a.audio_duration_ms = 0;
    if (a.audio_player) |player| player.stop();
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.TRUE);
}

fn startAudioPlayback(a: *App, message: *Message) void {
    const player = ensureAudioPlayer(a) orelse {
        setStatus(a, "Windows cannot start audio playback");
        return;
    };
    const path_utf8 = std.unicode.utf16LeToUtf8Alloc(a.allocator, message.local_path.slice()) catch return;
    defer a.allocator.free(path_utf8);
    player.play(path_utf8);
    a.audio_playing_id.set(message.id.slice());
    a.audio_state = .playing;
    a.audio_position_ms = 0;
    a.audio_duration_ms = 0;
    setStatus(a, "Playing voice message...");
}

fn toggleAudio(a: *App, message: *Message) void {
    const player = a.audio_player orelse return;
    // Drive from the player's real state; the cached UI state can desync
    // after a message ends, which made the button stop responding.
    switch (player.state()) {
        .playing => {
            player.pause();
            a.audio_state = .paused;
        },
        .paused => {
            player.unpause();
            a.audio_state = .playing;
        },
        .ended => {
            player.seek(0);
            player.unpause();
            a.audio_state = .playing;
        },
        else => startAudioPlayback(a, message),
    }
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.FALSE);
}

fn seekAudio(a: *App, x: i32, hit: win.RECT) void {
    const player = a.audio_player orelse return;
    if (a.audio_duration_ms <= 0) return;
    const track_left = hit.left + 94;
    const track_right = hit.right - 64;
    if (track_right <= track_left) return;
    const fraction = std.math.clamp(@as(f64, @floatFromInt(x - track_left)) / @as(f64, @floatFromInt(track_right - track_left)), 0, 1);
    const target_ms: i64 = @intFromFloat(fraction * @as(f64, @floatFromInt(a.audio_duration_ms)));
    player.seek(target_ms);
    a.audio_position_ms = target_ms;
    player.unpause();
    a.audio_state = .playing;
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.FALSE);
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.FALSE);
}

fn handleAudioClick(a: *App, message: *Message, x: i32) void {
    const active = std.mem.eql(u8, a.audio_playing_id.slice(), message.id.slice()) and a.audio_state != .empty;
    if (!active) {
        startAudioPlayback(a, message);
        return;
    }
    const hit = message.media_hit;
    if (x < hit.left + 48) {
        toggleAudio(a, message);
        return;
    }
    if (x < hit.left + 96) {
        cycleSpeed(a);
        return;
    }
    seekAudio(a, x, hit);
}

fn updateAudioPlayback(a: *App) void {
    const player = a.audio_player orelse return;
    const state = player.state();
    if (player.start_failed.load(.acquire) and state == .idle) {
        if (a.audio_state != .empty) {
            a.audio_state = .empty;
            a.audio_playing_id.set("");
            a.audio_position_ms = 0;
            a.audio_duration_ms = 0;
            setStatus(a, "Windows cannot play this audio format");
            if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.TRUE);
        }
        return;
    }
    const mapped: @TypeOf(a.audio_state) = switch (state) {
        .ready => .ready,
        .playing => .playing,
        .paused => .paused,
        .ended => .ready,
        .idle => .empty,
    };
    var changed = false;
    if (mapped != a.audio_state) {
        a.audio_state = mapped;
        changed = true;
        if (mapped == .empty) {
            a.audio_playing_id.set("");
            a.audio_position_ms = 0;
            a.audio_duration_ms = 0;
        }
    }
    const duration = player.durationMs();
    const position = player.positionMs();
    if (duration > 0 and duration != a.audio_duration_ms) {
        a.audio_duration_ms = duration;
        changed = true;
    }
    if (position != a.audio_position_ms) {
        a.audio_position_ms = position;
        changed = true;
    }
    if (changed or mapped == .playing) {
        if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.FALSE);
    }
}

fn formatClock(buffer: []u8, ms: i64) []const u8 {
    const seconds = @divTrunc(ms, 1000);
    return std.fmt.bufPrint(buffer, "{d}:{d:0>2}", .{ @divTrunc(seconds, 60), @mod(seconds, 60) }) catch "0:00";
}

fn isGif(message: *const Message) bool {
    return std.ascii.eqlIgnoreCase(message.media_type.slice(), "gif") or
        std.ascii.eqlIgnoreCase(message.mime_type.slice(), "image/gif");
}

fn isVideoGif(message: *const Message) bool {
    const mime = message.mime_type.slice();
    return std.ascii.eqlIgnoreCase(message.media_type.slice(), "gif") and
        mime.len >= 6 and std.ascii.eqlIgnoreCase(mime[0..6], "video/");
}

fn decodeGifVideoFrame(message: *Message) bool {
    if (message.gif_reader == null or message.bitmap_width <= 0 or message.bitmap_height <= 0) return false;
    var actual_stream: win.DWORD = 0;
    var flags: win.DWORD = 0;
    var timestamp: win.LONGLONG = 0;
    var sample: ?*win.IMFSample = null;
    const hr = message.gif_reader.*.lpVtbl.*.ReadSample.?(message.gif_reader, win.MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &actual_stream, &flags, &timestamp, &sample);
    if (hr < 0 or (flags & win.MF_SOURCE_READERF_ENDOFSTREAM) != 0) {
        if (sample) |value| _ = value.*.lpVtbl.*.Release.?(value);
        _ = message.gif_reader.*.lpVtbl.*.Release.?(message.gif_reader);
        message.gif_reader = null;
        return false;
    }
    const media_sample = sample orelse return false;
    defer _ = media_sample.*.lpVtbl.*.Release.?(media_sample);
    var buffer: ?*win.IMFMediaBuffer = null;
    if (media_sample.*.lpVtbl.*.ConvertToContiguousBuffer.?(media_sample, &buffer) < 0 or buffer == null) return false;
    defer _ = buffer.?.*.lpVtbl.*.Release.?(buffer);
    const row_bytes: usize = @intCast(message.bitmap_width * 4);
    const required: usize = row_bytes * @as(usize, @intCast(message.bitmap_height));
    var info = std.mem.zeroes(win.BITMAPINFO);
    info.bmiHeader.biSize = @sizeOf(win.BITMAPINFOHEADER);
    info.bmiHeader.biWidth = message.bitmap_width;
    // The reference decode proved MF RGB32 Lock2D rows start at the top
    // image row, so the DIB must be top-down to match.
    info.bmiHeader.biHeight = -message.bitmap_height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = win.BI_RGB;
    var bits: ?*anyopaque = null;
    const bitmap = win.CreateDIBSection(null, &info, win.DIB_RGB_COLORS, &bits, null, 0) orelse return false;
    if (bits == null) {
        _ = win.DeleteObject(bitmap);
        return false;
    }
    errdefer _ = win.DeleteObject(bitmap);
    const destination: [*]u8 = @ptrCast(bits.?);

    var two_d: [*c]win.IMF2DBuffer = null;
    if (buffer.?.*.lpVtbl.*.QueryInterface.?(buffer.?, &win.IID_IMF2DBuffer, @ptrCast(&two_d)) >= 0 and two_d != null) {
        defer _ = two_d.*.lpVtbl.*.Release.?(two_d);
        var scanline: [*c]u8 = null;
        var pitch: win.LONG = 0;
        if (two_d.*.lpVtbl.*.Lock2D.?(two_d, &scanline, &pitch) < 0) return false;
        defer _ = two_d.*.lpVtbl.*.Unlock2D.?(two_d);
        var row: usize = 0;
        while (row < @as(usize, @intCast(message.bitmap_height))) : (row += 1) {
            const source_address: isize = @as(isize, @intCast(@intFromPtr(scanline))) + @as(isize, pitch) * @as(isize, @intCast(row));
            const source: [*]const u8 = @ptrFromInt(@as(usize, @intCast(source_address)));
            @memcpy(destination[row * row_bytes ..][0..row_bytes], source[0..row_bytes]);
        }
    } else {
        var bytes: [*c]u8 = null;
        var maximum: win.DWORD = 0;
        var length: win.DWORD = 0;
        if (buffer.?.*.lpVtbl.*.Lock.?(buffer.?, &bytes, &maximum, &length) < 0) return false;
        defer _ = buffer.?.*.lpVtbl.*.Unlock.?(buffer.?);
        if (length < required) return false;
        const source_stride: usize = @intCast(length / @as(u32, @intCast(message.bitmap_height)));
        var row: usize = 0;
        while (row < @as(usize, @intCast(message.bitmap_height))) : (row += 1) {
            @memcpy(destination[row * row_bytes ..][0..row_bytes], bytes[row * source_stride ..][0..row_bytes]);
        }
    }
    message.bitmap = bitmap;
    return true;
}

fn ensureGifVideoBitmap(message: *Message) void {
    if (message.local_path.len == 0) return;
    if (message.gif_reader == null) {
        var attributes: ?*win.IMFAttributes = null;
        if (win.MFCreateAttributes(&attributes, 1) < 0 or attributes == null) return;
        defer _ = attributes.?.*.lpVtbl.*.Release.?(attributes);
        _ = attributes.?.*.lpVtbl.*.SetUINT32.?(attributes.?, &win.MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1);
        var reader: [*c]win.IMFSourceReader = null;
        if (win.MFCreateSourceReaderFromURL(message.local_path.ptr(), attributes, &reader) < 0 or reader == null) return;
        message.gif_reader = reader;

        var native_type: ?*win.IMFMediaType = null;
        var source_width: win.UINT32 = 0;
        var source_height: win.UINT32 = 0;
        if (reader.*.lpVtbl.*.GetNativeMediaType.?(reader, win.MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, &native_type) >= 0 and native_type != null) {
            var packed_size: win.UINT64 = 0;
            if (native_type.?.*.lpVtbl.*.GetUINT64.?(native_type.?, &win.MF_MT_FRAME_SIZE, &packed_size) >= 0) {
                source_width = @truncate(packed_size >> 32);
                source_height = @truncate(packed_size);
            }
            _ = native_type.?.*.lpVtbl.*.Release.?(native_type);
        }
        if (source_width == 0 or source_height == 0) {
            source_width = 320;
            source_height = 180;
        }
        var target_width: win.UINT32 = @min(source_width, 420);
        var target_height: win.UINT32 = @intCast(@max(1, @divTrunc(@as(u64, source_height) * target_width, source_width)));
        if (target_height > 250) {
            target_height = 250;
            target_width = @intCast(@max(1, @divTrunc(@as(u64, source_width) * target_height, source_height)));
        }
        var output_type: ?*win.IMFMediaType = null;
        if (win.MFCreateMediaType(&output_type) < 0 or output_type == null) return;
        defer _ = output_type.?.*.lpVtbl.*.Release.?(output_type);
        _ = output_type.?.*.lpVtbl.*.SetGUID.?(output_type.?, &win.MF_MT_MAJOR_TYPE, &win.MFMediaType_Video);
        _ = output_type.?.*.lpVtbl.*.SetGUID.?(output_type.?, &win.MF_MT_SUBTYPE, &win.MFVideoFormat_RGB32);
        _ = output_type.?.*.lpVtbl.*.SetUINT64.?(output_type.?, &win.MF_MT_FRAME_SIZE, (@as(u64, target_width) << 32) | target_height);
        if (reader.*.lpVtbl.*.SetCurrentMediaType.?(reader, win.MF_SOURCE_READER_FIRST_VIDEO_STREAM, null, output_type.?) < 0) return;
        // Media Foundation may ignore the requested size; query what it
        // actually produces, otherwise frames read with the wrong width
        // come out sheared and distorted.
        var effective_type: ?*win.IMFMediaType = null;
        if (reader.*.lpVtbl.*.GetCurrentMediaType.?(reader, win.MF_SOURCE_READER_FIRST_VIDEO_STREAM, &effective_type) >= 0 and effective_type != null) {
            var packed_size: win.UINT64 = 0;
            if (effective_type.?.*.lpVtbl.*.GetUINT64.?(effective_type.?, &win.MF_MT_FRAME_SIZE, &packed_size) >= 0) {
                const actual_width: win.UINT32 = @truncate(packed_size >> 32);
                const actual_height: win.UINT32 = @truncate(packed_size);
                if (actual_width > 0 and actual_height > 0) {
                    target_width = actual_width;
                    target_height = actual_height;
                }
            }
            _ = effective_type.?.*.lpVtbl.*.Release.?(effective_type);
        }
        message.bitmap_width = @intCast(target_width);
        message.bitmap_height = @intCast(target_height);
        message.gif_frame_count = 2;
    }
    _ = decodeGifVideoFrame(message);
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

fn ensureBitmap(a: *App, message: *Message) void {
    if (message.bitmap != null or message.local_path.len == 0) return;
    if (isVideoGif(message)) {
        ensureGifVideoBitmap(message);
        return;
    }
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
    if (decoder_hr < 0 or decoder == null) return;
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
        @ptrCast(frame),
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

fn downloadMedia(a: *App, message_index: usize, automatic: bool) void {
    if (message_index >= a.message_count or a.selected_chat >= a.chat_count) return;
    const message = &a.messages[message_index];
    if (message.media_type.len == 0 or message.id.len == 0) return;
    if (a.media_child != null or a.read_child != null or a.pending_read_count > 0) {
        if (!automatic) {
            // Reads have no queue a click can join, so remember the request
            // and start it once the mark-read job finishes.
            a.pending_download_jid.set(a.chats[a.selected_chat].jid.slice());
            a.pending_download_id.set(message.id.slice());
            setStatus(a, "Attachment download queued");
        }
        return;
    }
    setStatus(a, if (automatic) "Downloading media..." else "Downloading attachment...");
    if (a.hwnd) |hwnd| _ = win.UpdateWindow(hwnd);
    stopSync(a);
    const chat = &a.chats[a.selected_chat];
    const args = [_][]const u8{ a.wacli_path, "--json", "--lock-wait", "10s", "--timeout", "60s", "media", "download", "--chat", chat.jid.slice(), "--id", message.id.slice() };
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

fn isDownloadableMedia(message: *const Message) bool {
    return isImage(message) or isVideo(message) or isAudio(message) or
        std.ascii.eqlIgnoreCase(message.media_type.slice(), "document");
}

fn autoDownloadNextMedia(a: *App) void {
    if (a.media_child != null or a.read_child != null or a.archive_child != null or a.pending_archive_count > 0) return;
    for (a.messages[0..a.message_count], 0..) |*message, index| {
        if (!isDownloadableMedia(message) or message.local_path.len > 0 or message.id.len == 0) continue;
        if (mediaWasAttempted(a, message.id.slice())) continue;
        downloadMedia(a, index, true);
        return;
    }
}

fn ensureAvatarSession(a: *App) ?*avatar.Session {
    if (a.avatar_session) |session| return session;
    a.avatar_session = avatar.Session.create(a.allocator, a.io) catch null;
    return a.avatar_session;
}

fn avatarBusy(a: *const App) bool {
    return if (a.avatar_session) |session| session.state() == .working else false;
}

fn checkAvatarDownload(a: *App) void {
    const session = a.avatar_session orelse return;
    const state = session.state();
    if (state == .idle or state == .working) return;
    if (a.avatar_active_index) |index| {
        if (index < a.avatar_count) {
            const entry = &a.avatars[index];
            if (state == .ready) {
                entry.bitmap = loadAvatarBitmap(a, entry.path.ptr());
                entry.status = if (entry.bitmap != null) .ready else .unavailable;
            } else entry.status = .unavailable;
        }
    }
    a.avatar_active_index = null;
    session.reset();
    startSync(a);
    if (a.chats_hwnd) |list| _ = win.InvalidateRect(list, null, win.FALSE);
}

fn requestSelectedAvatar(a: *App) void {
    if (a.read_child != null or a.pending_read_count > 0 or a.media_child != null or a.send_child != null or a.archive_child != null or a.pending_archive_count > 0 or avatarBusy(a)) return;
    if (a.chat_count == 0 or a.selected_chat >= a.chat_count) return;
    const entry = avatarForChat(a, a.chats[a.selected_chat].jid.slice()) orelse return;
    if (entry.status != .unknown or entry.path.len == 0) return;
    var index: usize = 0;
    while (index < a.avatar_count and &a.avatars[index] != entry) : (index += 1) {}
    if (index >= a.avatar_count) return;
    const destination = std.unicode.utf16LeToUtf8Alloc(a.allocator, entry.path.slice()) catch return;
    defer a.allocator.free(destination);
    const session = ensureAvatarSession(a) orelse return;
    stopSync(a);
    if (session.start(a.wacli_path, entry.jid.slice(), destination)) {
        entry.status = .loading;
        a.avatar_active_index = index;
    } else startSync(a);
}

fn loadTranscriptCache(a: *App, message: *Message) void {
    const path_utf8 = std.unicode.utf16LeToUtf8Alloc(a.allocator, message.local_path.slice()) catch return;
    defer a.allocator.free(path_utf8);
    const cache_path = std.fmt.allocPrint(a.allocator, "{s}.txt", .{path_utf8}) catch return;
    defer a.allocator.free(cache_path);
    const contents = readFileWin(a.allocator, cache_path, 4096) orelse return;
    defer a.allocator.free(contents);
    const trimmed = std.mem.trim(u8, contents, " \r\n\t");
    if (trimmed.len == 0) return;
    message.transcript.set(a.allocator, trimmed);
    message.transcript_state = .ready;
}

fn readFileWin(allocator: std.mem.Allocator, path_utf8: []const u8, max_bytes: usize) ?[]u8 {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, path_utf8) catch return null;
    defer allocator.free(wide);
    const handle = win.CreateFileW(wide.ptr, win.GENERIC_READ, win.FILE_SHARE_READ, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == win.INVALID_HANDLE_VALUE or handle == null) return null;
    defer _ = win.CloseHandle(handle);
    var size: win.LARGE_INTEGER = undefined;
    if (win.GetFileSizeEx(handle, &size) == 0 or size.QuadPart <= 0 or size.QuadPart > max_bytes) return null;
    const buffer = allocator.alloc(u8, @intCast(size.QuadPart)) catch return null;
    var total: usize = 0;
    while (total < buffer.len) {
        var got: win.DWORD = 0;
        if (win.ReadFile(handle, buffer.ptr + total, @intCast(buffer.len - total), &got, null) == 0) break;
        if (got == 0) break;
        total += got;
    }
    if (total != buffer.len) {
        allocator.free(buffer);
        return null;
    }
    return buffer;
}

fn writeFileWin(path_utf8: []const u8, data: []const u8) void {
    const allocator = app_ptr orelse return;
    _ = allocator;
    const app = app_ptr.?;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(app.allocator, path_utf8) catch return;
    defer app.allocator.free(wide);
    const handle = win.CreateFileW(wide.ptr, win.GENERIC_WRITE, 0, null, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == win.INVALID_HANDLE_VALUE or handle == null) return;
    defer _ = win.CloseHandle(handle);
    var written: win.DWORD = 0;
    _ = win.WriteFile(handle, data.ptr, @intCast(data.len), &written, null);
}

fn saveTranscriptCache(a: *App, message: *const Message) void {
    const path_utf8 = std.unicode.utf16LeToUtf8Alloc(a.allocator, message.local_path.slice()) catch return;
    defer a.allocator.free(path_utf8);
    const cache_path = std.fmt.allocPrint(a.allocator, "{s}.txt", .{path_utf8}) catch return;
    defer a.allocator.free(cache_path);
    const transcript_utf8 = std.unicode.utf16LeToUtf8Alloc(a.allocator, message.transcript.slice()) catch return;
    defer a.allocator.free(transcript_utf8);
    writeFileWin(cache_path, transcript_utf8);
}

fn ensureTranscribeSession(a: *App) ?*dictation.FileSession {
    if (a.transcribe_session) |session| return session;
    a.transcribe_session = dictation.FileSession.create(a.allocator) catch null;
    return a.transcribe_session;
}

fn transcribeWasAttempted(a: *App, id: []const u8) bool {
    const hash = std.hash.Wyhash.hash(0, id);
    for (a.transcribe_attempts[0..a.transcribe_attempt_count]) |attempt| if (attempt == hash) return true;
    if (a.transcribe_attempt_count >= a.transcribe_attempts.len) a.transcribe_attempt_count = 0;
    a.transcribe_attempts[a.transcribe_attempt_count] = hash;
    a.transcribe_attempt_count += 1;
    return false;
}

fn appendDebugLog(a: *App, comptime format: []const u8, args: anytype) void {
    const line = std.fmt.allocPrint(a.allocator, format ++ "\n", args) catch return;
    defer a.allocator.free(line);
    const log_path = std.fs.path.join(a.allocator, &.{ a.avatar_dir, "..", "transcribe.log" }) catch return;
    defer a.allocator.free(log_path);
    const wide = std.unicode.utf8ToUtf16LeAllocZ(a.allocator, log_path) catch return;
    defer a.allocator.free(wide);
    const handle = win.CreateFileW(wide.ptr, win.FILE_APPEND_DATA, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, null, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == win.INVALID_HANDLE_VALUE or handle == null) return;
    defer _ = win.CloseHandle(handle);
    var written: win.DWORD = 0;
    _ = win.WriteFile(handle, line.ptr, @intCast(line.len), &written, null);
}

fn scheduleNextTranscription(a: *App) void {
    if (!a.deepgram_configured) return;
    // Keep the pipeline serial: wait until the previous transcript has been
    // formatted so no result is overwritten.
    if (a.openrouter_session) |format_session| {
        const format_state = format_session.state();
        if (format_state == .recording or format_state == .transcribing) return;
    }
    const session = ensureTranscribeSession(a) orelse return;
    const state = session.state();
    if (state != .idle and state != .ready and state != .failed) return;
    var candidate: ?usize = null;
    var index: usize = a.message_count;
    // Newest first: the voice notes the user just received transcribe first.
    while (index > 0) {
        index -= 1;
        const message = &a.messages[index];
        if (!isAudio(message) or message.local_path.len == 0 or message.transcript_state != .none) continue;
        if (message.id.len == 0 or transcribeWasAttempted(a, message.id.slice())) continue;
        candidate = index;
        break;
    }
    if (candidate == null) return;
    const message = &a.messages[candidate.?];
    const language: dictation.Language = switch (a.dictation_language) {
        .automatic => .automatic,
        .english => .english,
        .german => .german,
    };
    const path_utf8 = std.unicode.utf16LeToUtf8Alloc(a.allocator, message.local_path.slice()) catch return;
    defer a.allocator.free(path_utf8);
    if (session.start(path_utf8, a.deepgram_key, language)) {
        message.transcript_state = .loading;
        a.transcribe_active_id.set(message.id.slice());
        appendDebugLog(a, "schedule: started path_len={d} language={s}", .{ path_utf8.len, @tagName(language) });
    } else {
        appendDebugLog(a, "schedule: start returned false", .{});
    }
}

fn pollTranscription(a: *App) void {
    const session = a.transcribe_session orelse return;
    const state = session.state();
    if (state != .ready and state != .failed) return;
    const done_id = a.transcribe_active_id;
    a.transcribe_active_id.set("");
    if (done_id.len == 0) {
        if (state == .ready) {
            var discard: [8192]u8 = undefined;
            _ = session.takeResult(&discard);
        }
        return;
    }
    for (a.messages[0..a.message_count]) |*message| {
        if (!std.mem.eql(u8, message.id.slice(), done_id.slice())) continue;
        if (state == .ready) {
            var buffer: [8192]u8 = undefined;
            if (session.takeResult(&buffer)) |transcript| {
                if (transcript.len > 0) {
                    message.transcript.set(a.allocator, transcript);
                    message.transcript_state = .ready;
                    saveTranscriptCache(a, message);
                    appendDebugLog(a, "poll: ready len={d}", .{transcript.len});
                } else {
                    message.transcript_state = .failed;
                    appendDebugLog(a, "poll: ready but empty transcript", .{});
                }
            }
        } else {
            message.transcript_state = .failed;
            appendDebugLog(a, "poll: failed for one message", .{});
            setStatus(a, "Transcription failed for a voice message");
        }
        break;
    }
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.FALSE);
}

fn ensureOpenRouterSession(a: *App) ?*dictation.TextSession {
    if (a.openrouter_session) |session| return session;
    a.openrouter_session = dictation.TextSession.create(a.allocator) catch null;
    return a.openrouter_session;
}

fn pollFormatting(a: *App) void {
    const session = a.openrouter_session orelse return;
    const state = session.state();
    if (state != .ready and state != .failed) return;
    const done_id = a.openrouter_active_id;
    a.openrouter_active_id.set("");
    if (done_id.len == 0) {
        if (state == .ready) {
            var discard: [16384]u8 = undefined;
            _ = session.takeResult(&discard);
        }
        return;
    }
    for (a.messages[0..a.message_count]) |*message| {
        if (!std.mem.eql(u8, message.id.slice(), done_id.slice())) continue;
        if (state == .ready) {
            var buffer: [16384]u8 = undefined;
            if (session.takeResult(&buffer)) |formatted| {
                if (formatted.len > 0) {
                    message.transcript.set(a.allocator, formatted);
                    saveTranscriptCache(a, message);
                    appendDebugLog(a, "format: ready len={d}", .{formatted.len});
                }
            }
        } else {
            appendDebugLog(a, "format: failed, keeping raw transcript", .{});
        }
        break;
    }
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.FALSE);
}

fn openrouterWasAttempted(a: *App, id: []const u8) bool {
    const hash = std.hash.Wyhash.hash(0, id);
    for (a.openrouter_attempts[0..a.openrouter_attempt_count]) |attempt| if (attempt == hash) return true;
    if (a.openrouter_attempt_count >= a.openrouter_attempts.len) a.openrouter_attempt_count = 0;
    a.openrouter_attempts[a.openrouter_attempt_count] = hash;
    a.openrouter_attempt_count += 1;
    return false;
}

fn startsWithGist(text: []const u16) bool {
    if (text.len < 4) return false;
    const g = [_]u16{ 'g', 'i', 's', 't' };
    const lower = [4]u16{
        lowerUnit(text[0]),
        lowerUnit(text[1]),
        lowerUnit(text[2]),
        lowerUnit(text[3]),
    };
    return std.mem.eql(u16, &lower, &g);
}

fn scheduleNextFormatting(a: *App) void {
    if (!a.openrouter_configured) return;
    if (a.openrouter_active_id.len > 0) return;
    const session = ensureOpenRouterSession(a) orelse return;
    const state = session.state();
    if (state == .recording or state == .transcribing) return;
    if (state == .ready) {
        var discard: [16384]u8 = undefined;
        _ = session.takeResult(&discard);
    }
    var candidate: ?usize = null;
    var index: usize = a.message_count;
    while (index > 0) {
        index -= 1;
        const message = &a.messages[index];
        if (message.transcript_state != .ready or message.transcript.len == 0) continue;
        if (startsWithGist(message.transcript.slice())) continue;
        if (message.id.len == 0 or openrouterWasAttempted(a, message.id.slice())) continue;
        candidate = index;
        break;
    }
    const message_index = candidate orelse return;
    const message = &a.messages[message_index];
    const transcript_utf8 = std.unicode.utf16LeToUtf8Alloc(a.allocator, message.transcript.slice()) catch return;
    defer a.allocator.free(transcript_utf8);
    if (session.start(transcript_utf8, a.openrouter_key, a.openrouter_model)) {
        a.openrouter_active_id.set(message.id.slice());
        appendDebugLog(a, "format schedule: queued len={d}", .{transcript_utf8.len});
    }
}

fn cycleSpeed(a: *App) void {
    const player = a.audio_player orelse return;
    const next: u32 = switch (player.speed()) {
        100 => 150,
        150 => 200,
        else => 100,
    };
    player.setSpeed(next);
    var buffer: [32]u8 = undefined;
    const label: []const u8 = switch (next) {
        150 => "1.5x",
        200 => "2x",
        else => "1x",
    };
    setStatus(a, std.fmt.bufPrint(&buffer, "Playback speed {s}", .{label}) catch "Playback speed changed");
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.FALSE);
}

fn speedLabel(player: ?*audio.Player) [*:0]const u16 {
    const current: u32 = if (player) |p| p.speed() else 100;
    return switch (current) {
        150 => lit("1.5x"),
        200 => lit("2x"),
        else => lit("1x"),
    };
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
        setStatus(a, if (code == 0) "Attachment downloaded" else "Download failed, the attachment may have expired");
    }
}

fn openMedia(a: *App, message: *const Message) void {
    if (message.local_path.len == 0) return;
    const result = win.ShellExecuteW(a.hwnd.?, lit("open"), message.local_path.ptr(), null, null, win.SW_SHOWNORMAL);
    if (@intFromPtr(result) <= 32) setStatus(a, "Windows could not open the attachment");
}

fn advanceGifs(a: *App) void {
    var changed = false;
    var dirty = win.RECT{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
    for (a.messages[0..a.message_count]) |*message| {
        if (!isGif(message) or message.gif_frame_count <= 1) continue;
        const hit = message.bubble_hit;
        if (hit.right <= hit.left or hit.bottom <= hit.top) continue;
        const previous = message.bitmap;
        message.bitmap = null;
        message.gif_frame_index = (message.gif_frame_index + 1) % message.gif_frame_count;
        ensureBitmap(a, message);
        if (message.bitmap) |replacement| {
            _ = replacement;
            if (previous) |bitmap| _ = win.DeleteObject(bitmap);
            changed = true;
            if (dirty.right > dirty.left and dirty.bottom > dirty.top) {
                dirty.left = @min(dirty.left, hit.left);
                dirty.top = @min(dirty.top, hit.top);
                dirty.right = @max(dirty.right, hit.right);
                dirty.bottom = @max(dirty.bottom, hit.bottom);
            } else dirty = hit;
        } else message.bitmap = previous;
    }
    if (changed) {
        if (a.canvas) |canvas| {
            if (dirty.right > dirty.left and dirty.bottom > dirty.top) {
                _ = win.InvalidateRect(canvas, &dirty, win.FALSE);
            } else _ = win.InvalidateRect(canvas, null, win.FALSE);
        }
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
    const chat_changed = !std.mem.eql(u8, a.displayed_jid.slice(), chat.jid.slice());
    if (chat_changed) stopAudio(a);
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
        const stored = &a.messages[a.message_count - 1];
        if (isAudio(stored) and stored.local_path.len > 0) loadTranscriptCache(a, stored);
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
    // Preserve the reading position; only jump to the newest message when
    // a different chat was opened. Scrolling used to reset to the bottom
    // every time background refreshes redrew the conversation.
    if (chat_changed) a.scroll_y = 0;
    a.displayed_jid.set(chat.jid.slice());
    a.displayed_timestamp.set(chat.timestamp.slice());
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.TRUE);
    markChatRead(a);
}

fn startSync(a: *App) void {
    // Hold off while any write job is pending: they pause live sync and
    // serialize on the store lock, so don't fight them. checkSync restarts
    // sync once the last job finishes.
    if (a.sync_child != null or a.read_child != null or a.pending_read_count > 0 or
        a.media_child != null or a.send_child != null or a.pending_send_count > 0 or
        a.archive_child != null or a.pending_archive_count > 0 or avatarBusy(a)) return;
    const child = std.process.spawn(a.io, .{
        .argv = &.{ a.wacli_path, "--events", "sync", "--follow", "--max-reconnect", "0", "--stale-threshold", "1m", "--refresh-contacts", "--refresh-groups", "--download-media" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch {
        setStatus(a, "Could not start live sync");
        return;
    };
    if (a.sync_job == null) {
        a.sync_job = win.CreateJobObjectW(null, null);
        if (a.sync_job) |job| {
            var info = std.mem.zeroes(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION);
            info.BasicLimitInformation.LimitFlags = win.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            _ = win.SetInformationJobObject(job, win.JobObjectExtendedLimitInformation, &info, @sizeOf(win.JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
        }
    }
    if (a.sync_job) |job| {
        if (child.id) |handle| _ = win.AssignProcessToJobObject(job, handle);
    }
    a.sync_child = child;
    setStatus(a, "Live sync running");
}

fn stopSync(a: *App) void {
    if (a.sync_child) |*child| child.kill(a.io);
    a.sync_child = null;
}

fn checkSync(a: *App) void {
    if (a.media_child != null or a.read_child != null or a.send_child != null or a.pending_send_count > 0 or a.archive_child != null or a.pending_archive_count > 0 or avatarBusy(a)) return;
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

fn removeFirstPendingSend(a: *App) void {
    if (a.pending_send_count == 0) return;
    var index: usize = 1;
    while (index < a.pending_send_count) : (index += 1) {
        a.pending_sends[index - 1] = a.pending_sends[index];
    }
    a.pending_send_count -= 1;
}

fn startNextSend(a: *App) void {
    if (a.send_child != null or a.read_child != null or a.pending_send_count == 0) return;
    stopSync(a);
    const pending = &a.pending_sends[0];
    const child = std.process.spawn(a.io, .{
        .argv = &.{ a.wacli_path, "--json", "--lock-wait", "10s", "send", "text", "--to", pending.jid.slice(), "--message", pending.text.slice() },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch {
        removeFirstPendingSend(a);
        setStatus(a, "Could not start queued send");
        if (a.pending_send_count > 0) startNextSend(a) else startSync(a);
        return;
    };
    a.send_child = child;
    var status_buffer: [80]u8 = undefined;
    const status = std.fmt.bufPrint(&status_buffer, "Sending queued message, {d} remaining", .{a.pending_send_count}) catch "Sending queued message...";
    setStatus(a, status);
}

fn checkSend(a: *App) void {
    if (a.send_child) |*child| {
        const handle = child.id orelse return;
        var code: win.DWORD = 0;
        if (win.GetExitCodeProcess(handle, &code) == 0 or code == win.STILL_ACTIVE) return;
        _ = child.wait(a.io) catch {};
        a.send_child = null;
        removeFirstPendingSend(a);
        if (a.pending_send_count > 0) {
            startNextSend(a);
        } else {
            startSync(a);
            refreshChats(a);
            refreshMessages(a);
            setStatus(a, if (code == 0) "Sent" else "A queued message failed to send");
        }
    }
}

fn sendMessage(a: *App) void {
    if (a.compose == null or a.chat_count == 0 or a.selected_chat >= a.chat_count) return;
    if (a.pending_send_count >= max_pending_sends) {
        setStatus(a, "Send queue is full");
        return;
    }
    var wide_buffer: [4096]u16 = [_]u16{0} ** 4096;
    const length: usize = @intCast(win.GetWindowTextW(a.compose.?, &wide_buffer, wide_buffer.len));
    if (length == 0) return;
    const text = std.unicode.utf16LeToUtf8Alloc(a.allocator, wide_buffer[0..length]) catch return;
    defer a.allocator.free(text);

    const pending = &a.pending_sends[a.pending_send_count];
    pending.jid.set(a.chats[a.selected_chat].jid.slice());
    pending.text.set(text);
    a.pending_send_count += 1;
    a.user_viewed = true;
    _ = win.SetWindowTextW(a.compose.?, lit(""));
    focusCompose(a);
    startNextSend(a);
}

fn focusCompose(a: *App) void {
    if (a.compose) |compose| {
        _ = win.SetFocus(compose);
        const length: usize = @intCast(win.GetWindowTextLengthW(compose));
        const caret: isize = @intCast(length);
        _ = win.SendMessageW(compose, win.EM_SETSEL, @bitCast(caret), @bitCast(caret));
    }
}

fn ensureDictation(a: *App) ?*dictation.Session {
    if (a.dictation_session) |session| return session;
    a.dictation_session = dictation.Session.create(a.allocator) catch null;
    return a.dictation_session;
}

fn insertTranscript(a: *App, transcript: []const u8) void {
    const compose = a.compose orelse return;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(a.allocator, transcript) catch return;
    defer a.allocator.free(wide);
    const length: usize = @intCast(win.GetWindowTextLengthW(compose));
    const caret: isize = @intCast(length);
    _ = win.SendMessageW(compose, win.EM_SETSEL, @bitCast(caret), @bitCast(caret));
    if (length > 0) _ = win.SendMessageW(compose, win.EM_REPLACESEL, 1, @bitCast(@intFromPtr(lit(" "))));
    _ = win.SendMessageW(compose, win.EM_REPLACESEL, 1, @bitCast(@intFromPtr(wide.ptr)));
    focusCompose(a);
}

fn toggleDictation(a: *App) void {
    if (!a.deepgram_configured) {
        setStatus(a, "Set DEEPGRAM_API_KEY to enable dictation");
        return;
    }
    const session = ensureDictation(a) orelse {
        setStatus(a, "Could not initialize dictation");
        return;
    };
    switch (session.state()) {
        .idle, .failed => {
            if (session.start(a.deepgram_key, a.dictation_language)) {
                _ = win.SetWindowTextW(a.dictate.?, lit("Stop"));
                setStatus(a, "Listening... press Ctrl+D to stop");
            } else setStatus(a, "Could not start microphone capture");
        },
        .recording => {
            session.requestStop();
            _ = win.SetWindowTextW(a.dictate.?, lit("Wait..."));
            setStatus(a, "Transcribing...");
        },
        .transcribing => setStatus(a, "Transcription is still running"),
        .ready => {},
    }
}

fn updateDictation(a: *App) void {
    const session = a.dictation_session orelse return;
    const state = session.state();
    if (state == .ready) {
        var transcript_buffer: [8192]u8 = undefined;
        if (session.takeTranscript(&transcript_buffer)) |transcript| {
            insertTranscript(a, transcript);
            setStatus(a, "Dictation inserted");
        }
        _ = win.SetWindowTextW(a.dictate.?, lit("Dictate"));
        a.last_dictation_state = .idle;
        return;
    }
    if (state == a.last_dictation_state) return;
    a.last_dictation_state = state;
    switch (state) {
        .idle => _ = win.SetWindowTextW(a.dictate.?, lit("Dictate")),
        .recording => _ = win.SetWindowTextW(a.dictate.?, lit("Stop")),
        .transcribing => {
            _ = win.SetWindowTextW(a.dictate.?, lit("Wait..."));
            setStatus(a, "Transcribing...");
        },
        .failed => {
            _ = win.SetWindowTextW(a.dictate.?, lit("Dictate"));
            setStatus(a, "Dictation failed; check the microphone and DEEPGRAM_API_KEY");
        },
        .ready => unreachable,
    }
}

fn selectChat(a: *App, delta: i32, wrap: bool) void {
    if (a.chat_count == 0) return;
    var next: i32 = @intCast(a.selected_chat);
    next += delta;
    const count: i32 = @intCast(a.chat_count);
    if (wrap) {
        if (next < 0) next = count - 1;
        if (next >= count) next = 0;
    } else {
        next = std.math.clamp(next, 0, count - 1);
    }
    a.selected_chat = @intCast(next);
    a.user_viewed = true;
    if (a.chats_hwnd) |list| {
        // Let the native list box scroll only when the selection leaves the
        // visible viewport. Forcing the top index here made every Ctrl+Tab
        // appear to move the entire list.
        _ = win.SendMessageW(list, win.LB_SETCURSEL, a.selected_chat, 0);
    }
    a.chat_selection_pending = true;
    if (a.hwnd) |hwnd| {
        _ = win.KillTimer(hwnd, timer_chat_select);
        _ = win.SetTimer(hwnd, timer_chat_select, 120, null);
    }
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
    for (a.messages[0..a.message_count]) |*message| total_height += measureMessage(hdc, a, message, bubble_width) + 8;
    a.max_scroll = @max(0, total_height - (client.bottom - client.top));
    var y = client.bottom - 14 + a.scroll_y;
    var index = a.message_count;
    while (index > 0) {
        index -= 1;
        const height = measureMessage(hdc, a, &a.messages[index], bubble_width);
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
        const next = @as(i32, @intCast(selected)) + delta;
        // Hard stop at the oldest and newest message instead of cycling.
        if (next < 0 or next >= a.message_count) return;
        a.selected_message = @intCast(next);
    } else {
        a.selected_message = a.message_count - 1;
    }
    scrollToSelectedMessage(a);
    if (a.canvas) |canvas| {
        // Deliberately keep keyboard focus wherever it was so the composer
        // caret keeps blinking and typing can resume immediately.
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

fn copyToClipboard(a: *App, text: []const u16) bool {
    if (a.hwnd == null or text.len == 0) return false;
    if (win.OpenClipboard(a.hwnd.?) == 0) return false;
    defer _ = win.CloseClipboard();
    _ = win.EmptyClipboard();
    const bytes = (text.len + 1) * 2;
    const handle = win.GlobalAlloc(win.GMEM_MOVEABLE, bytes) orelse return false;
    const dest = win.GlobalLock(handle);
    if (dest == null) {
        _ = win.GlobalFree(handle);
        return false;
    }
    const destination: [*]u16 = @ptrCast(@alignCast(dest.?));
    @memcpy(destination[0..text.len], text);
    destination[text.len] = 0;
    _ = win.GlobalUnlock(handle);
    if (win.SetClipboardData(win.CF_UNICODETEXT, handle) == null) {
        _ = win.GlobalFree(handle);
        return false;
    }
    return true;
}

fn copySelectedText(a: *App) void {
    const selected = a.selected_message orelse {
        setStatus(a, "Select a message first (Alt+J/K or click)");
        return;
    };
    if (selected >= a.message_count) return;
    const message = &a.messages[selected];
    if (a.sel_message != null and a.sel_message.? == selected and a.sel_anchor_word != a.sel_focus_word) {
        const lo = @min(a.sel_anchor_word, a.sel_focus_word);
        const hi = @max(a.sel_anchor_word, a.sel_focus_word);
        if (hi < message.word_count) {
            const first = message.word_rects[lo];
            const last = message.word_rects[hi];
            const slice = message.text.slice()[first.start..][0 .. last.start + last.len - first.start];
            setStatus(a, if (copyToClipboard(a, slice)) "Selection copied" else "Could not copy");
            return;
        }
    }
    if (message.text.len == 0) {
        setStatus(a, "This message has no text");
        return;
    }
    setStatus(a, if (copyToClipboard(a, message.text.slice())) "Text copied" else "Could not copy text");
}

fn copySelectedLink(a: *App) void {
    const selected = a.selected_message orelse {
        setStatus(a, "Select a message first (Alt+J/K or click)");
        return;
    };
    if (selected >= a.message_count) return;
    const message = &a.messages[selected];
    if (message.link_count == 0) {
        setStatus(a, "No link in the selected message");
        return;
    }
    setStatus(a, if (copyToClipboard(a, message.links[0].url.slice())) "Link copied" else "Could not copy the link");
}

fn hitTestWord(message: *const Message, x: i32, y: i32) ?usize {
    var best: ?usize = null;
    var best_distance: i32 = 30;
    for (message.word_rects[0..message.word_count], 0..) |*span, index| {
        const dx = if (x < span.rect.left) span.rect.left - x else if (x > span.rect.right) x - span.rect.right else 0;
        const dy = if (y < span.rect.top) span.rect.top - y else if (y > span.rect.bottom) y - span.rect.bottom else 0;
        const distance = @max(dx, dy);
        if (distance < best_distance) {
            best_distance = distance;
            best = index;
        }
    }
    return best;
}

fn handleCanvasClick(a: *App, hwnd: win.HWND, x: i32, y: i32) void {
    for (a.messages[0..a.message_count], 0..) |*item, index| {
        const media = item.media_hit;
        const bubble = item.bubble_hit;
        if (x >= media.left and x <= media.right and y >= media.top and y <= media.bottom) {
            a.selected_message = index;
            if (item.local_path.len == 0) {
                downloadMedia(a, index, false);
            } else if (isAudio(item)) {
                handleAudioClick(a, item, x);
            } else if (!isGif(item)) {
                // GIFs already animate in place; popping them out to
                // an external player was unwanted.
                openMedia(a, item);
            }
            return;
        }
        if (item.transcript.len > 0) {
            const toggle = item.toggle_hit;
            if (x >= toggle.left and x <= toggle.right and y >= toggle.top and y <= toggle.bottom) {
                item.transcript_expanded = !item.transcript_expanded;
                a.selected_message = index;
                _ = win.InvalidateRect(hwnd, null, win.TRUE);
                return;
            }
        }
        if (x >= bubble.left and x <= bubble.right and y >= bubble.top and y <= bubble.bottom) {
            for (item.links[0..item.link_count]) |*span| {
                if (x >= span.rect.left and x <= span.rect.right and y >= span.rect.top and y <= span.rect.bottom) {
                    openUrlWide(a, span.url.ptr());
                    a.selected_message = index;
                    _ = win.InvalidateRect(hwnd, null, win.TRUE);
                    return;
                }
            }
            a.selected_message = index;
            _ = win.InvalidateRect(hwnd, null, win.TRUE);
            return;
        }
    }
}

fn reactToSelected(a: *App, command: u16) void {
    if (command == command_copy_selection) {
        const selected = a.selected_message orelse return;
        if (selected >= a.message_count or a.sel_message == null or a.sel_anchor_word == a.sel_focus_word) return;
        const message = &a.messages[selected];
        const lo = @min(a.sel_anchor_word, a.sel_focus_word);
        const hi = @max(a.sel_anchor_word, a.sel_focus_word);
        if (hi >= message.word_count) return;
        const first = message.word_rects[lo];
        const last = message.word_rects[hi];
        const slice = message.text.slice()[first.start..][0 .. last.start + last.len - first.start];
        setStatus(a, if (copyToClipboard(a, slice)) "Selection copied" else "Could not copy");
        return;
    }
    if (command == command_copy_transcript) {
        const selected = a.selected_message orelse return;
        if (selected >= a.message_count) return;
        const message = &a.messages[selected];
        if (message.transcript.len == 0) return;
        setStatus(a, if (copyToClipboard(a, message.transcript.slice())) "Transcript copied" else "Could not copy");
        return;
    }
    if (command == command_copy_text) {
        copySelectedText(a);
        return;
    }
    if (command == command_copy_link) {
        copySelectedLink(a);
        return;
    }
    const emoji = reactionForCommand(command) orelse return;
    const selected = a.selected_message orelse {
        setStatus(a, "Right-click a message to select it");
        return;
    };
    if (selected >= a.message_count or a.selected_chat >= a.chat_count) return;
    const message = &a.messages[selected];
    const chat = &a.chats[a.selected_chat];
    var args: [16][]const u8 = undefined;
    var count: usize = 0;
    for ([_][]const u8{ a.wacli_path, "--json", "--lock-wait", "10s", "send", "react", "--to", chat.jid.slice(), "--id", message.id.slice(), "--reaction", emoji }) |argument| {
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
    var parsed = runWacliExclusive(a, args[0..count]) catch {
        setStatus(a, "Reaction failed");
        return;
    };
    parsed.deinit();
    message.reaction.set(a.allocator, emoji);
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.TRUE);
    setStatus(a, if (emoji.len == 0) "Reaction removed" else "Reaction sent");
}

fn insertEmoji(a: *App, emoji: []const u8) void {
    const compose = a.compose orelse return;
    var wide = WideText(31){};
    wide.set(a.allocator, emoji);
    if (wide.len == 0) return;
    const length = win.GetWindowTextLengthW(compose);
    _ = win.SendMessageW(compose, win.EM_SETSEL, @bitCast(@as(isize, length)), @bitCast(@as(isize, length)));
    _ = win.SendMessageW(compose, win.EM_REPLACESEL, win.TRUE, @bitCast(@intFromPtr(wide.ptr())));
    _ = win.SendMessageW(compose, win.EM_SCROLLCARET, 0, 0);
    _ = win.SetFocus(compose);
}

fn openEmojiMenu(a: *App) void {
    const hwnd = a.hwnd orelse return;
    const menu = win.CreatePopupMenu() orelse return;
    defer _ = win.DestroyMenu(menu);
    for (picker_emojis, 0..) |emoji, index| {
        var wide = WideText(31){};
        wide.set(a.allocator, emoji);
        if (wide.len == 0) continue;
        _ = win.AppendMenuW(menu, win.MF_STRING, picker_base + @as(u32, @intCast(index)), wide.ptr());
    }
    var rect: win.RECT = undefined;
    _ = win.GetWindowRect(hwnd, &rect);
    const choice = win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_NONOTIFY, rect.right - 232, rect.bottom - 110, 0, hwnd, null);
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
    _ = win.AppendMenuW(menu, win.MF_SEPARATOR, 0, null);
    _ = win.AppendMenuW(menu, win.MF_STRING, command_copy_text, lit("Copy text"));
    _ = win.AppendMenuW(menu, win.MF_STRING, command_copy_link, lit("Copy link address"));
}

fn openUrlWide(a: *App, url: [*:0]const u16) void {
    const result = win.ShellExecuteW(a.hwnd.?, lit("open"), url, null, null, win.SW_SHOWNORMAL);
    if (@intFromPtr(result) <= 32) setStatus(a, "Windows could not open the link");
}

fn openReactionMenu(a: *App, x: i32, y: i32) void {
    const menu = win.CreatePopupMenu() orelse return;
    defer _ = win.DestroyMenu(menu);
    addReactionItems(menu);
    const choice = win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_NONOTIFY, x, y, 0, a.hwnd.?, null);
    reactToSelected(a, @intCast(choice));
}

fn openReactionMenuForSelected(a: *App) void {
    const canvas = a.canvas orelse return;
    if (a.message_count == 0) return;
    if (a.selected_message == null) a.selected_message = a.message_count - 1;
    scrollToSelectedMessage(a);
    _ = win.InvalidateRect(canvas, null, win.FALSE);
    _ = win.UpdateWindow(canvas);
    const message = &a.messages[a.selected_message.?];
    const bubble = message.bubble_hit;
    if (bubble.right <= bubble.left) return;
    var point = win.POINT{ .x = @divTrunc(bubble.left + bubble.right, 2), .y = bubble.bottom };
    _ = win.ClientToScreen(canvas, &point);
    openReactionMenu(a, point.x, point.y);
}

fn removeFirstPendingArchive(a: *App) void {
    if (a.pending_archive_count == 0) return;
    var index: usize = 1;
    while (index < a.pending_archive_count) : (index += 1) a.pending_archives[index - 1] = a.pending_archives[index];
    a.pending_archive_count -= 1;
}

fn startNextArchive(a: *App) void {
    if (a.archive_child != null or a.read_child != null or a.pending_archive_count == 0) return;
    if (a.media_child != null or a.send_child != null or a.pending_send_count > 0 or avatarBusy(a)) return;
    stopSync(a);
    const pending = &a.pending_archives[0];
    const child = std.process.spawn(a.io, .{
        .argv = &.{ a.wacli_path, "--json", "--lock-wait", "10s", "chats", if (pending.should_unarchive) "unarchive" else "archive", "--chat", pending.jid.slice() },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .create_no_window = true,
    }) catch {
        removeFirstPendingArchive(a);
        setStatus(a, "Could not start archive operation");
        startSync(a);
        return;
    };
    a.archive_child = child;
}

fn checkArchive(a: *App) void {
    if (a.archive_child) |*child| {
        const handle = child.id orelse return;
        var code: win.DWORD = 0;
        if (win.GetExitCodeProcess(handle, &code) == 0 or code == win.STILL_ACTIVE) return;
        _ = child.wait(a.io) catch {};
        a.archive_child = null;
        removeFirstPendingArchive(a);
        if (a.pending_archive_count > 0) {
            startNextArchive(a);
        } else {
            startSync(a);
            refreshChats(a);
            refreshMessages(a);
            setStatus(a, if (code == 0) "Chat archived" else "Archive operation failed");
        }
    } else startNextArchive(a);
}

fn removeSelectedChatOptimistically(a: *App) void {
    if (a.selected_chat >= a.chat_count) return;
    const removed = a.selected_chat;
    var index = removed + 1;
    while (index < a.chat_count) : (index += 1) a.chats[index - 1] = a.chats[index];
    a.chat_count -= 1;
    if (a.chat_count > 0 and a.selected_chat >= a.chat_count) a.selected_chat = a.chat_count - 1;
    if (a.chats_hwnd) |list| {
        _ = win.SendMessageW(list, win.LB_DELETESTRING, removed, 0);
        if (a.chat_count > 0) _ = win.SendMessageW(list, win.LB_SETCURSEL, a.selected_chat, 0);
    }
}

fn archiveSelectedChat(a: *App) void {
    if (a.chat_count == 0 or a.selected_chat >= a.chat_count) return;
    if (a.pending_archive_count >= a.pending_archives.len) {
        setStatus(a, "Archive queue is full");
        return;
    }
    const chat = &a.chats[a.selected_chat];
    const pending = &a.pending_archives[a.pending_archive_count];
    pending.jid.set(chat.jid.slice());
    pending.should_unarchive = a.show_archived or chat.archived;
    a.pending_archive_count += 1;
    removeSelectedChatOptimistically(a);
    setStatus(a, if (pending.should_unarchive) "Unarchive queued" else "Archive queued");
    startNextArchive(a);
}

fn appendPalette(a: *App, label: []const u8, shortcut: []const u8, command: u16) void {
    if (a.palette_item_count >= max_palette_items) return;
    const item = &a.palette_items[a.palette_item_count];
    a.palette_item_count += 1;
    item.label.set(a.allocator, label);
    item.shortcut.set(a.allocator, shortcut);
    item.command = command;
}

fn buildPaletteItems(a: *App) void {
    a.palette_item_count = 0;
    appendPalette(a, "Search chats", "Ctrl+F", command_search);
    appendPalette(a, "Compose message", "C", command_compose);
    appendPalette(a, "Dictate", "Ctrl+D", command_dictate);
    appendPalette(a, "Dictation language: Automatic", "", command_dictation_auto);
    appendPalette(a, "Dictation language: English", "", command_dictation_english);
    appendPalette(a, "Dictation language: German", "", command_dictation_german);
    appendPalette(a, "Playback speed: 1x", "", command_speed_1);
    appendPalette(a, "Playback speed: 1.5x", "", command_speed_150);
    appendPalette(a, "Playback speed: 2x", "", command_speed_200);
    appendPalette(a, "Make text smaller", "Ctrl+-", command_font_smaller);
    appendPalette(a, "Make text larger", "Ctrl++", command_font_larger);
    appendPalette(a, "Reset text size", "Ctrl+0", command_font_reset);
    appendPalette(a, "Toggle unread chats", "U", command_unread);
    appendPalette(a, if (a.show_archived) "Show inbox chats" else "Show archived chats", "", command_archived);
    appendPalette(a, if (a.show_archived) "Unarchive selected chat" else "Archive selected chat", "Ctrl+E", command_archive);
    appendPalette(a, "React to message: 👍 Like", "", reaction_like);
    appendPalette(a, "React to message: ❤️ Love", "", reaction_love);
    appendPalette(a, "React to message: 😂 Laugh", "", reaction_laugh);
    appendPalette(a, "React to message: 😮 Surprised", "", reaction_surprised);
    appendPalette(a, "React to message: 😢 Sad", "", reaction_sad);
    appendPalette(a, "React to message: 🙏 Thanks", "", reaction_thanks);
    appendPalette(a, "Remove reaction", "", reaction_remove);
    appendPalette(a, "Refresh", "R", command_refresh);
    appendPalette(a, "Restart live sync", "S", command_sync);
    appendPalette(a, "Quit Messages", "Q", command_quit);
}

fn lowerUnit(unit: u16) u16 {
    return if (unit >= 'A' and unit <= 'Z') unit + 32 else unit;
}

fn paletteScore(label: []const u16, query: []const u16) ?i32 {
    var score: i32 = 0;
    var text_index: usize = 0;
    var previous: ?usize = null;
    for (query) |query_unit| {
        const wanted = lowerUnit(query_unit);
        var matched = false;
        while (text_index < label.len) : (text_index += 1) {
            if (lowerUnit(label[text_index]) != wanted) continue;
            score += 1;
            if (previous) |previous_index| {
                if (text_index == previous_index + 1) score += 4 else score -= @intCast(@min(text_index - previous_index, 8));
            }
            if (text_index == 0 or label[text_index - 1] == ' ' or label[text_index - 1] == ':') score += 3;
            previous = text_index;
            text_index += 1;
            matched = true;
            break;
        }
        if (!matched) return null;
    }
    return score;
}

fn paletteLayout(a: *App) void {
    const palette = a.palette orelse return;
    const rows: i32 = @intCast(@max(1, @min(a.palette_match_count, palette_max_rows)));
    const height = palette_edit_zone + rows * palette_row_height + 12;
    _ = win.SetWindowPos(palette, null, 0, 0, palette_width, height, win.SWP_NOMOVE | win.SWP_NOZORDER | win.SWP_NOACTIVATE);
    if (a.palette_list) |list| {
        _ = win.MoveWindow(list, 1, palette_edit_zone, palette_width - 2, height - palette_edit_zone - 1, win.TRUE);
    }
}

fn paletteFilter(a: *App) void {
    var query_buf: [64]u16 = [_]u16{0} ** 64;
    const query_len: usize = if (a.palette_edit) |edit| @intCast(win.GetWindowTextW(edit, &query_buf, query_buf.len)) else 0;
    a.palette_match_count = 0;
    a.palette_selected = 0;
    var scores: [max_palette_items]i32 = [_]i32{0} ** max_palette_items;
    for (0..a.palette_item_count) |index| {
        if (query_len == 0) {
            scores[a.palette_match_count] = 0;
            a.palette_matches[a.palette_match_count] = index;
            a.palette_match_count += 1;
            continue;
        }
        if (paletteScore(a.palette_items[index].label.slice(), query_buf[0..query_len])) |score| {
            scores[a.palette_match_count] = score;
            a.palette_matches[a.palette_match_count] = index;
            a.palette_match_count += 1;
        }
    }
    var i: usize = 1;
    while (i < a.palette_match_count) : (i += 1) {
        var j = i;
        while (j > 0 and scores[j - 1] < scores[j]) : (j -= 1) {
            std.mem.swap(usize, &a.palette_matches[j - 1], &a.palette_matches[j]);
            std.mem.swap(i32, &scores[j - 1], &scores[j]);
        }
    }
    if (a.palette_list) |list| {
        _ = win.SendMessageW(list, win.WM_SETREDRAW, 0, 0);
        _ = win.SendMessageW(list, win.LB_RESETCONTENT, 0, 0);
        for (0..a.palette_match_count) |_| {
            _ = win.SendMessageW(list, win.LB_ADDSTRING, 0, 1);
        }
        if (a.palette_match_count > 0) _ = win.SendMessageW(list, win.LB_SETCURSEL, 0, 0);
        _ = win.SendMessageW(list, win.WM_SETREDRAW, 1, 0);
        _ = win.InvalidateRect(list, null, win.TRUE);
    }
    paletteLayout(a);
    if (a.palette) |palette| _ = win.InvalidateRect(palette, null, win.TRUE);
}

fn paletteMove(a: *App, delta: i32) void {
    if (a.palette_match_count == 0) return;
    var next: i32 = @intCast(a.palette_selected);
    next = std.math.clamp(next + delta, 0, @as(i32, @intCast(a.palette_match_count - 1)));
    a.palette_selected = @intCast(next);
    if (a.palette_list) |list| {
        _ = win.SendMessageW(list, win.LB_SETCURSEL, a.palette_selected, 0);
        _ = win.InvalidateRect(list, null, win.FALSE);
    }
}

fn closePalette(a: *App) void {
    if (a.palette) |palette| {
        _ = win.DestroyWindow(palette);
    }
    if (a.chats_hwnd) |list| _ = win.SetFocus(list);
}

fn paletteActivate(a: *App) void {
    if (a.palette_selected >= a.palette_match_count) return;
    const item = &a.palette_items[a.palette_matches[a.palette_selected]];
    if (item.url.len > 0) {
        const url_ptr = item.url.ptr();
        closePalette(a);
        openUrlWide(a, url_ptr);
        return;
    }
    const command = item.command;
    closePalette(a);
    runCommand(a, command);
}

fn openPalette(a: *App) void {
    if (a.palette != null) {
        closePalette(a);
        return;
    }
    a.palette_links_mode = false;
    buildPaletteItems(a);
    showPaletteWindow(a);
}

fn openLinkPalette(a: *App) void {
    if (a.palette != null) {
        closePalette(a);
        return;
    }
    a.palette_links_mode = true;
    buildLinkPaletteItems(a);
    if (a.palette_item_count == 0) {
        a.palette_links_mode = false;
        setStatus(a, "No links visible on screen");
        return;
    }
    showPaletteWindow(a);
}

fn buildLinkPaletteItems(a: *App) void {
    a.palette_item_count = 0;
    for (a.messages[0..a.message_count]) |*message| {
        if (message.bubble_hit.right <= message.bubble_hit.left) continue;
        for (message.links[0..message.link_count]) |*span| {
            if (span.url.len == 0) continue;
            var duplicate = false;
            for (a.palette_items[0..a.palette_item_count]) |*existing| {
                if (std.mem.eql(u16, existing.url.slice(), span.url.slice())) duplicate = true;
            }
            if (duplicate) continue;
            if (a.palette_item_count >= max_palette_items) return;
            const item = &a.palette_items[a.palette_item_count];
            const url_utf8 = std.unicode.utf16LeToUtf8Alloc(a.allocator, span.url.slice()) catch continue;
            defer a.allocator.free(url_utf8);
            item.label.set(a.allocator, url_utf8);
            item.url.set(a.allocator, url_utf8);
            item.shortcut.set(a.allocator, "");
            item.command = 0;
            a.palette_item_count += 1;
        }
    }
}

fn showPaletteWindow(a: *App) void {
    const owner = a.hwnd orelse return;
    var owner_rect: win.RECT = undefined;
    _ = win.GetWindowRect(owner, &owner_rect);
    const x = @max(owner_rect.left + 8, owner_rect.left + @divTrunc((owner_rect.right - owner_rect.left) - palette_width, 2));
    const y = owner_rect.top + 110;
    const palette = win.CreateWindowExW(
        win.WS_EX_TOOLWINDOW,
        lit("MessagesPalette"),
        null,
        win.WS_POPUP,
        x,
        y,
        palette_width,
        palette_edit_zone + palette_max_rows * palette_row_height + 12,
        owner,
        null,
        a.instance,
        null,
    ) orelse return;
    a.palette = palette;
    a.palette_ever_active = false;
    var corner: win.DWORD = 2; // DWMWCP_ROUND
    _ = win.DwmSetWindowAttribute(palette, 33, &corner, @sizeOf(win.DWORD));
    var margins = win.MARGINS{ .cxLeftWidth = 0, .cxRightWidth = 0, .cyTopHeight = 0, .cyBottomHeight = 1 };
    _ = win.DwmExtendFrameIntoClientArea(palette, &margins);
    a.palette_edit = win.CreateWindowExW(0, lit("EDIT"), null, win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.ES_AUTOHSCROLL, 16, 13, palette_width - 32, 36, palette, controlId(id_palette_edit), a.instance, null);
    a.palette_list = win.CreateWindowExW(0, lit("LISTBOX"), null, win.WS_CHILD | win.WS_VISIBLE | win.WS_VSCROLL | win.LBS_NOTIFY | win.LBS_OWNERDRAWFIXED | win.LBS_NOINTEGRALHEIGHT, 1, palette_edit_zone, palette_width - 2, palette_max_rows * palette_row_height + 12, palette, controlId(id_palette_list), a.instance, null);
    setFont(a.palette_edit, a.font);
    setFont(a.palette_list, a.font);
    if (a.palette_edit) |edit| {
        _ = win.SendMessageW(edit, win.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(lit("Type a command"))));
    }
    if (a.palette_list) |list| _ = win.SendMessageW(list, win.LB_SETITEMHEIGHT, 0, palette_row_height);
    paletteFilter(a);
    _ = win.ShowWindow(palette, win.SW_SHOW);
    if (a.palette_edit) |edit| _ = win.SetFocus(edit);
}

fn drawPaletteItem(a: *App, item: *win.DRAWITEMSTRUCT) void {
    if (item.itemID == @as(win.UINT, @bitCast(@as(c_int, -1)))) return;
    const index: usize = @intCast(item.itemID);
    if (index >= a.palette_match_count) return;
    const palette_item = &a.palette_items[a.palette_matches[index]];
    const selected = (item.itemState & win.ODS_SELECTED) != 0;
    const background = win.CreateSolidBrush(if (selected) color_selected else color_panel) orelse return;
    defer _ = win.DeleteObject(background);
    _ = win.FillRect(item.hDC, &item.rcItem, background);
    _ = win.SetBkMode(item.hDC, win.TRANSPARENT);
    if (selected) {
        const accent_brush = win.CreateSolidBrush(color_accent) orelse return;
        defer _ = win.DeleteObject(accent_brush);
        var bar = win.RECT{ .left = item.rcItem.left, .top = item.rcItem.top, .right = item.rcItem.left + 3, .bottom = item.rcItem.bottom };
        _ = win.FillRect(item.hDC, &bar, accent_brush);
    }
    _ = win.SelectObject(item.hDC, @ptrCast(a.font.?));
    _ = win.SetTextColor(item.hDC, color_text);
    var label_rect = win.RECT{ .left = item.rcItem.left + 20, .top = item.rcItem.top, .right = item.rcItem.right - 130, .bottom = item.rcItem.bottom };
    _ = win.DrawTextW(item.hDC, palette_item.label.ptr(), @intCast(palette_item.label.len), &label_rect, win.DT_LEFT | win.DT_SINGLELINE | win.DT_END_ELLIPSIS | win.DT_VCENTER);
    if (palette_item.shortcut.len > 0) {
        _ = win.SelectObject(item.hDC, @ptrCast(a.font_small.?));
        _ = win.SetTextColor(item.hDC, color_muted);
        var shortcut_rect = win.RECT{ .left = item.rcItem.right - 120, .top = item.rcItem.top, .right = item.rcItem.right - 16, .bottom = item.rcItem.bottom };
        _ = win.DrawTextW(item.hDC, palette_item.shortcut.ptr(), @intCast(palette_item.shortcut.len), &shortcut_rect, win.DT_RIGHT | win.DT_SINGLELINE | win.DT_VCENTER);
    }
}

fn paletteProc(hwnd: win.HWND, message: win.UINT, wparam: win.WPARAM, lparam: win.LPARAM) callconv(.winapi) win.LRESULT {
    const a = app_ptr orelse return win.DefWindowProcW(hwnd, message, wparam, lparam);
    switch (message) {
        win.WM_COMMAND => {
            const id = loword(wparam);
            const notification = hiword(wparam);
            if (id == id_palette_edit and notification == win.EN_CHANGE) {
                paletteFilter(a);
            } else if (id == id_palette_list and notification == win.LBN_SELCHANGE) {
                const selected = win.SendMessageW(a.palette_list.?, win.LB_GETCURSEL, 0, 0);
                if (selected >= 0) {
                    a.palette_selected = @intCast(selected);
                    if (a.palette_list) |list| _ = win.InvalidateRect(list, null, win.FALSE);
                }
            } else if (id == id_palette_list and notification == win.LBN_DBLCLK) {
                paletteActivate(a);
            }
            return 0;
        },
        win.WM_DRAWITEM => {
            const item: *win.DRAWITEMSTRUCT = winHandle(*win.DRAWITEMSTRUCT, @as(usize, @bitCast(lparam)));
            if (item.CtlID == id_palette_list) drawPaletteItem(a, item);
            return 1;
        },
        win.WM_CTLCOLORSTATIC, win.WM_CTLCOLOREDIT, win.WM_CTLCOLORLISTBOX => {
            const hdc: win.HDC = winHandle(win.HDC, wparam);
            _ = win.SetTextColor(hdc, color_text);
            _ = win.SetBkColor(hdc, color_panel);
            if (a.brush_panel) |brush| return @bitCast(@intFromPtr(brush));
            return @bitCast(@intFromPtr(win.GetStockObject(win.BLACK_BRUSH)));
        },
        win.WM_PAINT => {
            var paint: win.PAINTSTRUCT = undefined;
            const hdc = win.BeginPaint(hwnd, &paint);
            defer _ = win.EndPaint(hwnd, &paint);
            var client: win.RECT = undefined;
            _ = win.GetClientRect(hwnd, &client);
            _ = win.FillRect(hdc, &client, a.brush_panel.?);
            var separator = win.RECT{ .left = 0, .top = palette_edit_zone - 2, .right = client.right, .bottom = palette_edit_zone - 1 };
            _ = win.FillRect(hdc, &separator, a.brush_raised.?);
            if (a.palette_match_count == 0) {
                _ = win.SetTextColor(hdc, color_muted);
                _ = win.SelectObject(hdc, @ptrCast(a.font.?));
                var empty_rect = win.RECT{ .left = 20, .top = palette_edit_zone + 4, .right = client.right - 20, .bottom = palette_edit_zone + 36 };
                _ = win.DrawTextW(hdc, lit("No matching commands"), -1, &empty_rect, win.DT_LEFT | win.DT_SINGLELINE | win.DT_VCENTER);
            }
            return 0;
        },
        win.WM_ACTIVATE => {
            if (loword(wparam) == win.WA_INACTIVE) {
                if (a.palette_ever_active) _ = win.DestroyWindow(hwnd);
            } else a.palette_ever_active = true;
            return 0;
        },
        win.WM_DESTROY => {
            a.palette = null;
            a.palette_edit = null;
            a.palette_list = null;
            return 0;
        },
        else => return win.DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn runCommand(a: *App, command: u16) void {
    switch (command) {
        command_search => {
            if (a.search) |search| _ = win.SetFocus(search);
        },
        command_compose => {
            a.user_viewed = true;
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
        command_dictate => toggleDictation(a),
        command_dictation_auto, command_dictation_english, command_dictation_german => {
            a.dictation_language = switch (command) {
                command_dictation_english => .english,
                command_dictation_german => .german,
                else => .automatic,
            };
            saveDictationLanguage(a.dictation_language);
            setStatus(a, switch (a.dictation_language) {
                .automatic => "Dictation language: Automatic",
                .english => "Dictation language: English",
                .german => "Dictation language: German",
            });
        },
        command_font_smaller => changeFontScale(a, -10),
        command_speed_1, command_speed_150, command_speed_200 => {
            const player = ensureAudioPlayer(a) orelse return;
            player.setSpeed(switch (command) {
                command_speed_150 => 150,
                command_speed_200 => 200,
                else => 100,
            });
            setStatus(a, switch (command) {
                command_speed_150 => "Playback speed 1.5x",
                command_speed_200 => "Playback speed 2x",
                else => "Playback speed 1x",
            });
            if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.FALSE);
        },
        command_font_larger => changeFontScale(a, 10),
        command_font_reset => {
            a.font_scale = 80;
            recreateFonts(a);
            saveFontScale(a.font_scale);
            setStatus(a, "Font size 80%");
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
    const header_height: i32 = 0;
    const search_height: i32 = 48;
    const status_height: i32 = 26;
    const compose_height: i32 = 66;
    if (a.search) |hwnd| _ = win.MoveWindow(hwnd, 12, header_height + 8, left_width - 24, 34, win.TRUE);
    if (a.chats_hwnd) |hwnd| _ = win.MoveWindow(hwnd, 0, header_height + search_height, left_width, height - header_height - search_height - status_height, win.TRUE);
    if (a.status) |hwnd| _ = win.MoveWindow(hwnd, 12, height - status_height, left_width - 24, status_height, win.TRUE);
    if (a.canvas) |hwnd| _ = win.MoveWindow(hwnd, left_width + 1, header_height, width - left_width - 1, height - header_height - compose_height, win.TRUE);
    if (a.compose) |hwnd| _ = win.MoveWindow(hwnd, left_width + 14, height - compose_height + 11, width - left_width - 258, 44, win.TRUE);
    if (a.emoji_btn) |hwnd| _ = win.MoveWindow(hwnd, width - 236, height - compose_height + 11, 44, 44, win.TRUE);
    if (a.dictate) |hwnd| _ = win.MoveWindow(hwnd, width - 176, height - compose_height + 11, 84, 44, win.TRUE);
    if (a.send) |hwnd| _ = win.MoveWindow(hwnd, width - 82, height - compose_height + 11, 68, 44, win.TRUE);
}

fn loadAvatarBitmap(a: *App, path: [*:0]const u16) ?win.HBITMAP {
    if (a.wic_factory == null) return null;
    var decoder: [*c]win.IWICBitmapDecoder = null;
    if (a.wic_factory.*.lpVtbl.*.CreateDecoderFromFilename.?(a.wic_factory, path, null, win.GENERIC_READ, win.WICDecodeMetadataCacheOnLoad, &decoder) < 0 or decoder == null) return null;
    defer _ = decoder.*.lpVtbl.*.Release.?(decoder);
    var frame: [*c]win.IWICBitmapFrameDecode = null;
    if (decoder.*.lpVtbl.*.GetFrame.?(decoder, 0, &frame) < 0 or frame == null) return null;
    defer _ = frame.*.lpVtbl.*.Release.?(frame);
    var converter: [*c]win.IWICFormatConverter = null;
    if (a.wic_factory.*.lpVtbl.*.CreateFormatConverter.?(a.wic_factory, &converter) < 0 or converter == null) return null;
    defer _ = converter.*.lpVtbl.*.Release.?(converter);
    if (converter.*.lpVtbl.*.Initialize.?(converter, @ptrCast(frame), &win.GUID_WICPixelFormat32bppPBGRA, win.WICBitmapDitherTypeNone, null, 0, win.WICBitmapPaletteTypeCustom) < 0) return null;
    var scaler: [*c]win.IWICBitmapScaler = null;
    if (a.wic_factory.*.lpVtbl.*.CreateBitmapScaler.?(a.wic_factory, &scaler) < 0 or scaler == null) return null;
    defer _ = scaler.*.lpVtbl.*.Release.?(scaler);
    if (scaler.*.lpVtbl.*.Initialize.?(scaler, @ptrCast(converter), 42, 42, win.WICBitmapInterpolationModeFant) < 0) return null;
    var pixels: [42 * 42 * 4]u8 = undefined;
    if (scaler.*.lpVtbl.*.CopyPixels.?(@ptrCast(scaler), null, 42 * 4, pixels.len, &pixels) < 0) return null;
    var info = std.mem.zeroes(win.BITMAPINFO);
    info.bmiHeader.biSize = @sizeOf(win.BITMAPINFOHEADER);
    info.bmiHeader.biWidth = 42;
    info.bmiHeader.biHeight = -42;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = win.BI_RGB;
    var bits: ?*anyopaque = null;
    const bitmap = win.CreateDIBSection(null, &info, win.DIB_RGB_COLORS, &bits, null, 0) orelse return null;
    if (bits == null) {
        _ = win.DeleteObject(bitmap);
        return null;
    }
    const destination: [*]u8 = @ptrCast(bits.?);
    @memcpy(destination[0..pixels.len], &pixels);
    return bitmap;
}

fn avatarForChat(a: *App, jid: []const u8) ?*AvatarEntry {
    for (a.avatars[0..a.avatar_count]) |*entry| {
        if (std.mem.eql(u8, entry.jid.slice(), jid)) return entry;
    }
    if (a.avatar_count >= max_avatars) return null;
    const entry = &a.avatars[a.avatar_count];
    a.avatar_count += 1;
    entry.jid.set(jid);
    var filename_buffer: [40]u8 = undefined;
    const filename = std.fmt.bufPrint(&filename_buffer, "{x:0>16}.img", .{std.hash.Wyhash.hash(0, jid)}) catch return entry;
    const path = std.fs.path.join(a.allocator, &.{ a.avatar_dir, filename }) catch return entry;
    defer a.allocator.free(path);
    entry.path.set(a.allocator, path);
    if (win.GetFileAttributesW(entry.path.ptr()) != win.INVALID_FILE_ATTRIBUTES) {
        entry.bitmap = loadAvatarBitmap(a, entry.path.ptr());
        entry.status = if (entry.bitmap != null) .ready else .unknown;
    }
    return entry;
}

fn drawAvatarBitmap(hdc: win.HDC, bitmap: win.HBITMAP, left: i32, top: i32) void {
    const memory = win.CreateCompatibleDC(hdc) orelse return;
    defer _ = win.DeleteDC(memory);
    const old_bitmap = win.SelectObject(memory, bitmap);
    defer _ = win.SelectObject(memory, old_bitmap);
    const saved = win.SaveDC(hdc);
    const region = win.CreateEllipticRgn(left, top, left + 42, top + 42);
    if (region) |clip| {
        _ = win.SelectClipRgn(hdc, clip);
        _ = win.BitBlt(hdc, left, top, 42, 42, memory, 0, 0, win.SRCCOPY);
        _ = win.DeleteObject(clip);
    }
    _ = win.RestoreDC(hdc, saved);
}

fn isEmojiUnit(unit: u16) bool {
    return (unit >= 0x1F000 and unit <= 0x1FAFF) or
        (unit >= 0x2600 and unit <= 0x27BF) or
        (unit >= 0x2B00 and unit <= 0x2BFF) or
        (unit >= 0x1F1E6 and unit <= 0x1F1FF) or
        unit == 0xFE0F or unit == 0x200D or unit == 0x20E3 or
        unit == 0x00A9 or unit == 0x00AE or unit == 0x2122;
}

const TextRun = struct { start: usize, len: usize, emoji: bool };
const max_text_runs = 128;

fn splitRuns(text: []const u16, runs: []TextRun) usize {
    var count: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        const emoji = isEmojiUnit(text[index]);
        const start = index;
        while (index < text.len) {
            const unit = text[index];
            // Joiners, variation selectors, and combining keycaps keep the
            // current run attached so ZWJ sequences render in one font.
            const glue = unit == 0x200D or unit == 0xFE0F or unit == 0x20E3;
            if (isEmojiUnit(unit) != emoji and !glue) break;
            index += 1;
        }
        if (count >= runs.len) break;
        runs[count] = .{ .start = start, .len = index - start, .emoji = emoji };
        count += 1;
    }
    return count;
}

fn containsEmoji(text: []const u16) bool {
    for (text) |unit| if (isEmojiUnit(unit)) return true;
    return false;
}

fn runWidth(hdc: win.HDC, text: []const u16) i32 {
    var size: win.SIZE = undefined;
    if (win.GetTextExtentPoint32W(hdc, text.ptr, @intCast(text.len), &size) == 0) return 0;
    return size.cx;
}

/// Draws one line mixing text and emoji runs. Returns the end x position.
fn drawMixedLine(hdc: win.HDC, text_font: win.HFONT, emoji_font: win.HFONT, text: []const u16, x: i32, y: i32) i32 {
    var runs: [max_text_runs]TextRun = undefined;
    const count = splitRuns(text, &runs);
    var cursor = x;
    for (runs[0..count]) |run| {
        _ = win.SelectObject(hdc, @ptrCast(if (run.emoji) emoji_font else text_font));
        const slice = text[run.start..][0..run.len];
        _ = win.TextOutW(hdc, cursor, y, slice.ptr, @intCast(slice.len));
        cursor += runWidth(hdc, slice);
    }
    return cursor;
}

fn textLineHeight(hdc: win.HDC, font: win.HFONT) i32 {
    var metrics: win.TEXTMETRICW = undefined;
    const old = win.SelectObject(hdc, @ptrCast(font));
    _ = win.GetTextMetricsW(hdc, &metrics);
    _ = win.SelectObject(hdc, old);
    return metrics.tmHeight;
}

fn startsWithIgnoreCaseUtf16(hay: []const u16, comptime needle: []const u8) bool {
    if (hay.len < needle.len) return false;
    for (needle, 0..) |character, index| {
        if (lowerUnit(hay[index]) != lowerUnit(@as(u16, character))) return false;
    }
    return true;
}

fn wordIsUrl(word: []const u16) bool {
    return startsWithIgnoreCaseUtf16(word, "http://") or
        startsWithIgnoreCaseUtf16(word, "https://") or
        startsWithIgnoreCaseUtf16(word, "www.");
}

fn wrapMixed(hdc: win.HDC, a: *App, text_ptr: [*]const u16, len: c_int, max_width: i32, draw: bool, left: i32, top: i32) i32 {
    return wrapMixedSink(hdc, a, text_ptr, len, max_width, draw, left, top, null);
}

fn containsUrlHint(text: []const u16) bool {
    var index: usize = 0;
    while (index + 4 <= text.len) : (index += 1) {
        if (startsWithIgnoreCaseUtf16(text[index..], "http") or startsWithIgnoreCaseUtf16(text[index..], "www.")) return true;
    }
    return false;
}

fn wrapMixedSink(hdc: win.HDC, a: *App, text_ptr: [*]const u16, len: c_int, max_width: i32, draw: bool, left: i32, top: i32, sink: ?*const Message) i32 {
    const text = text_ptr[0..@intCast(len)];
    if (sink == null and !containsEmoji(text) and !containsUrlHint(text)) {
        var rect = win.RECT{ .left = 0, .top = 0, .right = max_width, .bottom = 0 };
        const flags: win.UINT = win.DT_CALCRECT | win.DT_WORDBREAK | win.DT_NOPREFIX;
        _ = win.DrawTextW(hdc, text_ptr, len, &rect, flags);
        if (draw) {
            var target = win.RECT{ .left = left, .top = top, .right = left + max_width, .bottom = top + (rect.bottom - rect.top) + 4 };
            _ = win.DrawTextW(hdc, text_ptr, len, &target, win.DT_WORDBREAK | win.DT_NOPREFIX);
        }
        return rect.bottom - rect.top;
    }
    const text_font = a.font orelse return 0;
    const emoji_font = a.font_emoji orelse text_font;
    const line_height = textLineHeight(hdc, text_font);
    var line_top = top;
    var cursor_x = left;
    var word_start: usize = 0;
    var index: usize = 0;
    while (index <= text.len) {
        const at_end = index == text.len;
        if (at_end or text[index] == ' ' or text[index] == '\n') {
            const word = text[word_start..index];
            var word_runs: [max_text_runs]TextRun = undefined;
            const word_run_count = splitRuns(word, &word_runs);
            var word_width: i32 = 0;
            for (word_runs[0..word_run_count]) |run| {
                _ = win.SelectObject(hdc, @ptrCast(if (run.emoji) emoji_font else text_font));
                word_width += runWidth(hdc, word[run.start..][0..run.len]);
            }
            const space_width = runWidth(hdc, &[_]u16{' '});
            if (cursor_x > left and cursor_x + word_width > left + max_width) {
                line_top += line_height;
                cursor_x = left;
            }
            if (draw) {
                const word_x_start = cursor_x;
                const is_link = wordIsUrl(word);
                for (word_runs[0..word_run_count]) |run| {
                    if (is_link) {
                        _ = win.SelectObject(hdc, @ptrCast(a.font_underline orelse text_font));
                        _ = win.SetTextColor(hdc, color_accent);
                    } else {
                        _ = win.SelectObject(hdc, @ptrCast(if (run.emoji) emoji_font else text_font));
                    }
                    const slice = word[run.start..][0..run.len];
                    _ = win.TextOutW(hdc, cursor_x, line_top, slice.ptr, @intCast(slice.len));
                    cursor_x += runWidth(hdc, slice);
                }
                if (is_link) {
                    _ = win.SetTextColor(hdc, color_text);
                    if (sink) |const_target| {
                        const target = @constCast(const_target);
                        if (target.link_count < target.links.len) {
                            const span = &target.links[target.link_count];
                            span.rect = .{ .left = word_x_start, .top = line_top, .right = cursor_x, .bottom = line_top + line_height };
                            if (std.unicode.utf16LeToUtf8Alloc(a.allocator, word)) |utf8_word| {
                                defer a.allocator.free(utf8_word);
                                span.url.set(a.allocator, utf8_word);
                                target.link_count += 1;
                            } else |_| {}
                        }
                    }
                }
                if (sink) |const_target| {
                    const target = @constCast(const_target);
                    if (text.ptr == target.text.ptr() and target.word_count < target.word_rects.len) {
                        const span = &target.word_rects[target.word_count];
                        span.rect = .{ .left = word_x_start, .top = line_top, .right = cursor_x, .bottom = line_top + line_height };
                        span.start = @intCast(word_start);
                        span.len = @intCast(index - word_start);
                        target.word_count += 1;
                    }
                }
                if (!at_end) {
                    _ = win.SelectObject(hdc, @ptrCast(text_font));
                    _ = win.TextOutW(hdc, cursor_x, line_top, &[_]u16{' '}, 1);
                    cursor_x += space_width;
                }
            } else {
                cursor_x += word_width + (if (at_end) @as(i32, 0) else space_width);
            }
            word_start = index + 1;
            if (at_end) break;
            // Formatted transcripts separate paragraphs with newlines; the
            // manual wrapper must honor them as hard breaks.
            if (text[index] == '\n') {
                line_top += line_height;
                cursor_x = left;
            }
        }
        index += 1;
    }
    _ = win.SelectObject(hdc, @ptrCast(text_font));
    return line_height + (line_top - top);
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

    const avatar_entry = avatarForChat(a, chat.jid.slice());
    if (avatar_entry != null and avatar_entry.?.bitmap != null) {
        drawAvatarBitmap(item.hDC, avatar_entry.?.bitmap.?, item.rcItem.left + 12, item.rcItem.top + 10);
    } else {
        const avatar_brush = win.CreateSolidBrush(rgb(59, 74, 84)) orelse return;
        defer _ = win.DeleteObject(avatar_brush);
        const old_brush = win.SelectObject(item.hDC, avatar_brush);
        const old_pen = win.SelectObject(item.hDC, win.GetStockObject(win.NULL_PEN));
        _ = win.Ellipse(item.hDC, item.rcItem.left + 12, item.rcItem.top + 10, item.rcItem.left + 54, item.rcItem.top + 52);
        _ = win.SelectObject(item.hDC, old_brush);
        _ = win.SelectObject(item.hDC, old_pen);
        if (chat.name.len > 0) {
            var initial_length: c_int = 1;
            if (chat.name.buf[0] >= 0xd800 and chat.name.buf[0] <= 0xdbff and chat.name.len > 1) initial_length = 2;
            _ = win.SelectObject(item.hDC, @ptrCast(a.font_bold.?));
            _ = win.SetTextColor(item.hDC, color_text);
            var avatar_rect = win.RECT{ .left = item.rcItem.left + 12, .top = item.rcItem.top + 10, .right = item.rcItem.left + 54, .bottom = item.rcItem.top + 52 };
            _ = win.DrawTextW(item.hDC, chat.name.ptr(), initial_length, &avatar_rect, win.DT_CENTER | win.DT_SINGLELINE | win.DT_VCENTER);
        }
    }

    const name_text = chat.name.slice();
    if (containsEmoji(name_text)) {
        _ = win.SelectObject(item.hDC, @ptrCast(a.font_bold.?));
        _ = win.SetTextColor(item.hDC, color_text);
        const line_h = textLineHeight(item.hDC, a.font_bold.?);
        const name_y = item.rcItem.top + 10 + @divTrunc(24 - line_h, 2);
        _ = drawMixedLine(item.hDC, a.font_bold.?, a.font_emoji orelse a.font_bold.?, name_text, item.rcItem.left + 66, name_y);
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

fn transcriptLineKind(line: []const u16) enum { text, header, bullet, rule, blank } {
    if (line.len == 0) return .blank;
    if (line[0] == '#') return .header;
    if (line[0] == '-' and (line.len == 1 or line[1] == ' ')) return .bullet;
    if (line[0] == '*' and line.len >= 2 and line[1] == ' ') return .bullet;
    if (line.len >= 3) {
        var all_dash = true;
        for (line) |character| {
            if (character != '-') {
                all_dash = false;
                break;
            }
        }
        if (all_dash) return .rule;
    }
    return .text;
}

// Renders the transcript with markdown interpreted: # headers become bold
// accent lines, - bullets become dot bullets with hanging indent, ---
// becomes a rule. Measure and draw share this exact code path so bubble
// heights always match what is drawn.
fn transcriptRender(hdc: win.HDC, a: *App, message: *const Message, shown: c_int, width: i32, draw: bool, left: i32, top: i32) i32 {
    const text = message.transcript.slice()[0..@intCast(shown)];
    var y = top;
    var line_start: usize = 0;
    var index: usize = 0;
    const bullet_char = [_]u16{0x2022};
    while (index <= text.len) {
        const at_end = index == text.len;
        if (at_end or text[index] == '\n') {
            var line = text[line_start..index];
            while (line.len > 0 and (line[line.len - 1] == '\r' or line[line.len - 1] == ' ')) line = line[0 .. line.len - 1];
            switch (transcriptLineKind(line)) {
                .blank => y += 8,
                .rule => {
                    if (draw) {
                        const rule_brush = win.CreateSolidBrush(rgb(59, 74, 84)) orelse return y - top;
                        defer _ = win.DeleteObject(rule_brush);
                        var rule_rect = win.RECT{ .left = left, .top = y + 3, .right = left + width, .bottom = y + 5 };
                        _ = win.FillRect(hdc, &rule_rect, rule_brush);
                    }
                    y += 12;
                },
                .header => {
                    var content = line;
                    while (content.len > 0 and content[0] == '#') content = content[1..];
                    while (content.len > 0 and content[0] == ' ') content = content[1..];
                    _ = win.SelectObject(hdc, @ptrCast(a.font_bold.?));
                    _ = win.SetTextColor(hdc, color_accent);
                    if (content.len > 0) y += wrapMixedSink(hdc, a, content.ptr, @intCast(content.len), width, draw, left, y, null) + 6;
                },
                .bullet => {
                    var content = line[1..];
                    while (content.len > 0 and content[0] == ' ') content = content[1..];
                    _ = win.SelectObject(hdc, @ptrCast(a.font.?));
                    _ = win.SetTextColor(hdc, color_accent);
                    if (draw) _ = win.TextOutW(hdc, left, y, &bullet_char, 1);
                    _ = win.SelectObject(hdc, @ptrCast(a.font.?));
                    _ = win.SetTextColor(hdc, color_text);
                    y += wrapMixedSink(hdc, a, content.ptr, @intCast(content.len), width - 16, draw, left + 16, y, null) + 2;
                },
                .text => {
                    _ = win.SelectObject(hdc, @ptrCast(a.font.?));
                    _ = win.SetTextColor(hdc, color_text);
                    y += wrapMixedSink(hdc, a, line.ptr, @intCast(line.len), width, draw, left, y, null) + 2;
                },
            }
            line_start = index + 1;
            if (at_end) break;
        }
        index += 1;
    }
    return y - top;
}

fn measureMessage(hdc: win.HDC, a: *App, message: *const Message, width: i32) i32 {
    _ = win.SelectObject(hdc, @ptrCast(a.font.?));
    var height = wrapMixedSink(hdc, a, if (message.text.len > 0) message.text.ptr() else lit(" "), if (message.text.len > 0) @intCast(message.text.len) else 1, width - 28, false, 0, 0, message) + 42;
    if (message.bitmap_height > 0) {
        height += message.bitmap_height + 8;
    } else if (message.media_type.len > 0) height += 54;
    if (message.transcript_state == .loading) height += 24;
    if (message.transcript.len > 0) {
        _ = win.SelectObject(hdc, @ptrCast(a.font.?));
        const shown: c_int = if (message.transcript_expanded) @intCast(message.transcript.len) else @intCast(@min(message.transcript.len, 400));
        height += transcriptRender(hdc, a, message, shown, width - 28, false, 0, 0) + 22;
    }
    if (message.reaction.len > 0) height += 18;
    return @max(height, 58);
}

const SenderColor = struct { r: u8, g: u8, b: u8 };

const sender_palette = [_]SenderColor{
    .{ .r = 0, .g = 168, .b = 132 },
    .{ .r = 83, .g = 189, .b = 235 },
    .{ .r = 235, .g = 140, .b = 84 },
    .{ .r = 178, .g = 132, .b = 235 },
    .{ .r = 235, .g = 195, .b = 84 },
    .{ .r = 235, .g = 110, .b = 150 },
};

// Stable per-sender color so the same person keeps one color within a chat.
fn senderColorFor(seed: []const u8) SenderColor {
    if (seed.len == 0) return sender_palette[0];
    var hash: u32 = 2166136261;
    for (seed) |byte| {
        hash ^= byte;
        hash = hash *% 16777619;
    }
    return sender_palette[hash % sender_palette.len];
}

// First grapheme-ish chunk of a UTF-16 name: pairs up surrogate halves so an
// emoji initial does not render as a lone surrogate.
fn senderInitial(sender: []const u16) []const u16 {
    if (sender.len == 0) return sender;
    const first = sender[0];
    if (first >= 0xd800 and first <= 0xdbff and sender.len > 1 and sender[1] >= 0xdc00 and sender[1] <= 0xdfff)
        return sender[0..2];
    return sender[0..1];
}

fn drawSenderAvatar(hdc: win.HDC, a: *App, x: i32, top: i32, message: *const Message) void {
    // Seed the color from the jid; fall back to the first name code unit when
    // the jid is missing (both are stable per person).
    const seed = if (message.sender_jid.len > 0)
        message.sender_jid.slice()
    else blk: {
        const units = message.sender.slice();
        break :blk std.mem.sliceAsBytes(units[0..@min(units.len, 2)]);
    };
    const tint = senderColorFor(seed);
    const circle_brush = win.CreateSolidBrush(rgb(tint.r, tint.g, tint.b)) orelse return;
    defer _ = win.DeleteObject(circle_brush);
    const old_brush = win.SelectObject(hdc, circle_brush);
    const old_pen = win.SelectObject(hdc, win.GetStockObject(win.NULL_PEN));
    _ = win.Ellipse(hdc, x, top, x + 30, top + 30);
    _ = win.SelectObject(hdc, old_brush);
    _ = win.SelectObject(hdc, old_pen);
    const initial = senderInitial(message.sender.slice());
    const old_font = win.SelectObject(hdc, @ptrCast(a.font_bold.?));
    const old_color = win.SetTextColor(hdc, color_text);
    var rect = win.RECT{ .left = x, .top = top, .right = x + 30, .bottom = top + 30 };
    _ = win.DrawTextW(hdc, @ptrCast(initial.ptr), @intCast(initial.len), &rect, win.DT_CENTER | win.DT_SINGLELINE | win.DT_VCENTER);
    _ = win.SetTextColor(hdc, old_color);
    _ = win.SelectObject(hdc, old_font);
}

fn drawCanvas(hwnd: win.HWND, a: *App) void {
    var paint: win.PAINTSTRUCT = undefined;
    const screen_dc = win.BeginPaint(hwnd, &paint);
    defer _ = win.EndPaint(hwnd, &paint);
    var client: win.RECT = undefined;
    _ = win.GetClientRect(hwnd, &client);
    const canvas_width = @max(1, client.right - client.left);
    const canvas_height = @max(1, client.bottom - client.top);
    // Draw into a memory bitmap first and blit once; painting directly to
    // the screen flickered whenever GIF frames invalidated the canvas.
    const memory_dc = win.CreateCompatibleDC(screen_dc);
    var memory_bitmap: win.HBITMAP = null;
    var old_bitmap: ?win.HGDIOBJ = null;
    const hdc = if (memory_dc) |dc| block: {
        memory_bitmap = win.CreateCompatibleBitmap(screen_dc, canvas_width, canvas_height);
        old_bitmap = win.SelectObject(dc, @ptrCast(memory_bitmap));
        break :block dc;
    } else screen_dc;
    defer {
        if (memory_dc != null) {
            _ = win.BitBlt(screen_dc, 0, 0, canvas_width, canvas_height, hdc, 0, 0, win.SRCCOPY);
            if (old_bitmap) |bitmap| _ = win.SelectObject(memory_dc.?, bitmap);
            if (memory_bitmap != null) _ = win.DeleteObject(memory_bitmap);
            _ = win.DeleteDC(memory_dc.?);
        }
    }
    _ = win.FillRect(hdc, &client, a.brush_bg.?);
    _ = win.SetBkMode(hdc, win.TRANSPARENT);
    const available_width = client.right - client.left;
    const bubble_width = std.math.clamp(@divTrunc(available_width * 7, 10), 280, 620);
    const chat_jid = if (a.displayed_jid.len > 0)
        a.displayed_jid.slice()
    else if (a.chat_count > 0 and a.selected_chat < a.chat_count)
        a.chats[a.selected_chat].jid.slice()
    else
        "";
    const in_group = std.mem.endsWith(u8, chat_jid, "@g.us");
    var total_height: i32 = 18;
    for (a.messages[0..a.message_count]) |*message| total_height += measureMessage(hdc, a, message, bubble_width) + 8;
    a.max_scroll = @max(0, total_height - (client.bottom - client.top));
    a.scroll_y = std.math.clamp(a.scroll_y, 0, a.max_scroll);
    var y = client.bottom - 14 + a.scroll_y;
    var index = a.message_count;
    while (index > 0) {
        index -= 1;
        const message = &a.messages[index];
        message.media_hit = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        message.bubble_hit = .{ .left = 0, .top = 0, .right = 0, .bottom = 0 };
        message.link_count = 0;
        message.word_count = 0;
        const estimated_height = measureMessage(hdc, a, message, bubble_width);
        y -= estimated_height + 8;
        if (y > client.bottom or y + estimated_height < client.top) continue;
        ensureBitmap(a, message);
        const height = measureMessage(hdc, a, message, bubble_width);
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

        _ = win.SelectObject(hdc, @ptrCast(a.font_bold.?));
        _ = win.SetTextColor(hdc, if (message.from_me) color_text else rgb(83, 189, 235));
        var sender_rect = win.RECT{ .left = left + 12, .top = y + 8, .right = right - 52, .bottom = y + 28 };
        const sender_text = message.sender.slice();
        if (containsEmoji(sender_text)) {
            const line_h = textLineHeight(hdc, a.font_bold.?);
            _ = drawMixedLine(hdc, a.font_bold.?, a.font_emoji orelse a.font_bold.?, sender_text, left + 12, y + 8 + @divTrunc(20 - line_h, 2));
        } else {
            _ = win.DrawTextW(hdc, message.sender.ptr(), @intCast(message.sender.len), &sender_rect, win.DT_LEFT | win.DT_SINGLELINE | win.DT_END_ELLIPSIS);
        }
        var text_top = y + 28;
        if (in_group and !message.from_me and message.sender.len > 0) drawSenderAvatar(hdc, a, left - 38, y + 8, message);
        if (message.bitmap) |bitmap| {
            const image_left = left + @divTrunc(bubble_width - message.bitmap_width, 2);
            const image_top = text_top + 4;
            const image_memory_dc = win.CreateCompatibleDC(hdc);
            if (image_memory_dc != null) {
                const previous = win.SelectObject(image_memory_dc, @ptrCast(bitmap));
                _ = win.BitBlt(hdc, image_left, image_top, message.bitmap_width, message.bitmap_height, image_memory_dc, 0, 0, win.SRCCOPY);
                _ = win.SelectObject(image_memory_dc, previous);
                _ = win.DeleteDC(image_memory_dc);
            }
            message.media_hit = .{ .left = image_left, .top = image_top, .right = image_left + message.bitmap_width, .bottom = image_top + message.bitmap_height };
            if (std.ascii.eqlIgnoreCase(message.media_type.slice(), "video")) {
                _ = win.SelectObject(hdc, @ptrCast(a.font_bold.?));
                _ = win.SetTextColor(hdc, color_text);
                var play_rect = message.media_hit;
                _ = win.DrawTextW(hdc, lit("▶"), -1, &play_rect, win.DT_CENTER | win.DT_SINGLELINE | win.DT_VCENTER);
            }
            text_top += message.bitmap_height + 8;
        } else if (isAudio(message)) {
            const strip_top = text_top + 4;
            const button_cx = left + 26;
            const button_cy = strip_top + 18;
            const active = std.mem.eql(u8, a.audio_playing_id.slice(), message.id.slice()) and a.audio_state != .empty;
            if (message.local_path.len == 0) {
                _ = win.SelectObject(hdc, @ptrCast(a.font_small.?));
                _ = win.SetTextColor(hdc, color_accent);
                var media_rect = win.RECT{ .left = left + 12, .top = strip_top, .right = right - 12, .bottom = strip_top + 42 };
                _ = win.DrawTextW(hdc, lit("Voice message · click to download"), -1, &media_rect, win.DT_CENTER | win.DT_SINGLELINE | win.DT_VCENTER);
            } else {
                const playing_now = active and a.audio_state == .playing;
                const button_brush = win.CreateSolidBrush(color_accent) orelse continue;
                const glyph_brush = win.CreateSolidBrush(color_text) orelse {
                    _ = win.DeleteObject(button_brush);
                    continue;
                };
                const previous_brush = win.SelectObject(hdc, button_brush);
                const previous_pen = win.SelectObject(hdc, win.GetStockObject(win.NULL_PEN));
                _ = win.Ellipse(hdc, left + 12, strip_top + 4, left + 40, strip_top + 32);
                _ = win.SelectObject(hdc, glyph_brush);
                if (playing_now) {
                    _ = win.Rectangle(hdc, button_cx - 7, button_cy - 8, button_cx - 2, button_cy + 8);
                    _ = win.Rectangle(hdc, button_cx + 2, button_cy - 8, button_cx + 7, button_cy + 8);
                } else {
                    var triangle = [3]win.POINT{
                        .{ .x = button_cx - 4, .y = button_cy - 8 },
                        .{ .x = button_cx - 4, .y = button_cy + 8 },
                        .{ .x = button_cx + 9, .y = button_cy },
                    };
                    _ = win.Polygon(hdc, &triangle, 3);
                }
                _ = win.SelectObject(hdc, previous_brush);
                _ = win.SelectObject(hdc, previous_pen);
                _ = win.DeleteObject(glyph_brush);
                _ = win.DeleteObject(button_brush);

                // Playback-speed button between the play control and the
                // progress track; click cycles 1x -> 1.5x -> 2x.
                _ = win.SelectObject(hdc, @ptrCast(a.font_small.?));
                const speed_active = a.audio_player != null and a.audio_player.?.speed() != 100;
                _ = win.SetTextColor(hdc, if (speed_active) color_accent else color_muted);
                var speed_rect = win.RECT{ .left = left + 48, .top = strip_top + 4, .right = left + 90, .bottom = strip_top + 32 };
                _ = win.DrawTextW(hdc, speedLabel(a.audio_player), -1, &speed_rect, win.DT_CENTER | win.DT_SINGLELINE | win.DT_VCENTER);

                const track_left = left + 94;
                const track_right = right - 64;
                const track_brush = win.CreateSolidBrush(rgb(59, 74, 84)) orelse continue;
                var track = win.RECT{ .left = track_left, .top = button_cy - 3, .right = track_right, .bottom = button_cy + 3 };
                _ = win.FillRect(hdc, &track, track_brush);
                if (active and a.audio_duration_ms > 0) {
                    const fraction = std.math.clamp(@as(f64, @floatFromInt(a.audio_position_ms)) / @as(f64, @floatFromInt(a.audio_duration_ms)), 0, 1);
                    track.right = track_left + @as(i32, @intFromFloat(fraction * @as(f64, @floatFromInt(track_right - track_left))));
                    const filled_brush = win.CreateSolidBrush(color_accent) orelse {
                        _ = win.DeleteObject(track_brush);
                        continue;
                    };
                    _ = win.FillRect(hdc, &track, filled_brush);
                    _ = win.DeleteObject(filled_brush);
                }
                _ = win.DeleteObject(track_brush);
                if (active and a.audio_duration_ms > 0) {
                    var time_buffer: [24]u8 = undefined;
                    var position_buffer: [16]u8 = undefined;
                    var duration_buffer: [16]u8 = undefined;
                    const time_text = std.fmt.bufPrint(&time_buffer, "{s} / {s}", .{ formatClock(&position_buffer, a.audio_position_ms), formatClock(&duration_buffer, a.audio_duration_ms) }) catch "";
                    var time_wide = WideText(31){};
                    time_wide.set(a.allocator, time_text);
                    _ = win.SelectObject(hdc, @ptrCast(a.font_small.?));
                    _ = win.SetTextColor(hdc, color_muted);
                    var time_rect = win.RECT{ .left = right - 60, .top = strip_top, .right = right - 10, .bottom = strip_top + 42 };
                    _ = win.DrawTextW(hdc, time_wide.ptr(), @intCast(time_wide.len), &time_rect, win.DT_RIGHT | win.DT_SINGLELINE | win.DT_VCENTER);
                }
            }
            message.media_hit = .{ .left = left + 8, .top = strip_top, .right = right - 8, .bottom = strip_top + 42 };
            text_top += 54;
            if (message.transcript_state == .loading) {
                _ = win.SelectObject(hdc, @ptrCast(a.font_small.?));
                _ = win.SetTextColor(hdc, color_muted);
                var loading_rect = win.RECT{ .left = left + 12, .top = text_top, .right = right - 12, .bottom = text_top + 20 };
                _ = win.DrawTextW(hdc, lit("Transcribing…"), -1, &loading_rect, win.DT_LEFT | win.DT_SINGLELINE | win.DT_END_ELLIPSIS);
                text_top += 24;
            } else if (message.transcript.len > 0) {
                const shown: c_int = if (message.transcript_expanded) @intCast(message.transcript.len) else @intCast(@min(message.transcript.len, 400));
                const transcript_height = transcriptRender(hdc, a, message, shown, right - left - 24, true, left + 12, text_top);
                text_top += transcript_height + 2;
                _ = win.SelectObject(hdc, @ptrCast(a.font_small.?));
                _ = win.SetTextColor(hdc, color_accent);
                var toggle_rect = win.RECT{ .left = left + 12, .top = text_top, .right = right - 12, .bottom = text_top + 18 };
                _ = win.DrawTextW(hdc, if (message.transcript_expanded) lit("Show less") else lit("Show more"), -1, &toggle_rect, win.DT_LEFT | win.DT_SINGLELINE);
                message.toggle_hit = toggle_rect;
                text_top += 20;
            }
        } else if (message.media_type.len > 0) {
            _ = win.SelectObject(hdc, @ptrCast(a.font_small.?));
            _ = win.SetTextColor(hdc, color_accent);
            var media_rect = win.RECT{ .left = left + 12, .top = text_top + 4, .right = right - 12, .bottom = text_top + 46 };
            const local = message.local_path.len > 0;
            const label = if (isVideoGif(message))
                (if (local) lit("GIF") else lit("GIF · click to download"))
            else if (isVideo(message))
                (if (local) lit("Video · click to play") else lit("Video · click to download"))
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
        const text_len: c_int = if (message.text.len > 0) @intCast(message.text.len) else 1;
        _ = wrapMixedSink(hdc, a, if (message.text.len > 0) message.text.ptr() else lit(" "), text_len, right - left - 24, true, left + 12, text_top, message);
        if (a.sel_message != null and a.sel_message.? == index and a.sel_anchor_word != a.sel_focus_word) {
            const lo = @min(a.sel_anchor_word, a.sel_focus_word);
            const hi = @max(a.sel_anchor_word, a.sel_focus_word);
            if (hi < message.word_count) {
                const highlight = win.CreateSolidBrush(rgb(0, 105, 85)) orelse return;
                defer _ = win.DeleteObject(highlight);
                var word_index = lo;
                while (word_index <= hi) : (word_index += 1) {
                    const span = &message.word_rects[word_index];
                    _ = win.FillRect(hdc, &span.rect, highlight);
                    _ = win.SelectObject(hdc, @ptrCast(a.font.?));
                    _ = win.SetTextColor(hdc, color_text);
                    const slice = message.text.slice()[span.start..][0..span.len];
                    _ = win.TextOutW(hdc, span.rect.left, span.rect.top, slice.ptr, @intCast(slice.len));
                }
            }
        }
        if (message.reaction.len > 0) {
            _ = win.SelectObject(hdc, @ptrCast(a.font.?));
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
        win.WM_LBUTTONDOWN => {
            const x: i32 = @as(i16, @bitCast(loword(@as(usize, @bitCast(lparam)))));
            const y: i32 = @as(i16, @bitCast(hiword(@as(usize, @bitCast(lparam)))));
            for (a.messages[0..a.message_count], 0..) |*item, index| {
                const bubble = item.bubble_hit;
                if (x >= bubble.left and x <= bubble.right and y >= bubble.top and y <= bubble.bottom) {
                    if (hitTestWord(item, x, y)) |word_index| {
                        a.sel_message = index;
                        a.sel_anchor_word = word_index;
                        a.sel_focus_word = word_index;
                        a.text_dragging = true;
                        a.drag_moved = false;
                        a.drag_origin = .{ .x = x, .y = y };
                        _ = win.SetCapture(hwnd);
                        _ = win.InvalidateRect(hwnd, null, win.FALSE);
                    }
                    break;
                }
            }
            return 0;
        },
        win.WM_MOUSEMOVE => {
            if (!a.text_dragging or a.sel_message == null) return win.DefWindowProcW(hwnd, message, wparam, lparam);
            const x: i32 = @as(i16, @bitCast(loword(@as(usize, @bitCast(lparam)))));
            const y: i32 = @as(i16, @bitCast(hiword(@as(usize, @bitCast(lparam)))));
            const dx = x - a.drag_origin.x;
            const dy = y - a.drag_origin.y;
            if (dx * dx + dy * dy > 16) a.drag_moved = true;
            const item = &a.messages[a.sel_message.?];
            if (hitTestWord(item, x, y)) |word_index| {
                if (word_index != a.sel_focus_word) {
                    a.sel_focus_word = word_index;
                    _ = win.InvalidateRect(hwnd, null, win.FALSE);
                }
            }
            return 0;
        },
        win.WM_LBUTTONUP => {
            const x: i32 = @as(i16, @bitCast(loword(@as(usize, @bitCast(lparam)))));
            const y: i32 = @as(i16, @bitCast(hiword(@as(usize, @bitCast(lparam)))));
            if (a.text_dragging) {
                _ = win.ReleaseCapture();
                a.text_dragging = false;
                if (!a.drag_moved) {
                    a.sel_message = null;
                    handleCanvasClick(a, hwnd, x, y);
                }
                return 0;
            }
            handleCanvasClick(a, hwnd, x, y);
            return 0;
        },
        win.WM_RBUTTONUP => {
            const x: i32 = @as(i16, @bitCast(loword(@as(usize, @bitCast(lparam)))));
            const y: i32 = @as(i16, @bitCast(hiword(@as(usize, @bitCast(lparam)))));
            if (a.sel_message != null and a.sel_anchor_word != a.sel_focus_word) {
                const selected_index = a.sel_message.?;
                if (selected_index < a.message_count) {
                    const item = &a.messages[selected_index];
                    const bubble = item.bubble_hit;
                    if (x >= bubble.left and x <= bubble.right and y >= bubble.top and y <= bubble.bottom) {
                        a.selected_message = selected_index;
                        var point = win.POINT{ .x = x, .y = y };
                        _ = win.ClientToScreen(hwnd, &point);
                        const menu = win.CreatePopupMenu() orelse return 0;
                        defer _ = win.DestroyMenu(menu);
                        _ = win.AppendMenuW(menu, win.MF_STRING, command_copy_selection, lit("Copy selection"));
                        _ = win.AppendMenuW(menu, win.MF_STRING, command_copy_text, lit("Copy message text"));
                        if (item.transcript.len > 0) _ = win.AppendMenuW(menu, win.MF_STRING, command_copy_transcript, lit("Copy transcript"));
                        if (item.link_count > 0) _ = win.AppendMenuW(menu, win.MF_STRING, command_copy_link, lit("Copy link address"));
                        const choice = win.TrackPopupMenu(menu, win.TPM_RETURNCMD | win.TPM_NONOTIFY, point.x, point.y, 0, a.hwnd.?, null);
                        reactToSelected(a, @intCast(choice));
                        return 0;
                    }
                }
            }
            for (a.messages[0..a.message_count], 0..) |*item, index| {
                const bubble = item.bubble_hit;
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
    addTooltip(tt, a.chats_hwnd, lit("Chats  ↑/↓ move · Enter to compose"));
    addTooltip(tt, a.canvas, lit("Messages  Alt+J/K select · Ctrl+T transcript · Ctrl+P play voice"));
    addTooltip(tt, a.compose, lit("Message box  Enter sends · Shift+Enter new line"));
    addTooltip(tt, a.dictate, lit("Dictate  Ctrl+D"));
    addTooltip(tt, a.send, lit("Send message  Enter"));
    addTooltip(tt, a.emoji_btn, lit("Emoji menu"));
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
            a.search = win.CreateWindowExW(0, lit("EDIT"), null, win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.ES_AUTOHSCROLL, 0, 0, 0, 0, hwnd, controlId(id_search), a.instance, null);
            a.chats_hwnd = win.CreateWindowExW(0, lit("LISTBOX"), null, win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.WS_VSCROLL | win.LBS_NOTIFY | win.LBS_OWNERDRAWFIXED | win.LBS_NOINTEGRALHEIGHT, 0, 0, 0, 0, hwnd, controlId(id_chats), a.instance, null);
            a.canvas = win.CreateWindowExW(0, lit("WacliMessageCanvas"), null, win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP, 0, 0, 0, 0, hwnd, controlId(id_canvas), a.instance, null);
            a.compose = win.CreateWindowExW(0, lit("EDIT"), null, win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.ES_MULTILINE | win.ES_AUTOVSCROLL | win.WS_VSCROLL, 0, 0, 0, 0, hwnd, controlId(id_compose), a.instance, null);
            a.dictate = win.CreateWindowExW(0, lit("BUTTON"), lit("Dictate"), win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.BS_PUSHBUTTON, 0, 0, 0, 0, hwnd, controlId(id_dictate), a.instance, null);
            a.send = win.CreateWindowExW(0, lit("BUTTON"), lit("Send"), win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.BS_PUSHBUTTON, 0, 0, 0, 0, hwnd, controlId(id_send), a.instance, null);
            a.emoji_btn = win.CreateWindowExW(0, lit("BUTTON"), lit("😊"), win.WS_CHILD | win.WS_VISIBLE | win.WS_TABSTOP | win.BS_PUSHBUTTON, 0, 0, 0, 0, hwnd, controlId(id_emoji), a.instance, null);
            a.status = win.CreateWindowExW(0, lit("STATIC"), lit("Loading..."), win.WS_CHILD | win.WS_VISIBLE | win.SS_LEFT, 0, 0, 0, 0, hwnd, controlId(id_status), a.instance, null);
            createTooltips(a, hwnd);
            recreateFonts(a);
            if (a.search) |search| _ = win.SendMessageW(search, win.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(lit("Search chats  Ctrl+F"))));
            if (a.chats_hwnd) |list| _ = win.SendMessageW(list, win.LB_SETITEMHEIGHT, 0, 64);
            _ = win.SetTimer(hwnd, timer_refresh, 1000, null);
            _ = win.SetTimer(hwnd, timer_animation, 120, null);
            _ = win.SetTimer(hwnd, timer_update_check, update_check_interval_ms, null);
            refreshGroups(a);
            refreshChats(a);
            refreshMessages(a);
            _ = storeChanged(a);
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
            var composer_rect = win.RECT{ .left = left_width + 1, .top = client.bottom - 66, .right = client.right, .bottom = client.bottom };
            _ = win.FillRect(hdc, &composer_rect, a.brush_raised.?);
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
                    a.user_viewed = true;
                    refreshMessages(a);
                    focusCompose(a);
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
                checkSend(a);
                checkMarkRead(a);
                checkAvatarDownload(a);
                checkArchive(a);
                if (a.media_child == null) {
                    checkSync(a);
                    a.group_refresh_ticks += 1;
                    if (a.group_refresh_ticks >= 60) {
                        refreshGroups(a);
                        a.group_refresh_ticks = 0;
                    }
                    const changed = storeChanged(a);
                    if (changed and !a.chat_selection_pending) {
                        refreshChats(a);
                        if (!messagesAreCurrent(a)) refreshMessages(a);
                    }
                    retryPendingDownload(a);
                    autoDownloadNextMedia(a);
                    requestSelectedAvatar(a);
                }
            } else if (wparam == timer_search) {
                _ = win.KillTimer(hwnd, timer_search);
                refreshChats(a);
                refreshMessages(a);
            } else if (wparam == timer_animation) {
                advanceGifs(a);
                updateAudioPlayback(a);
                updateDictation(a);
                // Harvest the finished result before scheduling the next
                // job; the session has one result slot and scheduling first
                // silently discarded every completed transcript.
                pollTranscription(a);
                scheduleNextTranscription(a);
                pollFormatting(a);
                scheduleNextFormatting(a);
            } else if (wparam == timer_chat_select) {
                _ = win.KillTimer(hwnd, timer_chat_select);
                a.chat_selection_pending = false;
                refreshMessages(a);
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
            _ = win.KillTimer(hwnd, timer_refresh);
            _ = win.KillTimer(hwnd, timer_search);
            _ = win.KillTimer(hwnd, timer_animation);
            _ = win.KillTimer(hwnd, timer_chat_select);
            if (a.media_child) |*child| child.kill(a.io);
            a.media_child = null;
            if (a.send_child) |*child| child.kill(a.io);
            a.send_child = null;
            if (a.archive_child) |*child| child.kill(a.io);
            a.archive_child = null;
            if (a.read_child) |*child| child.kill(a.io);
            a.read_child = null;
            stopSync(a);
            if (a.sync_job) |job| _ = win.CloseHandle(job);
            a.sync_job = null;
            if (a.audio_player) |player| {
                player.destroy();
                a.audio_player = null;
            }
            if (a.dictation_session) |session| {
                session.destroy();
                a.dictation_session = null;
            }
            if (a.avatar_session) |session| {
                session.destroy();
                a.avatar_session = null;
            }
            if (a.transcribe_session) |session| {
                session.destroy();
                a.transcribe_session = null;
            }
            if (a.openrouter_session) |session| {
                session.destroy();
                a.openrouter_session = null;
            }
            for (a.avatars[0..a.avatar_count]) |*entry| {
                if (entry.bitmap) |bitmap| _ = win.DeleteObject(bitmap);
            }
            a.audio_state = .empty;
            clearMessages(a);
            if (a.font) |font| _ = win.DeleteObject(font);
            if (a.font_small) |font| _ = win.DeleteObject(font);
            if (a.font_bold) |font| _ = win.DeleteObject(font);
            if (a.font_underline) |font| _ = win.DeleteObject(font);
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
    // Swallow a bare Alt keydown: if it reaches the edit control's default
    // proc it enters menu mode, which hides the caret, and because Alt+J/K
    // are consumed here the mode never exits and the caret stays hidden.
    if (alt and key == win.VK_MENU) return true;
    if (control and key == 'F') {
        if (a.search) |search| {
            _ = win.SetFocus(search);
            _ = win.SendMessageW(search, win.EM_SETSEL, 0, @bitCast(@as(isize, -1)));
        }
        return true;
    }
    if (control and key == 'K') {
        openPalette(a);
        return true;
    }
    if (a.palette != null) {
        if (key == win.VK_DOWN) {
            paletteMove(a, 1);
            return true;
        }
        if (key == win.VK_UP) {
            paletteMove(a, -1);
            return true;
        }
        if (key == win.VK_RETURN) {
            paletteActivate(a);
            return true;
        }
        if (key == win.VK_ESCAPE) {
            closePalette(a);
            return true;
        }
        return false;
    }
    if (key == win.VK_ESCAPE) {
        const focused = win.GetFocus();
        if (focused != null) {
            const root = win.GetAncestor(focused, win.GA_ROOT) orelse focused;
            var class_name: [32]u16 = [_]u16{0} ** 32;
            const class_len: usize = @intCast(win.GetClassNameW(root, &class_name, class_name.len));
            if (std.mem.eql(u16, class_name[0..class_len], std.mem.span(lit("MessagesPalette")))) {
                _ = win.DestroyWindow(root);
                if (a.chats_hwnd) |list| _ = win.SetFocus(list);
                return true;
            }
        }
    }
    if (control and (key == win.VK_OEM_MINUS or key == win.VK_SUBTRACT)) {
        runCommand(a, command_font_smaller);
        return true;
    }
    if (control and (key == win.VK_OEM_PLUS or key == win.VK_ADD)) {
        runCommand(a, command_font_larger);
        return true;
    }
    if (control and key == '0') {
        runCommand(a, command_font_reset);
        return true;
    }
    if (control and key == 'D') {
        runCommand(a, command_dictate);
        return true;
    }
    if (control and key == 'E') {
        archiveSelectedChat(a);
        return true;
    }
    if (control and shift and key == 'C') {
        copySelectedText(a);
        return true;
    }
    if (control and key == 'C') {
        // Keep native copy when an editor has its own text selection.
        const focus_control = win.GetFocus();
        const in_editor = (a.compose != null and focus_control == a.compose.?) or (a.search != null and focus_control == a.search.?);
        if (in_editor) {
            var selection_start: win.DWORD = 0;
            var selection_end: win.DWORD = 0;
            const start_result = win.SendMessageW(focus_control, win.EM_GETSEL, 0, 0);
            selection_start = @as(win.DWORD, @truncate(@as(usize, @bitCast(start_result)) & 0xffff));
            selection_end = @as(win.DWORD, @truncate((@as(usize, @bitCast(start_result)) >> 16) & 0xffff));
            if (selection_start != selection_end) return false;
        }
        copySelectedText(a);
        return true;
    }
    if (control and key == 'R') {
        openReactionMenuForSelected(a);
        return true;
    }
    if (control and key == 'P') {
        var handled_audio = false;
        if (a.selected_message) |selected| {
            if (selected < a.message_count) {
                const audio_item = &a.messages[selected];
                if (isAudio(audio_item)) {
                    handled_audio = true;
                    if (std.mem.eql(u8, a.audio_playing_id.slice(), audio_item.id.slice()) and a.audio_state != .empty) {
                        toggleAudio(a, audio_item);
                    } else if (audio_item.local_path.len > 0) {
                        startAudioPlayback(a, audio_item);
                    } else {
                        downloadMedia(a, selected, false);
                    }
                }
            }
        }
        if (!handled_audio) setStatus(a, "Select a voice message with Alt+J/K first");
        return true;
    }
    if (control and key == 'T') {
        var handled_transcript = false;
        if (a.selected_message) |selected| {
            if (selected < a.message_count) {
                const transcript_item = &a.messages[selected];
                if (transcript_item.transcript.len > 0) {
                    handled_transcript = true;
                    transcript_item.transcript_expanded = !transcript_item.transcript_expanded;
                    scrollToSelectedMessage(a);
                    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.TRUE);
                }
            }
        }
        if (!handled_transcript) setStatus(a, "Select a voice message with Alt+J/K first");
        return true;
    }
    if (alt and (key == 'J' or key == 'K')) {
        selectMessage(a, if (key == 'J') 1 else -1);
        return true;
    }
    if (alt and key == 'G') {
        const now_ms = win.GetTickCount64();
        if (now_ms - a.last_alt_g_ms <= 900) {
            a.last_alt_g_ms = 0;
            jumpToLatestMessage(a);
            setStatus(a, "Jumped to latest message");
        } else {
            a.last_alt_g_ms = now_ms;
            setStatus(a, "Press Alt+G again to jump to the latest message");
        }
        return true;
    }
    if (control and key == 'O') {
        openLinkPalette(a);
        return true;
    }
    if (control and key == win.VK_TAB) {
        selectChat(a, if (shift) -1 else 1, true);
        focusCompose(a);
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
    return false;
}

fn jumpToLatestMessage(a: *App) void {
    if (a.message_count == 0) return;
    a.selected_message = a.message_count - 1;
    a.scroll_y = 0;
    if (a.canvas) |canvas| _ = win.InvalidateRect(canvas, null, win.TRUE);
}

fn findWacli(init: std.process.Init, allocator: std.mem.Allocator) ![]u8 {
    const local = init.environ_map.get("LOCALAPPDATA") orelse return error.MissingLocalAppData;
    return std.fs.path.join(allocator, &.{ local, "Programs", "wacli", "wacli.exe" });
}

fn storeChanged(a: *App) bool {
    if (a.store_watch_path.len == 0) return true;
    var attributes = std.mem.zeroes(win.WIN32_FILE_ATTRIBUTE_DATA);
    if (win.GetFileAttributesExW(a.store_watch_path.ptr(), win.GetFileExInfoStandard, &attributes) == 0) return false;
    const stamp = (@as(u64, attributes.ftLastWriteTime.dwHighDateTime) << 32) | attributes.ftLastWriteTime.dwLowDateTime;
    if (stamp == a.last_store_write) return false;
    a.last_store_write = stamp;
    return true;
}

fn createStoreWatchPath(init: std.process.Init, allocator: std.mem.Allocator) ![]u8 {
    const home = init.environ_map.get("USERPROFILE") orelse return error.MissingUserProfile;
    return std.fs.path.join(allocator, &.{ home, ".wacli", "wacli.db-wal" });
}

fn createAvatarDirectory(init: std.process.Init, allocator: std.mem.Allocator) ![]u8 {
    const local = init.environ_map.get("LOCALAPPDATA") orelse return error.MissingLocalAppData;
    const messages_dir = try std.fs.path.join(allocator, &.{ local, "Messages" });
    defer allocator.free(messages_dir);
    const messages_wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, messages_dir);
    defer allocator.free(messages_wide);
    _ = win.CreateDirectoryW(messages_wide.ptr, null);
    const avatar_dir = try std.fs.path.join(allocator, &.{ messages_dir, "avatars" });
    errdefer allocator.free(avatar_dir);
    const avatar_wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, avatar_dir);
    defer allocator.free(avatar_wide);
    _ = win.CreateDirectoryW(avatar_wide.ptr, null);
    return avatar_dir;
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
    const avatar_dir = try createAvatarDirectory(init, init.gpa);
    defer init.gpa.free(avatar_dir);
    const store_watch_path = try createStoreWatchPath(init, init.gpa);
    defer init.gpa.free(store_watch_path);
    const deepgram_key = init.environ_map.get("DEEPGRAM_API_KEY") orelse "";
    var openrouter_key = init.environ_map.get("OPENROUTER_API_KEY") orelse "";
    if (openrouter_key.len == 0) {
        if (loadRegistryString(init.gpa, lit("OpenRouterApiKey"))) |stored| {
            openrouter_key = stored;
        }
    }
    var openrouter_model = init.environ_map.get("OPENROUTER_MODEL") orelse "";
    if (openrouter_model.len == 0) {
        if (loadRegistryString(init.gpa, lit("OpenRouterModel"))) |stored| {
            openrouter_model = stored;
        }
    }
    if (openrouter_model.len == 0) openrouter_model = "openai/gpt-5.6-luna";
    var app = App{ .allocator = init.gpa, .io = init.io, .instance = instance, .wacli_path = wacli_path, .avatar_dir = avatar_dir, .deepgram_configured = deepgram_key.len > 0, .deepgram_key = deepgram_key, .openrouter_key = openrouter_key, .openrouter_model = openrouter_model, .openrouter_configured = openrouter_key.len > 0, .dictation_language = loadDictationLanguage(), .font_scale = loadFontScale() };
    app.store_watch_path.set(init.gpa, store_watch_path);
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
    const media_foundation_started = win.MFStartup(win.MF_VERSION, win.MFSTARTUP_FULL) >= 0;
    defer {
        if (media_foundation_started) _ = win.MFShutdown();
    }
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
    var canvas_class = win.WNDCLASSEXW{
        .cbSize = @sizeOf(win.WNDCLASSEXW),
        .style = win.CS_HREDRAW | win.CS_VREDRAW,
        .lpfnWndProc = canvasProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = cursor,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = lit("WacliMessageCanvas"),
        .hIconSm = null,
    };
    if (win.RegisterClassExW(&canvas_class) == 0) return error.RegisterCanvasClassFailed;

    var main_class = win.WNDCLASSEXW{
        .cbSize = @sizeOf(win.WNDCLASSEXW),
        .style = win.CS_HREDRAW | win.CS_VREDRAW,
        .lpfnWndProc = mainProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = cursor,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = lit("MessagesZig"),
        .hIconSm = null,
    };
    if (win.RegisterClassExW(&main_class) == 0) return error.RegisterMainClassFailed;

    var palette_class = win.WNDCLASSEXW{
        .cbSize = @sizeOf(win.WNDCLASSEXW),
        .style = 0,
        .lpfnWndProc = paletteProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = instance,
        .hIcon = null,
        .hCursor = cursor,
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = lit("MessagesPalette"),
        .hIconSm = null,
    };
    if (win.RegisterClassExW(&palette_class) == 0) return error.RegisterPaletteClassFailed;

    const hwnd = win.CreateWindowExW(
        0,
        lit("MessagesZig"),
        lit("Wazig Messages v" ++ app_version),
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
    focusCompose(&app);

    var message: win.MSG = undefined;
    while (win.GetMessageW(&message, null, 0, 0) > 0) {
        // Scroll the conversation when the cursor is over it, no matter
        // which control holds keyboard focus.
        if (message.message == win.WM_MOUSEWHEEL and app.canvas != null) {
            const wheel_point = win.POINT{
                .x = @as(i16, @bitCast(loword(@as(usize, @bitCast(message.lParam))))),
                .y = @as(i16, @bitCast(hiword(@as(usize, @bitCast(message.lParam))))),
            };
            var canvas_rect: win.RECT = undefined;
            _ = win.GetWindowRect(app.canvas.?, &canvas_rect);
            if (wheel_point.x >= canvas_rect.left and wheel_point.x <= canvas_rect.right and wheel_point.y >= canvas_rect.top and wheel_point.y <= canvas_rect.bottom) {
                const wheel_delta: i16 = @bitCast(hiword(@as(usize, @bitCast(message.wParam))));
                app.scroll_y = std.math.clamp(app.scroll_y + @divTrunc(@as(i32, wheel_delta), 2), 0, app.max_scroll);
                _ = win.InvalidateRect(app.canvas.?, null, win.TRUE);
                continue;
            }
        }
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
    var extra_buf: [512]u16 = undefined;
    components.lpszHostName = &host_buf;
    components.dwHostNameLength = host_buf.len;
    components.lpszUrlPath = &path_buf;
    components.dwUrlPathLength = path_buf.len;
    components.lpszExtraInfo = &extra_buf;
    components.dwExtraInfoLength = extra_buf.len;
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
    if (components.dwUrlPathLength + components.dwExtraInfoLength >= path_buf.len) return error.UpdateBadUrl;
    host_buf[components.dwHostNameLength] = 0;
    // Keep query/fragment with the path; crackUrl otherwise discards them.
    std.mem.copyForwards(u16, path_buf[components.dwUrlPathLength..], extra_buf[0..components.dwExtraInfoLength]);
    const path_total = components.dwUrlPathLength + components.dwExtraInfoLength;
    path_buf[path_total] = 0;
    return httpGet(
        allocator,
        host_buf[0..components.dwHostNameLength :0].ptr,
        path_buf[0..path_total :0].ptr,
        headers,
        max_bytes,
    );
}

fn performUpdate(io: std.Io) !UpdateOutcome {
    const allocator = std.heap.page_allocator;
    const current = update.parseVersion(app_version) orelse return error.UpdateBadVersion;

    // One updater at a time across every running copy of the app.
    const mutex = win.CreateMutexW(null, win.FALSE, lit("Local\\MessagesUpdateMutex")) orelse return error.UpdateMutexFailed;
    defer _ = win.CloseHandle(mutex);
    // WAIT_ABANDONED still grants ownership (the previous holder died); treat it as acquired.
    const wait_result = win.WaitForSingleObject(mutex, 0);
    if (wait_result != win.WAIT_OBJECT_0 and wait_result != 0x80) return .none;
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
    const exe_name = std.fs.path.basename(exe_path);
    {
        const exe_old = try std.fmt.allocPrint(allocator, "{s}\\{s}.old", .{ exe_dir, exe_name });
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
    const maybe_asset = try update.pickAsset(allocator, json, &parsed);
    defer parsed.deinit();
    const asset = maybe_asset orelse return .none;
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
    const new_exe_rel = if (inner_root.len > 0)
        try std.fmt.allocPrint(allocator, "{s}/{s}", .{ inner_root, exe_name })
    else
        try allocator.dupe(u8, exe_name);
    defer allocator.free(new_exe_rel);
    _ = try stage.statFile(io, new_exe_rel, .{});

    // Swap: rename the running exe aside (always allowed on Windows), copy the
    // new files in, and roll the rename back if any copy fails.
    const exe_old = try std.fmt.allocPrint(allocator, "{s}\\{s}.old", .{ exe_dir, exe_name });
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
    // Rollback: restore the old executable (the install files are untouched
    // thanks to the two-phase copy).
    _ = win.MoveFileExW(exe_old_wide.ptr, exe_wide.ptr, win.MOVEFILE_REPLACE_EXISTING);
    return error.UpdateCopyFailed;
}

/// Copies every staged file (below `inner_root` inside `stage_path`) into
/// `exe_dir`. Copies go to temporary names and are renamed into place only
/// after every copy succeeded, so a failure leaves the existing files intact;
/// the caller additionally restores the renamed backup of the executable.
fn installStagedFiles(io: std.Io, allocator: std.mem.Allocator, stage: std.Io.Dir, stage_path: []const u8, inner_root: []const u8, exe_dir: []const u8) bool {
    const Pending = struct { temp: [:0]u16, dest: [:0]u16 };
    // Two-phase install: copy every file to "<dest>.new", then rename them into
    // place only after all copies succeeded, so a failed copy never leaves a
    // mixed-version install behind.
    var pending: std.ArrayList(Pending) = .empty;
    defer {
        for (pending.items) |p| {
            allocator.free(p.temp);
            allocator.free(p.dest);
        }
        pending.deinit(allocator);
    }
    var walker = stage.walk(allocator) catch return false;
    defer walker.deinit();
    while (walker.next(io) catch return false) |entry| {
        if (entry.kind != .file) continue;
        const relative = if (inner_root.len > 0 and std.mem.startsWith(u8, entry.path, inner_root))
            entry.path[inner_root.len + 1 ..]
        else
            entry.path;
        // Normalize separators first so the traversal guard sees both spellings.
        var relative_buf: [512]u8 = undefined;
        if (relative.len >= relative_buf.len) return false;
        for (relative, 0..) |c, i| relative_buf[i] = if (c == '\\') '/' else c;
        const normalized = relative_buf[0..relative.len];
        // Never install anything that escapes the application directory.
        var components = std.mem.splitScalar(u8, normalized, '/');
        while (components.next()) |component| {
            if (std.mem.eql(u8, component, "..")) return false;
        }
        var windows_relative_buf: [512]u8 = undefined;
        for (normalized, 0..) |c, i| windows_relative_buf[i] = if (c == '/') '\\' else c;
        const windows_relative = windows_relative_buf[0..normalized.len];
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
        const temp = std.fmt.allocPrint(allocator, "{s}.new", .{destination}) catch return false;
        defer allocator.free(temp);
        const temp_wide = utf8ToWide(allocator, temp) catch return false;
        if (win.CopyFileW(source_wide.ptr, temp_wide.ptr, win.FALSE) == 0) return false;
        pending.append(allocator, .{ .temp = temp_wide, .dest = destination_wide }) catch return false;
    }
    for (pending.items) |p| {
        if (win.MoveFileExW(p.temp.ptr, p.dest.ptr, win.MOVEFILE_REPLACE_EXISTING) == 0) {
            // Best-effort cleanup of the not-yet-renamed temps.
            for (pending.items) |q| {
                if (q.temp.ptr != p.temp.ptr) _ = win.DeleteFileW(q.temp.ptr);
            }
            return false;
        }
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
