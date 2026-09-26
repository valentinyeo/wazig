//! Colour emoji with plain GDI: Segoe UI Emoji's COLRv0 layers (colr.zig)
//! drawn one by one with ExtTextOutW(ETO_GLYPH_INDEX). No Direct2D or
//! DirectWrite, so d2d1.dll, dwrite.dll and the D3D10Warp software rasterizer
//! never load (the app's premise is a small memory footprint).
//!
//! Uniscribe (usp10) shapes each run so ZWJ families, skin tones and keycaps
//! become the font's single composed glyph. Every layer is rendered as a
//! grayscale-antialiased coverage mask, tinted with its CPAL colour, composed
//! into a premultiplied bitmap and AlphaBlended onto the caller's DC, so the
//! emoji sits correctly on any bubble colour. Composed bitmaps are cached per
//! (glyph, size, text colour). Measuring and drawing share one shaping call,
//! so wrapping always matches what is painted.
//!
//! Every failure returns null and the caller falls back to the GDI monochrome
//! path; the reason is recorded (failureNotice) and logged to emoji.log.
const std = @import("std");
const build_info = @import("build_info");
const colr = @import("colr.zig");
const win = @import("win32.zig").c;

pub const Metrics = struct { width: i32, baseline: i32 };

const max_sequence_units = 32;
// Uniscribe's documented worst case for the glyph buffer is 1.5n + 16.
const max_glyphs = max_sequence_units * 3 / 2 + 16;
const font_cache_size = 8;
const bitmap_cache_size = 128;

const tag_colr: win.DWORD = 0x524C4F43; // 'COLR' as GetFontData wants it
const tag_cpal: win.DWORD = 0x4C415043; // 'CPAL'
const gdi_error: win.DWORD = 0xFFFFFFFF;
const usp_e_script_not_in_font: win.HRESULT = @bitCast(@as(u32, 0x80040200));

// usp10.h's SCRIPT_ANALYSIS and SCRIPT_VISATTR are bitfield structs that
// translate-c cannot express, so declare the ABI-equal shapes here.
const ScriptAnalysis = extern struct { bits: u16 = 0, state: u16 = 0 };
const ScriptItem = extern struct { char_pos: c_int, analysis: ScriptAnalysis };
const ScriptVisAttr = extern struct { bits: u16 };
const GOffset = extern struct { du: i32, dv: i32 };
const ScriptCache = ?*anyopaque;

extern "usp10" fn ScriptItemize(chars: [*]const u16, char_count: c_int, max_items: c_int, control: ?*const anyopaque, script_state: ?*const anyopaque, items: [*]ScriptItem, item_count: *c_int) callconv(.c) win.HRESULT;
extern "usp10" fn ScriptShape(hdc: win.HDC, cache: *ScriptCache, chars: [*]const u16, char_count: c_int, max_glyph_count: c_int, analysis: *ScriptAnalysis, glyphs: [*]u16, clusters: [*]u16, attributes: [*]ScriptVisAttr, glyph_count: *c_int) callconv(.c) win.HRESULT;
extern "usp10" fn ScriptPlace(hdc: win.HDC, cache: *ScriptCache, glyphs: [*]const u16, glyph_count: c_int, attributes: [*]const ScriptVisAttr, analysis: *ScriptAnalysis, advances: [*]c_int, offsets: [*]GOffset, abc: ?*win.ABC) callconv(.c) win.HRESULT;
extern "usp10" fn ScriptFreeCache(cache: *ScriptCache) callconv(.c) win.HRESULT;

/// Stages where the colour path can bail, in call order. Each maps to a
/// plain-language reason the status bar and Ctrl+K palette can show (WAZI-65).
const ErrorStage = enum { surface, font, colour_tables, colour_parse, shape, bitmap };

const FontEntry = struct {
    em: i32 = 0,
    font: ?win.HFONT = null,
    cache: ScriptCache = null,
    ascent: i32 = 0,
    height: i32 = 0,
};

const BitmapEntry = struct {
    glyph: u16 = 0,
    em: i32 = 0,
    foreground: win.COLORREF = 0,
    width: i32 = 0,
    height: i32 = 0,
    pixels: []u8 = &.{},
    last_used: u64 = 0,
};

const ColourLoad = enum { pending, ready, failed };

const State = struct {
    // One memory DC for shaping, measuring and layer rendering; metrics()
    // has no caller DC, and the scratch bitmap lives here too.
    dc: ?win.HDC = null,
    scratch: ?win.HBITMAP = null,
    scratch_bits: ?[*]u8 = null,
    scratch_width: i32 = 0,
    scratch_height: i32 = 0,
    selected_em: i32 = 0,
    fonts: [font_cache_size]FontEntry = [_]FontEntry{.{}} ** font_cache_size,
    // Only the COLR v0 arrays and CPAL palette 0 are kept (one allocation);
    // the table's v1 paint data is never read.
    colour: ColourLoad = .pending,
    table: colr.Colr = .{ .base = &.{}, .layers = &.{}, .palette = &.{} },
    bitmaps: [bitmap_cache_size]BitmapEntry = [_]BitmapEntry{.{}} ** bitmap_cache_size,
    clock: u64 = 0,
    last_error: ?ErrorStage = null,
    last_code: u32 = 0,
    // One-shot announcement: the status bar shows each new reason once.
    announced: bool = false,
    notice_buf: [128]u8 = undefined,
};
var state: State = .{};

fn fail(stage: ErrorStage, code: u32) void {
    if (state.last_error == null or state.last_error.? != stage or state.last_code != code) {
        state.last_error = stage;
        state.last_code = code;
        state.announced = false;
        logStage(stage, code);
    }
}

/// Every new failure stage gets a timestamped line with the failing call's
/// code in %LOCALAPPDATA%\Wazig\emoji.log (WAZI-65): the diagnosis must not
/// depend on anyone running the "Why are emoji black and white?" palette
/// command, and the stage alone cannot tell two failing calls apart.
fn logStage(stage: ErrorStage, code: u32) void {
    var path: [280]u16 = undefined;
    const local_label = std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA");
    const local_len: usize = @intCast(win.GetEnvironmentVariableW(local_label, &path, path.len - 40));
    if (local_len == 0 or local_len >= path.len - 40) return;
    const suffix = std.unicode.utf8ToUtf16LeStringLiteral("\\Wazig\\emoji.log");
    @memcpy(path[local_len..][0..suffix.len], suffix);
    const total = local_len + suffix.len;
    path[total] = 0;
    // Ignore the "already exists" error; only a missing directory matters.
    // Temporarily terminate the "\Wazig" prefix so the directory path, not
    // the log path, is what CreateDirectoryW sees.
    const after_dir = path[local_len + 7];
    path[local_len + 7] = 0;
    _ = win.CreateDirectoryW(path[0 .. local_len + 7 :0].ptr, null);
    path[local_len + 7] = after_dir;
    var clock = std.mem.zeroes(win.SYSTEMTIME);
    win.GetLocalTime(&clock);
    var line_buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&line_buf, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} v{s} colour emoji fell back at stage {s} (code 0x{X:0>8}): {s}\r\n", .{
        clock.wYear, clock.wMonth, clock.wDay, clock.wHour, clock.wMinute, clock.wSecond, build_info.version, @tagName(stage), code, stageText(stage),
    }) catch return;
    const handle = win.CreateFileW(path[0..total :0].ptr, win.FILE_APPEND_DATA, win.FILE_SHARE_READ | win.FILE_SHARE_WRITE, null, win.OPEN_ALWAYS, win.FILE_ATTRIBUTE_NORMAL, null);
    if (handle == win.INVALID_HANDLE_VALUE or handle == null) return;
    defer _ = win.CloseHandle(handle);
    var written: win.DWORD = 0;
    _ = win.WriteFile(handle, line.ptr, @intCast(line.len), &written, null);
}

fn clearError() void {
    state.last_error = null;
    state.announced = false;
}

fn stageText(stage: ErrorStage) []const u8 {
    return switch (stage) {
        .surface => "the drawing surface could not be created",
        .font => "the emoji font (Segoe UI Emoji) could not be loaded",
        .colour_tables => "the emoji font has no colour information",
        .colour_parse => "the emoji font's colour information could not be read",
        .shape => "the emoji could not be matched to the font",
        .bitmap => "the emoji drawing surface could not be created",
    };
}

fn noticeText(stage: ErrorStage) []const u8 {
    const text = std.fmt.bufPrint(&state.notice_buf, "Emoji drawn in black and white: {s}", .{stageText(stage)}) catch return stageText(stage);
    return text;
}

/// The current reason the colour path is off, if any; stays until the colour
/// path works again. Shown by the "Why are emoji black and white?" command.
pub fn failureNotice() ?[]const u8 {
    const stage = state.last_error orelse return null;
    return noticeText(stage);
}

/// The reason once per new failure stage, for the status bar.
pub fn takeNotice() ?[]const u8 {
    if (state.last_error == null or state.announced) return null;
    state.announced = true;
    return failureNotice();
}

/// The one bounds check for an emoji sequence and its em size, shared by the
/// measure and draw funnels so the two can never disagree about what takes
/// the colour path versus the GDI fallback.
fn validSequence(text: []const u16, em: i32) bool {
    return text.len != 0 and text.len <= max_sequence_units and em > 0 and em <= 256;
}

fn ensureDc() ?win.HDC {
    if (state.dc) |dc| return dc;
    const dc = win.CreateCompatibleDC(null) orelse {
        fail(.surface, win.GetLastError());
        return null;
    };
    _ = win.SetBkMode(dc, win.TRANSPARENT);
    _ = win.SetTextColor(dc, 0x00FFFFFF);
    _ = win.SetTextAlign(dc, win.TA_LEFT | win.TA_TOP | win.TA_NOUPDATECP);
    state.dc = dc;
    return dc;
}

/// Selects the emoji font at `em` pixels into the module DC, creating it on
/// first use. Grayscale AA (not ClearType): the layers become alpha masks,
/// and per-channel ClearType coverage would leave colour fringes.
fn selectFont(dc: win.HDC, em: i32) ?*FontEntry {
    var slot: usize = 0;
    for (&state.fonts, 0..) |*entry, index| {
        if (entry.em == em and entry.font != null) {
            if (state.selected_em != em) {
                _ = win.SelectObject(dc, @ptrCast(entry.font.?));
                state.selected_em = em;
            }
            return entry;
        }
        // Reuse an empty slot, else overwrite the smallest em without
        // ceremony (an app uses a handful of sizes).
        if (entry.font == null or (state.fonts[slot].font != null and entry.em < state.fonts[slot].em)) slot = index;
    }
    const family: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Emoji");
    const font = win.CreateFontW(-em, 0, 0, 0, win.FW_NORMAL, 0, 0, 0, win.DEFAULT_CHARSET, win.OUT_TT_ONLY_PRECIS, win.CLIP_DEFAULT_PRECIS, win.ANTIALIASED_QUALITY, win.DEFAULT_PITCH, family.ptr) orelse {
        fail(.font, win.GetLastError());
        return null;
    };
    _ = win.SelectObject(dc, @ptrCast(font));
    state.selected_em = em;
    const entry = &state.fonts[slot];
    if (entry.font) |old| {
        _ = ScriptFreeCache(&entry.cache);
        _ = win.DeleteObject(@ptrCast(old));
    }
    var text_metrics: win.TEXTMETRICW = undefined;
    _ = win.GetTextMetricsW(dc, &text_metrics);
    entry.* = .{ .em = em, .font = font, .ascent = text_metrics.tmAscent, .height = text_metrics.tmHeight };
    return entry;
}

/// Loads the COLR v0 arrays and CPAL palette 0 once, from the font GDI
/// already has open (GetFontData with offsets, so the multi-megabyte v1
/// paint data is never copied). A missing or broken table latches the
/// colour path off for the session: the font will not change under us.
fn ensureColour(dc: win.HDC) bool {
    switch (state.colour) {
        .ready => return true,
        .failed => return false,
        .pending => {},
    }
    var face: [32]u16 = undefined;
    const face_len = win.GetTextFaceW(dc, face.len, &face);
    const expected = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI Emoji");
    if (face_len <= 0 or !std.mem.eql(u16, face[0..@intCast(face_len - 1)], expected)) {
        // Font substitution handed us some other face: its glyph ids mean
        // nothing to a COLR table we would read from it.
        state.colour = .failed;
        fail(.font, @intCast(@max(face_len, 0)));
        return false;
    }
    if (loadTables(dc)) |code| {
        state.colour = .failed;
        fail(if (code == gdi_error) .colour_tables else .colour_parse, code);
        return false;
    }
    state.colour = .ready;
    return true;
}

/// Returns null on success, else the failing code (gdi_error = table absent).
fn loadTables(dc: win.HDC) ?u32 {
    var header_bytes: [colr.header_len]u8 = undefined;
    if (win.GetFontData(dc, tag_colr, 0, &header_bytes, header_bytes.len) != header_bytes.len) return gdi_error;
    const header = colr.parseHeader(&header_bytes) catch return 1;
    if (header.base_count == 0 or header.layer_count == 0) return 2;
    const cpal_size = win.GetFontData(dc, tag_cpal, 0, null, 0);
    if (cpal_size == gdi_error or cpal_size == 0) return gdi_error;
    const cpal = std.heap.c_allocator.alloc(u8, cpal_size) catch return 3;
    defer std.heap.c_allocator.free(cpal);
    if (win.GetFontData(dc, tag_cpal, 0, cpal.ptr, cpal_size) != cpal_size) return 4;
    const palette = colr.paletteZero(cpal) catch return 5;
    const base_len = header.baseLen();
    const layer_len = header.layerLen();
    const kept = std.heap.c_allocator.alloc(u8, base_len + layer_len + palette.len) catch return 6;
    const base = kept[0..base_len];
    const layers = kept[base_len..][0..layer_len];
    if (win.GetFontData(dc, tag_colr, header.base_offset, base.ptr, @intCast(base_len)) != base_len or
        win.GetFontData(dc, tag_colr, header.layer_offset, layers.ptr, @intCast(layer_len)) != layer_len)
    {
        std.heap.c_allocator.free(kept);
        return 7;
    }
    @memcpy(kept[base_len + layer_len ..], palette);
    state.table = colr.Colr.init(base, layers, kept[base_len + layer_len ..]);
    return null;
}

const Shaped = struct {
    glyphs: [max_glyphs]u16 = undefined,
    advances: [max_glyphs]c_int = undefined,
    count: usize = 0,
    width: i32 = 0,
};

/// The one shaping call behind both metrics() and draw(): Uniscribe maps the
/// run to the font's glyphs, applying its ligatures so a ZWJ or skin-tone
/// sequence becomes one composed glyph. null when the font lacks a glyph
/// (GDI font fallback may still find one) or Uniscribe fails.
fn shape(dc: win.HDC, font: *FontEntry, text: []const u16, out: *Shaped) bool {
    var items: [max_sequence_units + 1]ScriptItem = undefined;
    var item_count: c_int = 0;
    const itemize_hr = ScriptItemize(text.ptr, @intCast(text.len), items.len, null, null, &items, &item_count);
    if (itemize_hr != 0 or item_count <= 0) {
        fail(.shape, @bitCast(itemize_hr));
        return false;
    }
    out.count = 0;
    out.width = 0;
    for (0..@intCast(item_count)) |index| {
        const start: usize = @intCast(items[index].char_pos);
        const end: usize = @intCast(items[index + 1].char_pos);
        if (end <= start) continue;
        var clusters: [max_sequence_units]u16 = undefined;
        var attributes: [max_glyphs]ScriptVisAttr = undefined;
        var offsets: [max_glyphs]GOffset = undefined;
        var glyph_count: c_int = 0;
        const room: c_int = @intCast(max_glyphs - out.count);
        const glyphs = out.glyphs[out.count..].ptr;
        const shape_hr = ScriptShape(dc, &font.cache, text[start..].ptr, @intCast(end - start), room, &items[index].analysis, glyphs, &clusters, &attributes, &glyph_count);
        if (shape_hr == usp_e_script_not_in_font) return false;
        if (shape_hr != 0) {
            fail(.shape, @bitCast(shape_hr));
            return false;
        }
        const placed: usize = @intCast(glyph_count);
        // Glyph 0 is .notdef: this font cannot draw the sequence.
        for (out.glyphs[out.count..][0..placed]) |glyph| if (glyph == 0) return false;
        const place_hr = ScriptPlace(dc, &font.cache, glyphs, glyph_count, &attributes, &items[index].analysis, out.advances[out.count..].ptr, &offsets, null);
        if (place_hr != 0) {
            fail(.shape, @bitCast(place_hr));
            return false;
        }
        for (out.advances[out.count..][0..placed]) |advance| out.width += advance;
        out.count += placed;
    }
    return out.count != 0;
}

/// Grows the scratch DIB that layers are rendered into and bitmaps are
/// blitted from; it stays selected in the module DC.
fn ensureScratch(dc: win.HDC, width: i32, height: i32) bool {
    if (state.scratch != null and state.scratch_width >= width and state.scratch_height >= height) return true;
    const new_width = @max(width, state.scratch_width);
    const new_height = @max(height, state.scratch_height);
    var info = std.mem.zeroes(win.BITMAPINFO);
    info.bmiHeader.biSize = @sizeOf(win.BITMAPINFOHEADER);
    info.bmiHeader.biWidth = new_width;
    info.bmiHeader.biHeight = -new_height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = win.BI_RGB;
    var bits: ?*anyopaque = null;
    const bitmap = win.CreateDIBSection(dc, &info, win.DIB_RGB_COLORS, &bits, null, 0) orelse {
        fail(.bitmap, win.GetLastError());
        return false;
    };
    if (bits == null) {
        _ = win.DeleteObject(bitmap);
        fail(.bitmap, 0);
        return false;
    }
    _ = win.SelectObject(dc, bitmap);
    if (state.scratch) |old| _ = win.DeleteObject(old);
    state.scratch = bitmap;
    state.scratch_bits = @ptrCast(bits.?);
    state.scratch_width = new_width;
    state.scratch_height = new_height;
    return true;
}

/// Horizontal room either side of the advance for glyph overhang.
fn padFor(em: i32) i32 {
    return @divTrunc(em, 8) + 1;
}

/// The composed premultiplied BGRA bitmap for one glyph, from the cache or
/// rendered now: each COLR layer (or the glyph itself when it has none) is
/// drawn white-on-black to get its coverage, then tinted and composited
/// source-over in paint order.
fn glyphBitmap(dc: win.HDC, font: *FontEntry, glyph: u16, advance: i32, foreground: win.COLORREF) ?*BitmapEntry {
    state.clock += 1;
    var victim = &state.bitmaps[0];
    for (&state.bitmaps) |*entry| {
        if (entry.pixels.len != 0 and entry.glyph == glyph and entry.em == font.em and entry.foreground == foreground) {
            entry.last_used = state.clock;
            return entry;
        }
        if (entry.last_used < victim.last_used) victim = entry;
    }
    const pad = padFor(font.em);
    const width = advance + 2 * pad;
    const height = font.height;
    if (!ensureScratch(dc, width, height)) return null;
    const size: usize = @intCast(width * height * 4);
    const pixels = std.heap.c_allocator.alloc(u8, size) catch {
        fail(.bitmap, 0);
        return null;
    };
    @memset(pixels, 0);
    const scratch = state.scratch_bits.?;
    const stride: usize = @intCast(state.scratch_width * 4);
    const scratch_size = stride * @as(usize, @intCast(state.scratch_height));
    const range = state.table.find(glyph);
    const layer_count = if (range) |found| found.count else 1;
    for (0..layer_count) |layer_index| {
        const layer = if (range) |found| state.table.layer(found.first + layer_index) else colr.Layer{ .glyph = glyph, .palette_index = colr.foreground };
        const bgra: [4]u8 = if (layer.palette_index == colr.foreground)
            .{ @truncate(foreground >> 16), @truncate(foreground >> 8), @truncate(foreground), 255 }
        else
            state.table.color(layer.palette_index) orelse continue;
        if (bgra[3] == 0) continue;
        @memset(scratch[0..scratch_size], 0);
        const layer_glyph = [1]u16{layer.glyph};
        _ = win.ExtTextOutW(dc, pad, 0, win.ETO_GLYPH_INDEX, null, &layer_glyph, 1, null);
        _ = win.GdiFlush();
        for (0..@intCast(height)) |y| {
            for (0..@intCast(width)) |x| {
                const coverage: u32 = scratch[y * stride + x * 4 + 1];
                if (coverage == 0) continue;
                const src_alpha = coverage * bgra[3] / 255;
                const pixel = pixels[(y * @as(usize, @intCast(width)) + x) * 4 ..][0..4];
                const keep = 255 - src_alpha;
                for (0..3) |channel| {
                    pixel[channel] = @intCast((@as(u32, bgra[channel]) * src_alpha + @as(u32, pixel[channel]) * keep) / 255);
                }
                pixel[3] = @intCast(src_alpha + @as(u32, pixel[3]) * keep / 255);
            }
        }
    }
    if (victim.pixels.len != 0) std.heap.c_allocator.free(victim.pixels);
    victim.* = .{ .glyph = glyph, .em = font.em, .foreground = foreground, .width = width, .height = height, .pixels = pixels, .last_used = state.clock };
    return victim;
}

fn blit(target: win.HDC, dc: win.HDC, entry: *const BitmapEntry, x: i32, y: i32) bool {
    if (!ensureScratch(dc, entry.width, entry.height)) return false;
    const scratch = state.scratch_bits.?;
    const stride: usize = @intCast(state.scratch_width * 4);
    const row: usize = @intCast(entry.width * 4);
    for (0..@intCast(entry.height)) |line| {
        @memcpy(scratch[line * stride ..][0..row], entry.pixels[line * row ..][0..row]);
    }
    _ = win.GdiFlush();
    const blend = win.BLENDFUNCTION{
        .BlendOp = win.AC_SRC_OVER,
        .BlendFlags = 0,
        .SourceConstantAlpha = 255,
        .AlphaFormat = win.AC_SRC_ALPHA,
    };
    return win.AlphaBlend(target, x, y, entry.width, entry.height, dc, 0, 0, entry.width, entry.height, blend) != 0;
}

/// Shared front half of metrics() and draw(): the DC, font and colour tables
/// ready, and the run shaped. null means "use the GDI fallback".
fn prepare(text: []const u16, em: i32, shaped: *Shaped) ?*FontEntry {
    if (!validSequence(text, em)) return null;
    if (state.colour == .failed) return null;
    const dc = ensureDc() orelse return null;
    const font = selectFont(dc, em) orelse return null;
    if (!ensureColour(dc)) return null;
    if (!shape(dc, font, text, shaped)) return null;
    return font;
}

/// Width and baseline distance of one emoji sequence at the given em size in
/// pixels. null means the color path is unavailable for this sequence and the
/// caller should measure and draw with GDI instead.
pub fn metrics(text: []const u16, em: i32) ?Metrics {
    var shaped: Shaped = .{};
    const font = prepare(text, em, &shaped) orelse return null;
    return .{ .width = shaped.width, .baseline = font.ascent };
}

/// Draws one emoji sequence with color glyphs and returns its measured run
/// width. `top_y` is the top of the text line's character cell and `ascent`
/// the text font's ascent, matching how GDI TextOutW positions the
/// neighbouring runs; the emoji baseline lands on the text baseline. null on
/// any failure (the reason lands in emoji.log via failureNotice), meaning the
/// caller should fall back to the GDI monochrome path.
pub fn draw(hdc: win.HDC, text: []const u16, x: i32, top_y: i32, text_ascent: i32, em: i32) ?Metrics {
    var shaped: Shaped = .{};
    const font = prepare(text, em, &shaped) orelse return null;
    const dc = state.dc.?;
    const foreground = win.GetTextColor(hdc) & 0x00FFFFFF;
    const top = top_y + text_ascent - font.ascent;
    const pad = padFor(em);
    var pen = x;
    for (shaped.glyphs[0..shaped.count], shaped.advances[0..shaped.count]) |glyph, advance| {
        // Zero-width glyphs (an unjoined ZWJ, a variation selector) are blank.
        if (advance > 0) {
            const entry = glyphBitmap(dc, font, glyph, advance, foreground) orelse return null;
            if (!blit(hdc, dc, entry, pen - pad, top)) {
                fail(.bitmap, win.GetLastError());
                return null;
            }
        }
        pen += advance;
    }
    clearError();
    return .{ .width = shaped.width, .baseline = font.ascent };
}
