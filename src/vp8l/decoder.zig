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
const meta_prefix = @import("meta_prefix.zig");
const pixel = @import("pixel.zig");
const prefix_groups = @import("prefix_groups.zig");
const transform = @import("transform.zig");

pub const WorkBuffers = struct {
    prefix_code_group: image_data.PrefixCodeGroupBuffers = .{},
    prefix_groups: prefix_groups.WorkBuffers = .{},
    prefix_group_options: prefix_groups.Options = .{},
    entropy_image: []pixel.Pixel = &.{},
    transform_pixels: []pixel.Pixel = &.{},
};

pub const Result = struct {
    header: header.Header,
    entropy_summary: entropy.DecodeSummary,
};

const TransformData = union(enum) {
    none: void,
    block: []const pixel.Pixel,
    color_table: []const pixel.Pixel,
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
    return decodeARGBInternal(null, payload, output, buffers);
}

pub fn decodeARGBAlloc(
    gpa: std.mem.Allocator,
    payload: []const u8,
    output: []pixel.Pixel,
    buffers: *WorkBuffers,
) errors.Error!Result {
    return decodeARGBInternal(gpa, payload, output, buffers);
}

/// Decodes a headerless VP8L image-data stream (transform list included)
/// with externally supplied dimensions, as used by VP8L-compressed ALPH
/// chunk payloads.
pub fn decodeImageStream(
    data: []const u8,
    dimensions: image.Dimensions,
    output: []pixel.Pixel,
    buffers: *WorkBuffers,
) errors.Error!entropy.DecodeSummary {
    return decodeImageStreamInternal(null, data, dimensions, output, buffers);
}

pub fn decodeImageStreamAlloc(
    gpa: std.mem.Allocator,
    data: []const u8,
    dimensions: image.Dimensions,
    output: []pixel.Pixel,
    buffers: *WorkBuffers,
) errors.Error!entropy.DecodeSummary {
    return decodeImageStreamInternal(gpa, data, dimensions, output, buffers);
}

fn decodeARGBInternal(
    gpa: ?std.mem.Allocator,
    payload: []const u8,
    output: []pixel.Pixel,
    buffers: *WorkBuffers,
) errors.Error!Result {
    const parsed_header = try header.parse(payload);
    const entropy_summary = try decodeImageStreamInternal(
        gpa,
        payload[header.byte_count..],
        parsed_header.dimensions,
        output,
        buffers,
    );

    return .{
        .header = parsed_header,
        .entropy_summary = entropy_summary,
    };
}

fn decodeImageStreamInternal(
    gpa: ?std.mem.Allocator,
    stream: []const u8,
    dimensions: image.Dimensions,
    output: []pixel.Pixel,
    buffers: *WorkBuffers,
) errors.Error!entropy.DecodeSummary {
    var reader = bit_reader.BitReader.init(stream);
    var transform_reader = transform.ListReader.init(dimensions);
    var transforms: [transform.transform_count_max]transform.Transform = undefined;
    var transform_data: [transform.transform_count_max]TransformData = undefined;
    var transform_dimensions: [transform.transform_count_max]image.Dimensions = undefined;
    var transform_pixels = TransformPixelStore.init(buffers.transform_pixels);
    var transform_count: usize = 0;
    while (true) {
        const dimensions_before = transform_reader.currentDimensions();
        const transform_value = (try transform_reader.readNext(&reader)) orelse break;
        const data: TransformData = switch (transform_value) {
            .subtract_green => .{ .none = {} },
            .predictor => |predictor_transform| .{
                .block = try decodeTransformImage(
                    &reader,
                    predictor_transform.image,
                    &transform_pixels,
                    &buffers.prefix_code_group,
                ),
            },
            .color => |color_transform| .{
                .block = try decodeTransformImage(
                    &reader,
                    color_transform.image,
                    &transform_pixels,
                    &buffers.prefix_code_group,
                ),
            },
            .color_indexing => |color_indexing| .{
                .color_table = try decodeColorTable(
                    &reader,
                    color_indexing,
                    &transform_pixels,
                    &buffers.prefix_code_group,
                ),
            },
        };

        assert(transform_count < transforms.len);
        transforms[transform_count] = transform_value;
        transform_data[transform_count] = data;
        transform_dimensions[transform_count] = dimensions_before;
        transform_count += 1;
    }

    const entropy_summary = try decodeMainImage(
        gpa,
        &reader,
        transform_reader.currentDimensions(),
        output,
        buffers,
    );

    var transform_index = transform_count;
    while (transform_index > 0) {
        transform_index -= 1;
        try applyDecodedTransform(
            transforms[transform_index],
            transform_data[transform_index],
            transform_dimensions[transform_index],
            output,
        );
    }

    return entropy_summary;
}

fn decodeMainImage(
    gpa: ?std.mem.Allocator,
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    output: []pixel.Pixel,
    buffers: *WorkBuffers,
) errors.Error!entropy.DecodeSummary {
    const color_cache = try image_data.readColorCache(reader);
    const meta_prefix_present = try reader.readBit();
    if (meta_prefix_present == 0) {
        const prefix_codes = try image_data.readPrefixCodeGroup(
            reader,
            image_data.colorCacheSize(color_cache),
            &buffers.prefix_code_group,
        );

        return entropy.decodeWithPrefixCodes(
            reader,
            dimensions,
            color_cache,
            prefix_codes,
            output,
        );
    }

    const allocator = gpa orelse return error.UnsupportedVP8LImageData;
    const info = try meta_prefix.readEntropyImage(
        reader,
        dimensions,
        buffers.entropy_image,
        &buffers.prefix_code_group,
    );
    var group_store = try prefix_groups.Store.readAll(
        allocator,
        reader,
        info.group_count,
        image_data.colorCacheSize(color_cache),
        buffers.prefix_group_options,
        &buffers.prefix_groups,
    );
    defer group_store.deinit();

    return entropy.decodeWithGroupStore(
        reader,
        dimensions,
        color_cache,
        group_store,
        info,
        buffers.entropy_image,
        output,
    );
}

fn decodeTransformImage(
    reader: *bit_reader.BitReader,
    dimensions: image.Dimensions,
    store: *TransformPixelStore,
    buffers: *image_data.PrefixCodeGroupBuffers,
) errors.Error![]pixel.Pixel {
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

fn decodeColorTable(
    reader: *bit_reader.BitReader,
    color_indexing: transform.ColorIndexing,
    store: *TransformPixelStore,
    buffers: *image_data.PrefixCodeGroupBuffers,
) errors.Error![]const pixel.Pixel {
    const pixels = try decodeTransformImage(
        reader,
        color_indexing.color_table,
        store,
        buffers,
    );
    inverse_transform.applyColorTableDeltas(pixels);

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
                .none,
                .color_table,
                => unreachable,
            };
            try inverse_transform.applyColorTransform(
                color_transform,
                transform_pixels,
                dimensions,
                output,
            );
        },
        .predictor => |predictor_transform| {
            const transform_pixels = switch (data) {
                .block => |pixels| pixels,
                .none,
                .color_table,
                => unreachable,
            };
            try inverse_transform.applyPredictorTransform(
                predictor_transform,
                transform_pixels,
                dimensions,
                output,
            );
        },
        .color_indexing => |color_indexing| {
            const color_table = switch (data) {
                .color_table => |pixels| pixels,
                .none,
                .block,
                => unreachable,
            };
            try inverse_transform.applyColorIndexingTransform(
                color_indexing,
                color_table,
                dimensions,
                output,
            );
        },
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

test "VP8L decoder materializes a main-image meta-prefix payload" {
    var payload: [header.byte_count + 64]u8 = undefined;
    writeHeader(payload[0..header.byte_count], 3, 1, false);

    var writer = bit_writer.BitWriter.init(payload[header.byte_count..]);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(1);
    try writer.writeBits(0, 3);

    try writer.writeBit(0);
    try writeConstantPrefixCodeGroup(&writer, 0, 0, 0, 0);

    try writeConstantPrefixCodeGroup(&writer, 2, 1, 3, 4);
    const image_data_bytes = try writer.finish();
    const payload_len = header.byte_count + image_data_bytes.len;

    var unsupported_buffers: WorkBuffers = .{};
    var unsupported_output: [3]pixel.Pixel = undefined;
    try std.testing.expectError(
        error.UnsupportedVP8LImageData,
        decodeARGB(payload[0..payload_len], &unsupported_output, &unsupported_buffers),
    );

    var entropy_image: [1]pixel.Pixel = undefined;
    var buffers = WorkBuffers{ .entropy_image = &entropy_image };
    var output: [3]pixel.Pixel = undefined;
    const result = try decodeARGBAlloc(
        std.testing.allocator,
        payload[0..payload_len],
        &output,
        &buffers,
    );

    try std.testing.expectEqual(@as(u64, 3), result.entropy_summary.pixel_count);
    try std.testing.expectEqual(pixel.fromChannels(4, 1, 2, 3), output[0]);
    try std.testing.expectEqual(pixel.fromChannels(4, 1, 2, 3), output[1]);
    try std.testing.expectEqual(pixel.fromChannels(4, 1, 2, 3), output[2]);
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

test "VP8L decoder applies predictor inverse transform data" {
    var payload: [header.byte_count + 96]u8 = undefined;
    writeHeader(payload[0..header.byte_count], 3, 2, false);

    var writer = bit_writer.BitWriter.init(payload[header.byte_count..]);
    try writer.writeBit(1);
    try writer.writeBits(@intFromEnum(transform.Kind.predictor), 2);
    try writer.writeBits(0, 3);

    try writer.writeBit(0);
    try writeConstantPrefixCodeGroup(&writer, 7, 0, 0, 0);

    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeConstantPrefixCodeGroup(&writer, 10, 10, 10, 0);
    const image_data_bytes = try writer.finish();
    const payload_len = header.byte_count + image_data_bytes.len;

    var transform_pixels: [1]pixel.Pixel = undefined;
    var buffers = WorkBuffers{ .transform_pixels = &transform_pixels };
    var output: [6]pixel.Pixel = undefined;
    const result = try decodeARGB(payload[0..payload_len], &output, &buffers);

    try std.testing.expectEqual(@as(u64, 6), result.entropy_summary.pixel_count);
    try std.testing.expectEqual(pixel.fromChannels(255, 10, 10, 10), output[0]);
    try std.testing.expectEqual(pixel.fromChannels(255, 20, 20, 20), output[1]);
    try std.testing.expectEqual(pixel.fromChannels(255, 30, 30, 30), output[2]);
    try std.testing.expectEqual(pixel.fromChannels(255, 20, 20, 20), output[3]);
    try std.testing.expectEqual(pixel.fromChannels(255, 30, 30, 30), output[4]);
    try std.testing.expectEqual(pixel.fromChannels(255, 40, 40, 40), output[5]);
}

test "VP8L decoder applies color-indexing with reduced-dimension predictor data" {
    var payload: [header.byte_count + 160]u8 = undefined;
    writeHeader(payload[0..header.byte_count], 5, 1, false);

    var writer = bit_writer.BitWriter.init(payload[header.byte_count..]);
    try writer.writeBit(1);
    try writer.writeBits(@intFromEnum(transform.Kind.color_indexing), 2);
    try writer.writeBits(3, 8);

    try writer.writeBit(0);
    try writeConstantPrefixCodeGroup(&writer, 0, 10, 0, 0);

    try writer.writeBit(1);
    try writer.writeBits(@intFromEnum(transform.Kind.predictor), 2);
    try writer.writeBits(0, 3);

    try writer.writeBit(0);
    try writeConstantPrefixCodeGroup(&writer, 1, 0, 0, 0);

    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeConstantPrefixCodeGroup(&writer, 1, 0, 0, 1);
    const image_data_bytes = try writer.finish();
    const payload_len = header.byte_count + image_data_bytes.len;

    var transform_pixels: [5]pixel.Pixel = undefined;
    var buffers = WorkBuffers{ .transform_pixels = &transform_pixels };
    var output: [5]pixel.Pixel = undefined;
    const result = try decodeARGB(payload[0..payload_len], &output, &buffers);

    try std.testing.expectEqual(@as(u64, 2), result.entropy_summary.pixel_count);
    try std.testing.expectEqual(pixel.fromChannels(0, 20, 0, 0), output[0]);
    try std.testing.expectEqual(pixel.fromChannels(0, 10, 0, 0), output[1]);
    try std.testing.expectEqual(pixel.fromChannels(0, 10, 0, 0), output[2]);
    try std.testing.expectEqual(pixel.fromChannels(0, 10, 0, 0), output[3]);
    try std.testing.expectEqual(pixel.fromChannels(0, 30, 0, 0), output[4]);
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

test "VP8L decoder requires storage for color-indexing transform data" {
    var payload: [header.byte_count + 2]u8 = undefined;
    writeHeader(payload[0..header.byte_count], 1, 1, false);

    var writer = bit_writer.BitWriter.init(payload[header.byte_count..]);
    try writer.writeBit(1);
    try writer.writeBits(@intFromEnum(transform.Kind.color_indexing), 2);
    try writer.writeBits(0, 8);
    const image_data_bytes = try writer.finish();
    const payload_len = header.byte_count + image_data_bytes.len;

    var buffers: WorkBuffers = .{};
    var output: [1]pixel.Pixel = undefined;
    try std.testing.expectError(
        error.OutputTooLarge,
        decodeARGB(payload[0..payload_len], &output, &buffers),
    );
}

test "fuzz VP8L still-image decode" {
    const testing_fuzz = @import("../testing/fuzz.zig");

    var payload: [header.byte_count + 16]u8 = undefined;
    writeHeader(payload[0..header.byte_count], 2, 1, false);
    var writer = bit_writer.BitWriter.init(payload[header.byte_count..]);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeLiteralOnlyPrefixCodeGroup(&writer);
    const image_data_bytes = try writer.finish();
    const payload_len = header.byte_count + image_data_bytes.len;

    var seed_buffer: [payload.len + testing_fuzz.slice_length_prefix_size]u8 = undefined;
    const seed = testing_fuzz.sliceCorpusEntry(&seed_buffer, payload[0..payload_len]);

    try std.testing.fuzz({}, fuzzDecodeARGBOne, .{ .corpus = &.{seed} });
}

const fuzz_pixel_count_max = 1 << 12;

fn fuzzDecodeARGBOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [1024]u8 = undefined;
    const input_len = smith.slice(&input_buffer);
    const payload = input_buffer[0..input_len];

    const parsed_header = header.parse(payload) catch return;
    const pixel_count = parsed_header.dimensions.pixelCount() catch return;
    if (pixel_count > fuzz_pixel_count_max) return;

    const gpa = std.testing.allocator;
    const count: usize = @intCast(pixel_count);
    const output = try gpa.alloc(pixel.Pixel, count);
    defer gpa.free(output);
    const transform_pixels = try gpa.alloc(pixel.Pixel, count + 257);
    defer gpa.free(transform_pixels);
    const entropy_pixels = try gpa.alloc(pixel.Pixel, count);
    defer gpa.free(entropy_pixels);

    var buffers = WorkBuffers{
        .transform_pixels = transform_pixels,
        .entropy_image = entropy_pixels,
        .prefix_group_options = .{ .allocation_bytes_max = 1 << 20 },
    };
    _ = decodeARGBAlloc(gpa, payload, output, &buffers) catch return;
}
