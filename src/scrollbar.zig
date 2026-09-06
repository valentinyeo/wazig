// Pure scrollbar thumb geometry, shared by every themed scrollbar in main.zig.
// Kept free of Win32 so the math is unit-testable on any host.

pub const Geom = struct { top: i32, height: i32 };

/// Thumb rect for a track starting at `track_top` with height `track_h`.
/// `total` is the content size in units (items/lines/pixels), `page` the
/// visible size, `top` the first visible unit. Returns null when nothing
/// overflows, so callers draw no thumb.
pub fn thumbGeom(track_top: i32, track_h: i32, total: i32, page: i32, top: i32, min_thumb: i32) ?Geom {
    if (total <= 0 or page <= 0 or page >= total or track_h <= min_thumb + 1) return null;
    const max_top = total - page;
    const clamped_top = @max(0, @min(top, max_top));
    var height = @max(min_thumb, @as(i32, @intCast(@divTrunc(@as(i64, track_h) * page, total))));
    if (height > track_h) height = track_h;
    const span = track_h - height;
    // total can be raw pixel counts (canvas: tens of millions), so widen the
    // products or i32 overflows wrap the thumb position.
    const offset = @as(i32, @intCast(@divTrunc(@as(i64, span) * clamped_top, max_top)));
    return .{ .top = track_top + offset, .height = height };
}

/// Content `top` matching a pointer at `y` treated as the thumb center line
/// (jump-and-center dragging). Result is clamped to a valid scroll position.
/// Returns null under the same conditions as `thumbGeom`, so a drag that
/// outlives a shrink to a non-overflowing track is simply ignored.
pub fn topFromPoint(y: i32, track_top: i32, track_h: i32, total: i32, page: i32, min_thumb: i32) ?i32 {
    if (total <= 0 or page <= 0 or page >= total or track_h <= min_thumb + 1) return null;
    const max_top = total - page;
    var height = @max(min_thumb, @as(i32, @intCast(@divTrunc(@as(i64, track_h) * page, total))));
    if (height > track_h) height = track_h;
    const span = track_h - height;
    const rel = @max(0, @min(y - track_top - @divTrunc(height, 2), span));
    return @intCast(@divTrunc(@as(i64, max_top) * rel, span));
}

test "thumb hidden when content fits" {
    if (thumbGeom(0, 500, 10, 10, 0, 24) != null) return error.TestExpectedEqual;
    if (thumbGeom(0, 500, 0, 10, 0, 24) != null) return error.TestExpectedEqual;
}

test "thumb fills track for one hidden item" {
    const g = thumbGeom(0, 500, 101, 100, 0, 24) orelse return error.TestExpectedEqual;
    if (g.height != 495) return error.TestExpectedEqual; // max(24, 500*100/101)
    if (g.top != 0) return error.TestExpectedEqual;
}

test "thumb reaches track bottom at max scroll" {
    const g = thumbGeom(100, 500, 101, 100, 1, 24) orelse return error.TestExpectedEqual;
    if (g.top + g.height != 600) return error.TestExpectedEqual;
}

test "topFromPoint matches thumbGeom guards" {
    if (topFromPoint(250, 0, 500, 10, 10, 24) != null) return error.TestExpectedEqual;
}

test "extreme content size does not overflow" {
    // Canvas scale: total in pixels, far beyond i32 product range.
    const total: i32 = 14_000_000;
    const page: i32 = 900;
    const track_top: i32 = 0;
    const track_h: i32 = 890;
    const g = thumbGeom(track_top, track_h, total, page, 7_000_000, 24) orelse return error.TestExpectedEqual;
    if (g.top <= track_top or g.top + g.height > track_h) return error.TestExpectedEqual;
    const back = topFromPoint(g.top + @divTrunc(g.height, 2), track_top, track_h, total, page, 24) orelse return error.TestExpectedEqual;
    if (@abs(back - 7_000_000) > total / track_h + 1) return error.TestExpectedEqual;
}

test "top clamps beyond scrollable range" {
    const g = thumbGeom(0, 500, 10, 4, 99, 24) orelse return error.TestExpectedEqual;
    if (g.top + g.height != 500) return error.TestExpectedEqual;
}

test "round trip maps thumb center back to top" {
    const track_top: i32 = 10;
    const track_h: i32 = 480;
    const total: i32 = 1000;
    const page: i32 = 40;
    const max_top = total - page;
    // Both directions truncate to whole track pixels, so the round trip can
    // drift by up to one pixel's worth of content units, plus one rounding step.
    const tolerance = @max(1, @divTrunc(max_top, track_h) + 1);
    const tops = [_]i32{ 0, 250, 500, 960 };
    for (tops) |top| {
        const g = thumbGeom(track_top, track_h, total, page, top, 24) orelse return error.TestExpectedEqual;
        const back = topFromPoint(g.top + @divTrunc(g.height, 2), track_top, track_h, total, page, 24) orelse return error.TestExpectedEqual;
        if (@abs(back - top) > tolerance) return error.TestExpectedEqual;
    }
}
