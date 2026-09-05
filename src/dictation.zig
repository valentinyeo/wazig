// Native Windows microphone capture and Deepgram transcription.
const std = @import("std");
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("COBJMACROS", "1");
    @cInclude("windows.h");
    @cInclude("objbase.h");
    @cInclude("mmdeviceapi.h");
    @cInclude("audioclient.h");
    @cInclude("winhttp.h");
});

pub const State = enum(u8) { idle, recording, transcribing, ready, failed };
pub const Language = enum(u8) { automatic, english, german };

const guid_mmdevice_enumerator = win.GUID{ .Data1 = 0xbcde0395, .Data2 = 0xe52f, .Data3 = 0x467c, .Data4 = .{ 0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e } };
const guid_immdevice_enumerator = win.GUID{ .Data1 = 0xa95664d2, .Data2 = 0x9614, .Data3 = 0x4f35, .Data4 = .{ 0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6 } };
const guid_iaudioclient = win.GUID{ .Data1 = 0x1cb9ad4c, .Data2 = 0xdbfa, .Data3 = 0x4c32, .Data4 = .{ 0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2 } };
const guid_iaudiocaptureclient = win.GUID{ .Data1 = 0xc8adbd64, .Data2 = 0xe71e, .Data3 = 0x48a0, .Data4 = .{ 0xa4, 0xde, 0x18, 0x5c, 0x39, 0x5c, 0xd3, 0x17 } };

pub const Session = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    state_value: std.atomic.Value(u8) = .init(@intFromEnum(State.idle)),
    result: [8192]u8 = [_]u8{0} ** 8192,
    result_len: usize = 0,

    pub fn create(allocator: std.mem.Allocator) !*Session {
        const self = try allocator.create(Session);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *Session) void {
        self.requestStop();
        if (self.thread) |thread| thread.join();
        self.allocator.destroy(self);
    }

    pub fn state(self: *const Session) State {
        return @enumFromInt(self.state_value.load(.acquire));
    }

    pub fn start(self: *Session, api_key: []const u8, language: Language) bool {
        if (self.state() != .idle and self.state() != .failed) return false;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        const key = self.allocator.dupe(u8, api_key) catch return false;
        self.result_len = 0;
        self.stop_requested.store(false, .release);
        self.state_value.store(@intFromEnum(State.recording), .release);
        self.thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, workerMain, .{ self, key, language }) catch {
            self.allocator.free(key);
            self.state_value.store(@intFromEnum(State.failed), .release);
            return false;
        };
        return true;
    }

    pub fn requestStop(self: *Session) void {
        if (self.state() == .recording) self.stop_requested.store(true, .release);
    }

    pub fn takeTranscript(self: *Session, destination: []u8) ?[]const u8 {
        if (self.state() != .ready) return null;
        const length = @min(destination.len, self.result_len);
        @memcpy(destination[0..length], self.result[0..length]);
        self.state_value.store(@intFromEnum(State.idle), .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        return destination[0..length];
    }
};

fn workerMain(self: *Session, api_key: []u8, language: Language) void {
    defer self.allocator.free(api_key);
    const wav = captureMicrophone(self) catch {
        self.state_value.store(@intFromEnum(State.failed), .release);
        return;
    };
    defer self.allocator.free(wav);
    if (wav.len <= 44) {
        self.state_value.store(@intFromEnum(State.failed), .release);
        return;
    }
    self.state_value.store(@intFromEnum(State.transcribing), .release);
    const transcript = transcribe(self.allocator, api_key, language, "audio/wav", wav) catch {
        self.state_value.store(@intFromEnum(State.failed), .release);
        return;
    };
    defer self.allocator.free(transcript);
    self.result_len = @min(self.result.len, transcript.len);
    @memcpy(self.result[0..self.result_len], transcript[0..self.result_len]);
    self.state_value.store(@intFromEnum(State.ready), .release);
}

fn captureMicrophone(self: *Session) ![]u8 {
    _ = win.CoInitializeEx(null, win.COINIT_MULTITHREADED);
    defer win.CoUninitialize();

    var enumerator: ?*win.IMMDeviceEnumerator = null;
    if (win.CoCreateInstance(&guid_mmdevice_enumerator, null, win.CLSCTX_ALL, &guid_immdevice_enumerator, @ptrCast(&enumerator)) < 0 or enumerator == null) return error.NoMicrophone;
    defer _ = enumerator.?.*.lpVtbl.*.Release.?(enumerator);

    var device: ?*win.IMMDevice = null;
    if (enumerator.?.*.lpVtbl.*.GetDefaultAudioEndpoint.?(enumerator.?, win.eCapture, win.eCommunications, &device) < 0 or device == null) return error.NoMicrophone;
    defer _ = device.?.*.lpVtbl.*.Release.?(device);

    var client: ?*win.IAudioClient = null;
    if (device.?.*.lpVtbl.*.Activate.?(device.?, &guid_iaudioclient, win.CLSCTX_ALL, null, @ptrCast(&client)) < 0 or client == null) return error.NoMicrophone;
    defer _ = client.?.*.lpVtbl.*.Release.?(client);

    var format: ?*win.WAVEFORMATEX = null;
    if (client.?.*.lpVtbl.*.GetMixFormat.?(client.?, &format) < 0 or format == null) return error.NoMicrophone;
    defer win.CoTaskMemFree(format);
    const wave_format = format.?;
    if (wave_format.nBlockAlign == 0) return error.UnsupportedFormat;

    if (client.?.*.lpVtbl.*.Initialize.?(client.?, win.AUDCLNT_SHAREMODE_SHARED, 0, 1 * 10_000_000, 0, wave_format, null) < 0) return error.NoMicrophone;
    var capture: ?*win.IAudioCaptureClient = null;
    if (client.?.*.lpVtbl.*.GetService.?(client.?, &guid_iaudiocaptureclient, @ptrCast(&capture)) < 0 or capture == null) return error.NoMicrophone;
    defer _ = capture.?.*.lpVtbl.*.Release.?(capture);

    var pcm: std.ArrayList(u8) = .empty;
    defer pcm.deinit(self.allocator);
    if (client.?.*.lpVtbl.*.Start.?(client.?) < 0) return error.NoMicrophone;
    defer _ = client.?.*.lpVtbl.*.Stop.?(client.?);

    const max_bytes: usize = @as(usize, wave_format.nAvgBytesPerSec) * 10 * 60;
    while (!self.stop_requested.load(.acquire) and pcm.items.len < max_bytes) {
        var packet_frames: win.UINT32 = 0;
        if (capture.?.*.lpVtbl.*.GetNextPacketSize.?(capture.?, &packet_frames) < 0) return error.CaptureFailed;
        while (packet_frames > 0) {
            var data: [*c]u8 = null;
            var frames: win.UINT32 = 0;
            var flags: win.DWORD = 0;
            var device_position: win.UINT64 = 0;
            var qpc_position: win.UINT64 = 0;
            if (capture.?.*.lpVtbl.*.GetBuffer.?(capture.?, &data, &frames, &flags, &device_position, &qpc_position) < 0) return error.CaptureFailed;
            const byte_count: usize = @as(usize, frames) * wave_format.nBlockAlign;
            if ((flags & win.AUDCLNT_BUFFERFLAGS_SILENT) != 0) {
                const old_len = pcm.items.len;
                try pcm.resize(self.allocator, old_len + byte_count);
                @memset(pcm.items[old_len..], 0);
            } else {
                try pcm.appendSlice(self.allocator, data[0..byte_count]);
            }
            if (capture.?.*.lpVtbl.*.ReleaseBuffer.?(capture.?, frames) < 0) return error.CaptureFailed;
            if (capture.?.*.lpVtbl.*.GetNextPacketSize.?(capture.?, &packet_frames) < 0) return error.CaptureFailed;
        }
        win.Sleep(10);
    }

    const simple_format = wave_format.wFormatTag == win.WAVE_FORMAT_PCM or wave_format.wFormatTag == win.WAVE_FORMAT_IEEE_FLOAT;
    const format_size: usize = if (simple_format) 16 else 18 + wave_format.cbSize;
    const total_size = 12 + 8 + format_size + 8 + pcm.items.len;
    const wav = try self.allocator.alloc(u8, total_size);
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], @intCast(total_size - 8), .little);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], @intCast(format_size), .little);
    const format_bytes: [*]const u8 = @ptrCast(wave_format);
    @memcpy(wav[20 .. 20 + format_size], format_bytes[0..format_size]);
    const data_header = 20 + format_size;
    @memcpy(wav[data_header .. data_header + 4], "data");
    std.mem.writeInt(u32, wav[data_header + 4 ..][0..4], @intCast(pcm.items.len), .little);
    @memcpy(wav[data_header + 8 ..], pcm.items);
    return wav;
}

fn transcribe(allocator: std.mem.Allocator, api_key: []const u8, language: Language, content_type: []const u8, body: []const u8) ![]u8 {
    const session = win.WinHttpOpen(lit("Wazig Messages/0.3"), win.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(session);
    _ = win.WinHttpSetTimeouts(session, 10_000, 10_000, 30_000, 120_000);
    const connection = win.WinHttpConnect(session, lit("api.deepgram.com"), win.INTERNET_DEFAULT_HTTPS_PORT, 0) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(connection);
    const request_path = switch (language) {
        .automatic => lit("/v1/listen?model=nova-3&smart_format=true&detect_language=true"),
        .english => lit("/v1/listen?model=nova-3&smart_format=true&language=en"),
        .german => lit("/v1/listen?model=nova-3&smart_format=true&language=de"),
    };
    const request = win.WinHttpOpenRequest(connection, lit("POST"), request_path, null, null, null, win.WINHTTP_FLAG_SECURE) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(request);

    const headers_utf8 = try std.fmt.allocPrint(allocator, "Authorization: Token {s}\r\nContent-Type: {s}\r\n", .{ api_key, content_type });
    defer allocator.free(headers_utf8);
    const headers = try std.unicode.utf8ToUtf16LeAllocZ(allocator, headers_utf8);
    defer allocator.free(headers);
    if (win.WinHttpSendRequest(request, headers.ptr, @intCast(headers.len), @ptrCast(@constCast(body.ptr)), @intCast(body.len), @intCast(body.len), 0) == 0) return error.NetworkFailed;
    if (win.WinHttpReceiveResponse(request, null) == 0) return error.NetworkFailed;
    var status_code: win.DWORD = 0;
    var status_size: win.DWORD = @sizeOf(win.DWORD);
    if (win.WinHttpQueryHeaders(request, win.WINHTTP_QUERY_STATUS_CODE | win.WINHTTP_QUERY_FLAG_NUMBER, null, &status_code, &status_size, null) == 0 or status_code < 200 or status_code >= 300) return error.ApiFailed;

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(allocator);
    while (true) {
        var available: win.DWORD = 0;
        if (win.WinHttpQueryDataAvailable(request, &available) == 0) return error.NetworkFailed;
        if (available == 0) break;
        const old_len = response.items.len;
        try response.resize(allocator, old_len + available);
        var read: win.DWORD = 0;
        if (win.WinHttpReadData(request, response.items.ptr + old_len, available, &read) == 0) return error.NetworkFailed;
        response.shrinkRetainingCapacity(old_len + read);
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.items, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.BadResponse,
    };
    const results = switch (root.get("results") orelse return error.BadResponse) {
        .object => |value| value,
        else => return error.BadResponse,
    };
    const channels = switch (results.get("channels") orelse return error.BadResponse) {
        .array => |value| value,
        else => return error.BadResponse,
    };
    if (channels.items.len == 0) return error.NoSpeech;
    const channel = switch (channels.items[0]) {
        .object => |value| value,
        else => return error.BadResponse,
    };
    const alternatives = switch (channel.get("alternatives") orelse return error.BadResponse) {
        .array => |value| value,
        else => return error.BadResponse,
    };
    if (alternatives.items.len == 0) return error.NoSpeech;
    const alternative = switch (alternatives.items[0]) {
        .object => |value| value,
        else => return error.BadResponse,
    };
    const transcript = switch (alternative.get("transcript") orelse return error.BadResponse) {
        .string => |value| value,
        else => return error.BadResponse,
    };
    if (transcript.len == 0) return error.NoSpeech;
    return allocator.dupe(u8, transcript);
}

fn lit(comptime text: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

// Transcribes an audio file that already exists on disk (voice notes).
pub const FileSession = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    state_value: std.atomic.Value(u8) = .init(@intFromEnum(State.idle)),
    result: [8192]u8 = [_]u8{0} ** 8192,
    result_len: usize = 0,

    pub fn create(allocator: std.mem.Allocator) !*FileSession {
        const self = try allocator.create(FileSession);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *FileSession) void {
        if (self.thread) |thread| thread.join();
        self.allocator.destroy(self);
    }

    pub fn state(self: *const FileSession) State {
        return @enumFromInt(self.state_value.load(.acquire));
    }

    pub fn start(self: *FileSession, path: []const u8, api_key: []const u8, language: Language) bool {
        if (self.state() == .recording or self.state() == .transcribing) return false;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        const path_copy = self.allocator.dupe(u8, path) catch return false;
        const key = self.allocator.dupe(u8, api_key) catch {
            self.allocator.free(path_copy);
            return false;
        };
        self.result_len = 0;
        self.state_value.store(@intFromEnum(State.recording), .release);
        self.thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, fileWorker, .{ self, path_copy, key, language }) catch {
            self.allocator.free(path_copy);
            self.allocator.free(key);
            self.state_value.store(@intFromEnum(State.failed), .release);
            return false;
        };
        return true;
    }

    pub fn takeResult(self: *FileSession, destination: []u8) ?[]const u8 {
        if (self.state() != .ready) return null;
        const length = @min(destination.len, self.result_len);
        @memcpy(destination[0..length], self.result[0..length]);
        self.state_value.store(@intFromEnum(State.idle), .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        return destination[0..length];
    }
};

fn fileWorker(self: *FileSession, path: []u8, api_key: []u8, language: Language) void {
    defer self.allocator.free(path);
    defer self.allocator.free(api_key);
    const data = readSmallFile(self.allocator, path, 24 * 1024 * 1024) orelse {
        self.state_value.store(@intFromEnum(State.failed), .release);
        return;
    };
    defer self.allocator.free(data);
    self.state_value.store(@intFromEnum(State.transcribing), .release);
    const transcript = transcribe(self.allocator, api_key, language, "audio/ogg", data) catch {
        self.state_value.store(@intFromEnum(State.failed), .release);
        return;
    };
    defer self.allocator.free(transcript);
    self.result_len = @min(self.result.len, transcript.len);
    @memcpy(self.result[0..self.result_len], transcript[0..self.result_len]);
    self.state_value.store(@intFromEnum(State.ready), .release);
}

// Formats a transcript through OpenRouter for easier reading.
pub const TextSession = struct {
    allocator: std.mem.Allocator,
    thread: ?std.Thread = null,
    state_value: std.atomic.Value(u8) = .init(@intFromEnum(State.idle)),
    result: [16384]u8 = [_]u8{0} ** 16384,
    result_len: usize = 0,

    pub fn create(allocator: std.mem.Allocator) !*TextSession {
        const self = try allocator.create(TextSession);
        self.* = .{ .allocator = allocator };
        return self;
    }

    pub fn destroy(self: *TextSession) void {
        if (self.thread) |thread| thread.join();
        self.allocator.destroy(self);
    }

    pub fn state(self: *const TextSession) State {
        return @enumFromInt(self.state_value.load(.acquire));
    }

    pub fn start(self: *TextSession, text: []const u8, api_key: []const u8, model: []const u8) bool {
        if (self.state() == .recording or self.state() == .transcribing) return false;
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        const text_copy = self.allocator.dupe(u8, text) catch return false;
        const key = self.allocator.dupe(u8, api_key) catch {
            self.allocator.free(text_copy);
            return false;
        };
        const model_copy = self.allocator.dupe(u8, model) catch {
            self.allocator.free(text_copy);
            self.allocator.free(key);
            return false;
        };
        self.result_len = 0;
        self.state_value.store(@intFromEnum(State.recording), .release);
        self.thread = std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, formatWorker, .{ self, text_copy, key, model_copy }) catch {
            self.allocator.free(text_copy);
            self.allocator.free(key);
            self.allocator.free(model_copy);
            self.state_value.store(@intFromEnum(State.failed), .release);
            return false;
        };
        return true;
    }

    pub fn takeResult(self: *TextSession, destination: []u8) ?[]const u8 {
        if (self.state() != .ready) return null;
        const length = @min(destination.len, self.result_len);
        @memcpy(destination[0..length], self.result[0..length]);
        self.state_value.store(@intFromEnum(State.idle), .release);
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
        return destination[0..length];
    }
};

fn appendJsonEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |character| {
        switch (character) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (character < 0x20) {
                    try list.appendSlice(allocator, " ");
                } else {
                    try list.append(allocator, character);
                }
            },
        }
    }
}

fn formatWorker(self: *TextSession, text: []u8, api_key: []u8, model: []u8) void {
    defer self.allocator.free(text);
    defer self.allocator.free(api_key);
    defer self.allocator.free(model);
    self.state_value.store(@intFromEnum(State.transcribing), .release);
    const formatted = formatTranscript(self.allocator, text, api_key, model) catch {
        self.state_value.store(@intFromEnum(State.failed), .release);
        return;
    };
    defer self.allocator.free(formatted);
    self.result_len = @min(self.result.len, formatted.len);
    @memcpy(self.result[0..self.result_len], formatted[0..self.result_len]);
    self.state_value.store(@intFromEnum(State.ready), .release);
}

fn formatTranscript(allocator: std.mem.Allocator, transcript: []const u8, api_key: []const u8, model: []const u8) ![]u8 {
    const system_prompt =
        \\You format raw voice-message transcripts for a reader with ADHD.
        \\
        \\INPUT: a raw transcript, usually one unbroken block of spoken text, often rambling, with filler words, false starts, and repetition. It may be in any language.
        \\
        \\ABSOLUTE RULE: You must not change, add, remove, correct, translate, or "clean up" a single word. No fixing grammar. No deleting filler. No merging repetitions. Keep the speaker's exact words in the exact original order, including stutters, false starts, and unfinished sentences. If the transcript ends mid-word, keep it mid-word and say so at the end.
        \\
        \\Your ONLY freedoms are: where you break lines, what headers you insert, and the summary you write at the top.
        \\
        \\OUTPUT, in this order:
        \\
        \\1. Start directly with 3 to 5 numbered lines, in the reader's language, summarizing what the speaker actually said. This is the only part you write yourself. One line per topic. Concrete, not vague: "trigger shot at 2am, next step Monday" not "she talks about medical stuff." Do not write any headline or title before or above them.
        \\
        \\2. A horizontal rule.
        \\
        \\3. The full transcript, segmented:
        \\- Split the transcript into 3 to 6 topic sections. Give each a short header: a number plus 2 to 4 words naming the topic.
        \\- Under each header, break the text into bullet points. One bullet per clause or thought unit - roughly where the speaker would breathe.
        \\- Break at natural boundaries: after a completed thought, before "aber", "und dann", "also", "weil", "so", "but", "and then", etc.
        \\- Do NOT bullet every few words. A bullet is a unit of meaning, usually 5 to 25 words.
        \\- Keep punctuation exactly as in the input. Do not add periods to make bullets look finished.
        \\
        \\4. If the transcript is cut off or incomplete, one final line stating that plainly.
        \\
        \\STYLE: No preamble. No "Here is your formatted transcript." No closing pleasantries. Start with the Gist, end with the last bullet or the cutoff note.
        \\
        \\If you are ever unsure whether a change is allowed: it is not. Keep the words.
    ;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"model\":\"");
    try appendJsonEscaped(&body, allocator, model);
    try body.appendSlice(allocator, "\",\"reasoning\":{\"effort\":\"medium\"},\"temperature\":0.2,\"messages\":[{\"role\":\"system\",\"content\":\"");
    try appendJsonEscaped(&body, allocator, system_prompt);
    try body.appendSlice(allocator, "\"},{\"role\":\"user\",\"content\":\"");
    try appendJsonEscaped(&body, allocator, transcript);
    try body.appendSlice(allocator, "\"}]}");

    const session = win.WinHttpOpen(lit("Wazig Messages/0.9"), win.WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY, null, null, 0) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(session);
    _ = win.WinHttpSetTimeouts(session, 10_000, 10_000, 30_000, 180_000);
    const connection = win.WinHttpConnect(session, lit("openrouter.ai"), win.INTERNET_DEFAULT_HTTPS_PORT, 0) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(connection);
    const request = win.WinHttpOpenRequest(connection, lit("POST"), lit("/api/v1/chat/completions"), null, null, null, win.WINHTTP_FLAG_SECURE) orelse return error.NetworkFailed;
    defer _ = win.WinHttpCloseHandle(request);

    const headers_utf8 = try std.fmt.allocPrint(allocator, "Authorization: Bearer {s}\r\nContent-Type: application/json\r\n", .{api_key});
    defer allocator.free(headers_utf8);
    const headers = try std.unicode.utf8ToUtf16LeAllocZ(allocator, headers_utf8);
    defer allocator.free(headers);
    if (win.WinHttpSendRequest(request, headers.ptr, @intCast(headers_utf8.len), @ptrCast(@constCast(body.items.ptr)), @intCast(body.items.len), @intCast(body.items.len), 0) == 0) return error.NetworkFailed;
    if (win.WinHttpReceiveResponse(request, null) == 0) return error.NetworkFailed;
    var status_code: win.DWORD = 0;
    var status_size: win.DWORD = @sizeOf(win.DWORD);
    if (win.WinHttpQueryHeaders(request, win.WINHTTP_QUERY_STATUS_CODE | win.WINHTTP_QUERY_FLAG_NUMBER, null, &status_code, &status_size, null) == 0 or status_code < 200 or status_code >= 300) return error.ApiFailed;

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(allocator);
    while (true) {
        var available: win.DWORD = 0;
        if (win.WinHttpQueryDataAvailable(request, &available) == 0) return error.NetworkFailed;
        if (available == 0) break;
        const old_len = response.items.len;
        try response.resize(allocator, old_len + available);
        var read: win.DWORD = 0;
        if (win.WinHttpReadData(request, response.items.ptr + old_len, available, &read) == 0) return error.NetworkFailed;
        response.shrinkRetainingCapacity(old_len + read);
    }

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response.items, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.BadResponse,
    };
    const choices = switch (root.get("choices") orelse return error.BadResponse) {
        .array => |value| value,
        else => return error.BadResponse,
    };
    if (choices.items.len == 0) return error.BadResponse;
    const choice = switch (choices.items[0]) {
        .object => |value| value,
        else => return error.BadResponse,
    };
    const message_value = switch (choice.get("message") orelse return error.BadResponse) {
        .object => |value| value,
        else => return error.BadResponse,
    };
    const content = switch (message_value.get("content") orelse return error.BadResponse) {
        .string => |value| value,
        else => return error.BadResponse,
    };
    const trimmed = std.mem.trim(u8, content, " \r\n\t");
    if (trimmed.len == 0) return error.BadResponse;
    return allocator.dupe(u8, trimmed);
}

fn readSmallFile(allocator: std.mem.Allocator, path_utf8: []const u8, max_bytes: usize) ?[]u8 {
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
