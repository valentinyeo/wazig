//! Pure wheel-accumulation math for chat list mouse scrolling. No Win32
//! dependencies so it can be unit-tested on the host (see build.zig test
//! step, like scrollbar.zig and message_scroll.zig).
const std = @import("std");

pub const WheelStep = struct { rows: i32, remainder: i32 };

/// Accumulates a WM_MOUSEWHEEL delta (which can be smaller than one notch on
/// smooth/precision touchpads) and converts whole notches into list rows to
/// scroll. `remainder` carries the leftover delta into the next event so no
/// motion is lost between calls.
pub fn wheelRows(accumulated: i32, delta: i32, wheel_delta: i32, lines_per_notch: i32) WheelStep {
    const total = accumulated + delta;
    const notches = @divTrunc(total, wheel_delta);
    return .{ .rows = notches * lines_per_notch, .remainder = total - notches * wheel_delta };
}

test "a full notch scrolls whole lines with nothing left over" {
    const step = wheelRows(0, 120, 120, 3);
    try std.testing.expectEqual(@as(i32, 3), step.rows);
    try std.testing.expectEqual(@as(i32, 0), step.remainder);
}

test "sub-notch touchpad deltas accumulate before scrolling" {
    var accum: i32 = 0;
    var step = wheelRows(accum, 40, 120, 3);
    try std.testing.expectEqual(@as(i32, 0), step.rows);
    accum = step.remainder;
    step = wheelRows(accum, 40, 120, 3);
    try std.testing.expectEqual(@as(i32, 0), step.rows);
    accum = step.remainder;
    step = wheelRows(accum, 40, 120, 3);
    try std.testing.expectEqual(@as(i32, 3), step.rows);
    try std.testing.expectEqual(@as(i32, 0), step.remainder);
}

test "reverse direction scrolls negative rows" {
    const step = wheelRows(0, -120, 120, 3);
    try std.testing.expectEqual(@as(i32, -3), step.rows);
}
