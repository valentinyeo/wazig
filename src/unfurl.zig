//! WAZI-68: classify YouTube, Instagram and Facebook video links so the chat
//! can unfurl them into inline cards. Pure functions only: no Win32, no
//! allocation, so the classifier and the page scrapers are unit-testable.
//! Security posture: an exact host allowlist (no suffix matches for pages),
//! userinfo rejection, and https-only canonical URLs. Stream and CDN URLs use
//! a separate suffix allowlist because provider CDNs rotate hostnames.

const std = @import("std");

pub const Provider = enum { none, youtube, instagram, facebook };

/// What kind of remote fetch is about to run; picks the allowlist.
pub const FetchKind = enum { page, image };

pub const max_id_len = 40;
pub const max_canonical_len = 384;

pub const Info = struct {
    provider: Provider = .none,
    id: [max_id_len]u8 = undefined,
    id_len: usize = 0,
    canonical: [max_canonical_len]u8 = undefined,
    canonical_len: usize = 0,

    pub fn idSlice(self: *const Info) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn canonicalSlice(self: *const Info) []const u8 {
        return self.canonical[0..self.canonical_len];
    }
};

// Exact page hosts only; "youtube.com.evil.com" must never match.
const youtube_hosts = [_][]const u8{
    "youtube.com", "www.youtube.com",      "m.youtube.com", "music.youtube.com",
    "youtu.be",    "youtube-nocookie.com",
};
const instagram_hosts = [_][]const u8{
    "instagram.com", "www.instagram.com", "m.instagram.com", "instagr.am", "www.instagr.am",
};
const facebook_hosts = [_][]const u8{
    "facebook.com", "www.facebook.com", "m.facebook.com", "web.facebook.com", "fb.watch",
};

fn hostIs(host: []const u8, list: []const []const u8) bool {
    for (list) |allowed| if (std.ascii.eqlIgnoreCase(host, allowed)) return true;
    return false;
}

fn providerForHost(host: []const u8) Provider {
    if (hostIs(host, &youtube_hosts)) return .youtube;
    if (hostIs(host, &instagram_hosts)) return .instagram;
    if (hostIs(host, &facebook_hosts)) return .facebook;
    return .none;
}

fn isLinkId(unit: u8, provider: Provider) bool {
    return switch (provider) {
        .youtube => std.ascii.isAlphanumeric(unit) or unit == '_' or unit == '-',
        else => std.ascii.isAlphanumeric(unit) or unit == '_' or unit == '-',
    };
}

fn store(info: *Info, provider: Provider, id: []const u8, canonical: []const u8) bool {
    if (id.len == 0 or id.len > max_id_len) return false;
    if (canonical.len == 0 or canonical.len > max_canonical_len) return false;
    info.provider = provider;
    @memcpy(info.id[0..id.len], id);
    info.id_len = id.len;
    @memcpy(info.canonical[0..canonical.len], canonical);
    info.canonical_len = canonical.len;
    return true;
}

/// Trim punctuation that linkification routinely glues onto URLs.
fn trimTrailingPunctuation(url: []const u8) []const u8 {
    return std.mem.trimEnd(u8, url, ".,;:!?)]}>\"'");
}

fn splitHostPath(rest: []const u8) ?struct { host: []const u8, path: []const u8 } {
    // Reject userinfo ("user:pass@host") outright.
    if (std.mem.indexOfScalar(u8, rest, '@') != null) return null;
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var host = rest[0..host_end];
    const path_and_more = if (host_end < rest.len) rest[host_end..] else "";
    // Drop a port if present; nothing on the allowlist needs one.
    if (std.mem.indexOfScalar(u8, host, ':')) |at| host = host[0..at];
    host = std.mem.trimEnd(u8, host, ".");
    if (host.len == 0) return null;
    for (host) |unit| {
        if (!std.ascii.isAlphanumeric(unit) and unit != '.' and unit != '-') return null;
    }
    return .{ .host = host, .path = path_and_more };
}

fn pathOf(path_and_more: []const u8) []const u8 {
    var path = path_and_more;
    if (path.len > 0 and path[0] == '/') {} else if (path.len > 0 and path[0] == '?') {
        return "/";
    } else if (path.len > 0 and path[0] == '#') {
        return "/";
    }
    const cut = std.mem.indexOfAny(u8, path, "?#") orelse path.len;
    return path[0..cut];
}

fn queryOf(path_and_more: []const u8) []const u8 {
    const question = std.mem.indexOfScalar(u8, path_and_more, '?') orelse return "";
    const cut = std.mem.indexOfScalar(u8, path_and_more[question..], '#') orelse path_and_more.len - question;
    return path_and_more[question + 1 ..][0 .. cut - 1];
}

fn queryValue(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const equals = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..equals], key)) return pair[equals + 1 ..];
    }
    return null;
}

fn idUntilStop(segment: []const u8, provider: Provider) []const u8 {
    var len: usize = 0;
    while (len < segment.len and segment[len] != '/' and segment[len] != '?' and segment[len] != '#') : (len += 1) {
        if (!isLinkId(segment[len], provider)) break;
    }
    return segment[0..len];
}

fn classifyYoutube(host: []const u8, path_and_more: []const u8, info: *Info) bool {
    const path = pathOf(path_and_more);
    const query = queryOf(path_and_more);
    var id: []const u8 = "";
    if (std.ascii.eqlIgnoreCase(host, "youtu.be")) {
        id = idUntilStop(path[1..], .youtube);
    } else if (std.ascii.startsWithIgnoreCase(path, "/shorts/")) {
        id = idUntilStop(path["/shorts/".len..], .youtube);
    } else if (std.ascii.startsWithIgnoreCase(path, "/embed/")) {
        id = idUntilStop(path["/embed/".len..], .youtube);
    } else if (std.ascii.startsWithIgnoreCase(path, "/live/")) {
        id = idUntilStop(path["/live/".len..], .youtube);
    } else if (std.ascii.startsWithIgnoreCase(path, "/v/")) {
        id = idUntilStop(path["/v/".len..], .youtube);
    } else if (std.ascii.startsWithIgnoreCase(path, "/watch")) {
        id = queryValue(query, "v") orelse "";
        if (id.len > max_id_len) id = "";
        for (id) |unit| {
            if (!isLinkId(unit, .youtube)) {
                id = "";
                break;
            }
        }
    }
    if (id.len < 5) return false;
    var canonical_buffer: [max_canonical_len]u8 = undefined;
    const canonical = std.fmt.bufPrint(&canonical_buffer, "https://www.youtube.com/watch?v={s}", .{id}) catch return false;
    return store(info, .youtube, id, canonical);
}

fn classifyInstagram(path: []const u8, info: *Info) bool {
    const prefixes = [_][]const u8{ "/reel/", "/reels/", "/p/", "/tv/" };
    for (prefixes) |prefix| {
        if (!std.ascii.startsWithIgnoreCase(path, prefix)) continue;
        const id = idUntilStop(path[prefix.len..], .instagram);
        if (id.len < 5) return false;
        var canonical_buffer: [max_canonical_len]u8 = undefined;
        // /reels/ normalizes to /reel/ so thumbnails and scrapes have one URL.
        const used_prefix: []const u8 = if (std.ascii.eqlIgnoreCase(prefix, "/reels/")) "/reel/" else prefix;
        const canonical = std.fmt.bufPrint(&canonical_buffer, "https://www.instagram.com{s}{s}/", .{ used_prefix, id }) catch return false;
        return store(info, .instagram, id, canonical);
    }
    return false;
}

fn classifyFacebook(host: []const u8, path_and_more: []const u8, info: *Info) bool {
    const path = pathOf(path_and_more);
    const query = queryOf(path_and_more);
    var canonical_buffer: [max_canonical_len]u8 = undefined;
    var id: []const u8 = "";
    if (std.ascii.eqlIgnoreCase(host, "fb.watch")) {
        id = idUntilStop(path[1..], .facebook);
        if (id.len == 0) return false;
        const canonical = std.fmt.bufPrint(&canonical_buffer, "https://fb.watch/{s}/", .{id}) catch return false;
        return store(info, .facebook, id, canonical);
    }
    if (std.ascii.startsWithIgnoreCase(path, "/watch")) {
        const value = queryValue(query, "v") orelse return false;
        if (value.len == 0 or value.len > max_id_len) return false;
        for (value) |unit| {
            if (!isLinkId(unit, .facebook)) return false;
        }
        const canonical = std.fmt.bufPrint(&canonical_buffer, "https://www.facebook.com/watch?v={s}", .{value}) catch return false;
        return store(info, .facebook, value, canonical);
    }
    if (std.ascii.startsWithIgnoreCase(path, "/share/v/")) {
        id = idUntilStop(path["/share/v/".len..], .facebook);
        if (id.len == 0) return false;
        const canonical = std.fmt.bufPrint(&canonical_buffer, "https://www.facebook.com/share/v/{s}/", .{id}) catch return false;
        return store(info, .facebook, id, canonical);
    }
    // /videos/<id> or /videos/<who>/<id>: the id is the final numeric segment.
    if (std.mem.indexOf(u8, path, "/videos/") != null) {
        var last: []const u8 = "";
        var it = std.mem.splitScalar(u8, path, '/');
        while (it.next()) |segment| {
            if (segment.len == 0) continue;
            last = segment;
        }
        if (last.len == 0 or last.len > max_id_len) return false;
        var numeric = true;
        for (last) |unit| {
            if (!std.ascii.isDigit(unit)) numeric = false;
        }
        if (!numeric) return false;
        const canonical = std.fmt.bufPrint(&canonical_buffer, "https://www.facebook.com/videos/{s}/", .{last}) catch return false;
        return store(info, .facebook, last, canonical);
    }
    return false;
}

/// Classify a pasted link. Anything that is not a video link from the three
/// providers yields provider == .none and the message keeps rendering as text.
pub fn classify(url: []const u8) Info {
    var info = Info{};
    var cleaned = std.mem.trim(u8, url, " \t\r\n");
    cleaned = trimTrailingPunctuation(cleaned);
    // Case-insensitive scheme strip; both schemes map onto https canonicals.
    if (std.ascii.startsWithIgnoreCase(cleaned, "https://")) {
        cleaned = cleaned[8..];
    } else if (std.ascii.startsWithIgnoreCase(cleaned, "http://")) {
        cleaned = cleaned[7..];
    } else {
        return info;
    }
    if (cleaned.len == 0) return info;
    const parts = splitHostPath(cleaned) orelse return info;
    const provider = providerForHost(parts.host);
    switch (provider) {
        .youtube => _ = classifyYoutube(parts.host, parts.path, &info),
        .instagram => _ = classifyInstagram(pathOf(parts.path), &info),
        .facebook => _ = classifyFacebook(parts.host, parts.path, &info),
        .none => {},
    }
    return info;
}

/// YouTube thumbnails are anonymous; Instagram and Facebook gate theirs.
pub fn thumbnailUrl(info: *const Info, buffer: []u8) ?[]const u8 {
    if (info.provider != .youtube) return null;
    return std.fmt.bufPrint(buffer, "https://img.youtube.com/vi/{s}/hqdefault.jpg", .{info.idSlice()}) catch null;
}

fn percentEncode(out: []u8, text: []const u8) ?[]const u8 {
    var length: usize = 0;
    for (text) |unit| {
        const safe = std.ascii.isAlphanumeric(unit) or unit == '-' or unit == '.' or unit == '_' or unit == '~';
        if (safe) {
            if (length + 1 > out.len) return null;
            out[length] = unit;
            length += 1;
        } else {
            if (length + 3 > out.len) return null;
            _ = std.fmt.bufPrint(out[length..][0..3], "%{X:0>2}", .{unit}) catch return null;
            length += 3;
        }
    }
    return out[0..length];
}

/// Percent-encoded oEmbed endpoint: https://www.youtube.com/oembed?url=<enc>&format=json
pub fn oembedEndpoint(info: *const Info, buffer: []u8) ?[]const u8 {
    if (info.provider != .youtube) return null;
    const head = "https://www.youtube.com/oembed?url=";
    const tail = "&format=json";
    const encoded = percentEncode(buffer[head.len .. buffer.len - tail.len], info.canonicalSlice()) orelse return null;
    @memcpy(buffer[0..head.len], head);
    const tail_start = head.len + encoded.len;
    @memcpy(buffer[tail_start..][0..tail.len], tail);
    return buffer[0 .. tail_start + tail.len];
}

fn suffixMatches(host: []const u8, suffix: []const u8) bool {
    return host.len > suffix.len and std.ascii.endsWithIgnoreCase(host, suffix);
}

/// Pages are fetched only from the exact provider hosts.
pub fn isPageFetchAllowed(url: []const u8) bool {
    const cleaned = trimTrailingPunctuation(url);
    if (!std.ascii.startsWithIgnoreCase(cleaned, "https://")) return false;
    const rest = cleaned[8..];
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const host = rest[0..host_end];
    return providerForHost(host) != .none;
}

/// Thumbnails come from YouTube's image hosts or the provider CDNs that
/// og:image tags point at (rotating scontent-*.cdninstagram.com / fbcdn.net).
pub fn isImageFetchAllowed(url: []const u8) bool {
    const cleaned = trimTrailingPunctuation(url);
    if (!std.ascii.startsWithIgnoreCase(cleaned, "https://")) return false;
    const rest = cleaned[8..];
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const host = rest[0..host_end];
    const exact = [_][]const u8{ "img.youtube.com", "i.ytimg.com" };
    for (exact) |allowed| if (std.ascii.eqlIgnoreCase(host, allowed)) return true;
    return suffixMatches(host, ".cdninstagram.com") or suffixMatches(host, ".fbcdn.net");
}

/// Playable streams: YouTube's googlevideo CDN and the provider CDNs.
pub fn isStreamUrlAllowed(url: []const u8) bool {
    const cleaned = trimTrailingPunctuation(url);
    if (!std.ascii.startsWithIgnoreCase(cleaned, "https://")) return false;
    const rest = cleaned[8..];
    const host_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    const host = rest[0..host_end];
    return suffixMatches(host, ".googlevideo.com") or
        suffixMatches(host, ".cdninstagram.com") or
        suffixMatches(host, ".fbcdn.net");
}

/// Pull `content` out of an og: meta tag regardless of attribute order.
/// `key` is the full property, e.g. "og:video" or "og:image". Each <meta>
/// tag is parsed as a unit so a content= from a neighbouring tag is never
/// attributed to the wrong key.
pub fn scrapeOgMeta(page: []const u8, key: []const u8) ?[]const u8 {
    var search_from: usize = 0;
    while (std.mem.indexOfPos(u8, page, search_from, "<meta")) |tag_start| {
        const tag_end = (std.mem.indexOfPos(u8, page, tag_start, ">") orelse page.len) + 1;
        search_from = tag_start + 5;
        const tag = page[tag_start..tag_end];
        const has_key = std.mem.indexOf(u8, tag, key) orelse continue;
        // The key must appear as a property/name value, not inside a URL.
        const before_ok = has_key == 0 or tag[has_key - 1] == '"' or tag[has_key - 1] == '\'';
        const after = has_key + key.len;
        const after_ok = after >= tag.len or tag[after] == '"' or tag[after] == '\'';
        if (!before_ok or !after_ok) continue;
        const content_at = std.mem.indexOf(u8, tag, "content=\"") orelse continue;
        const rest = tag[content_at + "content=\"".len ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
        if (end == 0) continue;
        return rest[0..end];
    }
    return null;
}

/// Extract a direct progressive stream URL from a YouTube watch page. Best
/// effort by design: when YouTube refuses, the card falls back to opening
/// the video externally.
pub fn extractYoutubeStream(page: []const u8, buffer: []u8) ?[]const u8 {
    const marker = "\"https://www.googlevideo.com/videoplayback";
    const at = std.mem.indexOf(u8, page, marker) orelse return null;
    const start = at + 1; // skip the leading quote
    var length: usize = 0;
    var index = start;
    while (index < page.len and page[index] != '"' and length < buffer.len) {
        if (page[index] == '\\' and index + 6 <= page.len and
            page[index + 1] == 'u' and page[index + 2] == '0' and
            page[index + 3] == '0' and page[index + 4] == '2' and page[index + 5] == '6')
        {
            buffer[length] = '&';
            length += 1;
            index += 6;
        } else if (page[index] == '\\' and index + 1 < page.len) {
            buffer[length] = page[index + 1];
            length += 1;
            index += 2;
        } else {
            buffer[length] = page[index];
            length += 1;
            index += 1;
        }
    }
    if (length == 0 or length >= buffer.len) return null;
    if (!isStreamUrlAllowed(buffer[0..length])) return null;
    return buffer[0..length];
}

test "classify youtube watch, share and shorts" {
    const watch = classify("https://www.youtube.com/watch?v=dQw4w9WgXcQ");
    try std.testing.expectEqual(Provider.youtube, watch.provider);
    try std.testing.expectEqualStrings("dQw4w9WgXcQ", watch.idSlice());
    try std.testing.expectEqualStrings("https://www.youtube.com/watch?v=dQw4w9WgXcQ", watch.canonicalSlice());

    const share = classify("youtu.be/dQw4w9WgXcQ?t=42"); // no scheme: rejected
    try std.testing.expectEqual(Provider.none, share.provider);

    const short = classify("https://youtu.be/dQw4w9WgXcQ?t=42");
    try std.testing.expectEqual(Provider.youtube, short.provider);
    try std.testing.expectEqualStrings("dQw4w9WgXcQ", short.idSlice());

    const shorts = classify("https://youtube.com/shorts/dQw4w9WgXcQ?feature=share");
    try std.testing.expectEqual(Provider.youtube, shorts.provider);

    const mobile = classify("http://m.youtube.com/watch?v=dQw4w9WgXcQ");
    try std.testing.expectEqual(Provider.youtube, mobile.provider);
    try std.testing.expectEqualStrings("https://www.youtube.com/watch?v=dQw4w9WgXcQ", mobile.canonicalSlice());
}

test "classify instagram and facebook" {
    const reel = classify("https://www.instagram.com/reel/Cabcdefghij/");
    try std.testing.expectEqual(Provider.instagram, reel.provider);
    try std.testing.expectEqualStrings("Cabcdefghij", reel.idSlice());
    try std.testing.expectEqualStrings("https://www.instagram.com/reel/Cabcdefghij/", reel.canonicalSlice());

    const reels = classify("https://instagram.com/reels/Cabcdefghij/");
    try std.testing.expectEqual(Provider.instagram, reels.provider);
    try std.testing.expectEqualStrings("https://www.instagram.com/reel/Cabcdefghij/", reels.canonicalSlice());

    const post = classify("https://www.instagram.com/p/Cabcdefghij/?img_index=1");
    try std.testing.expectEqual(Provider.instagram, post.provider);

    const watch = classify("https://www.facebook.com/watch?v=1234567890");
    try std.testing.expectEqual(Provider.facebook, watch.provider);
    try std.testing.expectEqualStrings("1234567890", watch.idSlice());

    const videos = classify("https://www.facebook.com/nike/videos/9876543210/");
    try std.testing.expectEqual(Provider.facebook, videos.provider);
    try std.testing.expectEqualStrings("9876543210", videos.idSlice());

    const share = classify("https://www.facebook.com/share/v/AbCdEf12345/");
    try std.testing.expectEqual(Provider.facebook, share.provider);

    const fbwatch = classify("https://fb.watch/AbCdEf123/");
    try std.testing.expectEqual(Provider.facebook, fbwatch.provider);
}

test "classify rejects non-video pages and hostile hosts" {
    try std.testing.expectEqual(Provider.none, classify("https://www.instagram.com/").provider);
    try std.testing.expectEqual(Provider.none, classify("https://www.facebook.com/photo/?fbid=123").provider);
    // Suffix-lookalike host must never match the allowlist.
    try std.testing.expectEqual(Provider.none, classify("https://youtube.com.evil.com/watch?v=dQw4w9WgXcQ").provider);
    try std.testing.expectEqual(Provider.none, classify("https://notyoutube.com/watch?v=dQw4w9WgXcQ").provider);
    // Userinfo is rejected outright.
    try std.testing.expectEqual(Provider.none, classify("https://user:pass@youtube.com/watch?v=dQw4w9WgXcQ").provider);
    // Non-video YouTube paths.
    try std.testing.expectEqual(Provider.none, classify("https://www.youtube.com/channel/UC1234567890").provider);
    // Too-short id.
    try std.testing.expectEqual(Provider.none, classify("https://youtu.be/ab").provider);
    // Id with illegal characters (query overflow).
    try std.testing.expectEqual(Provider.none, classify("https://www.youtube.com/watch?v=../../etc").provider);
    // Plain links stay plain.
    try std.testing.expectEqual(Provider.none, classify("https://example.com/watch?v=dQw4w9WgXcQ").provider);
    try std.testing.expectEqual(Provider.none, classify("").provider);
}

test "classify tolerates pasted punctuation" {
    const pasted = classify("https://youtu.be/dQw4w9WgXcQ.");
    try std.testing.expectEqual(Provider.youtube, pasted.provider);
    const wrapped = classify("https://youtu.be/dQw4w9WgXcQ)");
    try std.testing.expectEqual(Provider.youtube, wrapped.provider);
}

test "endpoints and fetch allowlists" {
    const watch = classify("https://youtu.be/dQw4w9WgXcQ");
    var buffer: [max_canonical_len]u8 = undefined;
    const endpoint = oembedEndpoint(&watch, &buffer).?;
    try std.testing.expectEqualStrings(
        "https://www.youtube.com/oembed?url=https%3A%2F%2Fwww.youtube.com%2Fwatch%3Fv%3DdQw4w9WgXcQ&format=json",
        endpoint,
    );
    var thumb_buffer: [max_canonical_len]u8 = undefined;
    try std.testing.expectEqualStrings(
        "https://img.youtube.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        thumbnailUrl(&watch, &thumb_buffer).?,
    );

    const reel = classify("https://www.instagram.com/reel/Cabcdefghij/");
    try std.testing.expect(thumbnailUrl(&reel, &thumb_buffer) == null);
    try std.testing.expect(oembedEndpoint(&reel, &buffer) == null);

    try std.testing.expect(isPageFetchAllowed("https://www.youtube.com/watch?v=dQw4w9WgXcQ"));
    try std.testing.expect(!isPageFetchAllowed("https://img.youtube.com/vi/x/hqdefault.jpg"));
    try std.testing.expect(!isPageFetchAllowed("http://www.youtube.com/watch?v=dQw4w9WgXcQ"));
    try std.testing.expect(isImageFetchAllowed("https://img.youtube.com/vi/x/hqdefault.jpg"));
    try std.testing.expect(isImageFetchAllowed("https://scontent-arn2-1.cdninstagram.com/v/x.jpg"));
    try std.testing.expect(isImageFetchAllowed("https://scontent.xx.fbcdn.net/v/x.jpg"));
    try std.testing.expect(!isImageFetchAllowed("https://evil.com/.cdninstagram.com/x.jpg"));
    try std.testing.expect(isStreamUrlAllowed("https://rr3---sn-x.googlevideo.com/videoplayback?x=1"));
    try std.testing.expect(isStreamUrlAllowed("https://scontent-arn2-1.cdninstagram.com/v.mp4"));
    try std.testing.expect(!isStreamUrlAllowed("http://rr3---sn-x.googlevideo.com/videoplayback"));
    try std.testing.expect(!isStreamUrlAllowed("https://evil.com/?x=.googlevideo.com"));
}

test "og scraping and stream extraction" {
    const page = "<html><meta property=\"og:video\" content=\"https://scontent-1.cdninstagram.com/v.mp4\" /><meta property=\"og:image\" content=\"https://scontent-1.cdninstagram.com/v.jpg\" /></html>";
    try std.testing.expectEqualStrings("https://scontent-1.cdninstagram.com/v.mp4", scrapeOgMeta(page, "og:video").?);
    try std.testing.expectEqualStrings("https://scontent-1.cdninstagram.com/v.jpg", scrapeOgMeta(page, "og:image").?);
    try std.testing.expect(scrapeOgMeta(page, "og:title") == null);

    // content-before-property ordering also works.
    const swapped = "<meta content=\"https://scontent-1.cdninstagram.com/v.mp4\" property=\"og:video\">";
    try std.testing.expectEqualStrings("https://scontent-1.cdninstagram.com/v.mp4", scrapeOgMeta(swapped, "og:video").?);

    const watch_page = "{\"args\":{}}\"https://www.googlevideo.com/videoplayback?expire=1\\u0026id=dQw4w9WgXcQ\"";
    var stream_buffer: [512]u8 = undefined;
    const stream = extractYoutubeStream(watch_page, &stream_buffer).?;
    try std.testing.expectEqualStrings("https://www.googlevideo.com/videoplayback?expire=1&id=dQw4w9WgXcQ", stream);
    try std.testing.expect(extractYoutubeStream("no stream here", &stream_buffer) == null);
    try std.testing.expect(extractYoutubeStream("\"https://www.googlevideo.com.evil.com/videoplayback?id=1\"", &stream_buffer) == null);
}
