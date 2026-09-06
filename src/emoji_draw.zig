//! Color emoji rendering via Direct2D + DirectWrite color fonts (Windows 10
//! floor). The rasterizer binds the caller's destination DC with an
//! ID2D1DCRenderTarget and draws emoji runs in place, so wrapping and painting
//! share one measurement and no bitmap cache is kept (grayscale AA, no GDI
//! bitmap management). Every failure returns false and the caller falls back
//! to the existing GDI monochrome path.
const std = @import("std");
const win = @import("win32.zig").c;

// mingw headers do not export these IIDs as linkable symbols, so define them
// here (from the public interface docs).
const iid_id2d1_factory = win.GUID{
    .Data1 = 0x06152247,
    .Data2 = 0x6f50,
    .Data3 = 0x465a,
    .Data4 = .{ 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 },
};
const iid_idwrite_factory = win.GUID{
    .Data1 = 0xb859ee5a,
    .Data2 = 0xd838,
    .Data3 = 0x4b5b,
    .Data4 = .{ 0xa2, 0xe8, 0x1a, 0xdc, 0x7d, 0x93, 0xdb, 0x48 },
};

pub const Metrics = struct { width: i32, baseline: i32 };

const max_sequence_units = 32;
const format_cache_size = 8;

const FormatEntry = struct { em: i32, format: ?*win.IDWriteTextFormat = null };

const State = struct {
    failed: bool = false,
    factory: ?*win.ID2D1Factory = null,
    dwrite: ?*win.IDWriteFactory = null,
    target: ?*win.ID2D1DCRenderTarget = null,
    brush: ?*win.ID2D1SolidColorBrush = null,
    bound_hdc: ?win.HDC = null,
    formats: [format_cache_size]FormatEntry = [_]FormatEntry{.{ .em = 0 }} ** format_cache_size,
    format_count: usize = 0,
};
var state: State = .{};

fn ensureFactory() bool {
    if (state.failed) return false;
    if (state.factory != null) return true;
    if (win.D2D1CreateFactory(win.D2D1_FACTORY_TYPE_SINGLE_THREADED, &iid_id2d1_factory, null, @ptrCast(&state.factory)) != 0 or state.factory == null) {
        state.failed = true;
        return false;
    }
    if (win.DWriteCreateFactory(win.DWRITE_FACTORY_TYPE_SHARED, &iid_idwrite_factory, @ptrCast(&state.dwrite)) != 0 or state.dwrite == null) {
        state.failed = true;
        return false;
    }
    return true;
}

fn ensureTarget(hdc: win.HDC) bool {
    const factory = state.factory orelse return false;
    if (state.target == null) {
        var props = win.D2D1_RENDER_TARGET_PROPERTIES{
            .type = win.D2D1_RENDER_TARGET_TYPE_SOFTWARE,
            .pixelFormat = .{
                .format = win.DXGI_FORMAT_B8G8R8A8_UNORM,
                .alphaMode = win.D2D1_ALPHA_MODE_PREMULTIPLIED,
            },
            .dpiX = 96.0,
            .dpiY = 96.0,
            .usage = 0,
            .minLevel = win.D2D1_FEATURE_LEVEL_DEFAULT,
        };
        if (factory.*.lpVtbl.*.CreateDCRenderTarget.?(factory, &props, &state.target) != 0 or state.target == null) {
            state.failed = true;
            return false;
        }
        const target = state.target.?;
        const base: *win.ID2D1RenderTarget = @ptrCast(target);
        // Grayscale, not ClearType: the target composites over whatever GDI
        // already drew, and ClearType fringes need an opaque known background.
        _ = base.*.lpVtbl.*.SetTextAntialiasMode.?(base, win.D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
        const white = win.D2D1_COLOR_F{ .r = 0, .g = 0, .b = 0, .a = 1 };
        const brush_props = win.D2D1_BRUSH_PROPERTIES{ .opacity = 1, .transform = identityMatrix() };
        if (base.*.lpVtbl.*.CreateSolidColorBrush.?(base, &white, &brush_props, &state.brush) != 0 or state.brush == null) {
            state.failed = true;
            return false;
        }
    }
    const already_bound = state.bound_hdc != null and state.bound_hdc.? == hdc;
    if (!already_bound) {
        var rect = win.RECT{
            .left = 0,
            .top = 0,
            .right = @max(1, win.GetDeviceCaps(hdc, win.HORZRES)),
            .bottom = @max(1, win.GetDeviceCaps(hdc, win.VERTRES)),
        };
        if (state.target.?.*.lpVtbl.*.BindDC.?(state.target.?, hdc, &rect) != 0) return false;
        state.bound_hdc = hdc;
    }
    return true;
}

fn identityMatrix() win.D2D1_MATRIX_3X2_F {
    return .{ .unnamed_0 = .{ .unnamed_0 = .{ .m11 = 1, .m12 = 0, .m21 = 0, .m22 = 1, .dx = 0, .dy = 0 } } };
}

fn formatFor(em: i32) ?*win.IDWriteTextFormat {
    const dwrite = state.dwrite orelse return null;
    for (state.formats[0..state.format_count]) |*entry| {
        if (entry.em == em) return entry.format;
    }
    var format: ?*win.IDWriteTextFormat = null;
    const family: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Emoji");
    const locale: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("en-us");
    const hr = dwrite.*.lpVtbl.*.CreateTextFormat.?(
        dwrite,
        family.ptr,
        null,
        win.DWRITE_FONT_WEIGHT_NORMAL,
        win.DWRITE_FONT_STYLE_NORMAL,
        win.DWRITE_FONT_STRETCH_NORMAL,
        @floatFromInt(em),
        locale.ptr,
        &format,
    );
    if (hr != 0 or format == null) return null;
    if (state.format_count < format_cache_size) {
        state.formats[state.format_count] = .{ .em = em, .format = format };
        state.format_count += 1;
    } else {
        // Ring of 8 em sizes is plenty for one app (a handful of font sizes);
        // overwrite the smallest without ceremony.
        var oldest: usize = 0;
        var oldest_em = state.formats[0].em;
        for (1..format_cache_size) |index| {
            if (state.formats[index].em < oldest_em) {
                oldest_em = state.formats[index].em;
                oldest = index;
            }
        }
        state.formats[oldest] = .{ .em = em, .format = format };
    }
    return format;
}

/// Width and baseline distance of one emoji sequence at the given em size in
/// pixels. null means the color path is unavailable for this sequence and the
/// caller should measure and draw with GDI instead.
pub fn metrics(text: []const u16, em: i32) ?Metrics {
    if (text.len == 0 or text.len > max_sequence_units or em <= 0 or em > 256) return null;
    if (!ensureFactory()) return null;
    const format = formatFor(em) orelse return null;
    var layout: ?*win.IDWriteTextLayout = null;
    const dwrite = state.dwrite.?;
    if (dwrite.*.lpVtbl.*.CreateTextLayout.?(dwrite, text.ptr, @intCast(text.len), format, 4096.0, 256.0, &layout) != 0 or layout == null) return null;
    defer _ = layout.?.*.lpVtbl.*.Release.?(layout.?);
    var text_metrics: win.DWRITE_TEXT_METRICS = undefined;
    if (layout.?.*.lpVtbl.*.GetMetrics.?(layout.?, &text_metrics) != 0) return null;
    var line: win.DWRITE_LINE_METRICS = undefined;
    var line_count: u32 = 0;
    if (layout.?.*.lpVtbl.*.GetLineMetrics.?(layout.?, &line, 1, &line_count) != 0 or line_count == 0) return null;
    return .{
        .width = @intFromFloat(@ceil(text_metrics.widthIncludingTrailingWhitespace)),
        .baseline = @intFromFloat(@ceil(line.baseline)),
    };
}

/// Draws one emoji sequence with color glyphs. `top_y` is the top of the text
/// line's character cell and `ascent` the text font's ascent, matching how
/// GDI TextOutW positions the neighbouring runs. Returns false on any failure.
pub fn draw(hdc: win.HDC, text: []const u16, x: i32, top_y: i32, text_ascent: i32, em: i32) bool {
    if (!ensureFactory()) return false;
    if (!ensureTarget(hdc)) return false;
    const format = formatFor(em) orelse return false;
    const run_metrics = metrics(text, em) orelse return false;
    const target = state.target.?;
    const brush: *win.ID2D1Brush = @ptrCast(state.brush.?);
    const origin_y = @as(f32, @floatFromInt(top_y + text_ascent - run_metrics.baseline));
    const base: *win.ID2D1RenderTarget = @ptrCast(target);
    base.*.lpVtbl.*.DrawTextLayout.?(
        base,
        .{ .x = @floatFromInt(x), .y = origin_y },
        @ptrCast(format),
        brush,
        win.D2D1_DRAW_TEXT_OPTIONS_ENABLE_COLOR_FONT,
    );
    var tag1: win.D2D1_TAG = 0;
    var tag2: win.D2D1_TAG = 0;
    if (base.*.lpVtbl.*.EndDraw.?(base, &tag1, &tag2) != 0) {
        // The target may need recreation after device loss; drop it so the
        // next call rebuilds, and fall back to GDI for this run.
        releaseTarget();
        return false;
    }
    return true;
}

fn releaseTarget() void {
    if (state.brush) |brush| {
        const unknown: *win.IUnknown = @ptrCast(brush);
        _ = unknown.*.lpVtbl.*.Release.?(unknown);
    }
    if (state.target) |target| {
        const unknown: *win.IUnknown = @ptrCast(target);
        _ = unknown.*.lpVtbl.*.Release.?(unknown);
    }
    state.brush = null;
    state.target = null;
    state.bound_hdc = null;
}

pub fn reset() void {
    releaseTarget();
    for (state.formats[0..state.format_count]) |entry| {
        if (entry.format) |format| _ = format.*.lpVtbl.*.Release.?(format);
    }
    state.formats = [_]FormatEntry{.{ .em = 0 }} ** format_cache_size;
    state.format_count = 0;
}
