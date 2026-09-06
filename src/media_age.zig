//! Pure date helpers for the media auto-download cutoff. Lives outside
//! main.zig so its test runs on the non-Windows CI host.
const std = @import("std");

// Howard Hinnant's days-from-civil: days since 1970-01-01 from a calendar date.
fn daysFromCivil(year: i64, month: i64, day: i64) i64 {
    var y = year;
    if (month <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const year_of_era = y - era * 400;
    const month_shift = if (month > 2) month - 3 else month + 9;
    const day_of_year = @divTrunc(153 * month_shift + 2, 5) + day - 1;
    const day_of_era = year_of_era * 365 + @divTrunc(year_of_era, 4) - @divTrunc(year_of_era, 100) + day_of_year;
    return era * 146097 + day_of_era - 719468;
}

// Age of a wacli "YYYY-MM-DD..." timestamp in whole days, or null when the
// timestamp is missing or malformed.
pub fn ageDays(timestamp: []const u8, now_unix: i64) ?i64 {
    if (timestamp.len < 10) return null;
    const year = std.fmt.parseInt(i64, timestamp[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, timestamp[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, timestamp[8..10], 10) catch return null;
    if (timestamp[4] != '-' or timestamp[7] != '-') return null;
    if (month < 1 or month > 12 or year <= 0) return null;
    const day_limit: i64 = switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        else => if (@mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0)) 29 else 28,
    };
    if (day < 1 or day > day_limit) return null;
    return @divTrunc(now_unix, 86400) - daysFromCivil(year, month, day);
}

// Within the cutoff window? An unparseable timestamp stays eligible so a
// format change cannot silently stop auto-downloads.
pub fn withinDays(timestamp: []const u8, now_unix: i64, days: i64) bool {
    const age = ageDays(timestamp, now_unix) orelse return true;
    return age <= days;
}

test "ageDays handles the epoch, leap years, and malformed input" {
    try std.testing.expectEqual(@as(?i64, 0), ageDays("1970-01-01T00:00:00", 0));
    // 1970 is not a leap year, so 1971-01-01 is exactly 365 days in.
    try std.testing.expectEqual(@as(?i64, 0), ageDays("1971-01-01T00:00:00", 365 * 86400));
    // 2000 is a leap year: Feb 29 exists, so 2000-03-01 is day 11017.
    try std.testing.expectEqual(@as(?i64, 0), ageDays("2000-03-01T12:00:00", 11017 * 86400));
    try std.testing.expectEqual(@as(?i64, null), ageDays("", 0));
    try std.testing.expectEqual(@as(?i64, null), ageDays("not-a-date", 0));
    try std.testing.expectEqual(@as(?i64, null), ageDays("2026-13-01T00:00:00", 0));
    try std.testing.expectEqual(@as(?i64, null), ageDays("2026-02-30T00:00:00", 0));
    try std.testing.expectEqual(@as(?i64, null), ageDays("2026/01/01T00:00:00", 0));
    try std.testing.expectEqual(@as(?i64, null), ageDays("2026-02-29T00:00:00", 0)); // 2026 is not a leap year
    try std.testing.expectEqual(@as(?i64, 0), ageDays("2024-02-29T00:00:00", 1709164800));
}

test "withinDays applies the cutoff and keeps unparseable timestamps" {
    const now: i64 = 10957 * 86400; // 2000-01-01
    try std.testing.expect(withinDays("1999-12-26T00:00:00", now, 14));
    try std.testing.expect(!withinDays("1999-12-01T00:00:00", now, 14));
    try std.testing.expect(!withinDays("1999-12-26T00:00:00", now, 0));
    // Slightly in the future (clock skew) is still within any window.
    try std.testing.expect(withinDays("2000-01-30T00:00:00", now, 0));
    try std.testing.expect(withinDays("garbage", now, 0));
}
