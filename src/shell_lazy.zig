// Lazy, on-demand loading of shell32.dll and comdlg32.dll.
//
// Both are only needed for occasional user actions (open a link or file,
// generate a video thumbnail, browse for a file to attach), never at
// startup, but a static import puts them in the exe's import table so the
// Windows loader maps them (shell32 alone is ~7.6 MB, and pulls in
// windows.storage.dll and other shell infrastructure) before the app's own
// code runs. Resolved lazily instead; see build.zig for the removed
// linkSystemLibrary entries.
const std = @import("std");
const win = @import("win32.zig").c;

fn lit(comptime text: []const u8) [*:0]const u16 {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

var shell32: win.HMODULE = null;
var comdlg32: win.HMODULE = null;

pub var shellExecuteW: ?*const @TypeOf(win.ShellExecuteW) = null;
pub var shCreateItemFromParsingName: ?*const @TypeOf(win.SHCreateItemFromParsingName) = null;
pub var dragQueryFileW: ?*const @TypeOf(win.DragQueryFileW) = null;

/// Resolves the shell32 entry points this app uses. Returns false (leaving
/// nothing loaded) if shell32.dll cannot be loaded or is missing a symbol.
pub fn ensureShell32() bool {
    if (shell32 != null) return true;
    const module = win.LoadLibraryW(lit("shell32.dll")) orelse return false;
    const execute_raw = win.GetProcAddress(module, "ShellExecuteW") orelse return false;
    const create_item_raw = win.GetProcAddress(module, "SHCreateItemFromParsingName") orelse return false;
    const drag_query_raw = win.GetProcAddress(module, "DragQueryFileW") orelse return false;
    shellExecuteW = @ptrCast(@alignCast(execute_raw));
    shCreateItemFromParsingName = @ptrCast(@alignCast(create_item_raw));
    dragQueryFileW = @ptrCast(@alignCast(drag_query_raw));
    shell32 = module;
    return true;
}

// main.zig's own OPENFILENAMEW mirrors the Win32 struct exactly, so a
// generic pointer here and a cast at the one call site keeps this module
// free of a dependency back on main.zig's types.
pub var getOpenFileNameW: ?*const fn (*anyopaque) callconv(.winapi) win.BOOL = null;

/// Resolves comdlg32!GetOpenFileNameW for the "attach a file" dialog.
pub fn ensureComdlg32() bool {
    if (comdlg32 != null) return true;
    const module = win.LoadLibraryW(lit("comdlg32.dll")) orelse return false;
    const raw = win.GetProcAddress(module, "GetOpenFileNameW") orelse return false;
    getOpenFileNameW = @ptrCast(@alignCast(raw));
    comdlg32 = module;
    return true;
}
