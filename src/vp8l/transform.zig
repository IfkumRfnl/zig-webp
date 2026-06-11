//! VP8L lossless transform header parsing and dimension bookkeeping.

const std = @import("std");
const assert = std.debug.assert;

const bit_reader = @import("../bit_reader.zig");
const bit_writer = @import("../bit_writer.zig");
const errors = @import("../errors.zig");
const image = @import("../image.zig");

pub const transform_count_max = 4;
pub const block_bits_min: u4 = 2;
pub const block_bits_max: u4 = 9;
pub const color_table_size_max = 256;

pub const Kind = enum(u2) {
    predictor = 0,
    color = 1,
    subtract_green = 2,
    color_indexing = 3,
};

pub const BlockTransform = struct {
    block_bits: u4,
    block_size: u32,
    image: image.Dimensions,
};

pub const ColorIndexing = struct {
    color_table_size: u16,
    width_bits: u2,
    color_table: image.Dimensions,
    image_after: image.Dimensions,
};

pub const Transform = union(Kind) {
    predictor: BlockTransform,
    color: BlockTransform,
    subtract_green: void,
    color_indexing: ColorIndexing,
};

pub const ListReader = struct {
    image_current: image.Dimensions,
    seen_mask: u4 = 0,
    count: u3 = 0,
    finished: bool = false,

    pub fn init(dimensions: image.Dimensions) ListReader {
        return .{ .image_current = dimensions };
    }

    pub fn currentDimensions(self: ListReader) image.Dimensions {
        return self.image_current;
    }

    pub fn readNext(
        self: *ListReader,
        reader: *bit_reader.BitReader,
    ) errors.Error!?Transform {
        if (self.finished) return null;

        const transform_present = try reader.readBit();
        if (transform_present == 0) {
            self.finished = true;

            return null;
        }

        if (self.count == transform_count_max) return error.InvalidVP8LTransform;

        const kind: Kind = @enumFromInt(@as(u2, @intCast(try reader.readBits(2))));
        const mask = kindMask(kind);
        if ((self.seen_mask & mask) != 0) return error.InvalidVP8LTransform;

        const transform = try self.readTransform(reader, kind);

        self.seen_mask |= mask;
        self.count += 1;
        switch (transform) {
            .color_indexing => |color_indexing| {
                self.image_current = color_indexing.image_after;
            },
            .predictor,
            .color,
            .subtract_green,
            => {},
        }

        return transform;
    }

    fn readTransform(
        self: ListReader,
        reader: *bit_reader.BitReader,
        kind: Kind,
    ) errors.Error!Transform {
        return switch (kind) {
            .predictor => .{
                .predictor = try readBlockTransform(reader, self.image_current),
            },
            .color => .{
                .color = try readBlockTransform(reader, self.image_current),
            },
            .subtract_green => .{ .subtract_green = {} },
            .color_indexing => .{
                .color_indexing = try readColorIndexing(reader, self.image_current),
            },
        };
    }
};

comptime {
    assert(transform_count_max == 4);
    assert(block_bits_min == 2);
    assert(block_bits_max == block_bits_min + 7);
    assert(color_table_size_max == 256);
}

fn readBlockTransform(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
) errors.Error!BlockTransform {
    const block_bits: u4 = @intCast((try reader.readBits(3)) + block_bits_min);
    assert(block_bits >= block_bits_min);
    assert(block_bits <= block_bits_max);

    const block_size = @as(u32, 1) << @as(u5, block_bits);

    return .{
        .block_bits = block_bits,
        .block_size = block_size,
        .image = try image.Dimensions.init(
            divRoundUp(dimensions.width, block_size),
            divRoundUp(dimensions.height, block_size),
        ),
    };
}

fn readColorIndexing(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
) errors.Error!ColorIndexing {
    const color_table_size: u16 = @intCast((try reader.readBits(8)) + 1);
    assert(color_table_size > 0);
    assert(color_table_size <= color_table_size_max);

    const width_bits = colorTableWidthBits(color_table_size);
    const width_scale = @as(u32, 1) << @as(u5, width_bits);

    return .{
        .color_table_size = color_table_size,
        .width_bits = width_bits,
        .color_table = try image.Dimensions.init(color_table_size, 1),
        .image_after = try image.Dimensions.init(
            divRoundUp(dimensions.width, width_scale),
            dimensions.height,
        ),
    };
}

fn colorTableWidthBits(color_table_size: u16) u2 {
    assert(color_table_size > 0);
    assert(color_table_size <= color_table_size_max);

    if (color_table_size <= 2) return 3;
    if (color_table_size <= 4) return 2;
    if (color_table_size <= 16) return 1;

    return 0;
}

fn divRoundUp(numerator: u32, denominator: u32) u32 {
    assert(numerator > 0);
    assert(denominator > 0);

    return ((numerator - 1) / denominator) + 1;
}

fn kindMask(kind: Kind) u4 {
    return @as(u4, 1) << @as(u2, @intFromEnum(kind));
}

fn writeTransformKind(writer: *bit_writer.BitWriter, kind: Kind) errors.Error!void {
    try writer.writeBit(1);
    try writer.writeBits(@intFromEnum(kind), 2);
}

test "VP8L transform list accepts an empty transform sequence" {
    var reader = bit_reader.BitReader.init(&.{0});
    var transform_reader = ListReader.init(try image.Dimensions.init(17, 5));

    try std.testing.expectEqual(@as(?Transform, null), try transform_reader.readNext(&reader));
    try std.testing.expect(transform_reader.finished);
    try std.testing.expectEqual(@as(u3, 0), transform_reader.count);
    try std.testing.expectEqual(@as(u32, 17), transform_reader.currentDimensions().width);
    try std.testing.expectEqual(@as(u32, 5), transform_reader.currentDimensions().height);
}

test "VP8L transform list parses subtract-green and terminates" {
    var bytes: [1]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&bytes);
    try writeTransformKind(&writer, .subtract_green);
    try writer.writeBit(0);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var transform_reader = ListReader.init(try image.Dimensions.init(17, 5));

    const transform = (try transform_reader.readNext(&reader)).?;
    switch (transform) {
        .subtract_green => {},
        .predictor,
        .color,
        .color_indexing,
        => return error.InvalidVP8LTransform,
    }

    try std.testing.expectEqual(@as(?Transform, null), try transform_reader.readNext(&reader));
    try std.testing.expect(transform_reader.finished);
    try std.testing.expectEqual(@as(u3, 1), transform_reader.count);
    try std.testing.expectEqual(@as(u32, 17), transform_reader.currentDimensions().width);
    try std.testing.expectEqual(@as(u32, 5), transform_reader.currentDimensions().height);
}

test "VP8L transform list parses predictor block metadata" {
    var bytes: [1]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&bytes);
    try writeTransformKind(&writer, .predictor);
    try writer.writeBits(3, 3);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var transform_reader = ListReader.init(try image.Dimensions.init(17, 33));

    const transform = (try transform_reader.readNext(&reader)).?;
    switch (transform) {
        .predictor => |predictor| {
            try std.testing.expectEqual(@as(u4, 5), predictor.block_bits);
            try std.testing.expectEqual(@as(u32, 32), predictor.block_size);
            try std.testing.expectEqual(@as(u32, 1), predictor.image.width);
            try std.testing.expectEqual(@as(u32, 2), predictor.image.height);
        },
        .color,
        .subtract_green,
        .color_indexing,
        => return error.InvalidVP8LTransform,
    }
}

test "VP8L transform list parses color indexing and updates dimensions" {
    var bytes: [2]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&bytes);
    try writeTransformKind(&writer, .color_indexing);
    try writer.writeBits(3, 8);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var transform_reader = ListReader.init(try image.Dimensions.init(17, 5));

    const transform = (try transform_reader.readNext(&reader)).?;
    switch (transform) {
        .color_indexing => |color_indexing| {
            try std.testing.expectEqual(@as(u16, 4), color_indexing.color_table_size);
            try std.testing.expectEqual(@as(u2, 2), color_indexing.width_bits);
            try std.testing.expectEqual(@as(u32, 4), color_indexing.color_table.width);
            try std.testing.expectEqual(@as(u32, 1), color_indexing.color_table.height);
            try std.testing.expectEqual(@as(u32, 5), color_indexing.image_after.width);
            try std.testing.expectEqual(@as(u32, 5), color_indexing.image_after.height);
        },
        .predictor,
        .color,
        .subtract_green,
        => return error.InvalidVP8LTransform,
    }

    try std.testing.expectEqual(@as(u32, 5), transform_reader.currentDimensions().width);
    try std.testing.expectEqual(@as(u32, 5), transform_reader.currentDimensions().height);
}

test "VP8L transform list rejects duplicate transform kinds" {
    var bytes: [1]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&bytes);
    try writeTransformKind(&writer, .subtract_green);
    try writeTransformKind(&writer, .subtract_green);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var transform_reader = ListReader.init(try image.Dimensions.init(1, 1));

    _ = try transform_reader.readNext(&reader);
    try std.testing.expectError(
        error.InvalidVP8LTransform,
        transform_reader.readNext(&reader),
    );
}

test "VP8L transform list preserves state on truncated transform presence" {
    var reader = bit_reader.BitReader.init(&.{});
    var transform_reader = ListReader.init(try image.Dimensions.init(1, 1));

    try std.testing.expectError(
        error.TruncatedBitstream,
        transform_reader.readNext(&reader),
    );
    try std.testing.expectEqual(@as(u3, 0), transform_reader.count);
    try std.testing.expect(!transform_reader.finished);
}
