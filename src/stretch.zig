// SOLA time-stretch: speeds audio up while keeping the original pitch, the
// way WhatsApp and Slack do. Pure f32 math so it is testable off-Windows.
const std = @import("std");

pub const window_frames = 960; // 20 ms read from the source per window
pub const overlap_frames = 240; // 5 ms fade between consecutive windows
pub const search_frames = 240; // alignment search range, frames
pub const max_channels = 2;

/// New stream frames emitted per window: the window read minus the overlap
/// that is held back as the pending fade-out and completed by the next
/// window's fade-in.
pub const hop_frames = window_frames - overlap_frames;

/// Input frames needed beyond the current position before a window can be
/// emitted: the widest search candidate plus a full read window.
pub const lookahead_frames = 2 * search_frames + window_frames;

/// Emits `hop_frames`-frame output blocks from a caller-owned input buffer.
/// The caller keeps the decoded PCM, tracks which absolute source frame `in`
/// starts at, and asks for windows while enough look-ahead exists. The last
/// `overlap_frames` of each read are never emitted directly; they fade out
/// into the pending buffer and are summed with the next window's fade-in, so
/// consecutive blocks join without a time jump (the crackle bug).
pub const Stretch = struct {
    channels: u32,
    /// Playback speed in percent (100 = normal). May be changed between
    /// windows; the tail carries over so there is no click.
    percent: u32 = 100,
    /// Absolute source-frame position of the next window, scaled by 100 for
    /// fractional advance.
    pos_scaled: u64 = 0,
    /// Fade-out of the current window's last overlap frames, already scaled
    /// by (1 - t). Summed with the next window's fade-in.
    pending: [overlap_frames * max_channels]f32 = [_]f32{0} ** (overlap_frames * max_channels),
    /// Raw last overlap of the current read window, used for alignment.
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
        return self.relFrames(in_base) + lookahead_frames <= in_frames;
    }

    /// Writes the next `hop_frames`-frame block into `out` and returns how
    /// many source frames were consumed by the search offset, so the caller
    /// can advance its own position. Requires at least `lookahead_frames`
    /// input frames beyond `pos`.
    pub fn emitWindow(self: *Stretch, in: []const f32, in_base: u64, in_frames: u64, out: []f32) void {
        const ch = self.channels;
        std.debug.assert(in_frames >= self.relFrames(in_base) + lookahead_frames);
        std.debug.assert(out.len >= hop_frames * ch);
        const rel_pos: usize = @intCast(self.relFrames(in_base));

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
        const inv: f32 = 1.0 / @as(f32, overlap_frames);

        if (self.has_tail) {
            // Overlap-add: pending fade-out of the previous window plus the
            // fade-in of this one cover the same output positions.
            for (0..overlap_frames) |i| {
                const t: f32 = @as(f32, @floatFromInt(i)) * inv;
                for (0..ch) |c| {
                    out[i * ch + c] = self.pending[i * ch + c] + in[(src + i) * ch + c] * t;
                }
            }
        } else {
            self.has_tail = true;
            for (0..overlap_frames) |i| {
                for (0..ch) |c| {
                    out[i * ch + c] = in[(src + i) * ch + c];
                }
            }
        }
        const rest = (src + overlap_frames) * ch;
        @memcpy(out[overlap_frames * ch .. hop_frames * ch], in[rest .. rest + (hop_frames - overlap_frames) * ch]);

        // Fade-out for the next join: raw source scaled by (1 - t), plus the
        // raw copy used for alignment.
        const tail_src = (src + hop_frames) * ch;
        for (0..overlap_frames) |i| {
            const t: f32 = @as(f32, @floatFromInt(i)) * inv;
            for (0..ch) |c| {
                self.tail[i * ch + c] = in[tail_src + i * ch + c];
                self.pending[i * ch + c] = self.tail[i * ch + c] * (1 - t);
            }
        }

        // Each emitted block of hop_frames output frames consumes
        // hop_frames * percent / 100 source frames; pos_scaled is in
        // 1/100-frame units.
        self.pos_scaled += @as(u64, hop_frames) * self.percent;
    }

    fn relFrames(self: *const Stretch, in_base: u64) u64 {
        return self.pos_scaled / 100 - in_base;
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
    const blocks = 100;
    const out = try std.testing.allocator.alloc(f32, blocks * hop_frames);
    defer std.testing.allocator.free(out);
    for (0..blocks) |w| {
        st.emitWindow(in, 0, frames, out[w * hop_frames ..][0..hop_frames]);
    }
    // 100 blocks = 1.5 s of output at 1.5x should consume ~2.25 s (108000
    // source frames), i.e. 1080 per block.
    const consumed = st.sourceFramesConsumed();
    try std.testing.expect(consumed > 104000 and consumed < 112000);
    // Output stays in the same amplitude range (no gaps or blowups).
    for (out[hop_frames..]) |s| {
        try std.testing.expect(s > -1.1 and s < 1.1);
    }
    // Pitch preserved: zero crossings per output second match the input tone.
    var crossings: u32 = 0;
    var prev = out[0];
    for (out[1..]) |s| {
        if (prev <= 0 and s > 0) crossings += 1;
        prev = s;
    }
    // 440 Hz tone over ~1.5 s of output: ~660 crossings, allow stretch seams.
    try std.testing.expectApproxEqAbs(@as(f64, 660), @as(f64, @floatFromInt(crossings)), 30);
}

test "stretch 200 consumes about half of the input" {
    var st: Stretch = .{ .channels = 1, .percent = 200 };
    const frames = 48000;
    const in = try std.testing.allocator.alloc(f32, frames);
    defer std.testing.allocator.free(in);
    for (in, 0..) |*s, i| {
        s.* = @sin(@as(f32, @floatFromInt(i)) * 2 * std.math.pi * 300 / 48000);
    }
    const out = try std.testing.allocator.alloc(f32, hop_frames);
    defer std.testing.allocator.free(out);
    var blocks: usize = 0;
    while (st.sourceFramesConsumed() + lookahead_frames <= frames) : (blocks += 1) {
        st.emitWindow(in, 0, frames, out);
    }
    // 48000 source frames at 2x -> ~24000 output frames -> ~33 blocks.
    try std.testing.expect(blocks > 28 and blocks < 38);
}

test "stretched output has no sample discontinuities beyond the input slope" {
    // Regression test for the crackle: consecutive output blocks must join
    // smoothly. A time jump at a block boundary shows up as a sample-to-
    // sample step far larger than anything in the input signal.
    var st: Stretch = .{ .channels = 1, .percent = 150 };
    const frames = 48000 * 12;
    const in = try std.testing.allocator.alloc(f32, frames);
    defer std.testing.allocator.free(in);
    for (in, 0..) |*s, i| {
        const t = @as(f32, @floatFromInt(i)) / 48000.0;
        const vib = 1.0 + 0.01 * @sin(t * 2 * std.math.pi * 5.0);
        s.* = @sin(t * 2 * std.math.pi * 180 * vib) * 0.5 +
            @sin(t * 2 * std.math.pi * 360 * vib) * 0.25 +
            @sin(t * 2 * std.math.pi * 540 * vib) * 0.125;
    }
    var in_slope: f32 = 0;
    for (1..in.len) |i| in_slope = @max(in_slope, @abs(in[i] - in[i - 1]));
    const blocks = 300;
    const out = try std.testing.allocator.alloc(f32, blocks * hop_frames);
    defer std.testing.allocator.free(out);
    for (0..blocks) |w| {
        st.emitWindow(in, 0, frames, out[w * hop_frames ..][0..hop_frames]);
    }
    for (1..out.len) |i| {
        const step = @abs(out[i] - out[i - 1]);
        try std.testing.expect(step <= 4 * in_slope);
    }
}
