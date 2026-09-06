// Self-update logic for WAZI-27: pure, testable parts of the GitHub Releases
// updater. The Win32 transport (WinHTTP, file swap, relaunch) lives in main.zig.
//
// Release contract with the live WAZI-26 release workflow: a release tagged
// "vMAJOR.MINOR.PATCH" (no pre-release suffix) with one asset named
// "Messages-<something>.zip" that contains the zig-out/bin contents.
const std = @import("std");

pub const zip_asset_prefix = "Messages-";

pub fn isZipAssetName(name: []const u8) bool {
    return std.mem.startsWith(u8, name, zip_asset_prefix) and std.mem.endsWith(u8, name, ".zip");
}

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32,
};

pub const Asset = struct {
    tag: []const u8,
    version: Version,
    url: []const u8,
    size: u64,
    digest: []const u8,
};

/// Strict release tag grammar: "v" prefix optional, three numeric components,
/// no build or pre-release suffix. Anything else is rejected so pre-releases
/// and malformed tags never trigger an update.
pub fn parseVersion(tag: []const u8) ?Version {
    var rest = tag;
    if (rest.len > 0 and rest[0] == 'v') rest = rest[1..];
    var parts: [3]u32 = undefined;
    var iter = std.mem.splitScalar(u8, rest, '.');
    for (&parts) |*part| {
        const chunk = iter.next() orelse return null;
        if (chunk.len == 0 or chunk.len > 9) return null;
        for (chunk) |c| if (c < '0' or c > '9') return null;
        part.* = std.fmt.parseInt(u32, chunk, 10) catch return null;
    }
    if (iter.next() != null) return null;
    return .{ .major = parts[0], .minor = parts[1], .patch = parts[2] };
}

pub fn isNewer(latest_tag: []const u8, current: Version) bool {
    const latest = parseVersion(latest_tag) orelse return false;
    if (latest.major != current.major) return latest.major > current.major;
    if (latest.minor != current.minor) return latest.minor > current.minor;
    return latest.patch > current.patch;
}

/// Checks the SHA-256 of `data` against a GitHub asset digest field
/// ("sha256:<64 lowercase hex chars>").
pub fn digestMatches(data: []const u8, digest_field: []const u8) bool {
    const prefix = "sha256:";
    if (digest_field.len != prefix.len + 64) return false;
    if (!std.mem.startsWith(u8, digest_field, prefix)) return false;
    var expected: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&expected, digest_field[prefix.len..]) catch return false;
    var actual: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &actual, .{});
    return std.crypto.timing_safe.eql([32]u8, expected, actual);
}

fn flagTrue(value: ?std.json.Value) bool {
    const v = value orelse return false;
    return v == .bool and v.bool;
}

/// Finds the release asset this updater consumes in a
/// /releases/latest JSON response. Caller owns the returned strings
/// (allocated from `allocator` as part of `parsed`).
pub fn pickAsset(
    allocator: std.mem.Allocator,
    json_text: []const u8,
    parsed: *std.json.Parsed(std.json.Value),
) !?Asset {
    // `parsed` stays valid on both the asset and no-asset paths; the caller
    // deinits it exactly once (nothing to clean up on a parse error).
    parsed.* = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    return findAsset(parsed.value);
}

fn findAsset(root: std.json.Value) ?Asset {
    var matched: ?Asset = null;
    if (root != .object) return null;
    const obj = root.object;
    if (flagTrue(obj.get("draft")) or flagTrue(obj.get("prerelease"))) return null;
    const tag_value = obj.get("tag_name") orelse return null;
    if (tag_value != .string) return null;
    const tag = tag_value.string;
    const version = parseVersion(tag) orelse return null;
    const assets_value = obj.get("assets") orelse return null;
    if (assets_value != .array) return null;
    for (assets_value.array.items) |asset_value| {
        if (asset_value != .object) continue;
        const asset = asset_value.object;
        const name = asset.get("name") orelse continue;
        if (name != .string or !isZipAssetName(name.string)) continue;
        const url = asset.get("browser_download_url") orelse continue;
        if (url != .string) continue;
        // No digest means no verification is possible: refuse the update.
        const digest = asset.get("digest") orelse continue;
        if (digest != .string) continue;
        // Refuse what we cannot cross-check, same as a missing digest.
        const size_value = asset.get("size") orelse continue;
        if (size_value != .integer) continue;
        if (size_value.integer < 0) continue;
        if (matched != null) return null; // ambiguous release: refuse rather than guess
        matched = .{
            // Strings live inside the caller's `parsed`; it stays alive while the asset is used.
            .tag = tag,
            .version = version,
            .url = url.string,
            .size = @intCast(size_value.integer),
            .digest = digest.string,
        };
    }
    return matched;
}

test parseVersion {
    try std.testing.expectEqual(Version{ .major = 1, .minor = 2, .patch = 3 }, parseVersion("v1.2.3").?);
    try std.testing.expectEqual(Version{ .major = 0, .minor = 10, .patch = 0 }, parseVersion("0.10.0").?);
    try std.testing.expect(parseVersion("1.2") == null);
    try std.testing.expect(parseVersion("v1.2.3-rc1") == null);
    try std.testing.expect(parseVersion("v1.2.3+build") == null);
    try std.testing.expect(parseVersion("latest") == null);
    try std.testing.expect(parseVersion("v1.2.x") == null);
    try std.testing.expect(parseVersion("") == null);
    try std.testing.expect(parseVersion("v9999999999.0.0") == null);
}

test isNewer {
    const current: Version = .{ .major = 0, .minor = 1, .patch = 0 };
    try std.testing.expect(isNewer("v0.1.1", current));
    try std.testing.expect(isNewer("v0.2.0", current));
    try std.testing.expect(isNewer("v1.0.0", current));
    try std.testing.expect(!isNewer("v0.1.0", current));
    try std.testing.expect(!isNewer("v0.0.9", current));
    try std.testing.expect(!isNewer("v0.1.0-rc1", current));
    try std.testing.expect(!isNewer("garbage", current));
}

test digestMatches {
    var data: [11]u8 = "hello world".*;
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&data, &hash, .{});
    const hex = std.fmt.bytesToHex(hash, .lower);
    var field: [71]u8 = undefined;
    @memcpy(field[0..7], "sha256:");
    @memcpy(field[7..], &hex);
    try std.testing.expect(digestMatches(&data, &field));
    field[7] ^= 0xff;
    try std.testing.expect(!digestMatches(&data, &field));
    try std.testing.expect(!digestMatches(&data, "sha256:00"));
    try std.testing.expect(!digestMatches(&data, "md5:"));
}

test pickAsset {
    const body =
        \\{
        \\  "tag_name": "v0.2.0",
        \\  "draft": false,
        \\  "prerelease": false,
        \\  "assets": [
        \\    {
        \\      "name": "Messages-windows-x86_64.zip",
        \\      "browser_download_url": "https://github.com/valentinyeo/wazig/releases/download/v0.2.0/Messages-windows-x86_64.zip",
        \\      "size": 12345,
        \\      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\    }
        \\  ]
        \\}
    ;
    var parsed: std.json.Parsed(std.json.Value) = undefined;
    const asset = (try pickAsset(std.testing.allocator, body, &parsed)).?;
    defer parsed.deinit();
    try std.testing.expectEqualStrings("v0.2.0", asset.tag);
    try std.testing.expectEqual(12345, asset.size);
    try std.testing.expect(asset.url.len > 0);

    // Pre-release with the same asset name must be ignored.
    const draft =
        \\{
        \\  "tag_name": "v0.2.0",
        \\  "draft": false,
        \\  "prerelease": true,
        \\  "assets": [
        \\    {
        \\      "name": "Messages-windows-x86_64.zip",
        \\      "browser_download_url": "https://github.com/valentinyeo/wazig/releases/download/v0.2.0/Messages-windows-x86_64.zip",
        \\      "size": 12345,
        \\      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\    }
        \\  ]
        \\}
    ;
    var parsed2: std.json.Parsed(std.json.Value) = undefined;
    try std.testing.expectEqual(@as(?Asset, null), try pickAsset(std.testing.allocator, draft, &parsed2));
    parsed2.deinit();

    // Asset without a digest must be refused, not trusted.
    const no_digest =
        \\{
        \\  "tag_name": "v0.2.0",
        \\  "draft": false,
        \\  "prerelease": false,
        \\  "assets": [
        \\    {
        \\      "name": "Messages-windows-x86_64.zip",
        \\      "browser_download_url": "https://github.com/valentinyeo/wazig/releases/download/v0.2.0/Messages-windows-x86_64.zip",
        \\      "size": 12345
        \\    }
        \\  ]
        \\}
    ;
    var parsed3: std.json.Parsed(std.json.Value) = undefined;
    try std.testing.expectEqual(@as(?Asset, null), try pickAsset(std.testing.allocator, no_digest, &parsed3));
    parsed3.deinit();

    var parsed4: std.json.Parsed(std.json.Value) = undefined;
    try std.testing.expectError(error.SyntaxError, pickAsset(std.testing.allocator, "not json", &parsed4));
    var parsed5: std.json.Parsed(std.json.Value) = undefined;
    try std.testing.expectEqual(@as(?Asset, null), try pickAsset(std.testing.allocator, "{}", &parsed5));
    parsed5.deinit();

    // Asset without a size must be refused: nothing to cross-check.
    const no_size =
        \\{
        \\  "tag_name": "v0.2.0",
        \\  "draft": false,
        \\  "prerelease": false,
        \\  "assets": [
        \\    {
        \\      "name": "Messages-windows-x86_64.zip",
        \\      "browser_download_url": "https://github.com/valentinyeo/wazig/releases/download/v0.2.0/Messages-windows-x86_64.zip",
        \\      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\    }
        \\  ]
        \\}
    ;
    var parsed6: std.json.Parsed(std.json.Value) = undefined;
    try std.testing.expectEqual(@as(?Asset, null), try pickAsset(std.testing.allocator, no_size, &parsed6));
    parsed6.deinit();

    // Two matching assets is an ambiguous release: refuse rather than guess.
    const two_assets =
        \\{
        \\  "tag_name": "v0.2.0",
        \\  "draft": false,
        \\  "prerelease": false,
        \\  "assets": [
        \\    {
        \\      "name": "Messages-windows-x86_64.zip",
        \\      "browser_download_url": "https://github.com/valentinyeo/wazig/releases/download/v0.2.0/Messages-windows-x86_64.zip",
        \\      "size": 12345,
        \\      "digest": "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        \\    },
        \\    {
        \\      "name": "Messages-hotfix.zip",
        \\      "browser_download_url": "https://github.com/valentinyeo/wazig/releases/download/v0.2.0/Messages-hotfix.zip",
        \\      "size": 234,
        \\      "digest": "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
        \\    }
        \\  ]
        \\}
    ;
    var parsed7: std.json.Parsed(std.json.Value) = undefined;
try std.testing.expectEqual(@as(?Asset, null), try pickAsset(std.testing.allocator, two_assets, &parsed7));
    parsed7.deinit();
}

test isZipAssetName {
    try std.testing.expect(isZipAssetName("Messages-v0.0.0.zip"));
    try std.testing.expect(isZipAssetName("Messages-windows-x86_64.zip"));
    try std.testing.expect(!isZipAssetName("Messages-v0.0.0"));
    try std.testing.expect(!isZipAssetName("SHA256SUMS.txt"));
    try std.testing.expect(!isZipAssetName("Other-v1.0.0.zip"));
}
