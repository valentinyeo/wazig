// Voice-note encoding: mono 48 kHz PCM -> Ogg Opus (libopus, vendored), plus
// the length and 64-bar waveform WhatsApp shows for a voice note. No Windows
// APIs here, so everything is unit-tested on any host.
const std = @import("std");
pub const c = @cImport({
    @cInclude("opus.h");
});

pub const sample_rate: u32 = 48000;
pub const frame_samples: usize = 960; // 20 ms
pub const waveform_bars: usize = 64;
const bitrate: i32 = 24000;
const packets_per_page: usize = 50; // about one second

pub const Result = struct {
    ogg: []u8,
    seconds: u32,
    waveform: [waveform_bars]u8,
};

// ---------------------------------------------------------------- Ogg

const crc_table = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, i| {
        var r: u32 = @as(u32, @intCast(i)) << 24;
        for (0..8) |_| r = if (r & 0x80000000 != 0) (r << 1) ^ 0x04c11db7 else r << 1;
        entry.* = r;
    }
    break :blk table;
};

pub fn oggCrc(data: []const u8) u32 {
    var crc: u32 = 0;
    for (data) |byte| crc = (crc << 8) ^ crc_table[@as(u8, @truncate(crc >> 24)) ^ byte];
    return crc;
}

const header_flag_bos: u8 = 0x02;
const header_flag_eos: u8 = 0x04;

pub const OggWriter = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    serial: u32,
    sequence: u32 = 0,
    // Pending page: lacing values and packet bytes not yet flushed.
    lacing: [255]u8 = undefined,
    lacing_len: usize = 0,
    body: std.ArrayList(u8) = .empty,
    packets_in_page: usize = 0,

    pub fn init(allocator: std.mem.Allocator, serial: u32) OggWriter {
        return .{ .allocator = allocator, .serial = serial };
    }

    pub fn deinit(self: *OggWriter) void {
        self.out.deinit(self.allocator);
        self.body.deinit(self.allocator);
    }

    /// Queue one packet on the pending page.
    pub fn addPacket(self: *OggWriter, packet: []const u8) !void {
        const segments = packet.len / 255 + 1;
        if (self.lacing_len + segments > 255 or self.packets_in_page >= packets_per_page) {
            // Callers check wouldOverflow and flush first.
            return error.PageFull;
        }
        var remaining = packet.len;
        while (remaining >= 255) : (remaining -= 255) {
            self.lacing[self.lacing_len] = 255;
            self.lacing_len += 1;
        }
        self.lacing[self.lacing_len] = @intCast(remaining);
        self.lacing_len += 1;
        try self.body.appendSlice(self.allocator, packet);
        self.packets_in_page += 1;
    }

    pub fn wouldOverflow(self: *const OggWriter, packet_len: usize) bool {
        return self.lacing_len + packet_len / 255 + 1 > 255 or self.packets_in_page >= packets_per_page;
    }

    pub fn flush(self: *OggWriter, granule: u64, flags: u8) !void {
        var header: [27]u8 = undefined;
        @memcpy(header[0..4], "OggS");
        header[4] = 0;
        header[5] = flags;
        std.mem.writeInt(u64, header[6..14], granule, .little);
        std.mem.writeInt(u32, header[14..18], self.serial, .little);
        std.mem.writeInt(u32, header[18..22], self.sequence, .little);
        std.mem.writeInt(u32, header[22..26], 0, .little);
        header[26] = @intCast(self.lacing_len);
        const start = self.out.items.len;
        try self.out.appendSlice(self.allocator, &header);
        try self.out.appendSlice(self.allocator, self.lacing[0..self.lacing_len]);
        try self.out.appendSlice(self.allocator, self.body.items);
        const crc = oggCrc(self.out.items[start..]);
        std.mem.writeInt(u32, self.out.items[start + 22 ..][0..4], crc, .little);
        self.sequence += 1;
        self.lacing_len = 0;
        self.body.clearRetainingCapacity();
        self.packets_in_page = 0;
    }
};

pub fn writeOpusHead(buffer: *[19]u8, pre_skip: u16, input_rate: u32) void {
    @memcpy(buffer[0..8], "OpusHead");
    buffer[8] = 1; // version
    buffer[9] = 1; // mono
    std.mem.writeInt(u16, buffer[10..12], pre_skip, .little);
    std.mem.writeInt(u32, buffer[12..16], input_rate, .little);
    std.mem.writeInt(i16, buffer[16..18], 0, .little); // output gain
    buffer[18] = 0; // channel mapping family 0
}

pub const opus_tags = blk: {
    const vendor = "wazig";
    var bytes: [8 + 4 + vendor.len + 4]u8 = undefined;
    @memcpy(bytes[0..8], "OpusTags");
    std.mem.writeInt(u32, bytes[8..12], vendor.len, .little);
    @memcpy(bytes[12 .. 12 + vendor.len], vendor);
    std.mem.writeInt(u32, bytes[12 + vendor.len ..][0..4], 0, .little); // no comments
    break :blk bytes;
};

// ---------------------------------------------------------------- Encode

/// Encodes mono 48 kHz PCM. The caller owns `Result.ogg`.
pub fn encode(allocator: std.mem.Allocator, pcm: []const i16) !Result {
    if (pcm.len == 0) return error.Empty;
    var err: c_int = 0;
    const encoder = c.opus_encoder_create(@intCast(sample_rate), 1, c.OPUS_APPLICATION_VOIP, &err) orelse return error.EncoderFailed;
    if (err != c.OPUS_OK) return error.EncoderFailed;
    defer c.opus_encoder_destroy(encoder);
    _ = c.opus_encoder_ctl(encoder, c.OPUS_SET_BITRATE_REQUEST, @as(i32, bitrate));
    _ = c.opus_encoder_ctl(encoder, c.OPUS_SET_VBR_REQUEST, @as(i32, 1));
    _ = c.opus_encoder_ctl(encoder, c.OPUS_SET_COMPLEXITY_REQUEST, @as(i32, 5));
    _ = c.opus_encoder_ctl(encoder, c.OPUS_SET_SIGNAL_REQUEST, @as(i32, c.OPUS_SIGNAL_VOICE));
    var lookahead: i32 = 0;
    _ = c.opus_encoder_ctl(encoder, c.OPUS_GET_LOOKAHEAD_REQUEST, &lookahead);
    const pre_skip: u16 = @intCast(@max(lookahead, 0));

    var writer = OggWriter.init(allocator, 0x57415a49 ^ @as(u32, @truncate(pcm.len)));
    errdefer writer.deinit();
    var head: [19]u8 = undefined;
    writeOpusHead(&head, pre_skip, sample_rate);
    try writer.addPacket(&head);
    try writer.flush(0, header_flag_bos);
    try writer.addPacket(&opus_tags);
    try writer.flush(0, 0);

    // Granule position counts 48 kHz samples including the pre-skip; the
    // final page carries the true end so decoders trim the padding.
    const total_frames = (pcm.len + pre_skip + frame_samples - 1) / frame_samples;
    var frame: [frame_samples]i16 = undefined;
    var packet: [1275]u8 = undefined;
    var page_granule: u64 = 0;
    var index: usize = 0;
    while (index < total_frames) : (index += 1) {
        const from = index * frame_samples;
        const have = if (from < pcm.len) @min(frame_samples, pcm.len - from) else 0;
        @memcpy(frame[0..have], pcm[from .. from + have]);
        if (have < frame_samples) @memset(frame[have..], 0);
        const size = c.opus_encode(encoder, &frame, @intCast(frame_samples), &packet, @intCast(packet.len));
        if (size < 0) return error.EncodeFailed;
        const length: usize = @intCast(size);
        if (writer.wouldOverflow(length)) try writer.flush(page_granule, 0);
        try writer.addPacket(packet[0..length]);
        page_granule = @min((index + 1) * frame_samples, @as(u64, pre_skip) + pcm.len);
    }
    try writer.flush(page_granule, header_flag_eos);

    const result = Result{
        .ogg = try writer.out.toOwnedSlice(allocator),
        .seconds = durationSeconds(pcm.len),
        .waveform = waveform(pcm),
    };
    writer.body.deinit(allocator);
    return result;
}

pub fn durationSeconds(samples: usize) u32 {
    const rate: usize = sample_rate;
    return @intCast(@max(1, (samples + rate - 1) / rate));
}

/// 64 bars, each the mean absolute level of its slice of the recording,
/// scaled so the loudest bar is 100 (the same shape wacli derives with
/// ffmpeg). Silence gives all zeros.
pub fn waveform(pcm: []const i16) [waveform_bars]u8 {
    var bars = [_]u8{0} ** waveform_bars;
    if (pcm.len == 0) return bars;
    var levels: [waveform_bars]f64 = undefined;
    var peak: f64 = 0;
    for (&levels, 0..) |*level, bar| {
        const from = bar * pcm.len / waveform_bars;
        var to = (bar + 1) * pcm.len / waveform_bars;
        if (to <= from) to = @min(pcm.len, from + 1);
        var sum: f64 = 0;
        for (pcm[from..to]) |sample| sum += @abs(@as(f64, @floatFromInt(sample)));
        level.* = sum / @as(f64, @floatFromInt(to - from));
        peak = @max(peak, level.*);
    }
    if (peak <= 0) return bars;
    for (&bars, levels) |*bar, level| {
        bar.* = @intFromFloat(@min(100.0, @round(level / peak * 100.0)));
    }
    return bars;
}

/// Converts interleaved capture frames to mono 48 kHz PCM, one block at a
/// time. Linear interpolation is plenty for speech.
pub const Converter = struct {
    in_rate: u32,
    channels: u32,
    float_samples: bool,
    bits: u32,
    // Fractional read position into the input stream, and the last input
    // sample (so interpolation can span blocks).
    position: f64 = 0,
    previous: f32 = 0,

    pub fn push(self: *Converter, allocator: std.mem.Allocator, out: *std.ArrayList(i16), data: []const u8, frames: usize) !void {
        const step = @as(f64, @floatFromInt(self.in_rate)) / @as(f64, @floatFromInt(sample_rate));
        const bytes_per = self.bits / 8;
        const frame_bytes = bytes_per * self.channels;
        // position is relative to the first frame of this block; previous is frame -1.
        while (self.position < @as(f64, @floatFromInt(frames))) {
            const whole: usize = @intFromFloat(@floor(self.position));
            const frac: f32 = @floatCast(self.position - @floor(self.position));
            const a = if (whole == 0) self.previous else monoAt(self, data, whole - 1, frame_bytes);
            const b = monoAt(self, data, whole, frame_bytes);
            const value = a + (b - a) * frac;
            try out.append(allocator, floatToI16(value));
            self.position += step;
        }
        if (frames > 0) {
            self.previous = monoAt(self, data, frames - 1, frame_bytes);
            self.position -= @floatFromInt(frames);
        }
    }

    fn monoAt(self: *const Converter, data: []const u8, frame: usize, frame_bytes: usize) f32 {
        var sum: f32 = 0;
        const bytes_per = self.bits / 8;
        for (0..self.channels) |channel| {
            const at = frame * frame_bytes + channel * bytes_per;
            sum += if (self.float_samples)
                @as(f32, @bitCast(std.mem.readInt(u32, data[at..][0..4], .little)))
            else
                @as(f32, @floatFromInt(std.mem.readInt(i16, data[at..][0..2], .little))) / 32768.0;
        }
        return sum / @as(f32, @floatFromInt(self.channels));
    }
};

fn floatToI16(value: f32) i16 {
    const scaled = std.math.clamp(value, -1.0, 1.0) * 32767.0;
    return @intFromFloat(@round(scaled));
}

// ---------------------------------------------------------------- Tests

const testing = std.testing;

fn tone(allocator: std.mem.Allocator, hz: f64, seconds: f64) ![]i16 {
    const count: usize = @intFromFloat(seconds * sample_rate);
    const pcm = try allocator.alloc(i16, count);
    for (pcm, 0..) |*sample, i| {
        const t = @as(f64, @floatFromInt(i)) / sample_rate;
        sample.* = @intFromFloat(12000.0 * @sin(2.0 * std.math.pi * hz * t));
    }
    return pcm;
}

const Page = struct { flags: u8, granule: u64, serial: u32, sequence: u32, segments: []const u8, body: []const u8, total: usize };

fn parsePage(data: []const u8) !Page {
    if (data.len < 27 or !std.mem.eql(u8, data[0..4], "OggS")) return error.BadPage;
    const count = data[26];
    if (data.len < 27 + count) return error.BadPage;
    const segments = data[27 .. 27 + count];
    var body_len: usize = 0;
    for (segments) |s| body_len += s;
    const total = 27 + count + body_len;
    if (data.len < total) return error.BadPage;
    // CRC is computed with the checksum field zeroed.
    var copy: [65307]u8 = undefined;
    @memcpy(copy[0..total], data[0..total]);
    const stored = std.mem.readInt(u32, copy[22..26], .little);
    @memset(copy[22..26], 0);
    if (oggCrc(copy[0..total]) != stored) return error.BadCrc;
    return .{
        .flags = data[5],
        .granule = std.mem.readInt(u64, data[6..14], .little),
        .serial = std.mem.readInt(u32, data[14..18], .little),
        .sequence = std.mem.readInt(u32, data[18..22], .little),
        .segments = segments,
        .body = data[27 + count .. total],
        .total = total,
    };
}

test "ogg crc matches the known check value" {
    // CRC-32/MPEG-2 style Ogg checksum of "123456789" (poly 0x04c11db7, init 0, no reflection).
    try testing.expectEqual(@as(u32, 0x89a1897f), oggCrc("123456789"));
}

test "ogg opus stream has valid headers, crc, sequence and granules" {
    const pcm = try tone(testing.allocator, 440, 2.5);
    defer testing.allocator.free(pcm);
    const result = try encode(testing.allocator, pcm);
    defer testing.allocator.free(result.ogg);

    var offset: usize = 0;
    var index: u32 = 0;
    var last_granule: u64 = 0;
    var packets: usize = 0;
    var pre_skip: u16 = 0;
    var serial: u32 = 0;
    var saw_eos = false;
    while (offset < result.ogg.len) : (index += 1) {
        const page = try parsePage(result.ogg[offset..]);
        try testing.expectEqual(index, page.sequence);
        if (index == 0) {
            try testing.expectEqual(header_flag_bos, page.flags);
            try testing.expectEqual(@as(u64, 0), page.granule);
            try testing.expectEqual(@as(usize, 1), page.segments.len);
            try testing.expectEqual(@as(usize, 19), page.body.len);
            try testing.expectEqualStrings("OpusHead", page.body[0..8]);
            try testing.expectEqual(@as(u8, 1), page.body[8]);
            try testing.expectEqual(@as(u8, 1), page.body[9]); // mono
            pre_skip = std.mem.readInt(u16, page.body[10..12], .little);
            try testing.expect(pre_skip > 0 and pre_skip < 1000);
            try testing.expectEqual(@as(u32, 48000), std.mem.readInt(u32, page.body[12..16], .little));
            try testing.expectEqual(@as(u8, 0), page.body[18]);
            serial = page.serial;
        } else if (index == 1) {
            try testing.expectEqual(@as(u8, 0), page.flags);
            try testing.expectEqual(@as(u64, 0), page.granule);
            try testing.expectEqualStrings("OpusTags", page.body[0..8]);
        } else {
            try testing.expect(page.granule > last_granule);
            packets += page.segments.len;
            last_granule = page.granule;
        }
        try testing.expectEqual(serial, page.serial);
        if (page.flags & header_flag_eos != 0) saw_eos = true;
        offset += page.total;
    }
    try testing.expectEqual(result.ogg.len, offset);
    try testing.expect(saw_eos);
    // Final granule = pre-skip + exact sample count (padding is trimmed).
    try testing.expectEqual(@as(u64, pre_skip) + pcm.len, last_granule);
    try testing.expectEqual((pcm.len + pre_skip + frame_samples - 1) / frame_samples, packets);
    try testing.expectEqual(@as(u32, 3), result.seconds);
}

test "round trip: libopus decodes the stream back to the same tone" {
    const hz = 440.0;
    const pcm = try tone(testing.allocator, hz, 1.0);
    defer testing.allocator.free(pcm);
    const result = try encode(testing.allocator, pcm);
    defer testing.allocator.free(result.ogg);

    var err: c_int = 0;
    const decoder = c.opus_decoder_create(48000, 1, &err) orelse return error.TestUnexpectedResult;
    defer c.opus_decoder_destroy(decoder);
    var decoded: std.ArrayList(i16) = .empty;
    defer decoded.deinit(testing.allocator);
    var offset: usize = 0;
    var index: usize = 0;
    var pre_skip: usize = 0;
    var final_granule: u64 = 0;
    while (offset < result.ogg.len) : (index += 1) {
        const page = try parsePage(result.ogg[offset..]);
        offset += page.total;
        if (index == 0) {
            pre_skip = std.mem.readInt(u16, page.body[10..12], .little);
            continue;
        }
        if (index == 1) continue;
        final_granule = page.granule;
        var at: usize = 0;
        var start: usize = 0;
        for (page.segments, 0..) |s, i| {
            at += s;
            // every packet here is below 255 bytes, so one segment each
            if (s < 255) {
                var out: [5760]i16 = undefined;
                const n = c.opus_decode(decoder, page.body[start..at].ptr, @intCast(at - start), &out, 5760, 0);
                try testing.expect(n > 0);
                try decoded.appendSlice(testing.allocator, out[0..@intCast(n)]);
                start = at;
            }
            _ = i;
        }
    }
    const usable = decoded.items[pre_skip..@min(decoded.items.len, @as(usize, @intCast(final_granule)))];
    try testing.expectEqual(pcm.len, usable.len);
    // Count rising zero crossings in the middle second: must match the pitch.
    var crossings: usize = 0;
    var prev = usable[1000];
    for (usable[1001..40000]) |s| {
        if (prev < 0 and s >= 0) crossings += 1;
        prev = s;
    }
    const expected = hz * 39000.0 / 48000.0;
    try testing.expect(@abs(@as(f64, @floatFromInt(crossings)) - expected) <= 2);
    // And the level survived (input amplitude 12000).
    var peak: i16 = 0;
    for (usable[2000..40000]) |s| peak = @max(peak, @as(i16, @intCast(@min(@abs(@as(i32, s)), 32767))));
    try testing.expect(peak > 9000 and peak < 15000);
}

test "waveform scales the loudest bar to 100 and silence to zero" {
    var pcm: [6400]i16 = undefined;
    for (&pcm, 0..) |*s, i| s.* = if (i < 3200) 1000 else 4000;
    const w = waveform(&pcm);
    try testing.expectEqual(@as(u8, 100), w[63]);
    try testing.expectEqual(@as(u8, 25), w[0]);
    for (w) |v| try testing.expect(v <= 100);
    const silent = [_]i16{0} ** 480;
    for (waveform(&silent)) |v| try testing.expectEqual(@as(u8, 0), v);
    try testing.expectEqual(@as(usize, 64), w.len);
}

test "duration rounds up and never reports zero" {
    try testing.expectEqual(@as(u32, 1), durationSeconds(10));
    try testing.expectEqual(@as(u32, 1), durationSeconds(48000));
    try testing.expectEqual(@as(u32, 2), durationSeconds(48001));
    try testing.expectEqual(@as(u32, 7), durationSeconds(48000 * 7));
}

test "converter resamples 44.1 kHz stereo float to 48 kHz mono" {
    var converter = Converter{ .in_rate = 44100, .channels = 2, .float_samples = true, .bits = 32 };
    var out: std.ArrayList(i16) = .empty;
    defer out.deinit(testing.allocator);
    // 0.1 s of a constant 0.5 on both channels, delivered in two blocks.
    var block: [2205 * 8]u8 = undefined;
    for (0..2205 * 2) |i| std.mem.writeInt(u32, block[i * 4 ..][0..4], @bitCast(@as(f32, 0.5)), .little);
    try converter.push(testing.allocator, &out, &block, 2205);
    try converter.push(testing.allocator, &out, &block, 2205);
    try testing.expect(out.items.len >= 4795 and out.items.len <= 4805); // 0.1 s at 48 kHz
}
