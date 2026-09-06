//! Pure height math for the composer strip. No Win32 dependencies so it can
//! be unit-tested on the host (see build.zig test step, like webp.zig).

pub const edit_min_height: i32 = 44;
/// Content growth cap when the user never dragged the handle taller.
pub const default_max_height: i32 = 240;
/// The message pane never shrinks below this.
pub const canvas_min_height: i32 = 160;
/// Total strip height padding around the edit control.
pub const strip_padding: i32 = 22;

pub const Composer = struct {
    edit_height: i32,
    /// Window height consumed by the composer strip (edit + padding).
    strip_height: i32,
};

/// The dragged height is a floor; content grows above it up to
/// cap = max(default_max_height, dragged), and everything is clamped so the
/// message pane keeps at least canvas_min_height.
/// Extra vertical band reserved above the edit while a pasted image waits
/// to be sent (WAZI-37).
pub const preview_band: i32 = 54;

pub fn compute(dragged: i32, content_height: i32, client_height: i32, preview: bool) Composer {
    const band: i32 = if (preview) preview_band else 0;
    const cap: i32 = @max(default_max_height, dragged);
    var edit: i32 = @max(@max(edit_min_height, dragged), content_height);
    edit = @min(edit, cap);
    // Clamp: even a squeezed edit never pushes the message pane below
    // canvas_min_height (the preview band shrinks away first).
    const room_for_edit: i32 = client_height - canvas_min_height - strip_padding - band;
    if (room_for_edit > 0 and edit > room_for_edit) edit = room_for_edit;
    if (edit < edit_min_height) edit = @min(edit_min_height, @max(0, room_for_edit));
    return .{ .edit_height = edit, .strip_height = edit + strip_padding + band };
}

test "grows with content up to the default cap" {
    const c = compute(0, 600, 900, false);
    try @import("std").testing.expectEqual(@as(i32, 240), c.edit_height);
    const mid = compute(0, 80, 900, false);
    try @import("std").testing.expectEqual(@as(i32, 80), mid.edit_height);
    const one = compute(0, 30, 900, false);
    try @import("std").testing.expectEqual(@as(i32, 44), one.edit_height);
}

test "dragged height raises floor and cap" {
    const c = compute(320, 30, 900, false);
    try @import("std").testing.expectEqual(@as(i32, 320), c.edit_height);
    const over = compute(320, 400, 900, false);
    try @import("std").testing.expectEqual(@as(i32, 320), over.edit_height);
}

test "clamps to keep the message pane usable" {
    const c = compute(400, 400, 300, false);
    try @import("std").testing.expectEqual(@as(i32, 118), c.edit_height);
    try @import("std").testing.expectEqual(@as(i32, 140), c.strip_height);
}

test "preview band adds height" {
    const plain = compute(0, 30, 900, false);
    const with = compute(0, 30, 900, true);
    try @import("std").testing.expectEqual(plain.strip_height + preview_band, with.strip_height);
}
