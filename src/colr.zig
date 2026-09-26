//! COLRv0 + CPAL parser for colour emoji drawn with plain GDI. Pure: it only
//! reads big-endian byte slices, so it runs in host unit tests. The caller
//! fetches the bytes (GetFontData on Windows) and may load only the v0 arrays
//! of a COLR table, skipping the much larger v1 paint data.
const std = @import("std");

pub const Error = error{ Truncated, UnsupportedVersion, NoPalette };

/// Palette index meaning "use the current text colour".
pub const foreground: u16 = 0xFFFF;

pub const header_len = 14;
const base_record_len = 6;
const layer_record_len = 4;

/// Where the v0 arrays live inside the COLR table (COLR v0 and v1 share it).
pub const Header = struct {
    base_count: u16,
    base_offset: u32,
    layer_count: u16,
    layer_offset: u32,

    pub fn baseLen(self: Header) usize {
        return @as(usize, self.base_count) * base_record_len;
    }

    pub fn layerLen(self: Header) usize {
        return @as(usize, self.layer_count) * layer_record_len;
    }
};

pub const Layer = struct { glyph: u16, palette_index: u16 };

pub fn parseHeader(bytes: []const u8) Error!Header {
    if (bytes.len < header_len) return error.Truncated;
    const version = be16(bytes, 0);
    if (version > 1) return error.UnsupportedVersion;
    return .{
        .base_count = be16(bytes, 2),
        .base_offset = be32(bytes, 4),
        .layer_offset = be32(bytes, 8),
        .layer_count = be16(bytes, 12),
    };
}

/// Palette 0 as B,G,R,A byte quads (CPAL stores them in exactly that order).
pub fn paletteZero(cpal: []const u8) Error![]const u8 {
    if (cpal.len < 12) return error.Truncated;
    const entries = be16(cpal, 2);
    const palettes = be16(cpal, 4);
    const records_offset = be32(cpal, 8);
    if (palettes == 0 or entries == 0) return error.NoPalette;
    const first = be16(cpal, 12);
    const start = @as(usize, records_offset) + @as(usize, first) * 4;
    const len = @as(usize, entries) * 4;
    if (cpal.len < 14 or start + len > cpal.len) return error.Truncated;
    return cpal[start..][0..len];
}

pub const Colr = struct {
    base: []const u8,
    layers: []const u8,
    palette: []const u8,

    /// Builds from the v0 arrays alone; `base` and `layers` are the raw
    /// BaseGlyphRecord and LayerRecord bytes.
    pub fn init(base: []const u8, layers: []const u8, palette: []const u8) Colr {
        return .{
            .base = base[0 .. base.len - base.len % base_record_len],
            .layers = layers[0 .. layers.len - layers.len % layer_record_len],
            .palette = palette[0 .. palette.len - palette.len % 4],
        };
    }

    /// Builds from whole COLR and CPAL tables (tests, or a caller that has
    /// both tables in memory anyway).
    pub fn fromTables(colr: []const u8, cpal: []const u8) Error!Colr {
        const header = try parseHeader(colr);
        const base_end = @as(usize, header.base_offset) + header.baseLen();
        const layer_end = @as(usize, header.layer_offset) + header.layerLen();
        if (base_end > colr.len or layer_end > colr.len) return error.Truncated;
        return init(colr[header.base_offset..base_end], colr[header.layer_offset..layer_end], try paletteZero(cpal));
    }

    pub fn layerCount(self: Colr) usize {
        return self.layers.len / layer_record_len;
    }

    /// The layer range of a base glyph, or null when the glyph has no colour
    /// layers (draw it plain) or its record points past the layer array.
    pub fn find(self: Colr, glyph: u16) ?LayerRange {
        var low: usize = 0;
        var high: usize = self.base.len / base_record_len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const record = self.base[mid * base_record_len ..];
            const id = be16(record, 0);
            if (id == glyph) {
                const first: usize = be16(record, 2);
                const count: usize = be16(record, 4);
                if (count == 0 or first + count > self.layerCount()) return null;
                return .{ .first = first, .count = count };
            }
            if (id < glyph) low = mid + 1 else high = mid;
        }
        return null;
    }

    pub fn layer(self: Colr, index: usize) Layer {
        const record = self.layers[index * layer_record_len ..];
        return .{ .glyph = be16(record, 0), .palette_index = be16(record, 2) };
    }

    /// Colour of a palette entry as B,G,R,A; null for an out-of-range index.
    /// The foreground index (0xFFFF) is the caller's to resolve.
    pub fn color(self: Colr, palette_index: u16) ?[4]u8 {
        const start = @as(usize, palette_index) * 4;
        if (start + 4 > self.palette.len) return null;
        return self.palette[start..][0..4].*;
    }
};

pub const LayerRange = struct { first: usize, count: usize };

fn be16(bytes: []const u8, offset: usize) u16 {
    return std.mem.readInt(u16, bytes[offset..][0..2], .big);
}

fn be32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .big);
}

// Fixture: glyph 5 = two layers (glyph 20 red, glyph 21 foreground),
// glyph 9 = one layer (glyph 22, half-transparent blue), glyph 12 points past
// the layer array. Palette 1 exists but must be ignored.
const fixture_colr = [_]u8{
    0, 1, // version 1 (v0 arrays still valid)
    0, 3, // numBaseGlyphRecords
    0, 0, 0, 14, // baseGlyphRecordsOffset
    0, 0, 0, 32, // layerRecordsOffset
    0,    3, // numLayerRecords
    // BaseGlyphRecords, sorted by glyph id
    0,    5,
    0,    0,
    0,    2,
    0,    9,
    0,    2,
    0,    1,
    0,    12,
    0,    2,
    0,    5,
    // LayerRecords
    0,    20,
    0,    0,
    0,    21,
    0xFF, 0xFF,
    0,    22,
    0,    1,
};

const fixture_cpal = [_]u8{
    0, 0, // version 0
    0, 2, // numPaletteEntries
    0, 2, // numPalettes
    0, 4, // numColorRecords
    0, 0, 0, 16, // colorRecordsArrayOffset
    0, 0, // palette 0 starts at record 0
    0, 2, // palette 1 starts at record 2
    // B, G, R, A
    0, 0, 0xFF, 0xFF, // red
    0xFF, 0, 0, 0x80, // half-transparent blue
    0, 0xFF, 0, 0xFF, // palette 1: green
    0, 0,    0, 0xFF,
};

test "finds layers and palette 0 colours of a base glyph" {
    const table = try Colr.fromTables(&fixture_colr, &fixture_cpal);
    const range = table.find(5).?;
    try std.testing.expectEqual(@as(usize, 0), range.first);
    try std.testing.expectEqual(@as(usize, 2), range.count);
    const bottom = table.layer(range.first);
    try std.testing.expectEqual(@as(u16, 20), bottom.glyph);
    try std.testing.expectEqual([4]u8{ 0, 0, 0xFF, 0xFF }, table.color(bottom.palette_index).?);
    // Layer order is paint order: the foreground layer is drawn last.
    try std.testing.expectEqual(foreground, table.layer(range.first + 1).palette_index);
    const blue = table.layer(table.find(9).?.first);
    try std.testing.expectEqual([4]u8{ 0xFF, 0, 0, 0x80 }, table.color(blue.palette_index).?);
}

test "glyphs without colour or with broken records draw plain" {
    const table = try Colr.fromTables(&fixture_colr, &fixture_cpal);
    try std.testing.expectEqual(@as(?LayerRange, null), table.find(4));
    try std.testing.expectEqual(@as(?LayerRange, null), table.find(0xFFFF));
    // Record says layers 2..6 but only 3 exist: never read out of bounds.
    try std.testing.expectEqual(@as(?LayerRange, null), table.find(12));
    // Palette 1's green is not reachable through palette 0.
    try std.testing.expectEqual(@as(?[4]u8, null), table.color(2));
}

test "the v0 arrays alone give the same answers as the whole table" {
    const header = try parseHeader(&fixture_colr);
    const base = fixture_colr[header.base_offset..][0..header.baseLen()];
    const layers = fixture_colr[header.layer_offset..][0..header.layerLen()];
    const table = Colr.init(base, layers, try paletteZero(&fixture_cpal));
    try std.testing.expectEqual(@as(usize, 2), table.find(5).?.count);
    try std.testing.expectEqual(@as(u16, 22), table.layer(table.find(9).?.first).glyph);
}

test "rejects truncated or unknown tables" {
    try std.testing.expectError(error.Truncated, parseHeader(fixture_colr[0..10]));
    var future = fixture_colr;
    future[1] = 2;
    try std.testing.expectError(error.UnsupportedVersion, parseHeader(&future));
    try std.testing.expectError(error.Truncated, Colr.fromTables(fixture_colr[0..30], &fixture_cpal));
    try std.testing.expectError(error.Truncated, paletteZero(fixture_cpal[0..20]));
    var empty = fixture_cpal;
    empty[5] = 0;
    try std.testing.expectError(error.NoPalette, paletteZero(&empty));
}
