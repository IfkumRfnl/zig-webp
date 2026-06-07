//! Bounded byte and LSB-first bit writers for codec bitstreams.

const std = @import("std");
const assert = std.debug.assert;

const errors = @import("errors.zig");

pub const Error = errors.Error;

pub const ByteWriter = struct {
    out: []u8,
    offset: usize = 0,

    pub fn init(out: []u8) ByteWriter {
        return .{ .out = out };
    }

    pub fn written(self: ByteWriter) []const u8 {
        assert(self.offset <= self.out.len);

        return self.out[0..self.offset];
    }

    pub fn remainingBytes(self: ByteWriter) usize {
        assert(self.offset <= self.out.len);

        return self.out.len - self.offset;
    }

    pub fn writeByte(self: *ByteWriter, value: u8) Error!void {
        try self.requireBytes(1);

        self.out[self.offset] = value;
        self.offset += 1;
    }

    pub fn writeBytes(self: *ByteWriter, bytes: []const u8) Error!void {
        try self.requireBytes(bytes.len);

        @memcpy(self.out[self.offset..][0..bytes.len], bytes);
        self.offset += bytes.len;
    }

    pub fn writeLittleU16(self: *ByteWriter, value: u16) Error!void {
        try self.requireBytes(2);

        self.out[self.offset] = @truncate(value);
        self.out[self.offset + 1] = @truncate(value >> 8);
        self.offset += 2;
    }

    pub fn writeLittleU24(self: *ByteWriter, value: u32) Error!void {
        assert(value <= 0x00ff_ffff);
        try self.requireBytes(3);

        self.out[self.offset] = @truncate(value);
        self.out[self.offset + 1] = @truncate(value >> 8);
        self.out[self.offset + 2] = @truncate(value >> 16);
        self.offset += 3;
    }

    pub fn writeLittleU32(self: *ByteWriter, value: u32) Error!void {
        try self.requireBytes(4);

        self.out[self.offset] = @truncate(value);
        self.out[self.offset + 1] = @truncate(value >> 8);
        self.out[self.offset + 2] = @truncate(value >> 16);
        self.out[self.offset + 3] = @truncate(value >> 24);
        self.offset += 4;
    }

    pub fn writeLittleU64(self: *ByteWriter, value: u64) Error!void {
        try self.requireBytes(8);

        self.out[self.offset] = @truncate(value);
        self.out[self.offset + 1] = @truncate(value >> 8);
        self.out[self.offset + 2] = @truncate(value >> 16);
        self.out[self.offset + 3] = @truncate(value >> 24);
        self.out[self.offset + 4] = @truncate(value >> 32);
        self.out[self.offset + 5] = @truncate(value >> 40);
        self.out[self.offset + 6] = @truncate(value >> 48);
        self.out[self.offset + 7] = @truncate(value >> 56);
        self.offset += 8;
    }

    fn requireBytes(self: ByteWriter, count: usize) Error!void {
        assert(self.offset <= self.out.len);
        if (count > self.out.len - self.offset) return error.OutputTooLarge;
    }
};

pub const BitWriter = struct {
    out: []u8,
    byte_offset: usize = 0,
    bit_buffer: u64 = 0,
    bit_count: u6 = 0,

    pub fn init(out: []u8) BitWriter {
        return .{ .out = out };
    }

    pub fn written(self: BitWriter) []const u8 {
        assert(self.byte_offset <= self.out.len);

        return self.out[0..self.byte_offset];
    }

    pub fn pendingBits(self: BitWriter) u6 {
        return self.bit_count;
    }

    pub fn remainingWholeBytes(self: BitWriter) usize {
        assert(self.byte_offset <= self.out.len);

        return self.out.len - self.byte_offset;
    }

    pub fn writeBit(self: *BitWriter, value: u1) Error!void {
        try self.writeBits(value, 1);
    }

    pub fn writeBits(self: *BitWriter, value: u32, count: u6) Error!void {
        if (count > 32) return error.InvalidBitCount;
        if (count == 0) return;
        if (count < 32) assert((value >> @as(u5, @intCast(count))) == 0);

        const bytes_to_flush = (@as(usize, self.bit_count) + count) / 8;
        if (bytes_to_flush > self.out.len - self.byte_offset) return error.OutputTooLarge;

        const masked_value = if (count == 32)
            @as(u64, value)
        else
            @as(u64, value) & ((@as(u64, 1) << count) - 1);
        self.bit_buffer |= masked_value << self.bit_count;
        self.bit_count += count;
        self.flushWholeBytes();
    }

    pub fn alignToByte(self: *BitWriter) Error!void {
        try self.flushZeroPad();
    }

    pub fn flushZeroPad(self: *BitWriter) Error!void {
        if (self.bit_count == 0) return;
        if (self.byte_offset == self.out.len) return error.OutputTooLarge;

        self.out[self.byte_offset] = @truncate(self.bit_buffer);
        self.byte_offset += 1;
        self.bit_buffer = 0;
        self.bit_count = 0;
    }

    pub fn finish(self: *BitWriter) Error![]const u8 {
        try self.flushZeroPad();

        return self.written();
    }

    fn flushWholeBytes(self: *BitWriter) void {
        assert(self.bit_count < 40);

        while (self.bit_count >= 8) {
            assert(self.byte_offset < self.out.len);
            self.out[self.byte_offset] = @truncate(self.bit_buffer);
            self.byte_offset += 1;
            self.bit_buffer >>= 8;
            self.bit_count = @intCast(@as(u7, self.bit_count) - 8);
        }
    }
};

test "byte writer writes little-endian values with bounds" {
    var out: [18]u8 = undefined;
    var writer = ByteWriter.init(&out);

    try writer.writeByte(0x11);
    try writer.writeLittleU16(0x1234);
    try writer.writeLittleU24(0x345678);
    try writer.writeLittleU32(0x89abcdef);
    try writer.writeLittleU64(0x1122334455667788);

    try std.testing.expectEqualSlices(u8, &.{
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
    }, writer.written());
}

test "byte writer rejects writes past the bounded output" {
    var out: [1]u8 = undefined;
    var writer = ByteWriter.init(&out);

    try std.testing.expectError(error.OutputTooLarge, writer.writeLittleU16(0x1234));
    try std.testing.expectEqual(@as(usize, 0), writer.written().len);
    try writer.writeByte(0xaa);
    try std.testing.expectEqualSlices(u8, &.{0xaa}, writer.written());
}

test "bit writer writes least-significant bits first" {
    var out: [2]u8 = undefined;
    var writer = BitWriter.init(&out);

    try writer.writeBit(0);
    try writer.writeBits(1, 3);
    try writer.writeBits(0b1011, 4);
    try writer.writeBits(0x61, 8);

    try std.testing.expectEqualSlices(u8, &.{ 0xb2, 0x61 }, try writer.finish());
    try std.testing.expectEqual(@as(u6, 0), writer.pendingBits());
}

test "bit writer pads partial bytes with zero bits" {
    var out: [1]u8 = undefined;
    var writer = BitWriter.init(&out);

    try writer.writeBits(0b101, 3);

    try std.testing.expectEqualSlices(u8, &.{0b0000_0101}, try writer.finish());
}

test "bit writer reports invalid counts and bounded-output overflow" {
    var out: [0]u8 = .{};
    var writer = BitWriter.init(&out);

    try std.testing.expectError(error.InvalidBitCount, writer.writeBits(0, 33));
    try std.testing.expectError(error.OutputTooLarge, writer.writeBits(0xff, 8));
    try std.testing.expectEqual(@as(usize, 0), writer.written().len);
    try std.testing.expectEqual(@as(u6, 0), writer.pendingBits());
}

test "bit writer output round trips through bit reader" {
    const bit_reader = @import("bit_reader.zig");
    const Item = struct {
        value: u32,
        count: u6,
    };
    const items = [_]Item{
        .{ .value = 0, .count = 0 },
        .{ .value = 1, .count = 1 },
        .{ .value = 2, .count = 2 },
        .{ .value = 0x55, .count = 7 },
        .{ .value = 0xa5, .count = 8 },
        .{ .value = 0x101, .count = 9 },
        .{ .value = 0xbeef, .count = 16 },
        .{ .value = 0x654321, .count = 23 },
        .{ .value = 0x89abcdef, .count = 32 },
    };

    var out: [16]u8 = undefined;
    var writer = BitWriter.init(&out);
    for (items) |item| {
        try writer.writeBits(item.value, item.count);
    }
    const encoded = try writer.finish();

    var reader = bit_reader.BitReader.init(encoded);
    for (items) |item| {
        try std.testing.expectEqual(item.value, try reader.readBits(item.count));
    }
}
