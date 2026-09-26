//! Pure scroll-into-view math for the selected chat message. No Win32
//! dependencies so it can be unit-tested on the host (see build.zig test
//! step, like scrollbar.zig).

/// Scroll offset to add to the current scroll position so the message
/// spanning [msg_top, msg_top + msg_height) sits inside [view_top, view_bottom]
/// with `margin` px of breathing room on the edge it crosses. Returns 0 when
/// the message is already fully visible. A message taller than the visible
/// area can never be fully shown, so its top is pinned into view instead.
pub fn scrollDelta(msg_top: i32, msg_height: i32, view_top: i32, view_bottom: i32, margin: i32) i32 {
    const target_top = view_top + margin;
    const target_bottom = view_bottom - margin;
    if (msg_height >= target_bottom - target_top) return target_top - msg_top;
    if (msg_top < target_top) return target_top - msg_top;
    const msg_bottom = msg_top + msg_height;
    if (msg_bottom > target_bottom) return target_bottom - msg_bottom;
    return 0;
}

test "message already fully visible needs no scroll" {
    if (scrollDelta(20, 40, 0, 100, 8) != 0) return error.TestExpectedEqual;
}

test "message above the top scrolls down to the margin" {
    if (scrollDelta(-10, 40, 0, 100, 8) != 18) return error.TestExpectedEqual; // target_top(8) - (-10)
}

test "message below the bottom scrolls up to the margin" {
    if (scrollDelta(80, 40, 0, 100, 8) != -28) return error.TestExpectedEqual; // target_bottom(92) - 120
}

test "message taller than the view shows its top, not its bottom" {
    // A 400px message in a 100px view: whether it currently sits high or low,
    // the fix must bring its TOP to the margin, never chase the bottom edge.
    if (scrollDelta(-300, 400, 0, 100, 8) != 308) return error.TestExpectedEqual;
    if (scrollDelta(50, 400, 0, 100, 8) != -42) return error.TestExpectedEqual;
}

test "oversized message already top-aligned needs no scroll" {
    if (scrollDelta(8, 400, 0, 100, 8) != 0) return error.TestExpectedEqual;
}

test "Ctrl+Up onto a partly visible image reveals its full top" {
    // Real numbers from the reported bug: a ~290px image message near the
    // top of a ~650px chat view, cut off with only its lower part on screen.
    const view_top = 0;
    const view_bottom = 650;
    const margin = 8;
    const msg_height = 290;
    const msg_top = -180; // top is off-screen; bottom (110) still shows
    const delta = scrollDelta(msg_top, msg_height, view_top, view_bottom, margin);
    const new_top = msg_top + delta;
    if (new_top != margin) return error.TestExpectedEqual;
    if (new_top + msg_height > view_bottom - margin) return error.TestExpectedEqual;
}
