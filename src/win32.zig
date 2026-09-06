//! Shared Win32 cImport: modules that exchange Win32/COM types (main.zig,
//! emoji_draw.zig) must use this one so handle and COM types are identical
//! across files. Standalone modules (audio.zig, avatar.zig, dictation.zig)
//! still keep private cImports until they are migrated.
pub const c = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("NOMINMAX", "1");
    @cDefine("COBJMACROS", "1");
    @cInclude("windows.h");
    @cInclude("windowsx.h");
    @cInclude("commctrl.h");
    @cInclude("dwmapi.h");
    @cInclude("shellapi.h");
    @cInclude("shobjidl.h");
    @cInclude("wincodec.h");
    @cInclude("mfapi.h");
    @cInclude("mfidl.h");
    @cInclude("mfreadwrite.h");
    @cInclude("mfplay.h");
    @cInclude("winhttp.h");
    @cInclude("d2d1.h");
    @cInclude("dwrite.h");
});
