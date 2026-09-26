// Scheduling rules for pausing WhatsApp live sync. Every pause kills the
// `wacli sync --follow` child and every restart reconnects to WhatsApp, so
// background work that needs the store lock (profile pictures, automatic
// media) must pause sync rarely and in batches. Pure logic, no Win32, so the
// rules are unit-tested on any host.
const std = @import("std");

/// Background work (avatar batches) waits this long after any sync pause.
pub const background_stop_gap_ms: u64 = 60_000;
/// Automatic media downloads for the open chat wait only this long, so
/// images still show up within seconds of opening a chat.
pub const media_stop_gap_ms: u64 = 15_000;
/// Minimum gap between the end of one avatar batch and the start of the next.
pub const avatar_batch_gap_ms: u64 = 180_000;
/// After a failed picture fetch (often WhatsApp's 429 rate limit) no new
/// batch starts for this long.
pub const avatar_failure_backoff_ms: u64 = 30 * 60 * 1000;
/// An avatar batch fetches at most this many pictures per sync pause...
pub const avatar_batch_max: u32 = 10;
/// ...and starts no new fetch once this much time has passed.
pub const avatar_batch_budget_ms: u64 = 20_000;
/// A cached picture, or a cached "this chat has no picture" answer, is
/// trusted for a week before it is checked again.
pub const avatar_cache_ttl_secs: i64 = 7 * 24 * 60 * 60;
/// A failed fetch (rate limit, network) is not retried for a day.
pub const avatar_failure_ttl_secs: i64 = 24 * 60 * 60;
/// Delegated writes (mark-read) go through the sync child's socket, which
/// only opens after it connects: give a fresh child this long first.
pub const delegate_warmup_secs: i64 = 20;
/// `--refresh-groups`/`--refresh-contacts` on a sync start at most this
/// often; WhatsApp answers 429 rate-overlimit when group refreshes repeat.
pub const sync_refresh_gap_ms: u64 = 6 * 60 * 60 * 1000;

/// True when enough time passed since the last sync pause. `last_stop_ms`
/// null means sync was never paused this session.
pub fn gapElapsed(last_stop_ms: ?u64, now_ms: u64, gap_ms: u64) bool {
    const last = last_stop_ms orelse return true;
    return now_ms -| last >= gap_ms;
}

/// A new avatar batch may pause sync only when both the global pause gap and
/// the gap since the previous batch ended have passed, and no failure
/// backoff (`retry_after_ms`, 0 for none) is running.
pub fn avatarBatchMayStart(last_stop_ms: ?u64, last_batch_end_ms: ?u64, retry_after_ms: u64, now_ms: u64) bool {
    return now_ms >= retry_after_ms and
        gapElapsed(last_stop_ms, now_ms, background_stop_gap_ms) and
        gapElapsed(last_batch_end_ms, now_ms, avatar_batch_gap_ms);
}

/// Whether a running batch starts one more fetch before sync resumes. A
/// failed fetch (often a rate limit) ends the batch at once.
pub fn avatarBatchContinues(fetched: u32, started_ms: u64, now_ms: u64, last_failed: bool) bool {
    return !last_failed and fetched < avatar_batch_max and now_ms -| started_ms < avatar_batch_budget_ms;
}

/// Whether a cache stamp (file modification time) is still within its TTL.
/// A stamp from the future (clock change) counts as fresh.
pub fn fresh(stamp_secs: ?i64, now_secs: i64, ttl_secs: i64) bool {
    const stamp = stamp_secs orelse return false;
    return now_secs - stamp < ttl_secs;
}

/// wacli exits non-zero when a chat has no picture or hides it from us
/// (whatsmeow's ErrProfilePictureNotSet / ErrProfilePictureUnauthorized).
/// Those are answers, not failures: cache them as "no picture" for a week
/// instead of treating them like a rate limit.
pub fn pictureAbsent(output: []const u8) bool {
    return std.mem.indexOf(u8, output, "does not have a profile picture") != null or
        std.mem.indexOf(u8, output, "hidden their profile picture") != null;
}

pub const AvatarCache = struct {
    /// A decodable picture is on disk: show it right away.
    has_image: bool,
    /// The picture (or its absence) must be asked of WhatsApp again.
    needs_fetch: bool,
};

/// Decide from the on-disk stamps what a chat's avatar starts as. Stamps are
/// modification times in unix seconds, null when that file is missing.
pub fn classifyAvatar(image_secs: ?i64, image_decodes: bool, none_secs: ?i64, failed_secs: ?i64, now_secs: i64) AvatarCache {
    if (fresh(failed_secs, now_secs, avatar_failure_ttl_secs)) {
        return .{ .has_image = image_secs != null and image_decodes, .needs_fetch = false };
    }
    if (image_secs != null and image_decodes) {
        return .{ .has_image = true, .needs_fetch = !fresh(image_secs, now_secs, avatar_cache_ttl_secs) };
    }
    return .{ .has_image = false, .needs_fetch = !fresh(none_secs, now_secs, avatar_cache_ttl_secs) };
}

test "background pauses are spaced a minute apart" {
    try std.testing.expect(gapElapsed(null, 5, background_stop_gap_ms));
    try std.testing.expect(!gapElapsed(100_000, 159_999, background_stop_gap_ms));
    try std.testing.expect(gapElapsed(100_000, 160_000, background_stop_gap_ms));
    // Media for the open chat uses a shorter gap so images still arrive fast.
    try std.testing.expect(gapElapsed(100_000, 115_000, media_stop_gap_ms));
}

test "an avatar batch needs both the global gap and the batch gap" {
    // Never paused and never batched: go.
    try std.testing.expect(avatarBatchMayStart(null, null, 0, 1_000));
    // A media pause 30 s ago blocks the batch even with no earlier batch.
    try std.testing.expect(!avatarBatchMayStart(970_000, null, 0, 1_000_000));
    // The last batch ended 2 minutes ago: wait for the 3-minute gap.
    try std.testing.expect(!avatarBatchMayStart(880_000, 880_000, 0, 1_000_000));
    try std.testing.expect(avatarBatchMayStart(820_000, 820_000, 0, 1_000_000));
    // A rate-limited fetch holds every batch off until the backoff ends.
    try std.testing.expect(!avatarBatchMayStart(null, null, 1_000_001, 1_000_000));
    try std.testing.expect(avatarBatchMayStart(null, null, 1_000_000, 1_000_000));
}

test "an avatar batch stops at its cap, its time budget, or a failure" {
    try std.testing.expect(avatarBatchContinues(1, 0, 5_000, false));
    try std.testing.expect(!avatarBatchContinues(avatar_batch_max, 0, 5_000, false));
    try std.testing.expect(!avatarBatchContinues(3, 0, avatar_batch_budget_ms, false));
    try std.testing.expect(!avatarBatchContinues(1, 0, 5_000, true));
}

test "cached avatars are trusted for a week, failures for a day" {
    const day: i64 = 24 * 60 * 60;
    const now: i64 = 100 * day;
    // Fresh picture: shown, no fetch.
    try std.testing.expectEqual(AvatarCache{ .has_image = true, .needs_fetch = false }, classifyAvatar(now - day, true, null, null, now));
    // Week-old picture: still shown, refreshed in a later batch.
    try std.testing.expectEqual(AvatarCache{ .has_image = true, .needs_fetch = true }, classifyAvatar(now - 8 * day, true, null, null, now));
    // Undecodable picture file counts as missing.
    try std.testing.expectEqual(AvatarCache{ .has_image = false, .needs_fetch = true }, classifyAvatar(now - day, false, null, null, now));
    // "No picture" answer from 3 days ago: no fetch. This is what stops a
    // fresh install from re-asking WhatsApp about every picture-less chat.
    try std.testing.expectEqual(AvatarCache{ .has_image = false, .needs_fetch = false }, classifyAvatar(null, false, now - 3 * day, null, now));
    try std.testing.expectEqual(AvatarCache{ .has_image = false, .needs_fetch = true }, classifyAvatar(null, false, now - 8 * day, null, now));
    // A failure (e.g. 429) an hour ago holds off even a stale picture.
    try std.testing.expectEqual(AvatarCache{ .has_image = true, .needs_fetch = false }, classifyAvatar(now - 8 * day, true, null, now - 3600, now));
    try std.testing.expectEqual(AvatarCache{ .has_image = false, .needs_fetch = true }, classifyAvatar(null, false, null, now - 2 * day, now));
}

test "no picture and hidden picture are answers, a rate limit is a failure" {
    try std.testing.expect(pictureAbsent("{\"error\":\"get profile picture info: that user or group does not have a profile picture\"}"));
    try std.testing.expect(pictureAbsent("get profile picture info: the user has hidden their profile picture from you"));
    try std.testing.expect(!pictureAbsent("info query returned status 429: rate-overlimit"));
    try std.testing.expect(!pictureAbsent("store is locked (another wacli is running?)"));
}
