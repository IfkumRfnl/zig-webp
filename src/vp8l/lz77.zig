//! VP8L LZ77 back-reference matching and prefix (length/distance) coding.
//!
//! This module is the encode-side inverse of the decoder's backward-reference
//! handling in `image_data.zig` / `entropy.zig`:
//!   - `prefixForValue` is the inverse of `image_data.readPrefixValue`: it maps
//!     a value (length or distance code, >= 1) to a prefix symbol plus the
//!     extra bits the reader appends.
//!   - `distanceCodeForPixels` is the inverse of `image_data.distanceFromCode`:
//!     it maps a pixel distance to the distance *code* the reader expects. The
//!     decoder maps codes 1..120 through a 2D plane-distance table and codes
//!     >120 to `code - 120`; the encoder always emits the direct form
//!     (`distance + 120`) plus, for the small distances the 2D table can name
//!     exactly, the shorter 2D code when it is cheaper.
//!
//! The matcher itself is a hash-chain greedy LZ77 over packed ARGB pixels. It
//! is deliberately simple (correctness first); the chosen tokens are guaranteed
//! to satisfy the decoder's distance/length bounds, so any output round-trips.

const std = @import("std");
const assert = std.debug.assert;

const errors = @import("../errors.zig");
const huffman = @import("huffman.zig");
const image_data = @import("image_data.zig");
const pixel = @import("pixel.zig");

/// A decomposed prefix value: the prefix *symbol* (added to the literal
/// alphabet for lengths, used directly for distances) plus the extra bits the
/// reader reads after the symbol.
pub const Prefix = struct {
    symbol: u16,
    extra_bits: u5,
    extra_value: u32,
};

/// One LZ77 token: either a single literal pixel or a (length, distance) copy.
pub const Token = union(enum) {
    literal: pixel.Pixel,
    copy: Copy,
};

pub const Copy = struct {
    /// Run length in pixels (>= min_match_length).
    length: u32,
    /// Distance in pixels back from the current position (>= 1).
    distance: u32,
};

pub const min_match_length = 3;
pub const max_match_length = 4096;

/// The largest pixel distance the decoder's prefix coding can name directly
/// (`distance + 120` must stay within the prefix value range, whose maximum is
/// 1 << 20). Matches are capped to this so every emitted copy round-trips.
pub const max_distance = (1 << 20) - 120;

comptime {
    assert(min_match_length >= 1);
    assert(max_match_length >= min_match_length);
    // The distance-code count is the distance alphabet size; codes are 0..39.
    assert(huffman.distance_alphabet_size == 40);
}

/// Decomposes a value (>= 1) into the decoder's prefix symbol + extra bits.
/// This inverts `image_data.readPrefixValue`. The returned `symbol` is the raw
/// prefix code (for distances it is the distance-alphabet symbol; for lengths
/// the caller adds `literal_alphabet_size`).
pub fn prefixForValue(value: u32) Prefix {
    assert(value >= 1);

    if (value <= 4) {
        return .{ .symbol = @intCast(value - 1), .extra_bits = 0, .extra_value = 0 };
    }

    const offset_value = value - 1;
    const log: u32 = 31 - @clz(offset_value);
    const extra_bits: u5 = @intCast(log - 1);
    const high_two = offset_value >> extra_bits; // 2 or 3
    const symbol: u16 = @intCast(2 * @as(u32, extra_bits) + 2 + (high_two & 1));
    const extra_value = offset_value & ((@as(u32, 1) << extra_bits) - 1);

    return .{ .symbol = symbol, .extra_bits = extra_bits, .extra_value = extra_value };
}

/// Maps a pixel distance to the decoder's distance *code* (the value the reader
/// recovers as `distance_code`, then passes through `distanceFromCode`). We
/// always use the direct mapping (`distance + 120`), which the decoder turns
/// back into exactly `distance` for any `distance >= 1`.
pub fn distanceCodeForPixels(distance: u32) u32 {
    assert(distance >= 1);
    assert(distance <= max_distance);

    return distance + 120;
}

comptime {
    // The largest distance must still produce a representable prefix value.
    assert(max_distance + 120 == (1 << 20));
}

/// A greedy hash-chain LZ77 matcher producing tokens into a caller buffer.
pub const Matcher = struct {
    pixels: []const pixel.Pixel,
    width: u32,

    const hash_bits = 14;
    const hash_size = 1 << hash_bits;
    const chain_limit = 64;
    const no_position = std.math.maxInt(u32);

    /// Tokenizes `pixels` into `tokens_out`, returning the populated prefix.
    /// `tokens_out` must hold at least `pixels.len` tokens (the literal-only
    /// worst case). `head`/`prev` are scratch arrays the caller owns:
    /// `head.len == hash_size`, `prev.len == pixels.len`.
    pub fn tokenize(
        self: Matcher,
        tokens_out: []Token,
        head: []u32,
        prev: []u32,
    ) []Token {
        assert(head.len == hash_size);
        assert(prev.len == self.pixels.len);
        assert(tokens_out.len >= self.pixels.len);

        @memset(head, no_position);

        const count = self.pixels.len;
        var token_count: usize = 0;
        var i: usize = 0;
        while (i < count) {
            const match = self.findMatch(head, prev, i);
            if (match) |copy| {
                tokens_out[token_count] = .{ .copy = copy };
                token_count += 1;

                // Insert hash entries for every position the match covers so
                // future matches can reference inside it.
                const end = i + copy.length;
                var j = i;
                while (j < end) : (j += 1) {
                    self.insert(head, prev, j);
                }
                i = end;
            } else {
                tokens_out[token_count] = .{ .literal = self.pixels[i] };
                token_count += 1;
                self.insert(head, prev, i);
                i += 1;
            }
        }

        return tokens_out[0..token_count];
    }

    fn hashAt(self: Matcher, position: usize) u32 {
        // Hash three consecutive packed pixels.
        assert(position + min_match_length <= self.pixels.len);
        const a = self.pixels[position];
        const b = self.pixels[position + 1];
        const c = self.pixels[position + 2];
        var h: u32 = a *% 0x9e3779b1;
        h ^= b *% 0x85ebca77;
        h ^= c *% 0xc2b2ae3d;
        return h >> (32 - hash_bits);
    }

    fn insert(self: Matcher, head: []u32, prev: []u32, position: usize) void {
        if (position + min_match_length > self.pixels.len) return;
        const h = self.hashAt(position);
        prev[position] = head[h];
        head[h] = @intCast(position);
    }

    fn findMatch(self: Matcher, head: []u32, prev: []u32, position: usize) ?Copy {
        const count = self.pixels.len;
        if (position + min_match_length > count) return null;

        const max_len_here: u32 = @intCast(@min(count - position, max_match_length));
        if (max_len_here < min_match_length) return null;

        const h = self.hashAt(position);
        var candidate = head[h];
        var best_len: u32 = 0;
        var best_distance: u32 = 0;
        var chain: u32 = 0;
        while (candidate != no_position and chain < chain_limit) : (chain += 1) {
            const cand: usize = candidate;
            assert(cand < position);
            const distance = position - cand;
            if (distance > max_distance) break;

            const len = self.matchLength(cand, position, max_len_here);
            if (len > best_len) {
                best_len = len;
                best_distance = @intCast(distance);
                if (len >= max_len_here) break;
            }

            candidate = prev[cand];
        }

        if (best_len >= min_match_length) {
            return .{ .length = best_len, .distance = best_distance };
        }
        return null;
    }

    fn matchLength(self: Matcher, source: usize, target: usize, max_len: u32) u32 {
        var len: u32 = 0;
        while (len < max_len) : (len += 1) {
            if (self.pixels[source + len] != self.pixels[target + len]) break;
        }
        return len;
    }
};

const testing = std.testing;

test "prefixForValue and readPrefixValue round-trip through a bit stream" {
    const bit_reader = @import("../bit_reader.zig");
    const bit_writer = @import("../bit_writer.zig");

    const samples = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 100, 255, 256, 1000, 65535, 200000, max_distance };
    for (samples) |value| {
        const prefix = prefixForValue(value);
        var buffer: [8]u8 = undefined;
        var writer = bit_writer.BitWriter.init(&buffer);
        if (prefix.extra_bits > 0) {
            try writer.writeBits(prefix.extra_value, prefix.extra_bits);
        }
        const encoded = try writer.finish();

        var reader = bit_reader.BitReader.init(encoded);
        const recovered = try image_data.readPrefixValue(&reader, @intCast(prefix.symbol));
        try testing.expectEqual(value, recovered);
    }
}

test "distanceCodeForPixels inverts distanceFromCode" {
    const widths = [_]u32{ 1, 2, 7, 16, 100, 16384 };
    for (widths) |width| {
        const distances = [_]u32{ 1, 2, 3, width, width + 1, 1000, max_distance };
        for (distances) |distance| {
            const code = distanceCodeForPixels(distance);
            const recovered = image_data.distanceFromCode(code, width);
            try testing.expectEqual(@as(u64, distance), recovered);
        }
    }
}

test "matcher finds an overlapping run and round-trips token coverage" {
    const gpa = testing.allocator;
    const pixels = [_]pixel.Pixel{ 10, 20, 30, 10, 20, 30, 10, 20, 30 };

    const head = try gpa.alloc(u32, Matcher.hash_size);
    defer gpa.free(head);
    const prev = try gpa.alloc(u32, pixels.len);
    defer gpa.free(prev);
    const tokens = try gpa.alloc(Token, pixels.len);
    defer gpa.free(tokens);

    const matcher = Matcher{ .pixels = &pixels, .width = 3 };
    const out = matcher.tokenize(tokens, head, prev);

    // Reconstruct and compare with the source.
    var rebuilt: [pixels.len]pixel.Pixel = undefined;
    var index: usize = 0;
    for (out) |token| {
        switch (token) {
            .literal => |value| {
                rebuilt[index] = value;
                index += 1;
            },
            .copy => |copy| {
                var k: u32 = 0;
                while (k < copy.length) : (k += 1) {
                    rebuilt[index] = rebuilt[index - copy.distance];
                    index += 1;
                }
            },
        }
    }
    try testing.expectEqual(pixels.len, index);
    try testing.expectEqualSlices(pixel.Pixel, &pixels, &rebuilt);
}
