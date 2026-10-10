//! Argument lists for the wacli send commands (text, file, voice note,
//! reaction). Pure, so the tests can pin the lock wait: since wacli 0.19 a
//! send that finds the store locked hands itself to the running sync, but
//! only after its --lock-wait runs out, so any wait above 0s delays every
//! send by its full length. Sends always pass 0s; the forwarder and
//! sendRetryDelayMs cover the rare moment no sync is there to take the job.

const std = @import("std");

pub const lock_wait = "0s";
pub const max_args = 18;

pub const SendSpec = struct {
    wacli: []const u8,
    jid: []const u8,
    text: []const u8 = "",
    file: []const u8 = "",
    ptt: bool = false,
    reply_to: []const u8 = "",
    reply_sender: []const u8 = "",
};

/// Fills `out` with the argv of `wacli send text|file` and returns its length.
pub fn buildSend(out: *[max_args][]const u8, spec: SendSpec) usize {
    var n: usize = 0;
    const is_file = spec.file.len > 0;
    for ([_][]const u8{ spec.wacli, "--json", "--lock-wait", lock_wait, "send", if (is_file) "file" else "text", "--to", spec.jid }) |arg| {
        out[n] = arg;
        n += 1;
    }
    if (is_file) {
        out[n] = "--file";
        out[n + 1] = spec.file;
        n += 2;
        if (spec.ptt) {
            out[n] = "--ptt";
            n += 1;
        }
        if (spec.text.len > 0) {
            out[n] = "--caption";
            out[n + 1] = spec.text;
            n += 2;
        }
    } else {
        out[n] = "--message";
        out[n + 1] = spec.text;
        n += 2;
    }
    if (spec.reply_to.len > 0) {
        out[n] = "--reply-to";
        out[n + 1] = spec.reply_to;
        n += 2;
        if (spec.reply_sender.len > 0) {
            out[n] = "--reply-to-sender";
            out[n + 1] = spec.reply_sender;
            n += 2;
        }
    }
    return n;
}

/// Fills `out` with the argv of `wacli send react` and returns its length.
pub fn buildReact(out: *[max_args][]const u8, wacli: []const u8, jid: []const u8, msg_id: []const u8, emoji: []const u8, sender: []const u8) usize {
    var n: usize = 0;
    for ([_][]const u8{ wacli, "--json", "--lock-wait", lock_wait, "send", "react", "--to", jid, "--id", msg_id, "--reaction", emoji }) |arg| {
        out[n] = arg;
        n += 1;
    }
    if (sender.len > 0) {
        out[n] = "--sender";
        out[n + 1] = sender;
        n += 2;
    }
    return n;
}

fn lockWaitOf(args: []const []const u8) ?[]const u8 {
    for (args, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--lock-wait") and i + 1 < args.len) return args[i + 1];
    }
    return null;
}

test "every send kind waits 0s for the store lock" {
    var out: [max_args][]const u8 = undefined;
    const text = buildSend(&out, .{ .wacli = "wacli", .jid = "1@s.whatsapp.net", .text = "hi" });
    try std.testing.expectEqualStrings("0s", lockWaitOf(out[0..text]).?);
    try std.testing.expectEqualStrings("text", out[5]);
    const image = buildSend(&out, .{ .wacli = "wacli", .jid = "1@s.whatsapp.net", .file = "a.png", .text = "cap" });
    try std.testing.expectEqualStrings("0s", lockWaitOf(out[0..image]).?);
    try std.testing.expectEqualStrings("file", out[5]);
    const voice = buildSend(&out, .{ .wacli = "wacli", .jid = "1@s.whatsapp.net", .file = "a.ogg", .ptt = true, .reply_to = "X", .reply_sender = "2@s.whatsapp.net" });
    try std.testing.expectEqualStrings("0s", lockWaitOf(out[0..voice]).?);
    try std.testing.expectEqualStrings("--ptt", out[10]);
    try std.testing.expectEqualStrings("2@s.whatsapp.net", out[voice - 1]);
    const react = buildReact(&out, "wacli", "1@s.whatsapp.net", "ID", "x", "2@s.whatsapp.net");
    try std.testing.expectEqualStrings("0s", lockWaitOf(out[0..react]).?);
    try std.testing.expectEqualStrings("react", out[5]);
}

test "text send carries the message and no file flags" {
    var out: [max_args][]const u8 = undefined;
    const n = buildSend(&out, .{ .wacli = "wacli", .jid = "j", .text = "hello" });
    try std.testing.expectEqual(@as(usize, 10), n);
    try std.testing.expectEqualStrings("--message", out[8]);
    try std.testing.expectEqualStrings("hello", out[9]);
}
