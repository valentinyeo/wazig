// Voice-note recording: WASAPI microphone capture on a worker thread, then
// in-process Opus encoding (voice_note.zig). The UI polls level, elapsed time
// and state; it never blocks on audio.
const std = @import("std");
const mic_choice = @import("mic_choice.zig");
const voice_note = @import("voice_note.zig");
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("COBJMACROS", "1");
    @cInclude("windows.h");
    @cInclude("objbase.h");
    @cInclude("mmdeviceapi.h");
    @cInclude("audioclient.h");
});

pub const State = enum(u8) { idle, recording, encoding, ready, failed };

/// Longest note we record; the capture stops by itself at this point.
pub const max_seconds: u32 = 300;

const guid_mmdevice_enumerator = win.GUID{ .Data1 = 0xbcde0395, .Data2 = 0xe52f, .Data3 = 0x467c, .Data4 = .{ 0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e } };
const guid_immdevice_enumerator = win.GUID{ .Data1 = 0xa95664d2, .Data2 = 0x9614, .Data3 = 0x4f35, .Data4 = .{ 0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6 } };
const guid_iaudioclient = win.GUID{ .Data1 = 0x1cb9ad4c, .Data2 = 0xdbfa, .Data3 = 0x4c32, .Data4 = .{ 0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2 } };
const guid_iaudiocaptureclient = win.GUID{ .Data1 = 0xc8adbd64, .Data2 = 0xe71e, .Data3 = 0x48a0, .Data4 = .{ 0xa4, 0xde, 0x18, 0x5c, 0x39, 0x5c, 0xd3, 0x17 } };

pub const Session = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    cancelled: std.atomic.Value(bool) = .init(false),
    state_value: std.atomic.Value(u8) = .init(@intFromEnum(State.idle)),
    // 48 kHz mono samples captured so far, and the loudest sample of the
    // last block (0..32767), both written by the worker and read by the UI.
    samples: std.atomic.Value(usize) = .init(0),
    level: std.atomic.Value(u32) = .init(0),
    result: ?voice_note.Result = null,

    pub fn create(allocator: std.mem.Allocator) !*Session {
        const self = try allocator.create(Session);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *Session) void {
        self.cancelled.store(true, .release);
        self.stop_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.result) |result| self.allocator.free(result.ogg);
        self.allocator.destroy(self);
    }

    pub fn state(self: *const Session) State {
        return @enumFromInt(self.state_value.load(.acquire));
    }

    pub fn elapsedMs(self: *const Session) u64 {
        return @as(u64, self.samples.load(.acquire)) * 1000 / voice_note.sample_rate;
    }

    /// Peak of the latest audio, 0..100 for the level meter.
    pub fn levelPercent(self: *const Session) u32 {
        return @min(100, self.level.load(.acquire) * 100 / 16384);
    }

    pub fn start(self: *Session) bool {
        const current = self.state();
        if (current == .recording or current == .encoding) return false;
        self.reap();
        self.stop_requested.store(false, .release);
        self.cancelled.store(false, .release);
        self.samples.store(0, .release);
        self.level.store(0, .release);
        self.state_value.store(@intFromEnum(State.recording), .release);
        self.thread = std.Thread.spawn(.{ .stack_size = 2 * 1024 * 1024 }, workerMain, .{self}) catch {
            self.state_value.store(@intFromEnum(State.failed), .release);
            return false;
        };
        return true;
    }

    /// Ends the recording; the worker encodes and the state turns `ready`.
    pub fn finish(self: *Session) void {
        self.stop_requested.store(true, .release);
    }

    /// Ends the recording and throws the audio away.
    pub fn cancel(self: *Session) void {
        self.cancelled.store(true, .release);
        self.stop_requested.store(true, .release);
    }

    /// Joins a finished worker and returns to idle. Safe in any non-running state.
    pub fn reap(self: *Session) void {
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        if (self.result) |result| {
            self.allocator.free(result.ogg);
            self.result = null;
        }
        self.state_value.store(@intFromEnum(State.idle), .release);
    }

    /// Takes the encoded note (caller frees `ogg`). Only valid in `ready`.
    pub fn take(self: *Session) ?voice_note.Result {
        if (self.state() != .ready) return null;
        const result = self.result;
        self.result = null;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        self.state_value.store(@intFromEnum(State.idle), .release);
        return result;
    }
};

fn workerMain(self: *Session) void {
    var pcm: std.ArrayList(i16) = .empty;
    defer pcm.deinit(self.allocator);
    capture(self, &pcm) catch {
        self.state_value.store(@intFromEnum(State.failed), .release);
        return;
    };
    if (self.cancelled.load(.acquire)) {
        self.state_value.store(@intFromEnum(State.idle), .release);
        return;
    }
    // Under a quarter second is an accidental click, not a note.
    if (pcm.items.len < voice_note.sample_rate / 4) {
        self.state_value.store(@intFromEnum(State.failed), .release);
        return;
    }
    self.state_value.store(@intFromEnum(State.encoding), .release);
    self.result = voice_note.encode(self.allocator, pcm.items) catch {
        self.state_value.store(@intFromEnum(State.failed), .release);
        return;
    };
    self.state_value.store(@intFromEnum(State.ready), .release);
}

fn capture(self: *Session, pcm: *std.ArrayList(i16)) !void {
    _ = win.CoInitializeEx(null, win.COINIT_MULTITHREADED);
    defer win.CoUninitialize();

    var enumerator: ?*win.IMMDeviceEnumerator = null;
    if (win.CoCreateInstance(&guid_mmdevice_enumerator, null, win.CLSCTX_ALL, &guid_immdevice_enumerator, @ptrCast(&enumerator)) < 0 or enumerator == null) return error.NoMicrophone;
    defer _ = enumerator.?.*.lpVtbl.*.Release.?(enumerator);

    var device: ?*win.IMMDevice = null;
    // The microphone picked in the palette, else the Windows default.
    if (mic_choice.openChosen()) |picked| device = @ptrCast(@alignCast(picked));
    if (device == null and (enumerator.?.*.lpVtbl.*.GetDefaultAudioEndpoint.?(enumerator.?, win.eCapture, win.eCommunications, &device) < 0 or device == null)) return error.NoMicrophone;
    defer _ = device.?.*.lpVtbl.*.Release.?(device);

    var client: ?*win.IAudioClient = null;
    if (device.?.*.lpVtbl.*.Activate.?(device.?, &guid_iaudioclient, win.CLSCTX_ALL, null, @ptrCast(&client)) < 0 or client == null) return error.NoMicrophone;
    defer _ = client.?.*.lpVtbl.*.Release.?(client);

    var format: ?*win.WAVEFORMATEX = null;
    if (client.?.*.lpVtbl.*.GetMixFormat.?(client.?, &format) < 0 or format == null) return error.NoMicrophone;
    defer win.CoTaskMemFree(format);
    const wave_format = format.?;
    if (wave_format.nBlockAlign == 0 or wave_format.nChannels == 0 or wave_format.nSamplesPerSec == 0) return error.UnsupportedFormat;

    // The shared-mode mix format is float32 on virtually every machine; 16-bit
    // PCM is the other shape worth handling. Anything else fails cleanly.
    var is_float = wave_format.wFormatTag == win.WAVE_FORMAT_IEEE_FLOAT;
    if (wave_format.wFormatTag == 0xFFFE and wave_format.cbSize >= 22) {
        const bytes: [*]const u8 = @ptrCast(wave_format);
        const sub_format = std.mem.readInt(u32, bytes[24..28], .little);
        is_float = sub_format == 3;
        if (sub_format != 3 and sub_format != 1) return error.UnsupportedFormat;
    } else if (wave_format.wFormatTag != win.WAVE_FORMAT_IEEE_FLOAT and wave_format.wFormatTag != win.WAVE_FORMAT_PCM) {
        return error.UnsupportedFormat;
    }
    if (is_float and wave_format.wBitsPerSample != 32) return error.UnsupportedFormat;
    if (!is_float and wave_format.wBitsPerSample != 16) return error.UnsupportedFormat;

    if (client.?.*.lpVtbl.*.Initialize.?(client.?, win.AUDCLNT_SHAREMODE_SHARED, 0, 1 * 10_000_000, 0, wave_format, null) < 0) return error.NoMicrophone;
    var capture_client: ?*win.IAudioCaptureClient = null;
    if (client.?.*.lpVtbl.*.GetService.?(client.?, &guid_iaudiocaptureclient, @ptrCast(&capture_client)) < 0 or capture_client == null) return error.NoMicrophone;
    defer _ = capture_client.?.*.lpVtbl.*.Release.?(capture_client);

    var converter = voice_note.Converter{
        .in_rate = wave_format.nSamplesPerSec,
        .channels = wave_format.nChannels,
        .float_samples = is_float,
        .bits = wave_format.wBitsPerSample,
    };
    if (client.?.*.lpVtbl.*.Start.?(client.?) < 0) return error.NoMicrophone;
    defer _ = client.?.*.lpVtbl.*.Stop.?(client.?);

    const max_samples: usize = @as(usize, max_seconds) * voice_note.sample_rate;
    var silence: std.ArrayList(u8) = .empty;
    defer silence.deinit(self.allocator);
    while (!self.stop_requested.load(.acquire) and pcm.items.len < max_samples) {
        var packet_frames: win.UINT32 = 0;
        if (capture_client.?.*.lpVtbl.*.GetNextPacketSize.?(capture_client.?, &packet_frames) < 0) return error.CaptureFailed;
        while (packet_frames > 0) {
            var data: [*c]u8 = null;
            var frames: win.UINT32 = 0;
            var flags: win.DWORD = 0;
            var device_position: win.UINT64 = 0;
            var qpc_position: win.UINT64 = 0;
            if (capture_client.?.*.lpVtbl.*.GetBuffer.?(capture_client.?, &data, &frames, &flags, &device_position, &qpc_position) < 0) return error.CaptureFailed;
            const byte_count: usize = @as(usize, frames) * wave_format.nBlockAlign;
            const before = pcm.items.len;
            if ((flags & win.AUDCLNT_BUFFERFLAGS_SILENT) != 0) {
                try silence.resize(self.allocator, byte_count);
                @memset(silence.items, 0);
                try converter.push(self.allocator, pcm, silence.items, frames);
            } else {
                try converter.push(self.allocator, pcm, data[0..byte_count], frames);
            }
            var peak: u32 = 0;
            for (pcm.items[before..]) |sample| peak = @max(peak, @abs(@as(i32, sample)));
            self.level.store(peak, .release);
            self.samples.store(pcm.items.len, .release);
            if (capture_client.?.*.lpVtbl.*.ReleaseBuffer.?(capture_client.?, frames) < 0) return error.CaptureFailed;
            if (capture_client.?.*.lpVtbl.*.GetNextPacketSize.?(capture_client.?, &packet_frames) < 0) return error.CaptureFailed;
        }
        win.Sleep(10);
    }
}
