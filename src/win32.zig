//! Single shared Win32 cImport: every module must use this one so that
//! handle and COM types are identical across files.
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
