// SOLA time-stretch: speeds audio up while keeping the original pitch, the
// way WhatsApp and Slack do. Pure f32 math so it is testable off-Windows.
const std = @import("std");

pub const window_frames = 960; // 20 ms at 48 kHz
pub const overlap_frames = 240; // 5 ms crossfade between windows
pub const search_frames = 240; // alignment search range, frames
pub const max_channels = 2;

/// Input frames needed beyond the current position before a window can be
/// emitted: the widest search candidate plus a full output window.
pub const lookahead_frames = 2 * search_frames + window_frames;

/// Emits `window_frames`-frame output windows from a caller-owned input
/// buffer. The caller keeps the decoded PCM, tracks which absolute source
/// frame `in` starts at, and asks for windows while enough look-ahead exists.
pub const Stretch = struct {
    channels: u32,
    /// Playback speed in percent (100 = normal). May be changed between
    /// windows; the tail carries over so there is no click.
    percent: u32 = 100,
    /// Absolute source-frame position of the next window, scaled by 100 for
    /// fractional advance.
    pos_scaled: u64 = 0,
    tail: [overlap_frames * max_channels]f32 = [_]f32{0} ** (overlap_frames * max_channels),
    has_tail: bool = false,

    pub fn sourceFramesConsumed(self: *const Stretch) u64 {
        return self.pos_scaled / 100;
    }

    /// Restart at an absolute source frame (used on seek).
    pub fn reset(self: *Stretch, pos_frames: u64) void {
        self.pos_scaled = pos_frames * 100;
        self.has_tail = false;
    }

    /// True when `in` (in_frames starting at absolute frame in_base) holds a
    /// full window at the current position.
    pub fn canEmit(self: *const Stretch, in_base: u64, in_frames: u64) bool {
        const rel = self.pos_scaled / 100 - in_base;
        return rel + lookahead_frames <= in_frames;
    }

    /// Writes the next window into `out` (window_frames * channels samples).
    pub fn emitWindow(self: *Stretch, in: []const f32, in_base: u64, in_frames: u64, out: []f32) void {
        const ch = self.channels;
        std.debug.assert(self.canEmit(in_base, in_frames));
        std.debug.assert(out.len >= window_frames * ch);
        const rel_pos: usize = @intCast(@min(self.pos_scaled / 100 - in_base, in_frames - lookahead_frames));

        var best_off: usize = 0;
        if (self.has_tail) {
            var best_err: f64 = std.math.floatMax(f64);
            for (0..2 * search_frames + 1) |off| {
                const start = rel_pos + off;
                var err: f64 = 0;
                var i: usize = 0;
                while (i < overlap_frames) : (i += 4) {
                    const d = in[(start + i) * ch] - self.tail[i * ch];
                    err += @floatCast(d * d);
                }
                if (err < best_err) {
                    best_err = err;
                    best_off = off;
                }
            }
        }
        const src = rel_pos + best_off;

        if (self.has_tail) {
            // Crossfade the overlap region from the tail into the new window.
            const inv: f32 = 1.0 / @as(f32, overlap_frames);
            for (0..overlap_frames) |i| {
                const t: f32 = @as(f32, @floatFromInt(i)) * inv;
                for (0..ch) |c| {
                    out[i * ch + c] = self.tail[i * ch + c] * (1 - t) + in[(src + i) * ch + c] * t;
                }
            }
        } else {
            self.has_tail = true;
            @memcpy(out[0 .. overlap_frames * ch], in[src * ch .. (src + overlap_frames) * ch]);
        }
        const rest = (src + overlap_frames) * ch;
        @memcpy(out[overlap_frames * ch .. window_frames * ch], in[rest .. rest + (window_frames - overlap_frames) * ch]);
        @memcpy(self.tail[0 .. overlap_frames * ch], out[(window_frames - overlap_frames) * ch .. window_frames * ch]);

        // Each emitted window of window_frames output frames consumes
        // window_frames * percent / 100 source frames; pos_scaled is in
        // 1/100-frame units.
        self.pos_scaled += @as(u64, window_frames) * self.percent;
    }
};

test "stretch 150 consumes about two thirds of the input" {
    var st: Stretch = .{ .channels = 1, .percent = 150 };
    // 10 seconds of a 440 Hz sine.
    const frames = 48000 * 10;
    const in = try std.testing.allocator.alloc(f32, frames);
    defer std.testing.allocator.free(in);
    for (in, 0..) |*s, i| {
        s.* = @sin(@as(f32, @floatFromInt(i)) * 2 * std.math.pi * 440 / 48000);
    }
    const windows = 100;
    const out = try std.testing.allocator.alloc(f32, windows * window_frames);
    defer std.testing.allocator.free(out);
    for (0..windows) |w| {
        st.emitWindow(in, 0, frames, out[w * window_frames ..][0..window_frames]);
    }
    // 100 windows = 2 s of output at 1.5x should consume ~3 s (144000
    // source frames), i.e. 1440 per window.
    const consumed = st.sourceFramesConsumed();
    try std.testing.expect(consumed > 140000 and consumed < 148000);
    // Output stays in the same amplitude range (no gaps or blowups).
    for (out[window_frames..]) |s| {
        try std.testing.expect(s > -1.1 and s < 1.1);
    }
    // Pitch preserved: zero crossings per output second match the input tone.
    var crossings: u32 = 0;
    var prev = out[0];
    for (out[1..]) |s| {
        if (prev <= 0 and s > 0) crossings += 1;
        prev = s;
    }
    // 440 Hz tone over ~2 s of output: ~880 crossings, allow stretch seams.
    try std.testing.expectApproxEqAbs(@as(f64, 880), @as(f64, @floatFromInt(crossings)), 30);
}

test "stretch 200 consumes about half of the input" {
    var st: Stretch = .{ .channels = 1, .percent = 200 };
    const frames = 48000;
    const in = try std.testing.allocator.alloc(f32, frames);
    defer std.testing.allocator.free(in);
    for (in, 0..) |*s, i| {
        s.* = @sin(@as(f32, @floatFromInt(i)) * 2 * std.math.pi * 300 / 48000);
    }
    const out = try std.testing.allocator.alloc(f32, window_frames);
    defer std.testing.allocator.free(out);
    var windows: usize = 0;
    while (st.canEmit(0, frames)) : (windows += 1) {
        st.emitWindow(in, 0, frames, out);
    }
    // 48000 source frames at 2x -> ~24000 output frames -> ~25 windows.
    try std.testing.expect(windows > 20 and windows < 30);
}
