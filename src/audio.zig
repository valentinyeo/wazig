// In-app voice message playback.
//
// Windows Media Foundation has no Ogg container source, so this module
// demuxes Opus packets from the Ogg stream, decodes them with the built-in
// Microsoft Opus decoder MFT, and renders PCM through shared-mode WASAPI.
// Only Windows system components are used.
const std = @import("std");
const sola = @import("stretch.zig");
pub const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("objbase.h");
    @cInclude("mmdeviceapi.h");
    @cInclude("audioclient.h");
    @cInclude("mfapi.h");
    @cInclude("mfidl.h");
    @cInclude("mftransform.h");
    @cInclude("mfobjects.h");
});

pub const State = enum(u8) { idle, ready, playing, paused, ended };

const max_file_bytes = 32 * 1024 * 1024;
const ring_seconds = 2;
const output_rate: u64 = 48000;
const output_channels: u32 = 2;
const output_bit_depth: u32 = 32;

const guid_mftransform = win.GUID{ .Data1 = 0xbf94c121, .Data2 = 0x5b05, .Data3 = 0x4e6f, .Data4 = .{ 0x80, 0x00, 0xba, 0x59, 0x89, 0x61, 0x41, 0x4d } };
const guid_mmdevice_enumerator = win.GUID{ .Data1 = 0xbcde0395, .Data2 = 0xe52f, .Data3 = 0x467c, .Data4 = .{ 0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e } };
const guid_immdevice_enumerator = win.GUID{ .Data1 = 0xa95664d2, .Data2 = 0x9614, .Data3 = 0x4f35, .Data4 = .{ 0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6 } };
const guid_iaudioclient = win.GUID{ .Data1 = 0x1cb9ad4c, .Data2 = 0xdbfa, .Data3 = 0x4c32, .Data4 = .{ 0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2 } };
const guid_iaudiorenderclient = win.GUID{ .Data1 = 0xf294acfc, .Data2 = 0x3146, .Data3 = 0x4483, .Data4 = .{ 0xa7, 0xbf, 0xad, 0xdc, 0xa7, 0xc2, 0x60, 0xe2 } };
const guid_mf_mt_major_type = win.GUID{ .Data1 = 0x48eba18e, .Data2 = 0xf8c9, .Data3 = 0x4687, .Data4 = .{ 0xbf, 0x11, 0x0a, 0x74, 0xc9, 0xf9, 0x6a, 0x8f } };
const guid_mf_mt_minor_type = win.GUID{ .Data1 = 0xf7e34c9a, .Data2 = 0x42e8, .Data3 = 0x4714, .Data4 = .{ 0xb7, 0x4b, 0xcb, 0x29, 0xd7, 0x2c, 0x35, 0xe5 } };
const guid_mf_mt_audio_samples_per_second = win.GUID{ .Data1 = 0x5faeeae7, .Data2 = 0x0290, .Data3 = 0x4c31, .Data4 = .{ 0x9e, 0x8a, 0xc5, 0x34, 0xf6, 0x8d, 0x9d, 0xba } };
const guid_mf_mt_audio_float_samples_per_second = win.GUID{ .Data1 = 0xfb3b724a, .Data2 = 0xcfb5, .Data3 = 0x4319, .Data4 = .{ 0xae, 0xfe, 0x6e, 0x42, 0xb2, 0x40, 0x61, 0x32 } };
const guid_mf_mt_audio_num_channels = win.GUID{ .Data1 = 0x37e48bf5, .Data2 = 0x645e, .Data3 = 0x4c5b, .Data4 = .{ 0x89, 0xde, 0xad, 0xa9, 0xe2, 0x9b, 0x69, 0x6a } };
const guid_mf_mt_audio_bits_per_sample = win.GUID{ .Data1 = 0xf2deb57f, .Data2 = 0x40fa, .Data3 = 0x4764, .Data4 = .{ 0xaa, 0x33, 0xed, 0xd4, 0xf2, 0xd1, 0x7f, 0x66 } };
const guid_mf_mt_audio_valid_bits_per_sample = win.GUID{ .Data1 = 0xd9bf8d6a, .Data2 = 0x9530, .Data3 = 0x4b7c, .Data4 = .{ 0x9d, 0xdf, 0xff, 0x6f, 0xd5, 0x8b, 0xbd, 0x06 } };
const guid_mf_mt_audio_block_alignment = win.GUID{ .Data1 = 0x322de230, .Data2 = 0x9eeb, .Data3 = 0x43bd, .Data4 = .{ 0xab, 0x7a, 0xff, 0x41, 0x22, 0x51, 0x54, 0x1d } };
const guid_mf_mt_audio_avg_bytes_per_second = win.GUID{ .Data1 = 0x1aab75c8, .Data2 = 0xcfef, .Data3 = 0x451c, .Data4 = .{ 0xab, 0x95, 0xac, 0x03, 0x4b, 0x8e, 0x17, 0x31 } };
const guid_mf_mt_audio_channel_mask = win.GUID{ .Data1 = 0x55fb5765, .Data2 = 0x644a, .Data3 = 0x4caf, .Data4 = .{ 0x84, 0x79, 0x93, 0x89, 0x83, 0xbb, 0x15, 0x88 } };
const guid_mf_mt_all_samples_independent = win.GUID{ .Data1 = 0xc9173739, .Data2 = 0x5e56, .Data3 = 0x461c, .Data4 = .{ 0xb7, 0x13, 0x46, 0xfb, 0x99, 0x5c, 0xb9, 0x5f } };
const guid_mf_mt_compressed = win.GUID{ .Data1 = 0x3afd0cee, .Data2 = 0x18f2, .Data3 = 0x4ba5, .Data4 = .{ 0xa1, 0x10, 0x8b, 0xea, 0x50, 0x2e, 0x1f, 0x92 } };
const guid_mf_media_type_audio = win.GUID{ .Data1 = 0x73647561, .Data2 = 0x0000, .Data3 = 0x0010, .Data4 = .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
const guid_mf_audio_format_float = win.GUID{ .Data1 = 0x00000003, .Data2 = 0x0000, .Data3 = 0x0010, .Data4 = .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };
const guid_mf_audio_format_opus = win.GUID{ .Data1 = 0x0000704f, .Data2 = 0x0000, .Data3 = 0x0010, .Data4 = .{ 0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71 } };

const error_need_more_input: u32 = 0xc00d6d72;
const error_stream_change: u32 = 0xc00d6d61;

const Packet = struct {
    offset: usize,
    len: usize,
    granule_end: u64,
};

const ParsedOgg = struct {
    packets: []Packet, // audio packets only (head/tags excluded)
    pre_skip: u32,
    duration_samples: u64,
};

fn parseOpusOgg(allocator: std.mem.Allocator, data: []const u8) !ParsedOgg {
    if (data.len < 4 or !std.mem.eql(u8, data[0..4], "OggS")) return error.UnsupportedFile;

    var packets: std.ArrayList(Packet) = .empty;
    errdefer packets.deinit(allocator);
    var pre_skip: u32 = 0;
    var saw_head = false;
    var stream_serial: ?u32 = null;
    var current_start: ?usize = null;
    var current_len: usize = 0;

    var offset: usize = 0;
    while (offset + 27 <= data.len) {
        if (!std.mem.eql(u8, data[offset .. offset + 4], "OggS")) break;
        if (data[offset + 4] != 0) break;
        const header_type = data[offset + 5];
        const granule = std.mem.readInt(u64, data[offset + 6 ..][0..8], .little);
        const serial = std.mem.readInt(u32, data[offset + 14 ..][0..4], .little);
        const segments = data[offset + 26];
        if (offset + 27 + segments > data.len) break;
        const payload_start = offset + 27 + segments;
        var payload_len: usize = 0;
        for (data[offset + 27 .. payload_start]) |lacing| payload_len += lacing;
        if (payload_start + payload_len > data.len) break;

        if (stream_serial == null) stream_serial = serial;
        if (serial == stream_serial.?) {
            var cursor = payload_start;
            for (data[offset + 27 .. payload_start]) |lacing| {
                if (current_start == null) current_start = cursor;
                cursor += lacing;
                current_len += lacing;
                if (lacing < 255) {
                    const start = current_start.?;
                    const bytes = data[start .. start + current_len];
                    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "OpusHead")) {
                        if (bytes.len >= 12) pre_skip = std.mem.readInt(u16, bytes[10..12], .little);
                        saw_head = true;
                    } else if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "OpusTags")) {
                        // Metadata packet, not decoder input.
                    } else if (saw_head) {
                        try packets.append(allocator, .{ .offset = start, .len = current_len, .granule_end = granule });
                    }
                    current_start = null;
                    current_len = 0;
                }
            }
        }

        if ((header_type & 0x04) != 0) break; // end of stream
        offset = payload_start + payload_len;
    }

    if (!saw_head or packets.items.len == 0) return error.UnsupportedFile;
    const final_granule = packets.items[packets.items.len - 1].granule_end;
    const duration_samples = if (final_granule > pre_skip) final_granule - pre_skip else 0;
    return .{
        .packets = try packets.toOwnedSlice(allocator),
        .pre_skip = pre_skip,
        .duration_samples = duration_samples,
    };
}

// Opus packet duration at 48 kHz (RFC 6716, opus_packet_get_nb_samples).
fn opusPacketSamples(packet: []const u8) u64 {
    if (packet.len == 0) return 0;
    const toc = packet[0];
    const config = toc >> 3;
    const code = toc & 0x03;
    const sizes = [4]u64{ 480, 960, 1920, 2880 };
    const frame_size = sizes[(config >> 3) & 0x03];
    var frames: u64 = 0;
    switch (code) {
        0 => frames = 1,
        1, 2 => frames = 2,
        3 => {
            if (packet.len < 2) return 0;
            frames = packet[1] & 0x3f;
        },
        else => unreachable,
    }
    return frames * frame_size;
}

fn findPacketForGranule(packets: []Packet, granule: u64) usize {
    var index: usize = 0;
    while (index < packets.len) : (index += 1) {
        if (packets[index].granule_end > granule) return index;
    }
    return if (packets.len > 0) packets.len - 1 else 0;
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
    defer allocator.free(wide);
    const handle = win.CreateFileW(wide.ptr, win.GENERIC_READ, win.FILE_SHARE_READ, null, win.OPEN_EXISTING, win.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == win.INVALID_HANDLE_VALUE or handle == null) return error.FileNotFound;
    defer _ = win.CloseHandle(handle);
    var size: win.LARGE_INTEGER = undefined;
    if (win.GetFileSizeEx(handle, &size) == 0) return error.ReadFailed;
    if (size.QuadPart <= 0 or size.QuadPart > max_bytes) return error.UnsupportedFile;
    const data = try allocator.alloc(u8, @intCast(size.QuadPart));
    errdefer allocator.free(data);
    var total: usize = 0;
    while (total < data.len) {
        var got: win.DWORD = 0;
        if (win.ReadFile(handle, data.ptr + total, @intCast(data.len - total), &got, null) == 0) return error.ReadFailed;
        if (got == 0) break;
        total += got;
    }
    if (total != data.len) return error.ReadFailed;
    return data;
}

// --- Public player ---

pub const Player = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    stop_requested: bool = false,
    pause_requested: bool = false,
    seek_request_ms: ?i64 = null,

    // Shared playback data (owned by worker while running).
    file_data: []u8 = &.{},
    packets: []Packet = &.{},
    ring: []f32 = &.{},
    ring_channels: u32 = output_channels,
    ring_read: std.atomic.Value(u64) = .init(0),
    ring_write: std.atomic.Value(u64) = .init(0),
    pre_skip: u32 = 0,
    duration_ms: std.atomic.Value(i64) = .init(0),
    // Source-frame position of audio handed to WASAPI: rendered output
    // converted to source time chunk-by-chunk at the speed in effect, plus
    // the source-frame offset playback started (or seeked) at.
    rendered_src: std.atomic.Value(u64) = .init(0),
    seek_base: std.atomic.Value(u64) = .init(0),
    // ponytail: rendered chunks are converted at the *current* speed, so for
    // up to ~2 s after a speed change the progress bar can drift until the
    // ring drains. Fixing exactly needs per-chunk speed metadata in the ring.
    position_ms_value: std.atomic.Value(i64) = .init(0),
    state_value: std.atomic.Value(u8) = .init(@intFromEnum(State.idle)),
    start_failed: std.atomic.Value(bool) = .init(false),
    speed_value: std.atomic.Value(u32) = .init(100),

    pub fn create(allocator: std.mem.Allocator, io: std.Io) !*Player {
        const self = try allocator.create(Player);
        self.* = .{ .allocator = allocator, .io = io };
        return self;
    }

    pub fn destroy(self: *Player) void {
        self.stop();
        self.allocator.destroy(self);
    }

    pub fn state(self: *Player) State {
        return @enumFromInt(self.state_value.load(.acquire));
    }

    pub fn durationMs(self: *Player) i64 {
        return self.duration_ms.load(.acquire);
    }

    pub fn positionMs(self: *Player) i64 {
        return self.position_ms_value.load(.acquire);
    }

    fn storePositionMs(self: *Player) void {
        const source_frames = self.seek_base.load(.acquire) + self.rendered_src.load(.acquire);
        self.position_ms_value.store(@intCast(source_frames * 1000 / output_rate), .release);
    }

    pub fn play(self: *Player, ogg_path: []const u8) void {
        self.stop();
        const path_copy = self.allocator.dupe(u8, ogg_path) catch return;
        self.mutex.lockUncancelable(self.io);
        self.stop_requested = false;
        self.pause_requested = false;
        self.seek_request_ms = null;
        self.mutex.unlock(self.io);
        self.state_value.store(@intFromEnum(State.playing), .release);
        self.start_failed.store(false, .release);
        const thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, workerMain, .{ self, path_copy }) catch {
            self.allocator.free(path_copy);
            self.state_value.store(@intFromEnum(State.idle), .release);
            self.start_failed.store(true, .release);
            return;
        };
        self.thread = thread;
    }

    pub fn pause(self: *Player) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.pause_requested = true;
        if (self.state_value.load(.acquire) == @intFromEnum(State.playing)) {
            self.state_value.store(@intFromEnum(State.paused), .release);
        }
    }

    pub fn unpause(self: *Player) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.pause_requested = false;
        if (self.state_value.load(.acquire) == @intFromEnum(State.paused)) {
            self.state_value.store(@intFromEnum(State.playing), .release);
        }
    }

    pub fn seek(self: *Player, ms: i64) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const duration = self.duration_ms.load(.acquire);
        const upper: i64 = if (duration > 0) duration - 1 else 0;
        self.seek_request_ms = std.math.clamp(ms, 0, upper);
    }

    pub fn setSpeed(self: *Player, percent: u32) void {
        self.speed_value.store(std.math.clamp(percent, 50, 300), .release);
    }

    pub fn speed(self: *Player) u32 {
        return self.speed_value.load(.acquire);
    }

    pub fn stop(self: *Player) void {
        self.mutex.lockUncancelable(self.io);
        self.stop_requested = true;
        self.mutex.unlock(self.io);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.state_value.store(@intFromEnum(State.idle), .release);
        self.rendered_src.store(0, .release);
        self.seek_base.store(0, .release);
        self.position_ms_value.store(0, .release);
        self.duration_ms.store(0, .release);
    }
};

fn workerMain(self: *Player, path: []u8) void {
    defer self.allocator.free(path);
    workerRun(self, path) catch |err| {
        std.debug.print("audio worker failed: {s}\n", .{@errorName(err)});
        self.start_failed.store(true, .release);
        self.state_value.store(@intFromEnum(State.idle), .release);
    };
}

fn workerRun(self: *Player, path: []const u8) !void {
    _ = win.CoInitializeEx(null, win.COINIT_MULTITHREADED);
    defer _ = win.CoUninitialize();
    if (!startupMediaFoundation()) return error.MfFailure;

    const data = try readFileAlloc(self.allocator, path, max_file_bytes);
    defer self.allocator.free(data);
    self.file_data = data;
    defer self.file_data = &.{};
    const opus = try parseOpusOgg(self.allocator, data);
    defer self.allocator.free(opus.packets);

    const duration: i64 = @intCast(opus.duration_samples * 1000 / output_rate);
    self.duration_ms.store(duration, .release);
    self.rendered_src.store(0, .release);
    self.seek_base.store(0, .release);
    self.position_ms_value.store(0, .release);

    var decoder = try openDecoder();
    defer decoder.destroy();

    const ring_frames: u64 = output_rate * ring_seconds;
    const ring = try self.allocator.alloc(f32, @intCast(ring_frames * output_channels));
    defer self.allocator.free(ring);
    self.ring = ring;
    self.ring_channels = output_channels;
    self.ring_read.store(0, .release);
    self.ring_write.store(0, .release);

    var audio = try WasapiOutput.open(48000);
    defer audio.close();

    // Decoded PCM accumulates here; the stretch stage consumes it from the
    // front (acc_base is the absolute source frame of acc[0]).
    var acc: std.ArrayList(f32) = .empty;
    defer acc.deinit(self.allocator);
    var acc_base: u64 = 0;
    var stretch: sola.Stretch = .{ .channels = output_channels, .percent = 100 };
    var out_block: [sola.window_frames * output_channels]f32 = undefined;

    var next_packet: usize = 0;
    var pending_skip: u64 = opus.pre_skip;
    var decode_samples: u64 = 0;
    var packets_done = false;
    var drained = false;

    while (true) {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.stop_requested) break;
            if (self.seek_request_ms) |ms| {
                self.seek_request_ms = null;
                const target_frames: u64 = @intCast(@divTrunc(@max(ms, 0) * @as(i64, @intCast(output_rate)), 1000));
                next_packet = findPacketForGranule(opus.packets, target_frames + opus.pre_skip);
                decoder.flush() catch {};
                self.ring_read.store(0, .release);
                self.ring_write.store(0, .release);
                self.seek_base.store(target_frames, .release);
                self.rendered_src.store(0, .release);
                self.position_ms_value.store(@intCast(target_frames * 1000 / output_rate), .release);
                acc.clearRetainingCapacity();
                acc_base = target_frames;
                stretch.reset(target_frames);
                pending_skip = 0;
                decode_samples = 0;
                packets_done = false;
                drained = false;
            }
        }

        stretch.percent = self.speed();
        const ring_cap: u64 = @intCast(ring_frames);

        if (!packets_done) {
            while (@as(u64, @intCast(acc.items.len / output_channels)) < 4 * output_rate and next_packet < opus.packets.len) {
                const wrote = try decodePacketToAcc(self, decoder, opus, next_packet, &acc, &pending_skip, &decode_samples);
                next_packet += 1;
                if (!wrote) break;
            }
            if (next_packet >= opus.packets.len) packets_done = true;
        }

        // Drop already-consumed frames from the front. Batched to a second
        // while stretching; fully before the 1x copy path so it never
        // replays consumed frames after a speed change.
        const pos = stretch.sourceFramesConsumed();
        // pos can overshoot the accumulator at high speeds (the hop skips
        // ahead); never trim more than is actually buffered.
        const stale = @min(pos - acc_base, @as(u64, @intCast(acc.items.len / output_channels)));
        if (stretch.percent == 100 or stale >= output_rate) {
            const n = stale * output_channels;
            std.mem.copyForwards(f32, acc.items[0 .. acc.items.len - n], acc.items[n..]);
            acc.shrinkRetainingCapacity(acc.items.len - n);
            acc_base += stale;
        }

        if (stretch.percent == 100) {
            // Normal speed: copy decoded frames through untouched. The
            // stretch tail is dropped so returning to a higher speed does
            // not crossfade against audio from before the 1x segment.
            stretch.has_tail = false;
            while (acc.items.len >= sola.window_frames * output_channels and
                ringAvailableFrames(self) + sola.window_frames <= ring_cap)
            {
                ringWriteFrames(self, acc.items[0 .. sola.window_frames * output_channels]);
                const n = sola.window_frames * output_channels;
                std.mem.copyForwards(f32, acc.items[0 .. acc.items.len - n], acc.items[n..]);
                acc.shrinkRetainingCapacity(acc.items.len - n);
                acc_base += sola.window_frames;
                stretch.pos_scaled += @as(u64, sola.window_frames) * 100;
            }
        } else while (stretch.canEmit(acc_base, @intCast(acc.items.len / output_channels)) and
            ringAvailableFrames(self) + sola.window_frames <= ring_cap)
        {
            stretch.emitWindow(acc.items, acc_base, @intCast(acc.items.len / output_channels), &out_block);
            ringWriteFrames(self, &out_block);
        }

        // End of file: flush what a window could not consume, crossfaded
        // from the stretch tail so the last seam stays click-free. Gate and
        // flush on the unconsumed part only.
        const stale_now = @min(stretch.sourceFramesConsumed() - acc_base, @as(u64, @intCast(acc.items.len / output_channels)));
        const unconsumed = acc.items.len / output_channels - stale_now;
        if (packets_done and unconsumed < sola.lookahead_frames) {
            const remaining = acc.items.len - @as(usize, @intCast(stale_now * output_channels));
            if (remaining == 0) {
                // Everything consumed (pos may overshoot at high speeds).
                acc.clearRetainingCapacity();
            } else if (ringAvailableFrames(self) + remaining / output_channels <= ring_cap) {
                const pcm = acc.items[@intCast(stale_now * output_channels)..];
                var tail_i: usize = 0;
                if (stretch.has_tail) {
                    const inv: f32 = 1.0 / @as(f32, sola.overlap_frames);
                    const fade = @min(remaining / output_channels, sola.overlap_frames);
                    while (tail_i < fade) : (tail_i += 1) {
                        const t: f32 = @as(f32, @floatFromInt(tail_i)) * inv;
                        for (0..output_channels) |c| {
                            pcm[tail_i * output_channels + c] =
                                stretch.tail[tail_i * output_channels + c] * (1 - t) + pcm[tail_i * output_channels + c] * t;
                        }
                    }
                }
                ringWriteFrames(self, pcm);
                stretch.pos_scaled = (acc_base + stale_now + remaining / output_channels) * 100;
                acc_base += stale_now + remaining / output_channels;
                acc.clearRetainingCapacity();
            }
        }

        const ended = packets_done and acc.items.len == 0 and ringAvailableFrames(self) == 0;
        try audio.renderFrame(self, !isPaused(self));
        if (ended and !drained) {
            audio.drain();
            drained = true;
            self.state_value.store(@intFromEnum(State.ended), .release);
        }
        win.Sleep(8);
    }
    audio.stopOutput();
    self.ring_read.store(self.ring_write.load(.acquire), .release);
}

// Copies whole frames into the playback ring. The caller must have checked
// that the ring has room.
fn ringWriteFrames(self: *Player, src: []const f32) void {
    const ch: usize = self.ring_channels;
    const cap: u64 = @intCast(self.ring.len / ch);
    var off: usize = 0;
    while (off * ch < src.len) {
        const write = self.ring_write.load(.acquire);
        const contiguous = @min(cap - (write % cap), cap - (write - self.ring_read.load(.acquire)));
        const chunk = @min(@as(u64, src.len / ch - off), contiguous);
        const slot = (write % cap) * ch;
        @memcpy(self.ring[@intCast(slot)..][0..@intCast(chunk * ch)], src[off * ch ..][0..@intCast(chunk * ch)]);
        self.ring_write.store(write + chunk, .release);
        off += @intCast(chunk);
    }
}

fn isPaused(self: *Player) bool {
    self.mutex.lockUncancelable(self.io);
    defer self.mutex.unlock(self.io);
    return self.pause_requested;
}

fn ringAvailableFrames(self: *Player) u64 {
    return self.ring_write.load(.acquire) - self.ring_read.load(.acquire);
}

// Decodes one packet into the PCM accumulator. Returns false while the
// decoder needs more input before producing output.
fn decodePacketToAcc(self: *Player, decoder: *Decoder, opus: ParsedOgg, packet_index: usize, acc: *std.ArrayList(f32), pending_skip: *u64, decode_samples: *u64) !bool {
    const packet = opus.packets[packet_index];
    const packet_data = self.file_data[packet.offset .. packet.offset + packet.len];
    const packet_samples: u64 = opusPacketSamples(packet_data);

    const input_sample = try Decoder.makeInputSample(packet_data, decode_samples.* * 10_000_000 / output_rate, packet_samples * 10_000_000 / output_rate);
    defer _ = input_sample.*.lpVtbl.*.Release.?(input_sample);
    decode_samples.* += packet_samples;

    var produced_any = false;
    try decoder.sendInput(input_sample);

    while (true) {
        const output = decoder.pullOutput() catch |err| switch (err) {
            error.NeedMoreInput => return produced_any,
            error.StreamChange => {
                try decoder.refreshOutputType();
                continue;
            },
            else => return err,
        };
        defer output.release();
        produced_any = true;
        var pcm = output.data;
        var frames: u64 = pcm.len / output_channels;

        if (pending_skip.* > 0) {
            const drop: u64 = @min(pending_skip.*, frames);
            pcm = pcm[drop * output_channels ..];
            frames -= drop;
            pending_skip.* -= drop;
        }

        try acc.appendSlice(self.allocator, pcm);
    }
}

// --- Microsoft Opus decoder MFT wrapper ---

const Decoder = struct {
    allocator: std.mem.Allocator,
    transform: *win.IMFTransform,
    output_channels: u32 = output_channels,

    fn destroy(self: *Decoder) void {
        _ = self.transform.*.lpVtbl.*.Release.?(self.transform);
        self.allocator.destroy(self);
    }

    fn flush(self: *Decoder) !void {
        if (self.transform.*.lpVtbl.*.ProcessMessage.?(self.transform, win.MFT_MESSAGE_COMMAND_FLUSH, 0) < 0) return error.MfFailure;
    }

    // Builds an input sample (copy of packet bytes with timestamps).
    fn makeInputSample(payload: []const u8, time_100ns: u64, duration_100ns: u64) !*win.IMFSample {
        var buffer: ?*win.IMFMediaBuffer = null;
        if (win.MFCreateMemoryBuffer(@intCast(payload.len), &buffer) < 0 or buffer == null) return error.MfFailure;
        const owned_buffer = buffer.?;
        defer _ = owned_buffer.*.lpVtbl.*.Release.?(owned_buffer);
        {
            var data_ptr: [*c]u8 = null;
            var max_len: win.DWORD = 0;
            var current_len: win.DWORD = 0;
            if (owned_buffer.*.lpVtbl.*.Lock.?(owned_buffer, &data_ptr, &max_len, &current_len) < 0) return error.MfFailure;
            @memcpy(data_ptr[0..payload.len], payload);
            _ = owned_buffer.*.lpVtbl.*.Unlock.?(owned_buffer);
            if (owned_buffer.*.lpVtbl.*.SetCurrentLength.?(owned_buffer, @intCast(payload.len)) < 0) return error.MfFailure;
        }
        var sample: ?*win.IMFSample = null;
        if (win.MFCreateSample(&sample) < 0 or sample == null) return error.MfFailure;
        if (sample.?.*.lpVtbl.*.AddBuffer.?(sample.?, owned_buffer) < 0) {
            _ = sample.?.*.lpVtbl.*.Release.?(sample);
            return error.MfFailure;
        }
        _ = sample.?.*.lpVtbl.*.SetSampleTime.?(sample.?, @intCast(time_100ns));
        _ = sample.?.*.lpVtbl.*.SetSampleDuration.?(sample.?, @intCast(duration_100ns));
        return sample.?;
    }

    fn sendInput(self: *Decoder, sample: *win.IMFSample) !void {
        const hr: u32 = @bitCast(self.transform.*.lpVtbl.*.ProcessInput.?(self.transform, 0, sample, 0));
        if (hr >= 0x80000000) return error.MfFailure;
    }

    fn pullOutput(self: *Decoder) !DecodedOutput {
        var stream_info = std.mem.zeroes(win.MFT_OUTPUT_STREAM_INFO);
        _ = self.transform.*.lpVtbl.*.GetOutputStreamInfo.?(self.transform, 0, &stream_info);
        var output = std.mem.zeroes(win.MFT_OUTPUT_DATA_BUFFER);
        output.dwStreamID = 0;
        if ((stream_info.dwFlags & win.MFT_OUTPUT_STREAM_PROVIDES_SAMPLES) == 0) {
            const buffer_size: win.DWORD = @intCast(@max(stream_info.cbSize, 65536));
            var buffer: ?*win.IMFMediaBuffer = null;
            if (win.MFCreateMemoryBuffer(buffer_size, &buffer) < 0 or buffer == null) return error.MfFailure;
            defer _ = buffer.?.*.lpVtbl.*.Release.?(buffer);
            var sample: ?*win.IMFSample = null;
            if (win.MFCreateSample(&sample) < 0 or sample == null) return error.MfFailure;
            if (sample.?.*.lpVtbl.*.AddBuffer.?(sample.?, buffer) < 0) {
                _ = sample.?.*.lpVtbl.*.Release.?(sample);
                return error.MfFailure;
            }
            output.pSample = sample;
        }
        var status: win.DWORD = 0;
        const hr: u32 = @bitCast(self.transform.*.lpVtbl.*.ProcessOutput.?(self.transform, 0, 1, @ptrCast(&output), &status));
        if (hr == error_need_more_input) {
            if (output.pSample) |sample| _ = sample.*.lpVtbl.*.Release.?(sample);
            return error.NeedMoreInput;
        }
        if (hr == error_stream_change) {
            if (output.pSample) |sample| _ = sample.*.lpVtbl.*.Release.?(sample);
            return error.StreamChange;
        }
        if (hr >= 0x80000000) {
            if (output.pSample) |sample| _ = sample.*.lpVtbl.*.Release.?(sample);
            return error.MfFailure;
        }
        const sample = output.pSample orelse return error.MfFailure;

        var buffer: ?*win.IMFMediaBuffer = null;
        if (sample.*.lpVtbl.*.ConvertToContiguousBuffer.?(sample, &buffer) < 0 or buffer == null) {
            _ = sample.*.lpVtbl.*.Release.?(sample);
            return error.MfFailure;
        }
        var data_ptr: [*c]u8 = null;
        var max_len: win.DWORD = 0;
        var current_len: win.DWORD = 0;
        if (buffer.?.*.lpVtbl.*.Lock.?(buffer.?, &data_ptr, &max_len, &current_len) < 0) {
            _ = buffer.?.*.lpVtbl.*.Release.?(buffer);
            _ = sample.*.lpVtbl.*.Release.?(sample);
            return error.MfFailure;
        }
        const bytes: [*]f32 = @ptrCast(@alignCast(data_ptr));
        return .{
            .sample = sample,
            .buffer = buffer.?,
            .data = bytes[0 .. current_len / @sizeOf(f32)],
        };
    }

    fn refreshOutputType(self: *Decoder) !void {
        var oi: u32 = 0;
        while (true) : (oi += 1) {
            var media_type: ?*win.IMFMediaType = null;
            const hr = self.transform.*.lpVtbl.*.GetOutputAvailableType.?(self.transform, 0, oi, &media_type);
            if (hr < 0 or media_type == null) return error.MfFailure;
            var subtype = std.mem.zeroes(win.GUID);
            _ = media_type.?.*.lpVtbl.*.GetGUID.?(media_type.?, &guid_mf_mt_minor_type, &subtype);
            const is_float = std.meta.eql(subtype, guid_mf_audio_format_float);
            if (is_float) {
                _ = media_type.?.*.lpVtbl.*.SetUINT32.?(media_type.?, &guid_mf_mt_audio_bits_per_sample, output_bit_depth);
                _ = media_type.?.*.lpVtbl.*.SetUINT32.?(media_type.?, &guid_mf_mt_audio_valid_bits_per_sample, output_bit_depth);
                _ = media_type.?.*.lpVtbl.*.SetUINT32.?(media_type.?, &guid_mf_mt_audio_num_channels, output_channels);
                _ = media_type.?.*.lpVtbl.*.SetUINT32.?(media_type.?, &guid_mf_mt_audio_samples_per_second, output_rate);
                _ = media_type.?.*.lpVtbl.*.SetUINT32.?(media_type.?, &guid_mf_mt_audio_block_alignment, output_channels * output_bit_depth / 8);
                _ = media_type.?.*.lpVtbl.*.SetUINT32.?(media_type.?, &guid_mf_mt_audio_avg_bytes_per_second, output_rate * output_channels * output_bit_depth / 8);
                const set_hr = self.transform.*.lpVtbl.*.SetOutputType.?(self.transform, 0, media_type.?, 0);
                _ = media_type.?.*.lpVtbl.*.Release.?(media_type);
                if (set_hr < 0) return error.MfFailure;
                return;
            }
            _ = media_type.?.*.lpVtbl.*.Release.?(media_type);
        }
    }
};

const DecodedOutput = struct {
    sample: *win.IMFSample,
    buffer: *win.IMFMediaBuffer,
    data: []f32,

    fn release(self: *const DecodedOutput) void {
        _ = self.buffer.*.lpVtbl.*.Unlock.?(self.buffer);
        _ = self.buffer.*.lpVtbl.*.Release.?(self.buffer);
        _ = self.sample.*.lpVtbl.*.Release.?(self.sample);
    }
};

var mf_create_media_type: ?*const fn (*?*win.IMFMediaType) callconv(.winapi) win.HRESULT = null;
var mf_create_memory_buffer: ?*const fn (win.DWORD, *?*win.IMFMediaBuffer) callconv(.winapi) win.HRESULT = null;
var mf_create_sample: ?*const fn (*?*win.IMFSample) callconv(.winapi) win.HRESULT = null;
var mf_started = false;

fn startupMediaFoundation() bool {
    if (mf_started) return true;
    const mfplat = win.LoadLibraryW(lit("mfplat.dll")) orelse return false;
    const startup_raw = win.GetProcAddress(mfplat, "MFStartup") orelse return false;
    const startup: *const fn (win.UINT, win.UINT) callconv(.winapi) win.HRESULT = @ptrCast(@alignCast(startup_raw));
    if (startup(0x00020070, 0) < 0) return false;
    const mt_raw = win.GetProcAddress(mfplat, "MFCreateMediaType") orelse return false;
    mf_create_media_type = @ptrCast(@alignCast(mt_raw));
    const buf_raw = win.GetProcAddress(mfplat, "MFCreateMemoryBuffer") orelse return false;
    mf_create_memory_buffer = @ptrCast(@alignCast(buf_raw));
    const sample_raw = win.GetProcAddress(mfplat, "MFCreateSample") orelse return false;
    mf_create_sample = @ptrCast(@alignCast(sample_raw));
    mf_started = true;
    return true;
}

fn openDecoder() !*Decoder {
    var count: win.UINT32 = 0;
    var activates: [*c]?*win.IMFActivate = null;
    var input_type = win.MFT_REGISTER_TYPE_INFO{ .guidMajorType = guid_mf_media_type_audio, .guidSubtype = guid_mf_audio_format_opus };
    var output_type = win.MFT_REGISTER_TYPE_INFO{ .guidMajorType = guid_mf_media_type_audio, .guidSubtype = guid_mf_audio_format_float };
    const category = win.GUID{ .Data1 = 0x9ea73fb4, .Data2 = 0xef7a, .Data3 = 0x4559, .Data4 = .{ 0x8d, 0x5d, 0x71, 0x9d, 0x8f, 0x04, 0x26, 0xc7 } };
    const mfplat = win.LoadLibraryW(lit("mfplat.dll")) orelse return error.MfFailure;
    defer _ = win.FreeLibrary(mfplat);
    const enum_raw = win.GetProcAddress(mfplat, "MFTEnumEx") orelse return error.MfFailure;
    const MFTEnumEx: *const fn (win.GUID, win.UINT32, ?*const anyopaque, ?*const anyopaque, *[*c]?*win.IMFActivate, *win.UINT32) callconv(.winapi) win.HRESULT = @ptrCast(@alignCast(enum_raw));
    if (MFTEnumEx(category, win.MFT_ENUM_FLAG_SYNCMFT | win.MFT_ENUM_FLAG_LOCALMFT, &input_type, &output_type, &activates, &count) < 0 or count == 0) return error.NoOpusDecoder;
    defer win.CoTaskMemFree(@ptrCast(activates));

    var transform: ?*win.IMFTransform = null;
    if (activates[0].?.lpVtbl.*.ActivateObject.?(activates[0], &guid_mftransform, @ptrCast(&transform)) < 0 or transform == null) return error.NoOpusDecoder;
    _ = activates[0].?.lpVtbl.*.Release.?(activates[0]);

    const self = try std.heap.page_allocator.create(Decoder);
    errdefer std.heap.page_allocator.destroy(self);
    self.* = .{ .allocator = std.heap.page_allocator, .transform = transform.? };

    // Input: compressed Opus, stereo-coded 48 kHz packets (WhatsApp quirk:
    // OpusHead says mono but the packets carry stereo TOCs).
    var media_type: ?*win.IMFMediaType = null;
    if (mf_create_media_type.?(&media_type) < 0 or media_type == null) return error.MfFailure;
    _ = media_type.?.*.lpVtbl.*.SetGUID.?(media_type.?, &guid_mf_mt_major_type, &guid_mf_media_type_audio);
    _ = media_type.?.*.lpVtbl.*.SetGUID.?(media_type.?, &guid_mf_mt_minor_type, &guid_mf_audio_format_opus);
    _ = media_type.?.*.lpVtbl.*.SetUINT32.?(media_type.?, &guid_mf_mt_audio_samples_per_second, output_rate);
    _ = media_type.?.*.lpVtbl.*.SetUINT32.?(media_type.?, &guid_mf_mt_audio_num_channels, output_channels);
    _ = media_type.?.*.lpVtbl.*.SetUINT32.?(media_type.?, &guid_mf_mt_audio_bits_per_sample, output_bit_depth);
    _ = media_type.?.*.lpVtbl.*.SetUINT32.?(media_type.?, &guid_mf_mt_all_samples_independent, 1);
    _ = media_type.?.*.lpVtbl.*.SetUINT32.?(media_type.?, &guid_mf_mt_compressed, 1);
    _ = media_type.?.*.lpVtbl.*.SetDouble.?(media_type.?, &guid_mf_mt_audio_float_samples_per_second, @floatFromInt(output_rate));
    const input_hr = self.transform.*.lpVtbl.*.SetInputType.?(self.transform, 0, media_type.?, 0);
    _ = media_type.?.*.lpVtbl.*.Release.?(media_type);
    if (input_hr < 0) return error.MfFailure;

    try self.refreshOutputType();
    _ = self.transform.*.lpVtbl.*.ProcessMessage.?(self.transform, win.MFT_MESSAGE_COMMAND_FLUSH, 0);
    _ = self.transform.*.lpVtbl.*.ProcessMessage.?(self.transform, win.MFT_MESSAGE_NOTIFY_BEGIN_STREAMING, 0);
    _ = self.transform.*.lpVtbl.*.ProcessMessage.?(self.transform, win.MFT_MESSAGE_NOTIFY_START_OF_STREAM, 0);
    return self;
}

// --- WASAPI output ---

const WasapiOutput = struct {
    client: *win.IAudioClient,
    render: *win.IAudioRenderClient,
    buffer_frames: u32,
    sample_rate: u32,

    fn open(rate: u32) !WasapiOutput {
        var enumerator: ?*win.IMMDeviceEnumerator = null;
        if (win.CoCreateInstance(&guid_mmdevice_enumerator, null, win.CLSCTX_ALL, &guid_immdevice_enumerator, @ptrCast(&enumerator)) < 0 or enumerator == null) return error.WasapiFailure;
        defer _ = enumerator.?.*.lpVtbl.*.Release.?(enumerator);
        var device: ?*win.IMMDevice = null;
        if (enumerator.?.*.lpVtbl.*.GetDefaultAudioEndpoint.?(enumerator.?, 0, 0, &device) < 0 or device == null) return error.WasapiFailure;
        defer _ = device.?.*.lpVtbl.*.Release.?(device);
        var client: ?*win.IAudioClient = null;
        if (device.?.lpVtbl.*.Activate.?(device.?, &guid_iaudioclient, win.CLSCTX_ALL, null, @ptrCast(&client)) < 0 or client == null) return error.WasapiFailure;

        var format = std.mem.zeroes(win.WAVEFORMATEX);
        format.wFormatTag = win.WAVE_FORMAT_IEEE_FLOAT;
        format.nChannels = output_channels;
        format.nSamplesPerSec = rate;
        format.wBitsPerSample = 32;
        format.nBlockAlign = format.nChannels * format.wBitsPerSample / 8;
        format.nAvgBytesPerSec = format.nSamplesPerSec * format.nBlockAlign;
        const flags: win.DWORD = win.AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | win.AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
        if (client.?.*.lpVtbl.*.Initialize.?(client.?, 0, flags, 200 * 10_000, 0, &format, null) < 0) {
            _ = client.?.*.lpVtbl.*.Release.?(client);
            return error.WasapiFailure;
        }
        var render: ?*win.IAudioRenderClient = null;
        if (client.?.*.lpVtbl.*.GetService.?(client.?, &guid_iaudiorenderclient, @ptrCast(&render)) < 0 or render == null) {
            _ = client.?.*.lpVtbl.*.Release.?(client);
            return error.WasapiFailure;
        }
        var buffer_frames: win.UINT32 = 0;
        _ = client.?.*.lpVtbl.*.GetBufferSize.?(client.?, &buffer_frames);
        _ = client.?.*.lpVtbl.*.Start.?(client.?);
        return .{
            .client = client.?,
            .render = render.?,
            .buffer_frames = buffer_frames,
            .sample_rate = rate,
        };
    }

    fn renderFrame(self: *WasapiOutput, player: *Player, playing: bool) !void {
        var padding: win.UINT32 = 0;
        if (self.client.*.lpVtbl.*.GetCurrentPadding.?(self.client, &padding) < 0) return;
        if (padding >= self.buffer_frames) return;
        const frames_free = self.buffer_frames - padding;
        if (frames_free == 0) return;
        var data_ptr: [*c]u8 = null;
        if (self.render.*.lpVtbl.*.GetBuffer.?(self.render, frames_free, &data_ptr) < 0) return;
        const samples: [*]f32 = @ptrCast(@alignCast(data_ptr));
        const channels: u64 = player.ring_channels;
        const total: u64 = @as(u64, frames_free) * channels;
        var written: u64 = 0;
        if (playing) {
            const ring_capacity_frames: u64 = @intCast(player.ring.len / player.ring_channels);
            while (written < total) {
                const read = player.ring_read.load(.acquire);
                const available = player.ring_write.load(.acquire) - read;
                if (available == 0) break;
                const slot = (read % ring_capacity_frames) * channels;
                const chunk_frames = @min(@min(available, (total - written) / channels), ring_capacity_frames - (read % ring_capacity_frames));
                const copy = chunk_frames * channels;
                @memcpy(samples[written .. written + copy], player.ring[@intCast(slot)..][0..@intCast(copy)]);
                player.ring_read.store(read + chunk_frames, .release);
                written += copy;
            }
        }
        @memset(samples[written..total], 0);
        _ = self.render.*.lpVtbl.*.ReleaseBuffer.?(self.render, frames_free, 0);
        if (playing and written > 0) {
            // Convert this chunk to source time at the speed in effect now,
            // so later speed changes do not rescale earlier audio.
            const src_frames = written / channels * player.speed() / 100;
            _ = player.rendered_src.fetchAdd(src_frames, .release);
            player.storePositionMs();
        }
    }

    fn drain(self: *WasapiOutput) void {
        var waited: u32 = 0;
        while (waited < 1000) : (waited += 20) {
            var padding: win.UINT32 = 0;
            if (self.client.*.lpVtbl.*.GetCurrentPadding.?(self.client, &padding) < 0) return;
            if (padding == 0) return;
            win.Sleep(20);
        }
    }

    fn stopOutput(self: *WasapiOutput) void {
        _ = self.client.*.lpVtbl.*.Stop.?(self.client);
    }

    fn close(self: *WasapiOutput) void {
        _ = self.client.*.lpVtbl.*.Stop.?(self.client);
        _ = self.render.*.lpVtbl.*.Release.?(self.render);
        _ = self.client.*.lpVtbl.*.Release.?(self.client);
    }
};

fn lit(comptime text: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}
