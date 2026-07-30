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

pub const chain_limit_default: u32 = 64;

/// A greedy hash-chain LZ77 matcher producing tokens into a caller buffer.
pub const Matcher = struct {
    pixels: []const pixel.Pixel,
    chain_limit: u32 = chain_limit_default,

    const hash_bits = 14;
    pub const hash_size = 1 << hash_bits;
    const no_position = std.math.maxInt(u32);

    pub const head_presence_size = hash_size / 8;

    /// Tokenizes `pixels` into `tokens_out`, returning the populated prefix.
    /// `tokens_out` must hold at least `pixels.len` tokens (the literal-only
    /// worst case). `head`/`prev` and `head_presence` are scratch arrays the caller owns:
    /// `head.len == hash_size`, `prev.len == pixels.len`, and
    /// `head_presence.len == head_presence_size`.
    pub fn tokenize(
        self: Matcher,
        tokens_out: []Token,
        head: []u32,
        prev: []u32,
        head_presence: []u8,
    ) []Token {
        assert(head.len == hash_size);
        assert(prev.len == self.pixels.len);
        assert(head_presence.len == head_presence_size);
        assert(tokens_out.len >= self.pixels.len);
        assert(self.chain_limit > 0);

        @memset(head_presence, 0);

        const count = self.pixels.len;
        var token_count: usize = 0;
        var i: usize = 0;
        while (i < count) {
            const position_hash = if (i + min_match_length <= count)
                self.hashAt(i)
            else
                null;
            const match = self.findMatch(head, prev, head_presence, i, position_hash);
            if (match) |copy| {
                tokens_out[token_count] = .{ .copy = copy };
                token_count += 1;

                // Insert hash entries for every position the match covers so
                // future matches can reference inside it.
                insertHashed(head, prev, head_presence, i, position_hash.?);
                const end = i + copy.length;
                var j = i + 1;
                while (j < end) : (j += 1) {
                    self.insert(head, prev, head_presence, j);
                }
                i = end;
            } else {
                tokens_out[token_count] = .{ .literal = self.pixels[i] };
                token_count += 1;
                if (position_hash) |hash| {
                    insertHashed(head, prev, head_presence, i, hash);
                }
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
        var hash: u32 = a *% 0x9e3779b1;
        hash ^= b *% 0x85ebca77;
        hash ^= c *% 0xc2b2ae3d;
        return hash >> (32 - hash_bits);
    }

    fn insert(
        self: Matcher,
        head: []u32,
        prev: []u32,
        head_presence: []u8,
        position: usize,
    ) void {
        if (position + min_match_length > self.pixels.len) return;
        insertHashed(head, prev, head_presence, position, self.hashAt(position));
    }

    fn insertHashed(
        head: []u32,
        prev: []u32,
        head_presence: []u8,
        position: usize,
        hash: u32,
    ) void {
        const presence_index = hash / 8;
        const presence_mask = @as(u8, 1) << @intCast(hash % 8);
        const was_present = head_presence[presence_index] & presence_mask != 0;
        prev[position] = if (was_present) head[hash] else no_position;
        head[hash] = @intCast(position);
        head_presence[presence_index] |= presence_mask;
    }

    fn findMatch(
        self: Matcher,
        head: []u32,
        prev: []u32,
        head_presence: []const u8,
        position: usize,
        position_hash: ?u32,
    ) ?Copy {
        const count = self.pixels.len;
        const hash = position_hash orelse return null;

        const max_len_here: u32 = @intCast(@min(count - position, max_match_length));
        assert(max_len_here >= min_match_length);

        const presence_index = hash / 8;
        const presence_mask = @as(u8, 1) << @intCast(hash % 8);
        var candidate = if (head_presence[presence_index] & presence_mask != 0)
            head[hash]
        else
            no_position;
        var best_len: u32 = 0;
        var best_distance: u32 = 0;

        var chain: u32 = 0;
        while (candidate != no_position and chain < self.chain_limit) : (chain += 1) {
            const cand: usize = candidate;
            assert(cand < position);
            const distance = position - cand;
            if (distance > max_distance) break;

            if (best_len > 0 and
                self.pixels[cand + best_len] != self.pixels[position + best_len])
            {
                candidate = prev[cand];
                continue;
            }
            const len = matchLength(self.pixels, cand, position, max_len_here);
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
};

/// Bounded matcher for packed palette-index images. It checks the previous
/// row and the most recent occurrence of the current index, avoiding hash-chain
/// allocation and search while retaining the matches common in UI imagery.
pub const LowColorMatcher = struct {
    pixels: []const pixel.Pixel,
    width: u32,

    pub fn tokenize(self: LowColorMatcher, tokens_out: []Token) []Token {
        assert(self.pixels.len > 0);
        assert(tokens_out.len >= self.pixels.len);

        const no_position = std.math.maxInt(u32);
        var latest_by_index: [256]u32 = @splat(no_position);
        var token_count: usize = 0;
        var position: usize = 0;
        while (position < self.pixels.len) {
            const max_len_here: u32 =
                @intCast(@min(self.pixels.len - position, max_match_length));
            var best_len: u32 = 0;
            var best_distance: u32 = 0;

            const row_distance: usize = self.width;
            if (row_distance <= position and row_distance <= max_distance) {
                const row_len = matchLength(
                    self.pixels,
                    position - row_distance,
                    position,
                    max_len_here,
                );
                if (row_len >= min_match_length) {
                    best_len = row_len;
                    best_distance = @intCast(row_distance);
                }
            }

            const index = pixel.green(self.pixels[position]);
            const latest = latest_by_index[index];
            if (latest != no_position and best_len < max_len_here) {
                const candidate: usize = latest;
                const distance = position - candidate;
                if (distance <= max_distance) {
                    if (best_len == 0 or
                        self.pixels[candidate + best_len] ==
                            self.pixels[position + best_len])
                    {
                        const len = matchLength(
                            self.pixels,
                            candidate,
                            position,
                            max_len_here,
                        );
                        if (len > best_len) {
                            best_len = len;
                            best_distance = @intCast(distance);
                        }
                    }
                }
            }

            const end = if (best_len >= min_match_length) blk: {
                tokens_out[token_count] = .{
                    .copy = .{ .length = best_len, .distance = best_distance },
                };
                break :blk position + best_len;
            } else blk: {
                tokens_out[token_count] = .{ .literal = self.pixels[position] };
                break :blk position + 1;
            };
            token_count += 1;

            while (position < end) : (position += 1) {
                latest_by_index[pixel.green(self.pixels[position])] = @intCast(position);
            }
        }
        return tokens_out[0..token_count];
    }
};

fn matchLength(
    pixels: []const pixel.Pixel,
    source: usize,
    target: usize,
    max_len: u32,
) u32 {
    const vector_len = 4;
    const PixelVector = @Vector(vector_len, pixel.Pixel);

    var len: u32 = 0;
    while (len + vector_len <= max_len) : (len += vector_len) {
        const source_vector: *align(@alignOf(pixel.Pixel)) const PixelVector =
            @ptrCast(pixels.ptr + source + len);
        const target_vector: *align(@alignOf(pixel.Pixel)) const PixelVector =
            @ptrCast(pixels.ptr + target + len);
        if (!@reduce(.And, source_vector.* == target_vector.*)) {
            const block_end = len + vector_len;
            while (len < block_end) : (len += 1) {
                if (pixels[source + len] != pixels[target + len]) return len;
            }
            unreachable;
        }
    }
    while (len < max_len) : (len += 1) {
        if (pixels[source + len] != pixels[target + len]) break;
    }
    return len;
}

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
    const head_presence = try gpa.alloc(u8, Matcher.head_presence_size);
    defer gpa.free(head_presence);
    const tokens = try gpa.alloc(Token, pixels.len);
    defer gpa.free(tokens);

    const matcher = Matcher{ .pixels = &pixels };
    const out = matcher.tokenize(tokens, head, prev, head_presence);

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

test "low-color matcher uses row and recent-index copies" {
    const a = pixel.fromChannels(0, 0, 1, 0);
    const b = pixel.fromChannels(0, 0, 2, 0);
    const c = pixel.fromChannels(0, 0, 3, 0);
    const d = pixel.fromChannels(0, 0, 4, 0);
    const e = pixel.fromChannels(0, 0, 5, 0);
    const pixels = [_]pixel.Pixel{
        a, b, c, d,
        a, b, c, d,
        e, e, e, e,
    };
    var tokens: [pixels.len]Token = undefined;
    const out = (LowColorMatcher{ .pixels = &pixels, .width = 4 }).tokenize(&tokens);

    try testing.expectEqual(@as(usize, 7), out.len);
    switch (out[4]) {
        .copy => |copy| {
            try testing.expectEqual(@as(u32, 4), copy.length);
            try testing.expectEqual(@as(u32, 4), copy.distance);
        },
        else => return error.TestUnexpectedResult,
    }
    switch (out[6]) {
        .copy => |copy| {
            try testing.expectEqual(@as(u32, 3), copy.length);
            try testing.expectEqual(@as(u32, 1), copy.distance);
        },
        else => return error.TestUnexpectedResult,
    }

    var rebuilt: [pixels.len]pixel.Pixel = undefined;
    var index: usize = 0;
    for (out) |token| {
        switch (token) {
            .literal => |value| {
                rebuilt[index] = value;
                index += 1;
            },
            .copy => |copy| {
                var copied: u32 = 0;
                while (copied < copy.length) : (copied += 1) {
                    rebuilt[index] = rebuilt[index - copy.distance];
                    index += 1;
                }
            },
        }
    }
    try testing.expectEqual(pixels.len, index);
    try testing.expectEqualSlices(pixel.Pixel, &pixels, &rebuilt);
}

test "vector match length equals scalar first mismatch" {
    var pixels: [40]pixel.Pixel = undefined;
    for (&pixels, 0..) |*value, index| {
        value.* = @intCast((index * 17 + index / 3) % 11);
    }
    @memcpy(pixels[16..32], pixels[0..16]);
    pixels[23] = 99;

    var source: usize = 0;
    while (source < pixels.len) : (source += 1) {
        var target = source + 1;
        while (target < pixels.len) : (target += 1) {
            var max_len: u32 = 0;
            const max_len_bound: u32 = @intCast(pixels.len - target);
            while (max_len <= max_len_bound) : (max_len += 1) {
                var expected: u32 = 0;
                while (expected < max_len) : (expected += 1) {
                    if (pixels[source + expected] != pixels[target + expected]) break;
                }
                try testing.expectEqual(
                    expected,
                    matchLength(&pixels, source, target, max_len),
                );
            }
        }
    }
}
