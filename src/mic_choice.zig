//! Which microphone voice notes and dictation record from. The choice is the
//! device's friendly name, kept in the registry; "System default" (empty
//! name), or a device that is no longer plugged in, uses the Windows default.
const std = @import("std");
const win = @cImport({
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cDefine("COBJMACROS", "1");
    @cInclude("windows.h");
    @cInclude("objbase.h");
    @cInclude("mmdeviceapi.h");
});

pub const max_devices = 16;
pub const name_cap = 128;

pub const Name = struct {
    buf: [name_cap]u8 = undefined,
    len: usize = 0,
    pub fn slice(self: *const Name) []const u8 {
        return self.buf[0..self.len];
    }
};

var chosen: Name = .{};

const guid_mmdevice_enumerator = win.GUID{ .Data1 = 0xbcde0395, .Data2 = 0xe52f, .Data3 = 0x467c, .Data4 = .{ 0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e } };
const guid_immdevice_enumerator = win.GUID{ .Data1 = 0xa95664d2, .Data2 = 0x9614, .Data3 = 0x4f35, .Data4 = .{ 0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6 } };
// PKEY_Device_FriendlyName
const key_friendly_name = win.PROPERTYKEY{
    .fmtid = .{ .Data1 = 0xa45c254e, .Data2 = 0xdf1c, .Data3 = 0x4efd, .Data4 = .{ 0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0 } },
    .pid = 14,
};

/// True when `name` should be used instead of the system default.
pub fn wantsDevice(name: []const u8) bool {
    return name.len > 0 and name.len <= name_cap;
}

pub fn current() []const u8 {
    return chosen.slice();
}

/// Pick a device by name ("" = System default) and remember it.
pub fn choose(name: []const u8) void {
    chosen.len = @min(name.len, name_cap);
    @memcpy(chosen.buf[0..chosen.len], name[0..chosen.len]);
    save();
}

pub fn load() void {
    var wide: [name_cap]u16 = undefined;
    var size: win.DWORD = @sizeOf(@TypeOf(wide));
    const hkcu = hkeyAt(0x80000001);
    const sub = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Messages");
    const value = std.unicode.utf8ToUtf16LeStringLiteral("Microphone");
    if (win.RegGetValueW(hkcu, sub, value, win.RRF_RT_REG_SZ, null, &wide, &size) != win.ERROR_SUCCESS) return;
    const units = @min(size / 2, wide.len);
    var end: usize = 0;
    while (end < units and wide[end] != 0) end += 1;
    chosen.len = std.unicode.utf16LeToUtf8(&chosen.buf, wide[0..end]) catch 0;
}

fn save() void {
    var wide: [name_cap + 1]u16 = undefined;
    const length = std.unicode.utf8ToUtf16Le(wide[0..name_cap], chosen.slice()) catch 0;
    wide[length] = 0;
    var key: win.HKEY = null;
    var disposition: win.DWORD = 0;
    const hkcu = hkeyAt(0x80000001);
    if (win.RegCreateKeyExW(hkcu, std.unicode.utf8ToUtf16LeStringLiteral("Software\\Messages"), 0, null, 0, win.KEY_SET_VALUE, null, &key, &disposition) != win.ERROR_SUCCESS) return;
    defer _ = win.RegCloseKey(key);
    _ = win.RegSetValueExW(key, std.unicode.utf8ToUtf16LeStringLiteral("Microphone"), 0, win.REG_SZ, @ptrCast(&wide), @intCast((length + 1) * 2));
}

fn friendlyName(device: *win.IMMDevice, out: *Name) bool {
    var store: ?*win.IPropertyStore = null;
    if (device.lpVtbl.*.OpenPropertyStore.?(device, 0, &store) < 0 or store == null) return false;
    defer _ = store.?.lpVtbl.*.Release.?(store);
    var variant = std.mem.zeroes(win.PROPVARIANT);
    if (store.?.lpVtbl.*.GetValue.?(store, &key_friendly_name, &variant) < 0) return false;
    defer _ = win.PropVariantClear(&variant);
    // PROPVARIANT: vt (u16) + 6 reserved bytes, then the value; for VT_LPWSTR
    // (31) that is a pointer to a NUL-terminated UTF-16 string.
    const bytes: [*]const u8 = @ptrCast(&variant);
    if (std.mem.readInt(u16, bytes[0..2], .little) != 31) return false;
    const text: ?[*:0]const u16 = @as(*const ?[*:0]const u16, @ptrCast(@alignCast(bytes + 8))).*;
    const wide = text orelse return false;
    out.len = std.unicode.utf16LeToUtf8(&out.buf, std.mem.span(wide)) catch return false;
    return out.len > 0;
}

fn collection(enumerator: *win.IMMDeviceEnumerator) ?*win.IMMDeviceCollection {
    var devices: ?*win.IMMDeviceCollection = null;
    if (enumerator.lpVtbl.*.EnumAudioEndpoints.?(enumerator, win.eCapture, win.DEVICE_STATE_ACTIVE, &devices) < 0) return null;
    return devices;
}

fn makeEnumerator() ?*win.IMMDeviceEnumerator {
    var enumerator: ?*win.IMMDeviceEnumerator = null;
    if (win.CoCreateInstance(&guid_mmdevice_enumerator, null, win.CLSCTX_ALL, &guid_immdevice_enumerator, @ptrCast(&enumerator)) < 0) return null;
    return enumerator;
}

/// Names of the active input devices (for the picker). Safe on the UI thread.
pub fn list(out: *[max_devices]Name) usize {
    _ = win.CoInitializeEx(null, win.COINIT_APARTMENTTHREADED);
    const enumerator = makeEnumerator() orelse return 0;
    defer _ = enumerator.lpVtbl.*.Release.?(enumerator);
    const devices = collection(enumerator) orelse return 0;
    defer _ = devices.lpVtbl.*.Release.?(devices);
    var count: win.UINT = 0;
    if (devices.lpVtbl.*.GetCount.?(devices, &count) < 0) return 0;
    var found: usize = 0;
    var index: win.UINT = 0;
    while (index < count and found < max_devices) : (index += 1) {
        var device: ?*win.IMMDevice = null;
        if (devices.lpVtbl.*.Item.?(devices, index, &device) < 0 or device == null) continue;
        defer _ = device.?.lpVtbl.*.Release.?(device);
        if (friendlyName(device.?, &out[found])) found += 1;
    }
    return found;
}

/// The chosen device as an owned IMMDevice (release it), or null to use the
/// system default (no choice made, or the device is gone). The caller has
/// already initialised COM on its thread. Returned untyped because each
/// capture module has its own Win32 import.
pub fn openChosen() ?*anyopaque {
    if (!wantsDevice(chosen.slice())) return null;
    const enumerator = makeEnumerator() orelse return null;
    defer _ = enumerator.lpVtbl.*.Release.?(enumerator);
    const devices = collection(enumerator) orelse return null;
    defer _ = devices.lpVtbl.*.Release.?(devices);
    var count: win.UINT = 0;
    if (devices.lpVtbl.*.GetCount.?(devices, &count) < 0) return null;
    var index: win.UINT = 0;
    while (index < count) : (index += 1) {
        var device: ?*win.IMMDevice = null;
        if (devices.lpVtbl.*.Item.?(devices, index, &device) < 0 or device == null) continue;
        var name: Name = .{};
        if (friendlyName(device.?, &name) and std.mem.eql(u8, name.slice(), chosen.slice())) return @ptrCast(device);
        _ = device.?.lpVtbl.*.Release.?(device);
    }
    return null;
}

test "an empty choice means the system default" {
    try std.testing.expect(!wantsDevice(""));
    try std.testing.expect(wantsDevice("Headset Microphone (USB)"));
}

fn hkeyAt(value: usize) win.HKEY {
    @setRuntimeSafety(false);
    return @ptrFromInt(value);
}
