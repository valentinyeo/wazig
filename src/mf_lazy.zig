// Lazy, on-demand loading of Media Foundation for GIF thumbnails and video
// playback.
//
// mfplat.dll, mfreadwrite.dll and mfplay.dll are not linked at build time
// (see build.zig): importing them statically puts them in the exe's import
// table, so the Windows loader maps them (and, transitively, mfcore.dll,
// msvproc.dll and Windows.Media.dll) before any of the app's own code runs,
// even when no video or GIF is ever opened. This module resolves the small
// set of entry points actually used only on first real use, and releases
// them again once nothing needs Media Foundation (see main.zig's idle
// check on timer_refresh).
const std = @import("std");
const win = @import("win32.zig").c;

fn lit(comptime text: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

var mfplat: win.HMODULE = null;
var mfreadwrite: win.HMODULE = null;
var mfplay: win.HMODULE = null;

var startup_fn: ?*const @TypeOf(win.MFStartup) = null;
var shutdown_fn: ?*const @TypeOf(win.MFShutdown) = null;

// Exposed directly (rather than through hand-written wrappers) so each
// call site keeps the exact parameter types the Windows headers declare.
pub var createAttributes: ?*const @TypeOf(win.MFCreateAttributes) = null;
pub var createMediaType: ?*const @TypeOf(win.MFCreateMediaType) = null;
pub var createSourceReaderFromURL: ?*const @TypeOf(win.MFCreateSourceReaderFromURL) = null;
pub var createMediaPlayer: ?*const @TypeOf(win.MFPCreateMediaPlayer) = null;

var started = false;

/// Loads mfplat.dll/mfreadwrite.dll/mfplay.dll and calls MFStartup, if not
/// already done. Returns false (leaving Media Foundation untouched) if any
/// step fails, e.g. on a stripped-down Windows image.
pub fn ensureStarted() bool {
    if (started) return true;
    mfplat = win.LoadLibraryW(lit("mfplat.dll")) orelse return false;
    mfreadwrite = win.LoadLibraryW(lit("mfreadwrite.dll")) orelse return false;
    mfplay = win.LoadLibraryW(lit("mfplay.dll")) orelse return false;

    startup_fn = @ptrCast(@alignCast(win.GetProcAddress(mfplat, "MFStartup") orelse return false));
    shutdown_fn = @ptrCast(@alignCast(win.GetProcAddress(mfplat, "MFShutdown") orelse return false));
    createAttributes = @ptrCast(@alignCast(win.GetProcAddress(mfplat, "MFCreateAttributes") orelse return false));
    createMediaType = @ptrCast(@alignCast(win.GetProcAddress(mfplat, "MFCreateMediaType") orelse return false));
    createSourceReaderFromURL = @ptrCast(@alignCast(win.GetProcAddress(mfreadwrite, "MFCreateSourceReaderFromURL") orelse return false));
    createMediaPlayer = @ptrCast(@alignCast(win.GetProcAddress(mfplay, "MFPCreateMediaPlayer") orelse return false));

    if (startup_fn.?(win.MF_VERSION, win.MFSTARTUP_FULL) < 0) return false;
    started = true;
    return true;
}

/// True while anything (a GIF reader or the video player) still needs
/// Media Foundation; main.zig only calls unloadIfStarted() when this, and
/// its own live-reader/player checks, are all false.
pub fn isStarted() bool {
    return started;
}

/// Shuts Media Foundation down and frees the three DLLs this module
/// loaded. Only safe to call once every gif_reader and the video player
/// have been released; main.zig's idle timer enforces that.
pub fn unloadIfStarted() void {
    if (!started) return;
    if (shutdown_fn) |shutdown| _ = shutdown();
    startup_fn = null;
    shutdown_fn = null;
    createAttributes = null;
    createMediaType = null;
    createSourceReaderFromURL = null;
    createMediaPlayer = null;
    started = false;
    if (mfplay) |m| _ = win.FreeLibrary(m);
    if (mfreadwrite) |m| _ = win.FreeLibrary(m);
    if (mfplat) |m| _ = win.FreeLibrary(m);
    mfplay = null;
    mfreadwrite = null;
    mfplat = null;
    // The MF platform DLLs bring in in-proc COM servers (the video
    // processor MFT, codecs) as separate modules; drop those too.
    _ = win.CoFreeUnusedLibraries();
}
