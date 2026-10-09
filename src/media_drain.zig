//! Pure selection and drain rules for the automatic media backfill
//! (WAZI-103). Lives outside main.zig so its tests run on the non-Windows CI
//! host and can reproduce the endless drain loop without a window server.

const std = @import("std");

/// The auto-download eligibility facts of one message, gathered by the
/// caller from the live message list. Candidates reach selectNext in
/// newest-first order, so the media the user is looking at is offered first.
pub const Candidate = struct {
    index: usize,
    /// image, sticker, video, gif, audio or document: anything the chat's
    /// transport can fetch for an open chat.
    downloadable: bool = false,
    has_id: bool = false,
    has_local_path: bool = false,
    /// A download for this message id is already running.
    in_flight: bool = false,
    within_age: bool = false,
    /// Arrived after live sync started: sync's own --download-media fetches
    /// it, pausing sync again would restart on every incoming photo.
    newer_than_sync_start: bool = false,
    /// Tried once this session (success or failure): never retried.
    attempted: bool = false,
    /// Recorded in the persistent fetched index, including earlier sessions.
    fetched: bool = false,
    /// wacli media download is a WhatsApp-store call: Slack and Telegram
    /// attachments fetch through their own transports and must never queue
    /// one. A candidate without it can never start a download.
    whatsapp_store: bool = false,
};

/// Picks the next auto-download target, newest first, or null when no
/// message is eligible. Every skipped candidate mirrors a gate of the live
/// scan, so a chat full of ineligible messages answers null instead of
/// naming an attempt that cannot start.
pub fn selectNext(candidates: []const Candidate) ?usize {
    for (candidates) |candidate| {
        if (!candidate.downloadable) continue;
        if (!candidate.has_id) continue;
        if (candidate.has_local_path) continue;
        if (candidate.in_flight) continue;
        if (!candidate.within_age) continue;
        if (candidate.newer_than_sync_start) continue;
        if (candidate.attempted) continue;
        if (candidate.fetched) continue;
        if (!candidate.whatsapp_store) continue;
        return candidate.index;
    }
    return null;
}

/// Hard per-tick cap on drain steps. Each productive step fills one media
/// slot (three exist), so the cap only ever bites when the loop would
/// otherwise spin.
pub const max_drain_steps = 8;

/// May the drain loop take another step? A drain begins because an item
/// changed state (a download finished, or a send, mark-read or archive
/// released the store), so the first step always runs; every later step must
/// itself have started a download. WAZI-103: the old loop kept going while
/// an attempt changed nothing and spun the UI thread to a freeze.
pub fn mayDrainStep(steps_done: usize, last_step_started: bool) bool {
    if (steps_done >= max_drain_steps) return false;
    if (steps_done == 0) return true;
    return last_step_started;
}

test "selectNext refuses a candidate that can never start a download" {
    // WAZI-103 endless loop, in pure form: an open Slack chat with a file
    // attachment looked downloadable to the old scan (id set, no local path,
    // within age, not fetched) but downloadMedia returned early at the
    // provider gate without changing any state, so the drain asked again
    // forever and froze the app. The selector must answer null instead.
    const slack_attachment = [_]Candidate{.{
        .index = 0,
        .downloadable = true,
        .has_id = true,
        .within_age = true,
    }};
    try std.testing.expectEqual(@as(?usize, null), selectNext(&slack_attachment));
}

test "a drain that cannot start anything stops after the entry step" {
    // Models the wired loop shape: the drain entered after a finished
    // download, then each turn counts only when the attempt actually started
    // one. With the old behaviour (an attempt always counted) the step count
    // would run to the cap instead of stopping at one.
    const candidates = [_]Candidate{.{
        .index = 0,
        .downloadable = true,
        .has_id = true,
        .within_age = true,
    }};
    var steps: usize = 0;
    var started = true;
    while (mayDrainStep(steps, started)) {
        started = selectNext(&candidates) != null;
        steps += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), steps);
}

test "selectNext walks past ineligible candidates to the newest eligible one" {
    const candidates = [_]Candidate{
        .{ .index = 2, .downloadable = true, .has_id = true, .within_age = true, .whatsapp_store = true, .in_flight = true },
        .{ .index = 1, .downloadable = true, .has_id = true, .within_age = true, .whatsapp_store = true, .has_local_path = true },
        .{ .index = 0, .downloadable = true, .has_id = true, .within_age = true, .whatsapp_store = true },
    };
    try std.testing.expectEqual(@as(?usize, 0), selectNext(&candidates));
}

test "selectNext returns null when nothing is eligible" {
    const all_done = [_]Candidate{
        .{ .index = 1, .downloadable = true, .has_id = true, .within_age = true, .whatsapp_store = true, .fetched = true },
        .{ .index = 0 },
    };
    try std.testing.expectEqual(@as(?usize, null), selectNext(&all_done));
    try std.testing.expectEqual(@as(?usize, null), selectNext(&.{}));
}

test "the drain continues only on started downloads and honours the cap" {
    try std.testing.expect(mayDrainStep(0, false));
    try std.testing.expect(!mayDrainStep(1, false));
    try std.testing.expect(mayDrainStep(1, true));
    try std.testing.expect(mayDrainStep(max_drain_steps - 1, true));
    try std.testing.expect(!mayDrainStep(max_drain_steps, true));
}
