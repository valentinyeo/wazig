//! Parsing for `wacli --json auth status` payloads (WAZI-67, WAZI-86).

const std = @import("std");

/// `auth status` moved its payload under a top-level `data` wrapper in newer
/// wacli releases (WAZI-86); accept both that shape and the old flat one.
pub fn linkedJid(value: std.json.Value) ?[]const u8 {
    const holder = switch (value) {
        .object => |object| object.get("data") orelse value,
        else => return null,
    };
    const object = switch (holder) {
        .object => |object| object,
        else => return null,
    };
    return switch (object.get("linked_jid") orelse return null) {
        .string => |jid| jid,
        else => null,
    };
}

test "linked jid parses both the flat and the data-wrapped auth status shape" {
    // wacli 0.17 moved the payload under `data` (WAZI-86); the parser must
    // accept both shapes or every launch disables the caches.
    const wrapped = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"success":true,"data":{"authenticated":true,"linked_jid":"1234@s.whatsapp.net"}}
    , .{});
    defer wrapped.deinit();
    try std.testing.expectEqualStrings("1234@s.whatsapp.net", linkedJid(wrapped.value).?);

    const flat = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"linked_jid":"5678@s.whatsapp.net"}
    , .{});
    defer flat.deinit();
    try std.testing.expectEqualStrings("5678@s.whatsapp.net", linkedJid(flat.value).?);

    const unlinked = try std.json.parseFromSlice(std.json.Value, std.testing.allocator,
        \\{"success":true,"data":{"authenticated":false}}
    , .{});
    defer unlinked.deinit();
    try std.testing.expect(linkedJid(unlinked.value) == null);
}
