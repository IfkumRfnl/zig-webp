//! Bounded VP8 boolean arithmetic reader.

const std = @import("std");
const assert = std.debug.assert;

const errors = @import("../errors.zig");

pub const Error = errors.Error;
pub const Probability = u8;

pub const probability_even: Probability = 128;
pub const range_min = 128;
pub const range_max = 255;

pub const BoolReader = struct {
    bytes: []const u8,
    offset: usize,
    range: u32,
    value: u32,
    bit_count: u4,

    pub fn init(bytes: []const u8) Error!BoolReader {
        if (bytes.len < 2) return error.TruncatedBitstream;

        return .{
            .bytes = bytes,
            .offset = 2,
            .range = range_max,
            .value = (@as(u32, bytes[0]) << 8) | bytes[1],
            .bit_count = 0,
        };
    }

    pub fn loadedBytes(self: BoolReader) usize {
        assert(self.offset <= self.bytes.len);

        return self.offset;
    }

    pub fn remainingBytes(self: BoolReader) usize {
        assert(self.offset <= self.bytes.len);

        return self.bytes.len - self.offset;
    }

    pub fn shiftedBits(self: BoolReader) u4 {
        assert(self.bit_count < 8);

        return self.bit_count;
    }

    pub fn readBit(self: *BoolReader) Error!u1 {
        return self.readBool(probability_even);
    }

    pub fn readBool(self: *BoolReader, probability_zero: Probability) Error!u1 {
        assert(self.range >= range_min);
        assert(self.range <= range_max);
        assert(self.bit_count < 8);

        const split = boolSplit(self.range, probability_zero);
        const split_scaled = split << 8;

        var range_next = self.range;
        var value_next = self.value;
        const bit: u1 = if (value_next >= split_scaled) bit: {
            range_next -= split;
            value_next -= split_scaled;
            break :bit 1;
        } else bit: {
            range_next = split;
            break :bit 0;
        };

        const shift_count = normalizeShiftCount(range_next);
        const needs_byte = @as(u5, self.bit_count) + shift_count >= 8;
        if (needs_byte) {
            if (self.offset == self.bytes.len) return error.TruncatedBitstream;
        }

        var bit_count_next = self.bit_count;
        var offset_next = self.offset;
        var shifts_done: u4 = 0;
        while (shifts_done < shift_count) : (shifts_done += 1) {
            value_next <<= 1;
            range_next <<= 1;
            bit_count_next += 1;

            if (bit_count_next == 8) {
                assert(offset_next < self.bytes.len);
                value_next |= self.bytes[offset_next];
                offset_next += 1;
                bit_count_next = 0;
            }
        }

        assert(range_next >= range_min);
        assert(range_next <= range_max);
        assert(bit_count_next < 8);

        self.range = range_next;
        self.value = value_next;
        self.bit_count = bit_count_next;
        self.offset = offset_next;

        return bit;
    }

    pub fn readLiteral(self: *BoolReader, bit_count: u6) Error!u32 {
        if (bit_count > 32) return error.InvalidBitCount;

        var reader_next = self.*;
        var value: u64 = 0;
        var bits_read: u6 = 0;
        while (bits_read < bit_count) : (bits_read += 1) {
            value = (value << 1) | @as(u64, try reader_next.readBit());
        }

        self.* = reader_next;
        return @intCast(value);
    }

    pub fn readSignedLiteral(self: *BoolReader, bit_count: u6) Error!i32 {
        if (bit_count > 31) return error.InvalidBitCount;
        if (bit_count == 0) return 0;

        var reader_next = self.*;
        const magnitude = try reader_next.readLiteral(bit_count);
        const sign = try reader_next.readBit();
        const value: i32 = @intCast(magnitude);
        const signed_value = if (sign == 1) -value else value;

        self.* = reader_next;
        return signed_value;
    }

    pub fn readProbability(self: *BoolReader) Error!Probability {
        return @intCast(try self.readLiteral(8));
    }

    pub fn readProbability7(self: *BoolReader) Error!Probability {
        const value: u8 = @intCast(try self.readLiteral(7));
        if (value == 0) return 1;

        return @intCast(@as(u16, value) << 1);
    }
};

fn boolSplit(range: u32, probability_zero: Probability) u32 {
    assert(range >= range_min);
    assert(range <= range_max);

    const split = 1 + (((range - 1) * probability_zero) >> 8);
    assert(split > 0);
    assert(split < range);

    return split;
}

fn normalizeShiftCount(range: u32) u4 {
    assert(range > 0);
    assert(range <= range_max);
    if (range >= range_min) return 0;

    var shifted_range = range;
    var shift_count: u4 = 0;
    while (shifted_range < range_min) : (shift_count += 1) {
        shifted_range <<= 1;
    }

    assert(shift_count <= 7);
    assert(shifted_range >= range_min);
    assert(shifted_range <= range_max);

    return shift_count;
}

comptime {
    assert(range_min == 128);
    assert(range_max == 255);
    assert(probability_even == 128);
    assert(boolSplit(range_max, 0) == 1);
    assert(boolSplit(range_max, probability_even) == 128);
    assert(boolSplit(range_max, 255) == 254);
}

test "VP8 bool reader initializes from the first sixteen input bits" {
    const bytes = [_]u8{ 0x12, 0x34, 0x56 };
    var reader = try BoolReader.init(&bytes);

    try std.testing.expectEqual(@as(usize, 2), reader.loadedBytes());
    try std.testing.expectEqual(@as(usize, 1), reader.remainingBytes());
    try std.testing.expectEqual(@as(u4, 0), reader.shiftedBits());
    try std.testing.expectEqual(@as(u32, range_max), reader.range);
    try std.testing.expectEqual(@as(u32, 0x1234), reader.value);
}

test "VP8 bool reader requires two bytes of initial value" {
    try std.testing.expectError(error.TruncatedBitstream, BoolReader.init(&.{}));
    try std.testing.expectError(error.TruncatedBitstream, BoolReader.init(&.{0}));
}

test "VP8 bool reader reads even-probability flags from high-order input bits" {
    const bytes = [_]u8{ 0xb0, 0x00, 0x00 };
    var reader = try BoolReader.init(&bytes);

    try std.testing.expectEqual(@as(u32, 0b1011), try reader.readLiteral(4));
    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
    try std.testing.expectEqual(@as(u1, 0), try reader.readBit());
}

test "VP8 bool reader handles biased probabilities" {
    var low_reader = try BoolReader.init(&.{ 0x01, 0x00 });
    try std.testing.expectEqual(@as(u1, 1), try low_reader.readBool(0));

    var high_reader = try BoolReader.init(&.{ 0xfe, 0x01 });
    try std.testing.expectEqual(@as(u1, 1), try high_reader.readBool(255));

    var zero_reader = try BoolReader.init(&.{ 0x00, 0xff });
    try std.testing.expectEqual(@as(u1, 0), try zero_reader.readBool(0));
}

test "VP8 bool reader reads signed literals and probability helpers" {
    var signed_reader = try BoolReader.init(&.{ 0x5c, 0x00, 0x00 });
    try std.testing.expectEqual(@as(i32, -5), try signed_reader.readSignedLiteral(4));
    try std.testing.expectEqual(@as(u1, 1), try signed_reader.readBit());

    var zero_signed_reader = try BoolReader.init(&.{ 0x04, 0x00, 0x00 });
    try std.testing.expectEqual(@as(i32, 0), try zero_signed_reader.readSignedLiteral(4));
    try std.testing.expectEqual(@as(u1, 1), try zero_signed_reader.readBit());

    var probability_reader = try BoolReader.init(&.{ 0x54, 0x00, 0x00 });
    try std.testing.expectEqual(@as(Probability, 84), try probability_reader.readProbability7());

    var zero_probability_reader = try BoolReader.init(&.{ 0x00, 0x00, 0x00 });
    try std.testing.expectEqual(
        @as(Probability, 1),
        try zero_probability_reader.readProbability7(),
    );
}

test "VP8 bool reader reports invalid literal widths" {
    var reader = try BoolReader.init(&.{ 0x00, 0x00, 0x00 });

    try std.testing.expectError(error.InvalidBitCount, reader.readLiteral(33));
    try std.testing.expectError(error.InvalidBitCount, reader.readSignedLiteral(32));
    try std.testing.expectError(error.InvalidBitCount, reader.readSignedLiteral(33));
}

test "VP8 bool reader reports truncation without advancing state" {
    const bytes = [_]u8{ 0x00, 0x00 };
    var reader = try BoolReader.init(&bytes);

    try std.testing.expectError(error.TruncatedBitstream, reader.readLiteral(9));
    try std.testing.expectEqual(@as(usize, 2), reader.loadedBytes());
    try std.testing.expectEqual(@as(u4, 0), reader.shiftedBits());

    try std.testing.expectEqual(@as(u32, 0), try reader.readLiteral(8));
    try std.testing.expectEqual(@as(usize, 2), reader.loadedBytes());
    try std.testing.expectEqual(@as(u4, 7), reader.shiftedBits());

    try std.testing.expectError(error.TruncatedBitstream, reader.readBit());
    try std.testing.expectEqual(@as(usize, 2), reader.loadedBytes());
    try std.testing.expectEqual(@as(u4, 7), reader.shiftedBits());
}
