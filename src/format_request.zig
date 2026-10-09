// Request bodies and response parsing for transcript formatting (Anthropic or OpenRouter).
// Windows-free so the unit tests run on any host.
const std = @import("std");

pub fn appendJsonEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |character| {
        switch (character) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => {
                if (character < 0x20) {
                    try list.appendSlice(allocator, " ");
                } else {
                    try list.append(allocator, character);
                }
            },
        }
    }
}

// Anthropic: Messages API without reasoning (speed matters more than depth here).
// OpenRouter: chat completions with medium reasoning, as before.
pub fn formatRequestBody(allocator: std.mem.Allocator, anthropic: bool, model: []const u8, system_prompt: []const u8, transcript: []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(allocator);
    try body.appendSlice(allocator, "{\"model\":\"");
    try appendJsonEscaped(&body, allocator, model);
    if (anthropic) {
        try body.appendSlice(allocator, "\",\"max_tokens\":8192,\"thinking\":{\"type\":\"disabled\"},\"system\":\"");
        try appendJsonEscaped(&body, allocator, system_prompt);
        try body.appendSlice(allocator, "\",\"messages\":[{\"role\":\"user\",\"content\":\"");
    } else {
        try body.appendSlice(allocator, "\",\"reasoning\":{\"effort\":\"medium\"},\"temperature\":0.2,\"messages\":[{\"role\":\"system\",\"content\":\"");
        try appendJsonEscaped(&body, allocator, system_prompt);
        try body.appendSlice(allocator, "\"},{\"role\":\"user\",\"content\":\"");
    }
    try appendJsonEscaped(&body, allocator, transcript);
    try body.appendSlice(allocator, "\"}]}");
    return body.toOwnedSlice(allocator);
}

pub fn formatResponseText(allocator: std.mem.Allocator, anthropic: bool, response: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const root = switch (parsed.value) {
        .object => |value| value,
        else => return error.BadResponse,
    };
    const items = switch (root.get(if (anthropic) "content" else "choices") orelse return error.BadResponse) {
        .array => |value| value,
        else => return error.BadResponse,
    };
    // Anthropic can put thinking blocks before the answer, so take the first text block.
    const first = for (items.items) |item| {
        const object = switch (item) {
            .object => |value| value,
            else => return error.BadResponse,
        };
        if (!anthropic) break object;
        const kind = object.get("type") orelse continue;
        if (kind == .string and std.mem.eql(u8, kind.string, "text")) break object;
    } else return error.BadResponse;
    const holder = if (anthropic) first else switch (first.get("message") orelse return error.BadResponse) {
        .object => |value| value,
        else => return error.BadResponse,
    };
    const content = switch (holder.get(if (anthropic) "text" else "content") orelse return error.BadResponse) {
        .string => |value| value,
        else => return error.BadResponse,
    };
    const trimmed = std.mem.trim(u8, content, " \r\n\t");
    if (trimmed.len == 0) return error.BadResponse;
    return allocator.dupe(u8, trimmed);
}

test "anthropic format request uses a system field and no reasoning" {
    const body = try formatRequestBody(std.testing.allocator, true, "claude-haiku-5-5", "sys \"x\"", "hi\nthere");
    defer std.testing.allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("sys \"x\"", root.get("system").?.string);
    try std.testing.expect(root.get("reasoning") == null);
    try std.testing.expect(root.get("max_tokens") != null);
    // Haiku 5.5 rejects temperature ("deprecated for this model"), which failed every summary.
    try std.testing.expect(root.get("temperature") == null);
    // Haiku 5.5 thinks by default; summaries want speed.
    try std.testing.expectEqualStrings("disabled", root.get("thinking").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("hi\nthere", root.get("messages").?.array.items[0].object.get("content").?.string);
}

test "openrouter format request keeps the system message and reasoning" {
    const body = try formatRequestBody(std.testing.allocator, false, "openai/x", "sys", "hi");
    defer std.testing.allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, body, .{});
    defer parsed.deinit();
    const messages = parsed.value.object.get("messages").?.array.items;
    try std.testing.expectEqualStrings("system", messages[0].object.get("role").?.string);
    try std.testing.expect(parsed.value.object.get("reasoning") != null);
}

test "format response text reads both providers and rejects empty output" {
    const a = try formatResponseText(std.testing.allocator, true, "{\"content\":[{\"type\":\"text\",\"text\":\"  1. gist\\n\"}]}");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("1. gist", a);
    const t = try formatResponseText(std.testing.allocator, true, "{\"content\":[{\"type\":\"thinking\",\"thinking\":\"hm\"},{\"type\":\"text\",\"text\":\"1. after thinking\"}]}");
    defer std.testing.allocator.free(t);
    try std.testing.expectEqualStrings("1. after thinking", t);
    const o = try formatResponseText(std.testing.allocator, false, "{\"choices\":[{\"message\":{\"content\":\"ok\"}}]}");
    defer std.testing.allocator.free(o);
    try std.testing.expectEqualStrings("ok", o);
    try std.testing.expectError(error.BadResponse, formatResponseText(std.testing.allocator, true, "{\"content\":[{\"type\":\"text\",\"text\":\"  \"}]}"));
    try std.testing.expectError(error.BadResponse, formatResponseText(std.testing.allocator, true, "{\"choices\":[]}"));
}
