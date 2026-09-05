// Fetches one WhatsApp profile image through wacli and stores it on disk.
const std = @import("std");
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("urlmon.h");
});

pub const State = enum(u8) { idle, working, ready, unavailable, failed };

pub const Session = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    thread: ?std.Thread = null,
    state_value: std.atomic.Value(u8) = .init(@intFromEnum(State.idle)),

    pub fn create(allocator: std.mem.Allocator, io: std.Io) !*Session {
        const self = try allocator.create(Session);
        self.* = .{ .allocator = allocator, .io = io };
        return self;
    }

    pub fn destroy(self: *Session) void {
        if (self.thread) |thread| thread.join();
        self.allocator.destroy(self);
    }

    pub fn state(self: *const Session) State {
        return @enumFromInt(self.state_value.load(.acquire));
    }

    pub fn start(self: *Session, wacli_path: []const u8, jid: []const u8, destination: []const u8) bool {
        if (self.state() != .idle) return false;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        const exe = self.allocator.dupe(u8, wacli_path) catch return false;
        const target = self.allocator.dupe(u8, jid) catch {
            self.allocator.free(exe);
            return false;
        };
        const path = self.allocator.dupe(u8, destination) catch {
            self.allocator.free(exe);
            self.allocator.free(target);
            return false;
        };
        self.state_value.store(@intFromEnum(State.working), .release);
        self.thread = std.Thread.spawn(.{}, workerMain, .{ self, exe, target, path }) catch {
            self.allocator.free(exe);
            self.allocator.free(target);
            self.allocator.free(path);
            self.state_value.store(@intFromEnum(State.failed), .release);
            return false;
        };
        return true;
    }

    pub fn reset(self: *Session) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.state_value.store(@intFromEnum(State.idle), .release);
    }
};

fn workerMain(self: *Session, exe: []u8, jid: []u8, destination: []u8) void {
    defer self.allocator.free(exe);
    defer self.allocator.free(jid);
    defer self.allocator.free(destination);
    workerRun(self, exe, jid, destination) catch {
        self.state_value.store(@intFromEnum(State.failed), .release);
    };
}

fn workerRun(self: *Session, exe: []const u8, jid: []const u8, destination: []const u8) !void {
    const result = try std.process.run(self.allocator, self.io, .{
        .argv = &.{ exe, "--json", "--lock-wait", "10s", "--timeout", "30s", "profile", "picture-info", "--jid", jid },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
        .create_no_window = true,
    });
    defer self.allocator.free(result.stdout);
    defer self.allocator.free(result.stderr);
    const success = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!success) return error.WacliFailed;

    var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, result.stdout, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.BadResponse,
    };
    const data_value = root.get("data") orelse {
        self.state_value.store(@intFromEnum(State.unavailable), .release);
        return;
    };
    const data = switch (data_value) {
        .object => |value| value,
        .null => {
            self.state_value.store(@intFromEnum(State.unavailable), .release);
            return;
        },
        else => return error.BadResponse,
    };
    const url_value = data.get("url") orelse {
        self.state_value.store(@intFromEnum(State.unavailable), .release);
        return;
    };
    const url = switch (url_value) {
        .string => |value| value,
        else => return error.BadResponse,
    };
    if (url.len == 0) {
        self.state_value.store(@intFromEnum(State.unavailable), .release);
        return;
    }
    const wide_url = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, url);
    defer self.allocator.free(wide_url);
    const wide_path = try std.unicode.utf8ToUtf16LeAllocZ(self.allocator, destination);
    defer self.allocator.free(wide_path);
    if (win.URLDownloadToFileW(null, wide_url.ptr, wide_path.ptr, 0, null) < 0) return error.DownloadFailed;
    self.state_value.store(@intFromEnum(State.ready), .release);
}
