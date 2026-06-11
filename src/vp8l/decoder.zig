//! Limited VP8L lossless payload decoder.

const std = @import("std");
const assert = std.debug.assert;

const bit_reader = @import("../bit_reader.zig");
const bit_writer = @import("../bit_writer.zig");
const container = @import("../container.zig");
const entropy = @import("entropy.zig");
const errors = @import("../errors.zig");
const header = @import("header.zig");
const image = @import("../image.zig");
const image_data = @import("image_data.zig");
const inverse_transform = @import("inverse_transform.zig");
const pixel = @import("pixel.zig");
const transform = @import("transform.zig");

pub const WorkBuffers = struct {
    prefix_code_group: image_data.PrefixCodeGroupBuffers = .{},
    transform_pixels: []pixel.Pixel = &.{},
};

pub const Result = struct {
    header: header.Header,
    entropy_summary: entropy.DecodeSummary,
};

const TransformData = union(enum) {
    none: void,
    block: []const pixel.Pixel,
};

const TransformPixelStore = struct {
    pixels: []pixel.Pixel,
    used: usize = 0,

    fn init(pixels: []pixel.Pixel) TransformPixelStore {
        return .{ .pixels = pixels };
    }

    fn reserve(self: *TransformPixelStore, pixel_count: u64) errors.Error![]pixel.Pixel {
        const count: usize = @intCast(pixel_count);
        if (count > self.pixels.len - self.used) return error.OutputTooLarge;

        const start = self.used;
        self.used += count;
        return self.pixels[start..self.used];
    }
};

pub fn decodeARGB(
    payload: []const u8,
    output: []pixel.Pixel,
    buffers: *WorkBuffers,
) errors.Error!Result {
    const parsed_header = try header.parse(payload);

    var reader = bit_reader.BitReader.init(payload[header.byte_count..]);
    var transform_reader = transform.ListReader.init(parsed_header.dimensions);
    var transforms: [transform.transform_count_max]transform.Transform = undefined;
    var transform_data: [transform.transform_count_max]TransformData = undefined;
    var transform_pixels = TransformPixelStore.init(buffers.transform_pixels);
    var transform_count: usize = 0;
    while (try transform_reader.readNext(&reader)) |transform_value| {
        const data: TransformData = switch (transform_value) {
            .subtract_green => .{ .none = {} },
            .color => |color_transform| .{
                .block = try decodeTransformImage(
                    &reader,
                    color_transform.image,
                    &transform_pixels,
                    &buffers.prefix_code_group,
                ),
            },
            .predictor,
            .color_indexing,
            => return error.UnsupportedVP8LImageData,
        };

        assert(transform_count < transforms.len);
        transforms[transform_count] = transform_value;
        transform_data[transform_count] = data;
        transform_count += 1;
    }

    const entropy_summary = try entropy.decodeSingleGroup(
        &reader,
        transform_reader.currentDimensions(),
        .argb,
        output,
        &buffers.prefix_code_group,
    );

    var transform_index = transform_count;
    while (transform_index > 0) {
        transform_index -= 1;
        try applyDecodedTransform(
            transforms[transform_index],
            transform_data[transform_index],
            parsed_header.dimensions,
            output,
        );
    }

    return .{
        .header = parsed_header,
        .entropy_summary = entropy_summary,
    };
}

fn decodeTransformImage(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    store: *TransformPixelStore,
    buffers: *image_data.PrefixCodeGroupBuffers,
) errors.Error![]const pixel.Pixel {
    const pixel_count = try dimensions.pixelCount();
    const pixels = try store.reserve(pixel_count);
    const summary = try entropy.decodeSingleGroup(
        reader,
        dimensions,
        .transform,
        pixels,
        buffers,
    );
    assert(summary.pixel_count == pixel_count);

    return pixels;
}

fn applyDecodedTransform(
    transform_value: transform.Transform,
    data: TransformData,
    dimensions: image.Dimensions,
    output: []pixel.Pixel,
) errors.Error!void {
    switch (transform_value) {
        .subtract_green => try inverse_transform.applyTransform(
            transform_value,
            dimensions,
            output,
        ),
        .color => |color_transform| {
            const transform_pixels = switch (data) {
                .block => |pixels| pixels,
                .none => unreachable,
            };
            try inverse_transform.applyColorTransform(
                color_transform,
                transform_pixels,
                dimensions,
                output,
            );
        },
        .predictor,
        .color_indexing,
        => unreachable,
    }
}

fn writeHeader(
    payload: *[header.byte_count]u8,
    width: u32,
    height: u32,
    has_alpha: bool,
) void {
    assert(width > 0);
    assert(width <= header.dimension_limit);
    assert(height > 0);
    assert(height <= header.dimension_limit);

    payload[0] = header.signature;
    const bits = (width - 1) |
        ((height - 1) << 14) |
        (@as(u32, @intFromBool(has_alpha)) << 28);
    container.writeLittleU32(payload[1..header.byte_count], bits);
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

fn writeConstantPrefixCodeGroup(
    writer: *bit_writer.BitWriter,
    green_symbol: u8,
    red_symbol: u8,
    blue_symbol: u8,
    alpha_symbol: u8,
) errors.Error!void {
    try writeSimplePrefixCode(writer, green_symbol);
    try writeSimplePrefixCode(writer, red_symbol);
    try writeSimplePrefixCode(writer, blue_symbol);
    try writeSimplePrefixCode(writer, alpha_symbol);
    try writeSimplePrefixCode(writer, 0);
}

test "VP8L decoder materializes a no-transform single-group payload" {
    var payload: [header.byte_count + 16]u8 = undefined;
    writeHeader(payload[0..header.byte_count], 2, 1, false);

    var writer = bit_writer.BitWriter.init(payload[header.byte_count..]);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeLiteralOnlyPrefixCodeGroup(&writer);
    const image_data_bytes = try writer.finish();
    const payload_len = header.byte_count + image_data_bytes.len;

    var buffers: WorkBuffers = .{};
    var output: [2]pixel.Pixel = undefined;
    const result = try decodeARGB(payload[0..payload_len], &output, &buffers);

    try std.testing.expectEqual(@as(u32, 2), result.header.dimensions.width);
    try std.testing.expectEqual(@as(u32, 1), result.header.dimensions.height);
    try std.testing.expectEqual(@as(u64, 2), result.entropy_summary.pixel_count);
    try std.testing.expectEqual(pixel.fromChannels(0, 0, 1, 0), output[0]);
    try std.testing.expectEqual(pixel.fromChannels(0, 0, 1, 0), output[1]);
}

test "VP8L decoder applies subtract-green inverse transform" {
    var payload: [header.byte_count + 32]u8 = undefined;
    writeHeader(payload[0..header.byte_count], 1, 1, false);

    var writer = bit_writer.BitWriter.init(payload[header.byte_count..]);
    try writer.writeBit(1);
    try writer.writeBits(@intFromEnum(transform.Kind.subtract_green), 2);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeConstantPrefixCodeGroup(&writer, 3, 2, 4, 1);
    const image_data_bytes = try writer.finish();
    const payload_len = header.byte_count + image_data_bytes.len;

    var buffers: WorkBuffers = .{};
    var output: [1]pixel.Pixel = undefined;
    const result = try decodeARGB(payload[0..payload_len], &output, &buffers);

    try std.testing.expectEqual(@as(u64, 1), result.entropy_summary.pixel_count);
    try std.testing.expectEqual(pixel.fromChannels(1, 5, 3, 7), output[0]);
}

test "VP8L decoder applies color inverse transform data" {
    var payload: [header.byte_count + 96]u8 = undefined;
    writeHeader(payload[0..header.byte_count], 1, 1, false);

    var writer = bit_writer.BitWriter.init(payload[header.byte_count..]);
    try writer.writeBit(1);
    try writer.writeBits(@intFromEnum(transform.Kind.color), 2);
    try writer.writeBits(0, 3);

    try writer.writeBit(0);
    try writeConstantPrefixCodeGroup(&writer, 64, 32, 32, 255);

    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeConstantPrefixCodeGroup(&writer, 5, 10, 20, 7);
    const image_data_bytes = try writer.finish();
    const payload_len = header.byte_count + image_data_bytes.len;

    var transform_pixels: [1]pixel.Pixel = undefined;
    var buffers = WorkBuffers{ .transform_pixels = &transform_pixels };
    var output: [1]pixel.Pixel = undefined;
    const result = try decodeARGB(payload[0..payload_len], &output, &buffers);

    try std.testing.expectEqual(@as(u64, 1), result.entropy_summary.pixel_count);
    try std.testing.expectEqual(pixel.fromChannels(7, 15, 5, 45), output[0]);
}

test "VP8L decoder requires storage for color transform data" {
    var payload: [header.byte_count + 1]u8 = undefined;
    writeHeader(payload[0..header.byte_count], 1, 1, false);

    var writer = bit_writer.BitWriter.init(payload[header.byte_count..]);
    try writer.writeBit(1);
    try writer.writeBits(@intFromEnum(transform.Kind.color), 2);
    try writer.writeBits(0, 3);
    const image_data_bytes = try writer.finish();
    const payload_len = header.byte_count + image_data_bytes.len;

    var buffers: WorkBuffers = .{};
    var output: [1]pixel.Pixel = undefined;
    try std.testing.expectError(
        error.OutputTooLarge,
        decodeARGB(payload[0..payload_len], &output, &buffers),
    );
}

test "VP8L decoder reports unimplemented transforms as unsupported" {
    var payload: [header.byte_count + 1]u8 = undefined;
    writeHeader(payload[0..header.byte_count], 1, 1, false);

    var writer = bit_writer.BitWriter.init(payload[header.byte_count..]);
    try writer.writeBit(1);
    try writer.writeBits(@intFromEnum(transform.Kind.predictor), 2);
    try writer.writeBits(0, 3);
    const image_data_bytes = try writer.finish();
    const payload_len = header.byte_count + image_data_bytes.len;

    var buffers: WorkBuffers = .{};
    var output: [1]pixel.Pixel = undefined;
    try std.testing.expectError(
        error.UnsupportedVP8LImageData,
        decodeARGB(payload[0..payload_len], &output, &buffers),
    );
}
