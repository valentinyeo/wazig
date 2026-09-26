//! wazigctl.exe: scriptable control of the running Wazig Messages app over
//! its per-user named pipe. Reads and list management only; it never sends
//! messages and never focuses the app window. See control.zig for the
//! command table and wire format.

const std = @import("std");
const win = @import("win32.zig").c;
const control = @import("control.zig");
const control_pipe = @import("control_pipe.zig");

const exit_ok: u8 = 0;
const exit_app_error: u8 = 1;
const exit_usage: u8 = 2;
const exit_not_running: u8 = 3;
const answer_timeout_ms: win.DWORD = 45_000;

pub fn main(init: std.process.Init.Minimal) u8 {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = init.args.toSlice(arena) catch return fail(exit_usage, "could not read the command line");
    const args = if (argv.len > 0) argv[1..] else argv;

    if (args.len == 0) {
        printTo(win.STD_ERROR_HANDLE, control.help_text);
        return exit_usage;
    }
    if (std.mem.eql(u8, args[0], "--help") or std.mem.eql(u8, args[0], "-h") or std.mem.eql(u8, args[0], "help")) {
        printTo(win.STD_OUTPUT_HANDLE, control.help_text);
        return exit_ok;
    }

    var plain_args = arena.alloc([]const u8, args.len) catch return fail(exit_usage, "out of memory");
    for (args, 0..) |arg, index| plain_args[index] = arg;
    var usage_message: []const u8 = "";
    const request = control.parseArgs(arena, plain_args, &usage_message) catch |err| {
        if (err == error.Usage) {
            printTo(win.STD_ERROR_HANDLE, "wazigctl: ");
            printTo(win.STD_ERROR_HANDLE, usage_message);
            printTo(win.STD_ERROR_HANDLE, "\nRun `wazigctl --help` for the command list.\n");
            return exit_usage;
        }
        return fail(exit_usage, "out of memory");
    };
    var request_line = std.Io.Writer.Allocating.init(arena);
    control.writeRequest(&request_line.writer, request) catch return fail(exit_usage, "out of memory");

    const pipe = connect() orelse return exit_not_running;
    // The app answers within ~20 s even when a chat is slow to load; a hung
    // wacli read must still not hang the caller forever.
    if (std.Thread.spawn(.{ .stack_size = 64 * 1024 }, watchdog, .{})) |thread| thread.detach() else |_| {}
    defer _ = win.CloseHandle(pipe);
    control_pipe.writeAll(pipe, request_line.written());

    var reply: std.ArrayList(u8) = .empty;
    var chunk: [16 * 1024]u8 = undefined;
    while (reply.items.len < control_pipe.max_response_bytes) {
        var got: win.DWORD = 0;
        if (win.ReadFile(pipe, &chunk, chunk.len, &got, null) == 0 or got == 0) break;
        reply.appendSlice(arena, chunk[0..got]) catch break;
        if (std.mem.endsWith(u8, reply.items, "\n")) break;
    }
    const line = std.mem.trimEnd(u8, reply.items, "\r\n");
    if (line.len == 0) return fail(exit_app_error, "Wazig closed the connection without an answer");
    printTo(win.STD_OUTPUT_HANDLE, line);
    printTo(win.STD_OUTPUT_HANDLE, "\n");
    if (control.responseOk(line)) return exit_ok;
    printTo(win.STD_ERROR_HANDLE, "wazigctl: ");
    printTo(win.STD_ERROR_HANDLE, control.responseError(line));
    printTo(win.STD_ERROR_HANDLE, "\n");
    return exit_app_error;
}

fn watchdog() void {
    win.Sleep(answer_timeout_ms);
    _ = fail(exit_app_error, "Wazig did not answer within 45 s");
    win.ExitProcess(exit_app_error);
}

/// Open the app's pipe, waiting briefly while every instance is busy.
fn connect() ?win.HANDLE {
    var name_buffer: [200]u16 = undefined;
    const name = control_pipe.pipeName(&name_buffer) orelse {
        _ = fail(exit_not_running, "USERNAME is not set, so the control pipe name is unknown");
        return null;
    };
    var attempt: u32 = 0;
    while (attempt < 5) : (attempt += 1) {
        const handle = win.CreateFileW(name.ptr, win.GENERIC_READ | win.GENERIC_WRITE, 0, null, win.OPEN_EXISTING, 0, null);
        if (handle != win.INVALID_HANDLE_VALUE and handle != null) return handle;
        switch (win.GetLastError()) {
            win.ERROR_PIPE_BUSY => _ = win.WaitNamedPipeW(name.ptr, 2000),
            win.ERROR_FILE_NOT_FOUND => {
                _ = fail(exit_not_running, "Wazig Messages is not running (no control pipe for this user)");
                return null;
            },
            else => {
                _ = fail(exit_not_running, "could not connect to Wazig Messages");
                return null;
            },
        }
    }
    _ = fail(exit_not_running, "Wazig Messages is busy; try again");
    return null;
}

fn fail(code: u8, text: []const u8) u8 {
    printTo(win.STD_ERROR_HANDLE, "wazigctl: ");
    printTo(win.STD_ERROR_HANDLE, text);
    printTo(win.STD_ERROR_HANDLE, "\n");
    return code;
}

fn printTo(which: win.DWORD, text: []const u8) void {
    const handle = win.GetStdHandle(which) orelse return;
    if (handle == win.INVALID_HANDLE_VALUE) return;
    control_pipe.writeAll(handle, text);
}
