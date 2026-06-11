//! Bounded VP8 boolean arithmetic writer.

const std = @import("std");
const assert = std.debug.assert;

const errors = @import("../errors.zig");
const bool_reader = @import("bool_reader.zig");

pub const Error = errors.Error;
pub const Probability = bool_reader.Probability;

pub const probability_even = bool_reader.probability_even;
pub const range_min = bool_reader.range_min;
pub const range_max = bool_reader.range_max;

const bottom_carry_bit: u32 = 1 << 31;
const bottom_low_mask: u32 = (1 << 24) - 1;

pub const BoolWriter = struct {
    out: []u8,
    offset: usize = 0,
    range: u32 = range_max,
    bottom: u32 = 0,
    bit_count: u5 = 24,
    finished: bool = false,

    pub fn init(out: []u8) BoolWriter {
        return .{ .out = out };
    }

    pub fn written(self: BoolWriter) []const u8 {
        assert(self.offset <= self.out.len);

        return self.out[0..self.offset];
    }

    pub fn remainingBytes(self: BoolWriter) usize {
        assert(self.offset <= self.out.len);

        return self.out.len - self.offset;
    }

    pub fn pendingShiftCount(self: BoolWriter) u5 {
        assertValidBitCount(self.bit_count);

        return self.bit_count;
    }

    pub fn isFinished(self: BoolWriter) bool {
        return self.finished;
    }

    pub fn writeBit(self: *BoolWriter, value: u1) Error!void {
        try self.writeBool(probability_even, value);
    }

    pub fn writeBool(
        self: *BoolWriter,
        probability_zero: Probability,
        value: u1,
    ) Error!void {
        assert(!self.finished);
        assert(self.range >= range_min);
        assert(self.range <= range_max);
        assertValidBitCount(self.bit_count);

        var range_next = self.range;
        var bottom_next = self.bottom;

        const split = boolSplit(range_next, probability_zero);
        if (value == 1) {
            bottom_next += split;
            range_next -= split;
        } else {
            range_next = split;
        }

        const shift_count = normalizeShiftCount(range_next);
        const bytes_needed = outputBytesForShift(self.bit_count, shift_count);
        if (bytes_needed > self.out.len - self.offset) return error.OutputTooLarge;

        var bit_count_next = self.bit_count;
        var offset_next = self.offset;
        var shifts_done: u4 = 0;
        while (shifts_done < shift_count) : (shifts_done += 1) {
            range_next <<= 1;
            if ((bottom_next & bottom_carry_bit) != 0) {
                addOneToOutput(self.out, offset_next);
            }
            bottom_next <<= 1;

            bit_count_next -= 1;
            if (bit_count_next == 0) {
                assert(offset_next < self.out.len);
                self.out[offset_next] = @truncate(bottom_next >> 24);
                offset_next += 1;
                bottom_next &= bottom_low_mask;
                bit_count_next = 8;
            }
        }

        assert(range_next >= range_min);
        assert(range_next <= range_max);
        assertValidBitCount(bit_count_next);

        self.range = range_next;
        self.bottom = bottom_next;
        self.bit_count = bit_count_next;
        self.offset = offset_next;
    }

    pub fn writeLiteral(self: *BoolWriter, value: u32, bit_count: u6) Error!void {
        if (bit_count > 32) return error.InvalidBitCount;
        if (bit_count == 0) {
            assert(value == 0);
            return;
        }
        if (bit_count < 32) assert((value >> @as(u5, @intCast(bit_count))) == 0);

        const bytes_needed = outputBytesForLiteral(self.*, value, bit_count);
        if (bytes_needed > self.out.len - self.offset) return error.OutputTooLarge;

        var bits_remaining = bit_count;
        while (bits_remaining > 0) {
            bits_remaining -= 1;
            try self.writeBit(@intCast((value >> @as(u5, @intCast(bits_remaining))) & 1));
        }
    }

    pub fn writeSignedLiteral(self: *BoolWriter, value: i32, bit_count: u6) Error!void {
        if (bit_count > 31) return error.InvalidBitCount;
        if (bit_count == 0) {
            assert(value == 0);
            return;
        }
        assertSignedLiteralFits(value, bit_count);

        const magnitude: u32 = if (value < 0)
            @intCast(-@as(i64, value))
        else
            @intCast(value);

        const sign: u1 = if (value < 0) 1 else 0;
        const total_bits = bit_count + 1;
        const encoded = (magnitude << 1) | sign;
        const bytes_needed = outputBytesForLiteral(self.*, encoded, total_bits);
        if (bytes_needed > self.out.len - self.offset) return error.OutputTooLarge;

        try self.writeLiteral(magnitude, bit_count);
        try self.writeBit(sign);
    }

    pub fn writeProbability(self: *BoolWriter, probability: Probability) Error!void {
        try self.writeLiteral(probability, 8);
    }

    pub fn writeProbability7(self: *BoolWriter, probability: Probability) Error!void {
        assert(probability > 0);
        assert(probability <= 254);
        assert(probability == 1 or probability % 2 == 0);

        const value: u8 = if (probability == 1) 0 else probability >> 1;
        try self.writeLiteral(value, 7);
    }

    pub fn finish(self: *BoolWriter) Error![]const u8 {
        if (self.finished) return self.written();
        assert(self.range >= range_min);
        assert(self.range <= range_max);
        assertValidBitCount(self.bit_count);

        if (4 > self.out.len - self.offset) return error.OutputTooLarge;

        var value = self.bottom;
        const carry_shift: u5 = @intCast(32 - @as(u6, self.bit_count));
        if ((value & (@as(u32, 1) << carry_shift)) != 0) {
            addOneToOutput(self.out, self.offset);
        }

        value <<= @intCast(self.bit_count & 7);

        var zero_byte_count = self.bit_count >> 3;
        while (zero_byte_count > 0) : (zero_byte_count -= 1) {
            value <<= 8;
        }

        var bytes_written: u3 = 0;
        while (bytes_written < 4) : (bytes_written += 1) {
            self.out[self.offset] = @truncate(value >> 24);
            self.offset += 1;
            value <<= 8;
        }

        self.finished = true;
        return self.written();
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

fn outputBytesForShift(bit_count: u5, shift_count: u4) usize {
    assertValidBitCount(bit_count);
    assert(shift_count <= 7);
    if (shift_count < bit_count) return 0;

    return 1;
}

fn outputBytesForLiteral(writer: BoolWriter, value: u32, bit_count: u6) usize {
    assert(!writer.finished);
    assert(writer.range >= range_min);
    assert(writer.range <= range_max);
    assertValidBitCount(writer.bit_count);
    assert(bit_count <= 32);
    if (bit_count == 0) return 0;
    if (bit_count < 32) assert((value >> @as(u5, @intCast(bit_count))) == 0);

    var range = writer.range;
    var pending_shifts = writer.bit_count;
    var output_count: usize = 0;

    var bits_remaining = bit_count;
    while (bits_remaining > 0) {
        bits_remaining -= 1;
        const bit = (value >> @as(u5, @intCast(bits_remaining))) & 1;

        const split = boolSplit(range, probability_even);
        if (bit == 1) {
            range -= split;
        } else {
            range = split;
        }

        const shift_count = normalizeShiftCount(range);
        output_count += outputBytesForShift(pending_shifts, shift_count);
        range <<= shift_count;
        if (shift_count >= pending_shifts) {
            pending_shifts = 8 - @as(u5, @intCast(shift_count - pending_shifts));
        } else {
            pending_shifts -= shift_count;
        }
    }

    assert(range >= range_min);
    assert(range <= range_max);
    assertValidBitCount(pending_shifts);

    return output_count;
}

fn assertValidBitCount(bit_count: u5) void {
    assert(bit_count > 0);
    assert(bit_count <= 24);
}

fn assertSignedLiteralFits(value: i32, bit_count: u6) void {
    assert(bit_count > 0);
    assert(bit_count <= 31);

    const magnitude_max = (@as(i64, 1) << @as(u6, bit_count)) - 1;
    assert(value >= -magnitude_max);
    assert(value <= magnitude_max);
}

fn addOneToOutput(out: []u8, offset: usize) void {
    assert(offset <= out.len);

    var index = offset;
    while (index > 0) {
        index -= 1;

        if (out[index] == 0xff) {
            out[index] = 0;
        } else {
            out[index] += 1;
            return;
        }
    }
}

comptime {
    assert(range_min == 128);
    assert(range_max == 255);
    assert(probability_even == 128);
    assert(bottom_carry_bit == 0x8000_0000);
    assert(bottom_low_mask == 0x00ff_ffff);
    assert(boolSplit(range_max, 0) == 1);
    assert(boolSplit(range_max, probability_even) == 128);
    assert(boolSplit(range_max, 255) == 254);
}

test "VP8 bool writer initializes empty bounded state" {
    var out: [8]u8 = undefined;
    const writer = BoolWriter.init(&out);

    try std.testing.expectEqual(@as(usize, 0), writer.written().len);
    try std.testing.expectEqual(@as(usize, 8), writer.remainingBytes());
    try std.testing.expectEqual(@as(u5, 24), writer.pendingShiftCount());
    try std.testing.expectEqual(@as(u32, range_max), writer.range);
    try std.testing.expectEqual(@as(u32, 0), writer.bottom);
    try std.testing.expect(!writer.isFinished());
}

test "VP8 bool writer matches a known mixed probability byte sequence" {
    var out: [16]u8 = undefined;
    var writer = BoolWriter.init(&out);

    try writer.writeBit(0);
    try writer.writeBool(10, 1);
    try writer.writeBool(250, 0);
    try writer.writeLiteral(1, 1);
    try writer.writeLiteral(5, 3);
    try writer.writeLiteral(64, 8);
    try writer.writeLiteral(185, 8);

    try std.testing.expectEqualSlices(u8, &.{ 104, 101, 107, 128 }, try writer.finish());
    try std.testing.expect(writer.isFinished());
}

test "VP8 bool writer round trips mixed probability bools through reader" {
    const Item = struct {
        probability_zero: Probability,
        value: u1,
    };
    const items = [_]Item{
        .{ .probability_zero = 40, .value = 1 },
        .{ .probability_zero = 110, .value = 1 },
        .{ .probability_zero = 70, .value = 0 },
        .{ .probability_zero = 10, .value = 0 },
        .{ .probability_zero = 5, .value = 1 },
        .{ .probability_zero = 255, .value = 0 },
        .{ .probability_zero = 0, .value = 1 },
        .{ .probability_zero = 128, .value = 0 },
    };

    var out: [16]u8 = undefined;
    var writer = BoolWriter.init(&out);
    for (items) |item| {
        try writer.writeBool(item.probability_zero, item.value);
    }
    const encoded = try writer.finish();

    var reader = try bool_reader.BoolReader.init(encoded);
    for (items) |item| {
        try std.testing.expectEqual(
            item.value,
            try reader.readBool(item.probability_zero),
        );
    }
}

test "VP8 bool writer round trips a longer deterministic bool sequence" {
    const item_count = 512;
    const Item = struct {
        probability_zero: Probability,
        value: u1,
    };

    var seed: u32 = 0x1234_abcd;
    var items: [item_count]Item = undefined;
    for (&items) |*item| {
        seed = seed *% 1_664_525 +% 1_013_904_223;
        item.probability_zero = @truncate(seed >> 24);
        item.value = @truncate(seed >> 31);
    }

    var out: [1024]u8 = undefined;
    var writer = BoolWriter.init(&out);
    for (items) |item| {
        try writer.writeBool(item.probability_zero, item.value);
    }
    const encoded = try writer.finish();

    var reader = try bool_reader.BoolReader.init(encoded);
    for (items) |item| {
        try std.testing.expectEqual(
            item.value,
            try reader.readBool(item.probability_zero),
        );
    }
}

test "VP8 bool writer round trips literals and probability helpers" {
    var out: [32]u8 = undefined;
    var writer = BoolWriter.init(&out);

    try writer.writeLiteral(0, 0);
    try writer.writeLiteral(0xb0, 8);
    try writer.writeSignedLiteral(-5, 4);
    try writer.writeSignedLiteral(5, 4);
    try writer.writeSignedLiteral(0, 4);
    try writer.writeBit(1);
    try writer.writeProbability(201);
    try writer.writeProbability7(84);
    try writer.writeProbability7(1);
    const encoded = try writer.finish();

    var reader = try bool_reader.BoolReader.init(encoded);
    try std.testing.expectEqual(@as(u32, 0xb0), try reader.readLiteral(8));
    try std.testing.expectEqual(@as(i32, -5), try reader.readSignedLiteral(4));
    try std.testing.expectEqual(@as(i32, 5), try reader.readSignedLiteral(4));
    try std.testing.expectEqual(@as(i32, 0), try reader.readSignedLiteral(4));
    try std.testing.expectEqual(@as(u1, 1), try reader.readBit());
    try std.testing.expectEqual(@as(Probability, 201), try reader.readProbability());
    try std.testing.expectEqual(@as(Probability, 84), try reader.readProbability7());
    try std.testing.expectEqual(@as(Probability, 1), try reader.readProbability7());
}

test "VP8 bool writer reports invalid literal widths" {
    var out: [8]u8 = undefined;
    var writer = BoolWriter.init(&out);

    try std.testing.expectError(error.InvalidBitCount, writer.writeLiteral(0, 33));
    try std.testing.expectError(error.InvalidBitCount, writer.writeSignedLiteral(0, 32));
    try std.testing.expectError(error.InvalidBitCount, writer.writeSignedLiteral(0, 33));
}

test "VP8 bool writer reports bounded-output overflow without advancing state" {
    var out: [0]u8 = .{};
    var writer = BoolWriter.init(&out);

    try std.testing.expectError(error.OutputTooLarge, writer.writeLiteral(0, 32));
    try std.testing.expectEqual(@as(usize, 0), writer.written().len);
    try std.testing.expectEqual(@as(u5, 24), writer.pendingShiftCount());
    try std.testing.expectEqual(@as(u32, range_max), writer.range);
    try std.testing.expectEqual(@as(u32, 0), writer.bottom);

    try std.testing.expectError(error.OutputTooLarge, writer.finish());
    try std.testing.expectEqual(@as(usize, 0), writer.written().len);
    try std.testing.expect(!writer.isFinished());
}

test "VP8 bool writer direct bool overflow preserves the pending state" {
    var out: [0]u8 = .{};
    var writer = BoolWriter.init(&out);

    var write_count: u8 = 0;
    while (write_count < 64) : (write_count += 1) {
        const before = writer;
        writer.writeBit(0) catch |err| {
            try std.testing.expectEqual(error.OutputTooLarge, err);
            try std.testing.expectEqual(before.offset, writer.offset);
            try std.testing.expectEqual(before.range, writer.range);
            try std.testing.expectEqual(before.bottom, writer.bottom);
            try std.testing.expectEqual(before.bit_count, writer.bit_count);
            return;
        };
    }

    try std.testing.expect(false);
}

test "VP8 bool writer propagates carry through existing output bytes" {
    var out = [_]u8{ 0x12, 0xff, 0x00 };
    var writer = BoolWriter{
        .out = &out,
        .offset = 2,
        .range = 128,
        .bottom = bottom_carry_bit,
        .bit_count = 1,
    };

    try writer.writeBool(probability_even, 0);

    try std.testing.expectEqualSlices(u8, &.{ 0x13, 0x00, 0x00 }, writer.written());
    try std.testing.expectEqual(@as(u32, range_min), writer.range);
    try std.testing.expectEqual(@as(u5, 8), writer.pendingShiftCount());
}

test "VP8 bool writer treats carry before first output byte as a no-op" {
    var out: [1]u8 = undefined;
    var writer = BoolWriter{
        .out = &out,
        .offset = 0,
        .range = 128,
        .bottom = bottom_carry_bit,
        .bit_count = 1,
    };

    try writer.writeBool(probability_even, 0);

    try std.testing.expectEqualSlices(u8, &.{0}, writer.written());
    try std.testing.expectEqual(@as(u32, range_min), writer.range);
    try std.testing.expectEqual(@as(u5, 8), writer.pendingShiftCount());
}

test "VP8 bool writer drops carry past an all 0xff output prefix" {
    var out = [_]u8{ 0xff, 0xff, 0x00 };
    var writer = BoolWriter{
        .out = &out,
        .offset = 2,
        .range = 128,
        .bottom = bottom_carry_bit,
        .bit_count = 1,
    };

    try writer.writeBool(probability_even, 0);

    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x00, 0x00 }, writer.written());
    try std.testing.expectEqual(@as(u32, range_min), writer.range);
    try std.testing.expectEqual(@as(u5, 8), writer.pendingShiftCount());
}

test "VP8 bool writer finish is idempotent after final padding" {
    var out: [8]u8 = undefined;
    var writer = BoolWriter.init(&out);

    try writer.writeBit(1);
    const first = try writer.finish();
    const first_len = first.len;
    const second = try writer.finish();

    try std.testing.expectEqual(@as(usize, 4), first_len);
    try std.testing.expectEqualSlices(u8, first, second);
}
