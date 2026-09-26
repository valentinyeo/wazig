//! Win32 side of the wazigctl control channel: the per-user named pipe the
//! app serves and the CLI connects to, and the hand-off from a pipe thread
//! to the UI thread. Nothing here touches windows beyond PostMessageW, so
//! no request can focus, show or activate the app.

const std = @import("std");
const win = @import("win32.zig").c;
const control = @import("control.zig");

pub const max_request_bytes: usize = 64 * 1024;
pub const max_response_bytes: usize = 16 * 1024 * 1024;

/// `\\.\pipe\wazig-control-<USERNAME>` as UTF-16; null when USERNAME is unset.
pub fn pipeName(buffer: *[200]u16) ?[:0]const u16 {
    const prefix = std.unicode.utf8ToUtf16LeStringLiteral(control.pipe_prefix);
    const rest = buffer[prefix.len..];
    const user_len = win.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("USERNAME"), rest.ptr, @intCast(rest.len));
    if (user_len == 0 or user_len >= rest.len) return null;
    @memcpy(buffer[0..prefix.len], prefix);
    const len = prefix.len + user_len;
    buffer[len] = 0;
    return buffer[0..len :0];
}

/// Handles one request line and writes the one-line reply into `out`. Runs
/// on a pipe connection thread, never on the UI thread.
pub const Handler = *const fn (context: *anyopaque, line: []const u8, out: *std.Io.Writer.Allocating) void;

/// Accept loop; runs for the life of the process on its own thread. Each
/// client gets its own short-lived thread, so a stalled client can never
/// hold up the next one.
pub fn serve(allocator: std.mem.Allocator, context: *anyopaque, handler: Handler) void {
    var name_buffer: [200]u16 = undefined;
    const name = pipeName(&name_buffer) orelse return;
    while (true) {
        const pipe = win.CreateNamedPipeW(
            name.ptr,
            win.PIPE_ACCESS_DUPLEX,
            win.PIPE_TYPE_BYTE | win.PIPE_READMODE_BYTE | win.PIPE_WAIT | win.PIPE_REJECT_REMOTE_CLIENTS,
            win.PIPE_UNLIMITED_INSTANCES,
            64 * 1024,
            64 * 1024,
            0,
            null,
        );
        if (pipe == win.INVALID_HANDLE_VALUE or pipe == null) {
            win.Sleep(5000);
            continue;
        }
        const connected = win.ConnectNamedPipe(pipe, null) != 0 or win.GetLastError() == win.ERROR_PIPE_CONNECTED;
        if (!connected) {
            _ = win.CloseHandle(pipe);
            continue;
        }
        const job = Connection{ .allocator = allocator, .context = context, .handler = handler, .pipe = pipe.? };
        if (std.Thread.spawn(.{ .stack_size = 512 * 1024 }, Connection.run, .{job})) |thread| {
            thread.detach();
        } else |_| job.run();
    }
}

const Connection = struct {
    allocator: std.mem.Allocator,
    context: *anyopaque,
    handler: Handler,
    pipe: win.HANDLE,

    fn run(self: Connection) void {
        defer {
            _ = win.FlushFileBuffers(self.pipe);
            _ = win.DisconnectNamedPipe(self.pipe);
            _ = win.CloseHandle(self.pipe);
        }
        var out = std.Io.Writer.Allocating.init(self.allocator);
        defer out.deinit();
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(self.allocator);
        if (readLine(self.allocator, self.pipe, &line)) {
            self.handler(self.context, line.items, &out);
        } else {
            control.writeError(&out.writer, "request must be one JSON line under 64 KB") catch {};
        }
        writeAll(self.pipe, out.written());
    }
};

/// Read up to the first newline. False on a read error, an oversized
/// request, or a client that hung up before sending anything.
fn readLine(allocator: std.mem.Allocator, pipe: win.HANDLE, line: *std.ArrayList(u8)) bool {
    var chunk: [4096]u8 = undefined;
    while (line.items.len <= max_request_bytes) {
        var got: win.DWORD = 0;
        if (win.ReadFile(pipe, &chunk, chunk.len, &got, null) == 0 or got == 0) return line.items.len > 0;
        const piece = chunk[0..got];
        if (std.mem.indexOfScalar(u8, piece, '\n')) |end| {
            line.appendSlice(allocator, piece[0..end]) catch return false;
            return true;
        }
        line.appendSlice(allocator, piece) catch return false;
    }
    return false;
}

pub fn writeAll(handle: win.HANDLE, bytes: []const u8) void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        var wrote: win.DWORD = 0;
        const size: win.DWORD = @intCast(@min(bytes.len - sent, 64 * 1024));
        if (win.WriteFile(handle, bytes[sent..].ptr, size, &wrote, null) == 0 or wrote == 0) return;
        sent += wrote;
    }
}

pub const UiResult = enum { done, timeout, gone };

/// Post `payload` to the UI thread as `message` and wait for it to signal
/// `event`. On .timeout the UI thread still owns `payload` until it signals:
/// the caller must `waitForever(event)` before freeing it.
pub fn callUi(hwnd: win.HWND, message: win.UINT, payload: *anyopaque, event: win.HANDLE, timeout_ms: u32) UiResult {
    if (win.PostMessageW(hwnd, message, 0, @bitCast(@intFromPtr(payload))) == 0) return .gone;
    return if (win.WaitForSingleObject(event, timeout_ms) == win.WAIT_OBJECT_0) .done else .timeout;
}

pub fn waitForever(event: win.HANDLE) void {
    _ = win.WaitForSingleObject(event, win.INFINITE);
}
