//! Parsing of `wacli --json --read-only auth status` output, the probe that
//! names the linked WhatsApp account for the launch cache (WAZI-67). Pure
//! logic, unit tested without Windows; main.zig owns the spawning and the
//! cache tag hashing.
//!
//! wacli 0.17.x moved the payload under a top-level `data` object:
//!   {"success":true,"data":{"authenticated":true,"linked_jid":"...","phone":"..."}}
//! Older builds answered with those fields at the top level. Both shapes
//! must parse, or the account tag is never found and every launch opens
//! with the caches disabled (WAZI-86).

const std = @import("std");

/// The linked jid from an auth status payload: top level first, then under
/// `data`. Null when the payload carries neither, is not an object, or holds
/// an empty or non-string jid.
pub fn linkedJid(root: std.json.Value) ?[]const u8 {
    const object = switch (root) {
        .object => |object| object,
        else => return null,
    };
    if (stringField(object, "linked_jid")) |jid| return jid;
    const data = object.get("data") orelse return null;
    return switch (data) {
        .object => |nested| stringField(nested, "linked_jid"),
        else => null,
    };
}

fn stringField(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| if (text.len > 0) text else null,
        else => null,
    };
}

test "linkedJid reads the wacli 0.17 shape with the payload under data" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"success\":true,\"data\":{\"authenticated\":true,\"linked_jid\":\"4917012345678@s.whatsapp.net\",\"phone\":\"+49...\"}}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("4917012345678@s.whatsapp.net", linkedJid(parsed.value) orelse return error.TestUnexpectedResult);
}

test "linkedJid still reads the old top-level shape" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"authenticated\":true,\"linked_jid\":\"4917012345678@s.whatsapp.net\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("4917012345678@s.whatsapp.net", linkedJid(parsed.value) orelse return error.TestUnexpectedResult);
}

test "linkedJid rejects payloads without a usable jid" {
    const cases = [_][]const u8{
        "{\"success\":false,\"error\":\"not linked\"}",
        "{\"data\":{\"authenticated\":false}}",
        "{\"data\":{\"linked_jid\":\"\"}}",
        "{\"linked_jid\":\"\"}",
        "{\"linked_jid\":null}",
        "{\"linked_jid\":42}",
        "[]",
        "not json",
        "",
    };
    for (cases) |body| {
        var parsed = std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{}) catch {
            // A payload that does not parse at all has no jid either.
            continue;
        };
        defer parsed.deinit();
        try std.testing.expectEqual(@as(?[]const u8, null), linkedJid(parsed.value));
    }
}

test "linkedJid prefers the top-level field when both shapes are present" {
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, "{\"linked_jid\":\"111@host\",\"data\":{\"linked_jid\":\"222@host\"}}", .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("111@host", linkedJid(parsed.value) orelse return error.TestUnexpectedResult);
}
