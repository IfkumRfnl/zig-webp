//! Bounded byte and LSB-first bit readers for codec bitstreams.

const std = @import("std");
const assert = std.debug.assert;

const errors = @import("errors.zig");

pub const Error = errors.Error;
pub const read_bits_max = 32;

const bits_per_byte = 8;
const buffered_bits_max = read_bits_max + bits_per_byte - 1;

pub const ByteReader = struct {
    bytes: []const u8,
    offset: usize = 0,

    pub fn init(bytes: []const u8) ByteReader {
        return .{ .bytes = bytes };
    }

    pub fn consumedBytes(self: ByteReader) usize {
        assert(self.offset <= self.bytes.len);

        return self.offset;
    }

    pub fn remainingBytes(self: ByteReader) usize {
        assert(self.offset <= self.bytes.len);

        return self.bytes.len - self.offset;
    }

    pub fn isEmpty(self: ByteReader) bool {
        return self.remainingBytes() == 0;
    }

    pub fn readByte(self: *ByteReader) Error!u8 {
        try self.requireBytes(1);

        const value = self.bytes[self.offset];
        self.offset += 1;

        return value;
    }

    pub fn readBytes(self: *ByteReader, count: usize) Error![]const u8 {
        try self.requireBytes(count);

        const start = self.offset;
        self.offset += count;

        return self.bytes[start..self.offset];
    }

    pub fn skip(self: *ByteReader, count: usize) Error!void {
        _ = try self.readBytes(count);
    }

    pub fn readLittleU16(self: *ByteReader) Error!u16 {
        const bytes = try self.readBytes(2);

        return @as(u16, bytes[0]) |
            (@as(u16, bytes[1]) << 8);
    }

    pub fn readLittleU24(self: *ByteReader) Error!u32 {
        const bytes = try self.readBytes(3);

        return @as(u32, bytes[0]) |
            (@as(u32, bytes[1]) << 8) |
            (@as(u32, bytes[2]) << 16);
    }

    pub fn readLittleU32(self: *ByteReader) Error!u32 {
        const bytes = try self.readBytes(4);

        return @as(u32, bytes[0]) |
            (@as(u32, bytes[1]) << 8) |
            (@as(u32, bytes[2]) << 16) |
            (@as(u32, bytes[3]) << 24);
    }

    pub fn readLittleU64(self: *ByteReader) Error!u64 {
        const bytes = try self.readBytes(8);

        return @as(u64, bytes[0]) |
            (@as(u64, bytes[1]) << 8) |
            (@as(u64, bytes[2]) << 16) |
            (@as(u64, bytes[3]) << 24) |
            (@as(u64, bytes[4]) << 32) |
            (@as(u64, bytes[5]) << 40) |
            (@as(u64, bytes[6]) << 48) |
            (@as(u64, bytes[7]) << 56);
    }

    fn requireBytes(self: ByteReader, count: usize) Error!void {
        assert(self.offset <= self.bytes.len);
        if (count > self.bytes.len - self.offset) return error.TruncatedBitstream;
    }
};

pub const BitReader = struct {
    bytes: []const u8,
    byte_offset: usize = 0,
    bit_buffer: u64 = 0,
    bit_count: u6 = 0,

    pub fn init(bytes: []const u8) BitReader {
        return .{ .bytes = bytes };
    }

    pub fn loadedBytes(self: BitReader) usize {
        assert(self.byte_offset <= self.bytes.len);

        return self.byte_offset;
    }

    pub fn bufferedBits(self: BitReader) u6 {
        return self.bit_count;
    }

    pub fn remainingUnloadedBytes(self: BitReader) usize {
        assert(self.byte_offset <= self.bytes.len);

        return self.bytes.len - self.byte_offset;
    }

    pub fn remainingBits(self: BitReader) usize {
        assert(self.byte_offset <= self.bytes.len);

        const remaining_bytes = self.bytes.len - self.byte_offset;
        const bits_max: usize = std.math.maxInt(usize);
        if (remaining_bytes > (bits_max - @as(usize, self.bit_count)) / 8) return bits_max;

        return @as(usize, self.bit_count) + remaining_bytes * 8;
    }

    pub fn readBit(self: *BitReader) Error!u1 {
        return @intCast(try self.readBits(1));
    }

    pub fn readBits(self: *BitReader, count: u6) Error!u32 {
        const value = try self.peekBits(count);
        try self.dropBits(count);

        return value;
    }

    pub fn peekBits(self: *BitReader, count: u6) Error!u32 {
        if (count > read_bits_max) return error.InvalidBitCount;
        if (count == 0) return 0;

        try self.ensureBits(count);

        return if (count == 32)
            @as(u32, @truncate(self.bit_buffer))
        else
            @as(u32, @truncate(self.bit_buffer & ((@as(u64, 1) << count) - 1)));
    }

    pub fn dropBits(self: *BitReader, count: u6) Error!void {
        if (count > read_bits_max) return error.InvalidBitCount;
        if (count == 0) return;

        try self.ensureBits(count);

        self.bit_buffer >>= count;
        self.bit_count = @intCast(@as(u7, self.bit_count) - @as(u7, count));
    }

    pub fn alignToByte(self: *BitReader) void {
        const unaligned_bits: u3 = @truncate(self.bit_count);
        if (unaligned_bits == 0) return;

        self.bit_buffer >>= unaligned_bits;
        self.bit_count = @intCast(@as(u7, self.bit_count) - @as(u7, unaligned_bits));
    }

    fn ensureBits(self: *BitReader, count: u6) Error!void {
        assert(count <= 32);
        if (self.bit_count >= count) return;

        const missing_bits = @as(u6, count - self.bit_count);
        const bytes_needed = (@as(usize, missing_bits) + bits_per_byte - 1) / bits_per_byte;
        if (bytes_needed > self.bytes.len - self.byte_offset) return error.TruncatedBitstream;

        var bytes_loaded: usize = 0;
        while (bytes_loaded < bytes_needed) : (bytes_loaded += 1) {
            self.bit_buffer |= @as(u64, self.bytes[self.byte_offset]) << self.bit_count;
            self.byte_offset += 1;
            self.bit_count += bits_per_byte;
        }
    }
};

comptime {
    assert(read_bits_max == 32);
    assert(bits_per_byte == 8);
    assert(buffered_bits_max == 39);
    assert(buffered_bits_max <= std.math.maxInt(u6));
    assert(buffered_bits_max < @bitSizeOf(u64));
}

test "byte reader reads little-endian values with bounds" {
    const bytes = [_]u8{
        0x11,
        0x34,
        0x12,
        0x78,
        0x56,
        0x34,
        0xef,
        0xcd,
        0xab,
        0x89,
        0x88,
        0x77,
        0x66,
        0x55,
        0x44,
        0x33,
        0x22,
        0x11,
    };
    var reader = ByteReader.init(&bytes);

    try std.testing.expectEqual(@as(u8, 0x11), try reader.readByte());
    try std.testing.expectEqual(@as(u16, 0x1234), try reader.readLittleU16());
    try std.testing.expectEqual(@as(u32, 0x345678), try reader.readLittleU24());
    try std.testing.expectEqual(@as(u32, 0x89abcdef), try reader.readLittleU32());
    try std.testing.expectEqual(@as(u64, 0x1122334455667788), try reader.readLittleU64());
    try std.testing.expect(reader.isEmpty());
}

test "byte reader returns slices and preserves state on truncation" {
    const bytes = [_]u8{ 1, 2, 3 };
    var reader = ByteReader.init(&bytes);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, try reader.readBytes(2));
    try std.testing.expectError(error.TruncatedBitstream, reader.readLittleU16());
    try std.testing.expectEqual(@as(usize, 2), reader.consumedBytes());
    try std.testing.expectEqual(@as(u8, 3), try reader.readByte());
}

test "bit reader reads least-significant bits first" {
    const bytes = [_]u8{ 0xb2, 0x61 };
    var reader = BitReader.init(&bytes);

    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u32, 1), try reader.readBits(3));
    try std.testing.expectEqual(@as(u32, 0b1011), try reader.readBits(4));
    try std.testing.expectEqual(@as(u32, 0x61), try reader.readBits(8));
    try std.testing.expectEqual(@as(usize, 2), reader.loadedBytes());
    try std.testing.expectEqual(@as(u6, 0), reader.bufferedBits());
}

test "bit reader handles zero-width and cross-byte reads" {
    const bytes = [_]u8{ 0xac, 0x03 };
    var reader = BitReader.init(&bytes);

    try std.testing.expectEqual(@as(u32, 0), try reader.readBits(0));
    try std.testing.expectEqual(@as(u32, 0b101100), try reader.readBits(6));
    try std.testing.expectEqual(@as(u32, 0b1110), try reader.readBits(4));
    reader.alignToByte();
    try std.testing.expectEqual(@as(usize, 2), reader.loadedBytes());
    try std.testing.expectEqual(@as(u6, 0), reader.bufferedBits());
}

test "bit reader peeks and drops without changing logical bit order" {
    const bytes = [_]u8{ 0x6d, 0x02 };
    var reader = BitReader.init(&bytes);

    try std.testing.expectEqual(@as(usize, 16), reader.remainingBits());
    try std.testing.expectEqual(@as(u32, 0b101), try reader.peekBits(3));
    try std.testing.expectEqual(@as(u32, 0b101), try reader.peekBits(3));
    try std.testing.expectEqual(@as(usize, 16), reader.remainingBits());
    try reader.dropBits(3);
    try std.testing.expectEqual(@as(u32, 0b1101), try reader.readBits(4));
    try std.testing.expectEqual(@as(usize, 9), reader.remainingBits());
    try reader.dropBits(9);
    try std.testing.expectEqual(@as(usize, 0), reader.remainingBits());
}

test "bit reader byte alignment preserves prefetched bytes" {
    const bytes = [_]u8{ 0xa5, 0x3c };
    var reader = BitReader.init(&bytes);

    try std.testing.expectEqual(@as(u32, 1), try reader.peekBits(1));
    try std.testing.expectEqual(@as(usize, 1), reader.loadedBytes());
    try std.testing.expectEqual(@as(u6, 8), reader.bufferedBits());
    reader.alignToByte();
    try std.testing.expectEqual(@as(usize, 1), reader.loadedBytes());
    try std.testing.expectEqual(@as(u6, 8), reader.bufferedBits());
    try std.testing.expectEqual(@as(u32, 0xa5), try reader.readBits(8));
    try std.testing.expectEqual(@as(u32, 0x3c), try reader.readBits(8));
}

test "bit reader reports invalid counts and truncation without consuming bytes" {
    const bytes = [_]u8{0x5a};
    var reader = BitReader.init(&bytes);

    try std.testing.expectError(error.InvalidBitCount, reader.readBits(33));
    try std.testing.expectError(error.TruncatedBitstream, reader.readBits(16));
    try std.testing.expectEqual(@as(usize, 0), reader.loadedBytes());
    try std.testing.expectEqual(@as(u32, 0x5a), try reader.readBits(8));
}
