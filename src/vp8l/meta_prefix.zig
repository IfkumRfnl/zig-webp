//! VP8L meta-prefix entropy image parsing.

const std = @import("std");
const assert = std.debug.assert;

const bit_reader = @import("../bit_reader.zig");
const bit_writer = @import("../bit_writer.zig");
const entropy = @import("entropy.zig");
const errors = @import("../errors.zig");
const huffman = @import("huffman.zig");
const image = @import("../image.zig");
const image_data = @import("image_data.zig");
const pixel = @import("pixel.zig");

pub const prefix_bits_min: u4 = 2;
pub const prefix_bits_max: u4 = 9;
pub const group_count_max: u32 = 1 << 16;

pub const Info = struct {
    prefix_bits: u4,
    block_size: u32,
    image_dimensions: image.Dimensions,
    entropy_dimensions: image.Dimensions,
    group_count: u32,

    pub fn groupIndex(
        self: Info,
        entropy_image: []const pixel.Pixel,
        x: u32,
        y: u32,
    ) errors.Error!u16 {
        if (x >= self.image_dimensions.width) return error.InvalidVP8LImageData;
        if (y >= self.image_dimensions.height) return error.InvalidVP8LImageData;

        const pixel_count = try self.entropy_dimensions.pixelCount();
        if (entropy_image.len < pixel_count) return error.InvalidVP8LImageData;

        const entropy_x = x >> self.prefix_bits;
        const entropy_y = y >> self.prefix_bits;
        assert(entropy_x < self.entropy_dimensions.width);
        assert(entropy_y < self.entropy_dimensions.height);

        const entropy_index = @as(usize, entropy_y) *
            @as(usize, self.entropy_dimensions.width) +
            @as(usize, entropy_x);
        assert(entropy_index < entropy_image.len);

        return code(entropy_image[entropy_index]);
    }
};

pub fn readEntropyImage(
    reader: *bit_reader.BitReader,
    image_dimensions: image.Dimensions,
    entropy_image: []pixel.Pixel,
    buffers: *image_data.PrefixCodeGroupBuffers,
) errors.Error!Info {
    const prefix_bits: u4 = @intCast((try reader.readBits(3)) + prefix_bits_min);
    assert(prefix_bits >= prefix_bits_min);
    assert(prefix_bits <= prefix_bits_max);

    const block_size = @as(u32, 1) << @as(u5, prefix_bits);
    const entropy_dimensions = try image.Dimensions.init(
        divRoundUp(image_dimensions.width, block_size),
        divRoundUp(image_dimensions.height, block_size),
    );
    const entropy_pixel_count = try entropy_dimensions.pixelCount();
    if (entropy_image.len < entropy_pixel_count) return error.OutputTooLarge;

    const summary = try entropy.decodeSingleGroup(
        reader,
        entropy_dimensions,
        .transform,
        entropy_image[0..@intCast(entropy_pixel_count)],
        buffers,
    );
    assert(summary.pixel_count == entropy_pixel_count);

    return .{
        .prefix_bits = prefix_bits,
        .block_size = block_size,
        .image_dimensions = image_dimensions,
        .entropy_dimensions = entropy_dimensions,
        .group_count = groupCount(entropy_image[0..@intCast(entropy_pixel_count)]),
    };
}

pub fn code(value: pixel.Pixel) u16 {
    return (@as(u16, pixel.red(value)) << 8) | @as(u16, pixel.green(value));
}

fn groupCount(entropy_image: []const pixel.Pixel) u32 {
    assert(entropy_image.len > 0);

    var group_index_max: u16 = 0;
    for (entropy_image) |value| {
        group_index_max = @max(group_index_max, code(value));
    }

    return @as(u32, group_index_max) + 1;
}

fn divRoundUp(numerator: u32, denominator: u32) u32 {
    assert(numerator > 0);
    assert(denominator > 0);

    return ((numerator - 1) / denominator) + 1;
}

fn writeSimplePrefixCode(writer: *bit_writer.BitWriter, symbol: u8) errors.Error!void {
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(if (symbol <= 1) 0 else 1);
    try writer.writeBits(symbol, if (symbol <= 1) 1 else 8);
}

fn writeLiteralOnlyPrefixCodeGroup(writer: *bit_writer.BitWriter) errors.Error!void {
    var code_index: usize = 0;
    while (code_index < image_data.prefix_code_count) : (code_index += 1) {
        try writeSimplePrefixCode(writer, @intFromBool(code_index == 0));
    }
}

comptime {
    assert(prefix_bits_min == 2);
    assert(prefix_bits_max == prefix_bits_min + 7);
    assert(group_count_max == 65_536);
    assert(huffman.literal_alphabet_size == 256);
}

test "VP8L meta-prefix entropy image decodes group count" {
    var encoded: [16]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBits(0, 3);
    try writer.writeBit(0);
    try writeLiteralOnlyPrefixCodeGroup(&writer);

    var reader = bit_reader.BitReader.init(try writer.finish());
    var buffers: image_data.PrefixCodeGroupBuffers = .{};
    var entropy_pixels: [1]pixel.Pixel = undefined;
    const info = try readEntropyImage(
        &reader,
        try image.Dimensions.init(3, 3),
        &entropy_pixels,
        &buffers,
    );

    try std.testing.expectEqual(@as(u4, 2), info.prefix_bits);
    try std.testing.expectEqual(@as(u32, 4), info.block_size);
    try std.testing.expectEqual(@as(u32, 1), info.entropy_dimensions.width);
    try std.testing.expectEqual(@as(u32, 1), info.entropy_dimensions.height);
    try std.testing.expectEqual(@as(u32, 2), info.group_count);
    try std.testing.expectEqual(@as(u16, 1), try info.groupIndex(&entropy_pixels, 2, 2));
}

test "VP8L meta-prefix group lookup uses entropy image blocks" {
    const info = Info{
        .prefix_bits = 2,
        .block_size = 4,
        .image_dimensions = try image.Dimensions.init(9, 5),
        .entropy_dimensions = try image.Dimensions.init(3, 2),
        .group_count = 6,
    };
    const entropy_pixels = [_]pixel.Pixel{
        pixel.fromChannels(0, 0, 0, 0),
        pixel.fromChannels(0, 0, 1, 0),
        pixel.fromChannels(0, 0, 2, 0),
        pixel.fromChannels(0, 0, 3, 0),
        pixel.fromChannels(0, 0, 4, 0),
        pixel.fromChannels(0, 0, 5, 0),
    };

    try std.testing.expectEqual(@as(u16, 0), try info.groupIndex(&entropy_pixels, 0, 0));
    try std.testing.expectEqual(@as(u16, 1), try info.groupIndex(&entropy_pixels, 4, 0));
    try std.testing.expectEqual(@as(u16, 2), try info.groupIndex(&entropy_pixels, 8, 0));
    try std.testing.expectEqual(@as(u16, 4), try info.groupIndex(&entropy_pixels, 4, 4));
    try std.testing.expectError(
        error.InvalidVP8LImageData,
        info.groupIndex(&entropy_pixels, 9, 0),
    );
}

test "VP8L meta-prefix code uses red high byte and green low byte" {
    const value = pixel.fromChannels(0xaa, 0x12, 0x34, 0x56);

    try std.testing.expectEqual(@as(u16, 0x1234), code(value));
}
