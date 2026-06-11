//! VP8L color-cache state used by entropy decoding.

const std = @import("std");
const assert = std.debug.assert;

const errors = @import("../errors.zig");
const huffman = @import("huffman.zig");
const pixel = @import("pixel.zig");

pub const multiplier: u32 = 0x1e35a7bd;
pub const entries_max = huffman.color_cache_size_max;

pub const Cache = struct {
    bits: u4 = 0,
    size: u16 = 0,
    entries: [entries_max]pixel.Pixel = .{0} ** entries_max,

    pub fn init(self: *Cache, bits: u4) errors.Error!void {
        if (bits == 0) return error.InvalidVP8LImageData;
        if (bits > huffman.color_cache_bits_max) return error.InvalidVP8LImageData;

        self.* = .{
            .bits = bits,
            .size = @as(u16, 1) << bits,
        };
    }

    pub fn insert(self: *Cache, value: pixel.Pixel) void {
        assert(self.bits > 0);
        assert(self.bits <= huffman.color_cache_bits_max);
        assert(self.size > 0);
        assert(self.size <= entries_max);

        self.entries[hash(self.bits, value)] = value;
    }

    pub fn lookup(self: Cache, index: u16) errors.Error!pixel.Pixel {
        assert(self.bits > 0);
        assert(self.bits <= huffman.color_cache_bits_max);
        assert(self.size > 0);
        assert(self.size <= entries_max);

        if (index >= self.size) return error.InvalidVP8LImageData;

        return self.entries[index];
    }
};

pub fn hash(bits: u4, value: pixel.Pixel) u16 {
    assert(bits > 0);
    assert(bits <= huffman.color_cache_bits_max);

    const shift: u5 = @intCast(32 - @as(u6, bits));
    return @intCast((multiplier *% value) >> shift);
}

comptime {
    assert(entries_max == 2048);
    assert(multiplier == 0x1e35a7bd);
}

test "VP8L color cache initializes and validates cache bit counts" {
    var cache: Cache = undefined;

    try std.testing.expectError(error.InvalidVP8LImageData, cache.init(0));
    try std.testing.expectError(error.InvalidVP8LImageData, cache.init(12));

    try cache.init(4);
    try std.testing.expectEqual(@as(u4, 4), cache.bits);
    try std.testing.expectEqual(@as(u16, 16), cache.size);
    try std.testing.expectEqual(@as(pixel.Pixel, 0), try cache.lookup(0));
}

test "VP8L color cache stores colors by multiplicative hash" {
    var cache: Cache = undefined;
    try cache.init(5);

    const value = pixel.fromChannels(0xdd, 0xcc, 0xbb, 0xaa);
    const index = hash(cache.bits, value);
    try std.testing.expect(index < cache.size);

    cache.insert(value);

    try std.testing.expectEqual(value, try cache.lookup(index));
    try std.testing.expectError(error.InvalidVP8LImageData, cache.lookup(cache.size));
}
