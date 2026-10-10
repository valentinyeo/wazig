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
    // Tagged so the model formats a note that greets "Valentin" instead of answering it.
    try body.appendSlice(allocator, "<transcript>\\n");
    try appendJsonEscaped(&body, allocator, transcript);
    try body.appendSlice(allocator, "\\n</transcript>\"}]}");
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

/// True when the model answered about the task instead of doing it: a refusal,
/// an apology, a question, or any reply that is not the numbered summary the
/// prompt demands. Such an answer must never replace the raw transcript.
pub fn isRefusal(text: []const u8) bool {
    const body = std.mem.trimStart(u8, text, " \r\n\t");
    if (body.len == 0) return true;
    var lower_buffer: [96]u8 = undefined;
    const head = std.ascii.lowerString(&lower_buffer, body[0..@min(body.len, lower_buffer.len)]);
    // Skip a list marker so "1. I cannot ..." is caught too.
    var skip: usize = 0;
    while (skip < head.len and (std.ascii.isDigit(head[skip]) or head[skip] == '.' or head[skip] == ')' or head[skip] == ' ' or head[skip] == '-')) skip += 1;
    const openers = [_][]const u8{
        "i cannot",       "i can't",    "i can not",       "i'm unable",      "i am unable",
        "i'm sorry",      "i am sorry", "sorry",           "i apologize",     "unfortunately",
        "as an ai",       "i won't",    "i will not",      "i'm not able",    "i am not able",
        "entschuldigung", "leider",     "ich kann nicht",  "ich kann dieses", "ich kann diese",
        "there is no",    "there's no", "this transcript", "the transcript",  "it looks like",
        "it seems",       "could you",  "can you",         "please provide",  "please share",
    };
    for (openers) |opener| if (std.mem.startsWith(u8, head[skip..], opener)) return true;
    // The contract: the answer starts with the numbered summary line "1.".
    // Anything else is a meta answer, not a summary.
    return !(head.len >= 2 and head[0] == '1' and (head[1] == '.' or head[1] == ')'));
}

/// True when a transcript already carries the numbered summary this app asks
/// for, so it is not sent for formatting a second time.
pub fn looksFormatted(comptime T: type, text: []const T) bool {
    if (text.len < 2) return false;
    if (text[0] == '1' and (text[1] == '.' or text[1] == ')')) return true;
    if (text.len < 4) return false;
    const gist = "gist";
    for (gist, 0..) |letter, index| {
        const unit: u32 = text[index];
        const lower: u32 = if (unit >= 'A' and unit <= 'Z') unit + 32 else unit;
        if (lower != letter) return false;
    }
    return true;
}

test "refusals and meta answers are detected, real summaries are not" {
    try std.testing.expect(isRefusal("I cannot format this transcript because it is too short."));
    try std.testing.expect(isRefusal("  I'm sorry, but this does not look like speech."));
    try std.testing.expect(isRefusal("Unfortunately the text is empty."));
    try std.testing.expect(isRefusal("1. I cannot format this transcript."));
    try std.testing.expect(isRefusal("This transcript is already formatted."));
    try std.testing.expect(isRefusal("Could you send the full transcript?"));
    try std.testing.expect(isRefusal("Here is the formatted version"));
    try std.testing.expect(isRefusal(""));
    try std.testing.expect(!isRefusal("1. Trigger shot at 2am, next step Monday\n2. Asks about the invoice\n---\n1 Medical"));
    try std.testing.expect(!isRefusal("1) Sie fragt nach dem Termin\n---\n1 Termin"));
    try std.testing.expect(!isRefusal("1. She says sorry for being late and cannot come Friday\n---"));
}

test "formatted transcripts are recognised in utf8 and utf16" {
    try std.testing.expect(looksFormatted(u8, "1. gist line"));
    try std.testing.expect(looksFormatted(u8, "Gist\n1. x"));
    try std.testing.expect(!looksFormatted(u8, "Hallo Valentin, wie geht es"));
    try std.testing.expect(looksFormatted(u16, std.unicode.utf8ToUtf16LeStringLiteral("1. Termin am Montag")));
    try std.testing.expect(!looksFormatted(u16, std.unicode.utf8ToUtf16LeStringLiteral("Hello there")));
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
    try std.testing.expectEqualStrings("<transcript>\nhi\nthere\n</transcript>", root.get("messages").?.array.items[0].object.get("content").?.string);
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
