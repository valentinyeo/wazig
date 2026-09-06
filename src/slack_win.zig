// Slack Windows transport: WinHTTP REST client, Socket Mode websocket thread,
// DPAPI-protected token storage, and file upload/download. Windows only; the
// pure JSON logic lives in slack.zig so it stays unit-testable on any host.
const std = @import("std");
const builtin = @import("builtin");
const slack = @import("slack.zig");

pub const enabled = builtin.os.tag == .windows;

const win = if (enabled)
    @cImport({
        @cDefine("WIN32_LEAN_AND_MEAN", "1");
        @cDefine("NOMINMAX", "1");
        @cInclude("windows.h");
        @cInclude("winhttp.h");
        @cInclude("dpapi.h");
    })
else
    struct {};

// Fallbacks in case the SDK headers are missing the newer winhttp constants.
const option_upgrade_to_web_socket = 114;
const web_socket_utf8_message: c_int = 0;
const web_socket_utf8_fragment: c_int = 1;
const web_socket_binary_message: c_int = 2;
const web_socket_binary_fragment: c_int = 3;
const web_socket_close: c_int = 4;
const web_socket_success_close_status: c_ushort = 1000;

pub const Tokens = struct {
    user: []u8,
    app: []u8,
};

pub const max_download_bytes: u64 = 100 * 1024 * 1024;

pub fn isUserToken(token: []const u8) bool {
    return std.mem.startsWith(u8, token, "xoxp-") and token.len >= 20 and token.len <= 512;
}

pub fn isAppToken(token: []const u8) bool {
    return std.mem.startsWith(u8, token, "xapp-") and token.len >= 20 and token.len <= 512;
}

// --- registry storage with DPAPI encryption ---

const DATA_BLOB = extern struct {
    cbData: win.DWORD,
    pbData: ?[*]u8,
};

extern "crypt32" fn CryptProtectData(data_in: *const DATA_BLOB, name: ?[*:0]const u16, entropy: ?*const DATA_BLOB, reserved: ?*anyopaque, prompt: ?*anyopaque, flags: win.DWORD, data_out: *DATA_BLOB) win.BOOL;
extern "crypt32" fn CryptUnprotectData(data_in: *const DATA_BLOB, name: ?*?[*:0]u16, entropy: ?*const DATA_BLOB, reserved: ?*anyopaque, prompt: ?*anyopaque, flags: win.DWORD, data_out: *DATA_BLOB) win.BOOL;

fn wideLiteral(comptime text: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

fn protect(allocator: std.mem.Allocator, plain: []const u8) ?[]u8 {
    if (!enabled) return null;
    var in = DATA_BLOB{ .cbData = @intCast(plain.len), .pbData = @constCast(plain.ptr) };
    var out = DATA_BLOB{ .cbData = 0, .pbData = null };
    if (CryptProtectData(&in, null, null, null, null, 0, &out) == 0) return null;
    const bytes = allocator.dupe(u8, out.pbData.?[0..out.cbData]) catch null;
    _ = win.LocalFree(out.pbData);
    return bytes;
}

fn unprotect(allocator: std.mem.Allocator, blob: []const u8) ?[]u8 {
    if (!enabled) return null;
    var in = DATA_BLOB{ .cbData = @intCast(blob.len), .pbData = @constCast(blob.ptr) };
    var out = DATA_BLOB{ .cbData = 0, .pbData = null };
    if (CryptUnprotectData(&in, null, null, null, null, 0, &out) == 0) return null;
    const bytes = allocator.dupe(u8, out.pbData.?[0..out.cbData]) catch null;
    _ = win.LocalFree(out.pbData);
    return bytes;
}

fn regSetBinary(name: [*:0]const u16, blob: []const u8) bool {
    var key: win.HKEY = null;
    if (win.RegCreateKeyExW(winHandleHkey(0x80000001), wideLiteral("Software\\Messages"), 0, null, 0, win.KEY_SET_VALUE, null, &key, null) != win.ERROR_SUCCESS) return false;
    defer _ = win.RegCloseKey(key);
    return win.RegSetValueExW(key, name, 0, win.REG_BINARY, @ptrCast(@constCast(blob.ptr)), @intCast(blob.len)) == win.ERROR_SUCCESS;
}

fn regGetBinary(allocator: std.mem.Allocator, name: [*:0]const u16) ?[]u8 {
    var size: win.DWORD = 0;
    if (win.RegGetValueW(winHandleHkey(0x80000001), wideLiteral("Software\\Messages"), name, win.RRF_RT_REG_BINARY, null, null, &size) != win.ERROR_SUCCESS or size == 0 or size > 64 * 1024) return null;
    const blob = allocator.alloc(u8, size) catch return null;
    var real_size = size;
    if (win.RegGetValueW(winHandleHkey(0x80000001), wideLiteral("Software\\Messages"), name, win.RRF_RT_REG_BINARY, null, blob.ptr, &real_size) != win.ERROR_SUCCESS) {
        allocator.free(blob);
        return null;
    }
    const shrunk = allocator.realloc(blob, real_size) catch return blob[0..real_size];
    return shrunk;
}

fn regDelete(name: [*:0]const u16) void {
    var key: win.HKEY = null;
    if (win.RegCreateKeyExW(winHandleHkey(0x80000001), wideLiteral("Software\\Messages"), 0, null, 0, win.KEY_SET_VALUE, null, &key, null) != win.ERROR_SUCCESS) return;
    defer _ = win.RegCloseKey(key);
    _ = win.RegDeleteValueW(key, name);
}

fn winHandleHkey(value: usize) win.HKEY {
    return @ptrFromInt(value);
}

pub fn saveTokens(user: []const u8, app: []const u8) bool {
    const allocator = std.heap.page_allocator;
    const user_blob = protect(allocator, user) orelse return false;
    defer allocator.free(user_blob);
    const app_blob = protect(allocator, app) orelse return false;
    defer allocator.free(app_blob);
    return regSetBinary(wideLiteral("SlackUserToken"), user_blob) and regSetBinary(wideLiteral("SlackAppToken"), app_blob);
}

pub fn clearTokens() void {
    regDelete(wideLiteral("SlackUserToken"));
    regDelete(wideLiteral("SlackAppToken"));
}

pub fn loadTokens(allocator: std.mem.Allocator) ?Tokens {
    if (!enabled) return null;
    const user_blob = regGetBinary(allocator, wideLiteral("SlackUserToken")) orelse return null;
    defer allocator.free(user_blob);
    const app_blob = regGetBinary(allocator, wideLiteral("SlackAppToken")) orelse return null;
    defer allocator.free(app_blob);
    const user = unprotect(allocator, user_blob) orelse return null;
    const app = unprotect(allocator, app_blob) orelse {
        allocator.free(user);
        return null;
    };
    if (!isUserToken(user) or !isAppToken(app)) {
        allocator.free(user);
        allocator.free(app);
        return null;
    }
    return .{ .user = user, .app = app };
}

// --- WinHTTP REST ---

pub const Response = struct {
    status: u32 = 0,
    body: []u8 = &.{},
    headers: []u8 = &.{}, // raw header block, CRLF-separated

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        if (self.body.len > 0) allocator.free(self.body);
        if (self.headers.len > 0) allocator.free(self.headers);
        self.body = &.{};
        self.headers = &.{};
    }
};

fn toWide(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

/// Host portion of an https URL (no scheme, no path), borrowed from `url`.
fn urlHost(url: []const u8) []const u8 {
    const scheme_end = std.mem.indexOf(u8, url, "://") orelse return "";
    const host_start = scheme_end + 3;
    const path_start = std.mem.indexOfScalarPos(u8, url, host_start, '/') orelse url.len;
    var host = url[host_start..path_start];
    if (std.mem.indexOfScalar(u8, host, '@')) |at| host = host[at + 1 ..]; // strip userinfo
    if (std.mem.indexOfScalar(u8, host, ':')) |colon| host = host[0..colon]; // strip port
    return host;
}

fn readResponse(allocator: std.mem.Allocator, request: win.HINTERNET, max_bytes: usize) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    while (out.items.len < max_bytes) {
        var available: win.DWORD = 0;
        if (win.WinHttpQueryDataAvailable(request, &available) == 0) break;
        if (available == 0) break;
        const old_len = out.items.len;
        try out.resize(allocator, old_len + available);
        var read: win.DWORD = 0;
        if (win.WinHttpReadData(request, out.items.ptr + old_len, available, &read) == 0) return error.NetworkFailed;
        if (read == 0) {
            out.shrinkRetainingCapacity(old_len);
            break;
        }
        out.shrinkRetainingCapacity(old_len + read);
    }
    return out.toOwnedSlice(allocator);
}

/// One HTTPS call to slack.com/api. `body` null means GET. Returns the status
/// and body; Slack's own "ok" flag is checked by the caller through the job
/// runner. 429 responses surface with their status so the caller can honor
/// Retry-After.
pub fn callApi(allocator: std.mem.Allocator, token: []const u8, method: []const u8, path_query: []const u8, body: ?[]const u8) !Response {
    if (!enabled) return error.Unsupported;
    const wide_path = try toWide(allocator, path_query);
    defer allocator.free(wide_path);
    const wide_method = try toWide(allocator, if (std.mem.eql(u8, method, "GET")) "GET" else "POST");
    defer allocator.free(wide_method);

    const session = win.WinHttpOpen(wideLiteral("Wazig Messages/1.0"), win.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(session);
    _ = win.WinHttpSetTimeouts(session, 10_000, 10_000, 30_000, 60_000);
    const connection = win.WinHttpConnect(session, wideLiteral("slack.com"), win.INTERNET_DEFAULT_HTTPS_PORT, 0) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(connection);
    const request = win.WinHttpOpenRequest(connection, wide_method.ptr, wide_path.ptr, null, null, null, win.WINHTTP_FLAG_SECURE) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(request);

    var headers = std.ArrayList(u16).empty;
    defer headers.deinit(allocator);
    try headers.appendSlice(allocator, std.unicode.utf8ToUtf16LeStringLiteral("Authorization: Bearer "));
    for (token) |char| try headers.append(allocator, char);
    try headers.appendSlice(allocator, std.unicode.utf8ToUtf16LeStringLiteral("\r\nContent-Type: application/json; charset=utf-8\r\n"));
    try headers.append(allocator, 0);
    if (body) |payload| {
        if (win.WinHttpSendRequest(request, headers.items.ptr, @intCast(headers.items.len - 1), @constCast(payload.ptr), @intCast(payload.len), @intCast(payload.len), 0) == 0) return error.NetworkFailed;
    } else {
        if (win.WinHttpSendRequest(request, headers.items.ptr, @intCast(headers.items.len - 1), null, 0, 0, 0) == 0) return error.NetworkFailed;
    }
    if (win.WinHttpReceiveResponse(request, null) == 0) return error.NetworkFailed;
    var status: win.DWORD = 0;
    var status_size: win.DWORD = @sizeOf(win.DWORD);
    _ = win.WinHttpQueryHeaders(request, win.WINHTTP_QUERY_STATUS_CODE | win.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null);
    const data = try readResponse(allocator, request, 32 * 1024 * 1024);
    var header_size: win.DWORD = 0;
    _ = win.WinHttpQueryHeaders(request, win.WINHTTP_QUERY_RAW_HEADERS_CRLF, null, null, &header_size, 0);
    var raw_headers: []u8 = &.{};
    if (header_size > 0) {
        const wide_headers = allocator.alloc(u16, header_size) catch null;
        if (wide_headers) |wh| {
            var real = header_size;
            if (win.WinHttpQueryHeaders(request, win.WINHTTP_QUERY_RAW_HEADERS_CRLF, null, wh.ptr, &real, 0) != 0) {
                if (std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(@as([*:0]const u16, @ptrCast(wh))))) |narrow| {
                    raw_headers = narrow;
                } else |_| {}
            }
            allocator.free(wh);
        }
    }
    return .{ .status = status, .body = data, .headers = raw_headers };
}

/// PUT raw bytes to Slack's pre-signed upload host. Never sends the bearer
/// token: the upload URL is the credential for this call.
pub fn putFile(allocator: std.mem.Allocator, url: []const u8, bytes: []const u8) !void {
    if (!enabled) return error.Unsupported;
    if (!std.mem.startsWith(u8, url, "https://")) return error.UntrustedUrl;
    const scheme_end = std.mem.indexOf(u8, url, "://").?;
    const host_start = scheme_end + 3;
    const path_start = std.mem.indexOfScalarPos(u8, url, host_start, '/') orelse return error.UntrustedUrl;
    const wide_host = try toWide(allocator, url[host_start..path_start]);
    defer allocator.free(wide_host);
    const wide_path = try toWide(allocator, url[path_start..]);
    defer allocator.free(wide_path);

    const session = win.WinHttpOpen(wideLiteral("Wazig Messages/1.0"), win.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(session);
    _ = win.WinHttpSetTimeouts(session, 10_000, 10_000, 60_000, 300_000);
    const connection = win.WinHttpConnect(session, wide_host.ptr, win.INTERNET_DEFAULT_HTTPS_PORT, 0) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(connection);
    const request = win.WinHttpOpenRequest(connection, wideLiteral("PUT"), wide_path.ptr, null, null, null, win.WINHTTP_FLAG_SECURE) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(request);
    const content_type = std.unicode.utf8ToUtf16LeStringLiteral("Content-Type: application/octet-stream\r\n");
    if (win.WinHttpSendRequest(request, content_type.ptr, @intCast(content_type.len), @constCast(bytes.ptr), @intCast(bytes.len), @intCast(bytes.len), 0) == 0) return error.NetworkFailed;
    if (win.WinHttpReceiveResponse(request, null) == 0) return error.NetworkFailed;
    var status: win.DWORD = 0;
    var status_size: win.DWORD = @sizeOf(win.DWORD);
    _ = win.WinHttpQueryHeaders(request, win.WINHTTP_QUERY_STATUS_CODE | win.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null);
    if (status < 200 or status >= 300) return error.UploadRejected;
}

/// Download a Slack file (bearer-authenticated) to dest_path. Only HTTPS
/// hosts under slack.com receive the Authorization header, and the size is
/// capped so a runaway file cannot fill the disk.
pub fn downloadTo(allocator: std.mem.Allocator, token: []const u8, url: []const u8, dest_path: []const u8) !void {
    if (!enabled) return error.Unsupported;
    if (!std.mem.startsWith(u8, url, "https://")) return error.UntrustedUrl;
    const host = urlHost(url);
    if (!std.mem.endsWith(u8, host, "slack.com")) return error.UntrustedUrl;
    const scheme_end = std.mem.indexOf(u8, url, "://").?;
    const host_start = scheme_end + 3;
    const path_start = std.mem.indexOfScalarPos(u8, url, host_start, '/') orelse return error.UntrustedUrl;
    const wide_host = try toWide(allocator, url[host_start..path_start]);
    defer allocator.free(wide_host);
    const wide_path = try toWide(allocator, url[path_start..]);
    defer allocator.free(wide_path);
    const wide_dest = try toWide(allocator, dest_path);
    defer allocator.free(wide_dest);

    const session = win.WinHttpOpen(wideLiteral("Wazig Messages/1.0"), win.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(session);
    _ = win.WinHttpSetTimeouts(session, 10_000, 10_000, 30_000, 600_000);
    const connection = win.WinHttpConnect(session, wide_host.ptr, win.INTERNET_DEFAULT_HTTPS_PORT, 0) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(connection);
    const request = win.WinHttpOpenRequest(connection, wideLiteral("GET"), wide_path.ptr, null, null, null, win.WINHTTP_FLAG_SECURE) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(request);
    var headers = std.ArrayList(u16).empty;
    defer headers.deinit(allocator);
    try headers.appendSlice(allocator, std.unicode.utf8ToUtf16LeStringLiteral("Authorization: Bearer "));
    for (token) |char| try headers.append(allocator, char);
    try headers.appendSlice(allocator, std.unicode.utf8ToUtf16LeStringLiteral("\r\n"));
    try headers.append(allocator, 0);
    if (win.WinHttpSendRequest(request, headers.items.ptr, @intCast(headers.items.len - 1), null, 0, 0, 0) == 0) return error.NetworkFailed;
    if (win.WinHttpReceiveResponse(request, null) == 0) return error.NetworkFailed;
    var status: win.DWORD = 0;
    var status_size: win.DWORD = @sizeOf(win.DWORD);
    _ = win.WinHttpQueryHeaders(request, win.WINHTTP_QUERY_STATUS_CODE | win.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null);
    if (status != 200) return error.DownloadRejected;

    const file = win.CreateFileW(wide_dest.ptr, win.GENERIC_WRITE, 0, null, win.CREATE_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (file == win.INVALID_HANDLE_VALUE or file == null) return error.WriteFailed;
    defer _ = win.CloseHandle(file);
    var total: u64 = 0;
    var buffer: [256 * 1024]u8 = undefined;
    while (true) {
        var read: win.DWORD = 0;
        if (win.WinHttpReadData(request, &buffer, buffer.len, &read) == 0) return error.NetworkFailed;
        if (read == 0) break;
        total += read;
        if (total > max_download_bytes) return error.TooLarge;
        var written: win.DWORD = 0;
        if (win.WriteFile(file, &buffer, read, &written, null) == 0) return error.WriteFailed;
    }
}

// --- Socket Mode websocket ---

pub const Socket = struct {
    session: win.HINTERNET,
    connection: win.HINTERNET,
    request: win.HINTERNET,
    socket: win.HINTERNET,
};

/// Connect to a wss:// endpoint from apps.connections.open using WinHTTP's
/// native WebSocket upgrade.
pub fn socketConnect(allocator: std.mem.Allocator, endpoint: slack.WsEndpoint) !Socket {
    if (!enabled) return error.Unsupported;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const wide_host = try toWide(arena.allocator(), endpoint.host);
    const wide_path = try toWide(arena.allocator(), endpoint.path_query);

    const session = win.WinHttpOpen(wideLiteral("Wazig Messages/1.0"), win.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse return error.NetworkFailed;
    errdefer _ = win.WinHttpCloseHandle(session);
    _ = win.WinHttpSetTimeouts(session, 10_000, 10_000, 30_000, 0); // receive timeout 0: no deadline while idle
    const connection = win.WinHttpConnect(session, wide_host.ptr, win.INTERNET_DEFAULT_HTTPS_PORT, 0) orelse return error.NetworkFailed;
    errdefer _ = win.WinHttpCloseHandle(connection);
    const request = win.WinHttpOpenRequest(connection, wideLiteral("GET"), wide_path.ptr, null, null, null, win.WINHTTP_FLAG_SECURE) orelse return error.NetworkFailed;
    errdefer _ = win.WinHttpCloseHandle(request);
    var upgrade: win.BOOL = 1;
    if (win.WinHttpSetOption(request, option_upgrade_to_web_socket, &upgrade, @sizeOf(win.BOOL)) == 0) return error.WebSocketUnsupported;
    if (win.WinHttpSendRequest(request, null, 0, null, 0, 0, 0) == 0) return error.NetworkFailed;
    if (win.WinHttpReceiveResponse(request, null) == 0) return error.NetworkFailed;
    var status: win.DWORD = 0;
    var status_size: win.DWORD = @sizeOf(win.DWORD);
    _ = win.WinHttpQueryHeaders(request, win.WINHTTP_QUERY_STATUS_CODE | win.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &status_size, null);
    if (status != 101 and status != 200) return error.WebSocketRejected;
    const socket = win.WinHttpWebSocketCompleteUpgrade(request, 0) orelse return error.NetworkFailed;
    return .{ .session = session, .connection = connection, .request = request, .socket = socket };
}

pub fn socketClose(sock: Socket) void {
    if (enabled) {
        _ = win.WinHttpWebSocketClose(sock.socket, web_socket_success_close_status, null, 0);
        _ = win.WinHttpCloseHandle(sock.socket);
        _ = win.WinHttpCloseHandle(sock.request);
        _ = win.WinHttpCloseHandle(sock.connection);
        _ = win.WinHttpCloseHandle(sock.session);
    }
}

pub fn socketSend(allocator: std.mem.Allocator, sock: Socket, bytes: []const u8) !void {
    if (!enabled) return error.Unsupported;
    const wide_free = false;
    _ = allocator;
    _ = wide_free;
    // WebSocket calls return a DWORD error code; 0 (NO_ERROR) means success.
    if (win.WinHttpWebSocketSend(sock.socket, web_socket_utf8_message, @constCast(bytes.ptr), @intCast(bytes.len)) != 0) return error.NetworkFailed;
}

/// Receive one complete websocket message (across fragments) into buf.
/// Returns the slice. A close frame returns error.Closed.
pub fn socketReceive(sock: Socket, buf: []u8) ![]u8 {
    if (!enabled) return error.Unsupported;
    var offset: usize = 0;
    while (true) {
        if (offset >= buf.len) return error.TooLarge;
        var kind: c_int = 0;
        var read: win.DWORD = 0;
        if (win.WinHttpWebSocketReceive(sock.socket, buf.ptr + offset, @intCast(buf.len - offset), &read, @ptrCast(&kind)) != 0) return error.NetworkFailed;
        offset += read;
        if (kind == web_socket_close) return error.Closed;
        if (kind == web_socket_utf8_message or kind == web_socket_binary_message) return buf[0..offset];
        if (kind != web_socket_utf8_fragment and kind != web_socket_binary_fragment) return error.Closed;
    }
}

// --- event handed to the UI thread ---

/// Deep-copied Socket Mode message event. Lives on the heap from the socket
/// thread until the UI thread frees it.
pub const Event = struct {
    channel: [slack.max_channel_id + 1]u8 = undefined,
    channel_len: u8 = 0,
    ts: [40]u8 = undefined,
    ts_len: u8 = 0,
    thread_ts: [40]u8 = undefined,
    thread_ts_len: u8 = 0,
    user: [slack.max_user_id + 1]u8 = undefined,
    user_len: u8 = 0,
    text: [slack.max_text + 1]u8 = undefined,
    text_len: u16 = 0,
    file_id: [32]u8 = undefined,
    file_id_len: u8 = 0,
    file_url: [512]u8 = undefined,
    file_url_len: u16 = 0,
    file_name: [259]u8 = undefined,
    file_name_len: u16 = 0,
    file_mime: [95]u8 = undefined,
    file_mime_len: u8 = 0,
    file_size: i64 = 0,

    pub fn channelSlice(self: *const Event) []const u8 {
        return self.channel[0..self.channel_len];
    }
    pub fn tsSlice(self: *const Event) []const u8 {
        return self.ts[0..self.ts_len];
    }
    pub fn threadTsSlice(self: *const Event) []const u8 {
        return self.thread_ts[0..self.thread_ts_len];
    }
    pub fn userSlice(self: *const Event) []const u8 {
        return self.user[0..self.user_len];
    }
    pub fn textSlice(self: *const Event) []const u8 {
        return self.text[0..self.text_len];
    }
    pub fn fileIdSlice(self: *const Event) []const u8 {
        return self.file_id[0..self.file_id_len];
    }
    pub fn fileUrlSlice(self: *const Event) []const u8 {
        return self.file_url[0..self.file_url_len];
    }
    pub fn fileNameSlice(self: *const Event) []const u8 {
        return self.file_name[0..self.file_name_len];
    }
    pub fn fileMimeSlice(self: *const Event) []const u8 {
        return self.file_mime[0..self.file_mime_len];
    }
};

fn copyInto(dest: anytype, dest_len: anytype, source: []const u8) void {
    if (@TypeOf(dest_len.*) == u8) {
        const taken = @min(source.len, dest.len);
        @memcpy(dest[0..taken], source[0..taken]);
        dest_len.* = @intCast(taken);
        return;
    }
    const taken = @min(source.len, dest.len);
    @memcpy(dest[0..taken], source[0..taken]);
    dest_len.* = @intCast(taken);
}

pub const EventSink = struct {
    hwnd: *anyopaque, // win.HWND as opaque to keep this module UI-free
    message_id: u32,
    queue: *std.atomic.Value(usize), // number of events posted but not yet consumed
};

/// Build a heap Event from classified envelope fields; returns null when the
/// event carries nothing displayable.
pub fn buildEvent(envelope: slack.Envelope) ?*Event {
    if (envelope.channel.len == 0 or envelope.ts.len == 0) return null;
    if (envelope.ts.len != envelope.thread_ts.len or !std.mem.eql(u8, envelope.ts, envelope.thread_ts)) {
        // A thread reply: still displayable.
    }
    const event = std.heap.page_allocator.create(Event) catch return null;
    event.* = .{};
    copyInto(&event.channel, &event.channel_len, envelope.channel);
    copyInto(&event.ts, &event.ts_len, envelope.ts);
    copyInto(&event.thread_ts, &event.thread_ts_len, envelope.thread_ts);
    copyInto(&event.user, &event.user_len, envelope.user);
    copyInto(&event.text, &event.text_len, envelope.text);
    copyInto(&event.file_id, &event.file_id_len, envelope.file_id);
    copyInto(&event.file_url, &event.file_url_len, envelope.file_url);
    copyInto(&event.file_name, &event.file_name_len, envelope.file_name);
    copyInto(&event.file_mime, &event.file_mime_len, envelope.file_mime);
    event.file_size = envelope.file_size;
    return event;
}

pub fn destroyEvent(event: *Event) void {
    std.heap.page_allocator.destroy(event);
}

// --- background Socket Mode session ---

pub const SocketConfig = struct {
    user_token: []const u8,
    app_token: []const u8,
    stop: *std.atomic.Value(bool),
    sink: EventSink,
    connected: *std.atomic.Value(bool),
};

/// Reconnect with fresh URLs forever until stopped. Each cycle: fetch a new
/// wss URL (old ones expire), connect, ACK every envelope immediately, then
/// hand displayable messages to the UI thread.
pub fn socketThreadMain(config: SocketConfig) void {
    var backoff_seconds: u64 = 1;
    while (!config.stop.load(.acquire)) {
        var connected_here = false;
        runOneSession(config, &connected_here) catch {};
        _ = config.connected.swap(false, .acq_rel);
        if (config.stop.load(.acquire)) return;
        // Fresh connections reset the backoff; failures grow it.
        win.Sleep(@intCast(if (connected_here) 1000 else backoff_seconds * 1000));
        backoff_seconds = @min(if (connected_here) @as(u64, 1) else backoff_seconds * 2, 30);
    }
}

fn runOneSession(config: SocketConfig, connected_here: *bool) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const response = try callApi(arena, config.app_token, "POST", "/api/apps.connections.open", null);
    if (response.status != 200) return error.HttpFailed;
    const endpoint = slack.parseWsUrl(arena, response.body) orelse return error.BadHandshake;
    const sock = try socketConnect(arena, endpoint);
    defer socketClose(sock);
    connected_here.* = true;
    _ = config.connected.swap(true, .acq_rel);

    var buffer: [128 * 1024]u8 = undefined;
    while (!config.stop.load(.acquire)) {
        const message = socketReceive(sock, &buffer) catch |err| return err;
        var classify_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer classify_arena.deinit();
        const envelope = (slack.classifyEnvelope(classify_arena.allocator(), message) catch return error.BadEnvelope) orelse continue;
        // ACK before any parsing/UI work so Slack does not redeliver. A real
        // event envelope carries both envelope_id and an event object, so the
        // decision to ACK must not depend on the classified kind.
        if (envelope.envelope_id.len > 0) {
            const ack = slack.buildAckBody(classify_arena.allocator(), envelope.envelope_id) catch return error.OutOfMemory;
            socketSend(classify_arena.allocator(), sock, ack) catch return error.NetworkFailed;
        }
        if (envelope.kind != .events) continue;
        if (!std.mem.eql(u8, envelope.event_type, "message")) continue;
        const event = buildEvent(envelope) orelse continue;
        _ = config.sink.queue.fetchAdd(1, .acq_rel);
        const hwnd: win.HWND = @ptrFromInt(@intFromPtr(config.sink.hwnd));
        if (win.PostMessageW(hwnd, config.sink.message_id, 0, @bitCast(@intFromPtr(event))) == 0) {
            _ = config.sink.queue.fetchSub(1, .acq_rel);
            destroyEvent(event);
        }
    }
}

// --- worker-thread jobs (run on the shared background queue) ---

pub const JobKind = enum(u8) {
    workspace, // conversations.list page: args = [types, cursor]
    users, // users.list page: args = [cursor]
    history, // conversations.history: args = [channel]
    replies, // conversations.replies: args = [channel, parent_ts]
    send_text, // chat.postMessage: args = [channel, text, thread_ts]
    send_image, // 3-step upload: args = [channel, thread_ts, file_path]
    download, // file to media cache: args = [url, file_id, filename, channel, ts]
    auth, // auth.test: no args
};

pub const JobContext = struct {
    user_token: []const u8,
    media_dir: []const u8,
    io: std.Io,
};

fn ensureMediaDir(dir: []const u8) !void {
    const wide = try toWide(std.heap.page_allocator, dir);
    defer std.heap.page_allocator.free(wide);
    _ = win.CreateDirectoryW(wide.ptr, null);
}

fn httpOk(allocator: std.mem.Allocator, body: []const u8) bool {
    return slack.responseIsOk(allocator, body);
}

/// Run one Slack HTTP job on the worker thread. Returns heap-allocated
/// response data (raw JSON, or the local file path for downloads).
/// One 429 retry honoring Retry-After, capped at 30 seconds.
pub fn runJob(allocator: std.mem.Allocator, ctx: JobContext, kind: JobKind, args: []const []const u8) ![]u8 {
    switch (kind) {
        .workspace => {
            var path = std.ArrayList(u8).empty;
            defer path.deinit(allocator);
            try path.appendSlice(allocator, "/api/conversations.list?limit=200&types=");
            try path.appendSlice(allocator, if (args.len > 0) args[0] else "public_channel,private_channel,im");
            if (args.len > 1 and args[1].len > 0) {
                const encoded = try slack.percentEncode(allocator, args[1]);
                defer allocator.free(encoded);
                try path.appendSlice(allocator, "&cursor=");
                try path.appendSlice(allocator, encoded);
            }
            return (try callWithRetry(allocator, ctx.user_token, path.items, null)).body;
        },
        .users => {
            var path = std.ArrayList(u8).empty;
            defer path.deinit(allocator);
            try path.appendSlice(allocator, "/api/users.list?limit=200");
            if (args.len > 0 and args[0].len > 0) {
                const encoded = try slack.percentEncode(allocator, args[0]);
                defer allocator.free(encoded);
                try path.appendSlice(allocator, "&cursor=");
                try path.appendSlice(allocator, encoded);
            }
            return (try callWithRetry(allocator, ctx.user_token, path.items, null)).body;
        },
        .history => {
            var path = std.ArrayList(u8).empty;
            defer path.deinit(allocator);
            try path.appendSlice(allocator, "/api/conversations.history?limit=80&channel=");
            try path.appendSlice(allocator, if (args.len > 0) args[0] else "");
            return (try callWithRetry(allocator, ctx.user_token, path.items, null)).body;
        },
        .replies => {
            var path = std.ArrayList(u8).empty;
            defer path.deinit(allocator);
            try path.appendSlice(allocator, "/api/conversations.replies?limit=100&channel=");
            try path.appendSlice(allocator, if (args.len > 0) args[0] else "");
            if (args.len > 1) {
                try path.appendSlice(allocator, "&ts=");
                try path.appendSlice(allocator, args[1]);
            }
            return (try callWithRetry(allocator, ctx.user_token, path.items, null)).body;
        },
        .send_text => {
            if (args.len < 3) return error.BadArguments;
            const body = try slack.buildPostMessageBody(allocator, .{ .channel_id = args[0], .text = args[1], .thread_ts = args[2] });
            defer allocator.free(body);
            var response = try callWithRetry(allocator, ctx.user_token, "/api/chat.postMessage", body);
            errdefer response.deinit(allocator);
            if (response.status == 200 and !httpOk(allocator, response.body)) return error.SlackRejected;
            if (response.status != 200) return error.HttpFailed;
            return response.body;
        },
        .send_image => {
            if (args.len < 4) return error.BadArguments;
            return uploadImage(allocator, ctx, args[0], args[1], args[2], args[3]);
        },
        .auth => {
            var response = try callWithRetry(allocator, ctx.user_token, "/api/auth.test", null);
            errdefer response.deinit(allocator);
            if (response.status != 200) return error.HttpFailed;
            if (!httpOk(allocator, response.body)) return error.SlackRejected;
            return response.body;
        },
        .download => {
            if (args.len < 5) return error.BadArguments;
            try ensureMediaDir(ctx.media_dir);
            var name_buffer: [128]u8 = undefined;
            const safe_name = slack.sanitizeFilename(&name_buffer, args[2]);
            var dest = std.ArrayList(u8).empty;
            defer dest.deinit(allocator);
            try dest.appendSlice(allocator, ctx.media_dir);
            try dest.append(allocator, '\\');
            try dest.appendSlice(allocator, args[3]); // channel id
            try dest.append(allocator, '-');
            try dest.appendSlice(allocator, args[4]); // message ts
            try dest.append(allocator, '-');
            try dest.appendSlice(allocator, args[1]); // file id
            // Generated name: channel, ts and file id are collision-free and
            // trusted; only the suffix comes from the remote name.
            const dot = std.mem.lastIndexOfScalar(u8, safe_name, '.');
            const suffix = if (dot) |dot_index| safe_name[dot_index..] else "";
            if (suffix.len > 0) {
                try dest.appendSlice(allocator, suffix);
            } else if (safe_name.len > 0) {
                try dest.append(allocator, '-');
                try dest.appendSlice(allocator, safe_name);
            }
            try downloadTo(allocator, ctx.user_token, args[0], dest.items);
            return allocator.dupe(u8, dest.items);
        },
    }
}

fn callWithRetry(allocator: std.mem.Allocator, token: []const u8, path: []const u8, body: ?[]const u8) !Response {
    var response = try callApi(allocator, token, if (body == null) "GET" else "POST", path, body);
    if (response.status == 429) {
        const wait_seconds = slack.parseRetryAfter(response.headers) orelse 5;
        response.deinit(allocator);
        win.Sleep(@intCast(@as(u64, @min(wait_seconds, 30)) * 1000));
        response = try callApi(allocator, token, if (body == null) "GET" else "POST", path, body);
    }
    return response;
}

fn uploadImage(allocator: std.mem.Allocator, ctx: JobContext, channel: []const u8, thread_ts: []const u8, file_path: []const u8, caption: []const u8) ![]u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(ctx.io, file_path, allocator, .limited(max_download_bytes)) catch return error.ReadFailed;
    defer allocator.free(bytes);
    const base = std.fs.path.basename(file_path);
    var name_buffer: [128]u8 = undefined;
    const safe_name = slack.sanitizeFilename(&name_buffer, base);
    const safe = if (safe_name.len > 0) safe_name else "image";

    var start_path = std.ArrayList(u8).empty;
    defer start_path.deinit(allocator);
    try start_path.appendSlice(allocator, "/api/files.getUploadURLExternal");
    var start_body = std.ArrayList(u8).empty;
    defer start_body.deinit(allocator);
    const escaped_name = try slack.escapeJson(allocator, safe);
    defer allocator.free(escaped_name);
    const body = try std.fmt.allocPrint(allocator, "{{\"filename\":\"{s}\",\"length\":{d}}}", .{ escaped_name, bytes.len });
    defer allocator.free(body);
    var grant_response = try callWithRetry(allocator, ctx.user_token, start_path.items, body);
    defer grant_response.deinit(allocator);
    if (grant_response.status != 200) return error.HttpFailed;
    const grant = slack.parseUploadGrant(allocator, grant_response.body) orelse return error.SlackRejected;
    defer allocator.free(grant.upload_url);
    defer allocator.free(grant.file_id);

    try putFile(allocator, grant.upload_url, bytes);

    const complete_body = try slack.buildCompleteUploadBody(allocator, grant.file_id, channel, thread_ts, caption);
    defer allocator.free(complete_body);
    var complete = try callWithRetry(allocator, ctx.user_token, "/api/files.completeUploadExternal", complete_body);
    errdefer complete.deinit(allocator);
    if (complete.status != 200 or !httpOk(allocator, complete.body)) return error.UploadRejected;
    return complete.body;
}
