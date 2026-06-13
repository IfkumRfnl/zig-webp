//! Public static image decode composition.

const std = @import("std");
const assert = std.debug.assert;

const bit_writer = @import("bit_writer.zig");
const container = @import("container.zig");
const demux = @import("demux.zig");
const errors = @import("errors.zig");
const image = @import("image.zig");
const mux = @import("mux.zig");
const options = @import("options.zig");
const vp8l_decoder = @import("vp8l/decoder.zig");
const vp8l_header = @import("vp8l/header.zig");
const vp8l_pixel = @import("vp8l/pixel.zig");

pub fn decodeStatic(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    decode_options: options.DecoderOptions,
) errors.Error!image.OwnedBuffer {
    var parsed = try demux.parse(gpa, bytes, .{
        .limits = decode_options.limits,
    });
    defer parsed.deinit();

    if (parsed.features.is_animation) return error.UnsupportedAnimationDecode;

    const format = parsed.features.format orelse return error.MissingImageData;
    if (format != .lossless) return error.UnsupportedImageFormat;

    const image_chunk = parsed.features.image_data orelse return error.MissingImageData;
    const payload = image_chunk.payload(bytes);
    const dimensions = parsed.features.canvas;
    const pixel_count = try dimensions.pixelCount();

    var allocation_bytes: u64 = 0;
    const argb_count = try reserveElements(
        vp8l_pixel.Pixel,
        pixel_count,
        &allocation_bytes,
        decode_options,
    );
    const transform_count = try reserveElements(
        vp8l_pixel.Pixel,
        try transformPixelCapacity(pixel_count),
        &allocation_bytes,
        decode_options,
    );
    const entropy_count = try reserveElements(
        vp8l_pixel.Pixel,
        pixel_count,
        &allocation_bytes,
        decode_options,
    );
    const output_len = try outputByteLength(dimensions, decode_options.output_format);
    const output_count = try reserveElements(u8, output_len, &allocation_bytes, decode_options);

    const argb_pixels = try gpa.alloc(vp8l_pixel.Pixel, argb_count);
    defer gpa.free(argb_pixels);

    const transform_pixels = try gpa.alloc(vp8l_pixel.Pixel, transform_count);
    defer gpa.free(transform_pixels);

    const entropy_image = try gpa.alloc(vp8l_pixel.Pixel, entropy_count);
    defer gpa.free(entropy_image);

    const out = try gpa.alloc(u8, output_count);
    errdefer gpa.free(out);

    var work_buffers = vp8l_decoder.WorkBuffers{
        .transform_pixels = transform_pixels,
        .entropy_image = entropy_image,
        .prefix_group_options = .{
            .allocation_bytes_max = decode_options.limits.allocation_bytes_max - allocation_bytes,
        },
    };
    _ = try vp8l_decoder.decodeARGBAlloc(gpa, payload, argb_pixels, &work_buffers);

    writePixels(out, decode_options.output_format, argb_pixels);

    const stride: u32 = @intCast(try rowByteLength(dimensions, decode_options.output_format));
    return .{
        .gpa = gpa,
        .buffer = .{
            .pixels = out,
            .dimensions = dimensions,
            .stride = stride,
            .format = decode_options.output_format,
        },
    };
}

fn reserveElements(
    comptime T: type,
    count: u64,
    allocation_bytes: *u64,
    decode_options: options.DecoderOptions,
) errors.Error!usize {
    if (count > std.math.maxInt(usize)) return error.AllocationLimitExceeded;
    if (count > std.math.maxInt(u64) / @sizeOf(T)) return error.AllocationLimitExceeded;

    const bytes = count * @sizeOf(T);
    if (bytes > std.math.maxInt(u64) - allocation_bytes.*) {
        return error.AllocationLimitExceeded;
    }

    allocation_bytes.* += bytes;
    try decode_options.limits.validateAllocationBytes(allocation_bytes.*);

    return @intCast(count);
}

fn transformPixelCapacity(pixel_count: u64) errors.Error!u64 {
    if (pixel_count > std.math.maxInt(u64) - 257) return error.AllocationLimitExceeded;

    return pixel_count + 257;
}

fn outputByteLength(
    dimensions: image.Dimensions,
    format: image.PixelFormat,
) errors.Error!u64 {
    const row_bytes = try rowByteLength(dimensions, format);
    const height: u64 = @intCast(dimensions.height);
    if (height > 0 and row_bytes > std.math.maxInt(u64) / height) {
        return error.AllocationLimitExceeded;
    }

    return row_bytes * height;
}

fn rowByteLength(
    dimensions: image.Dimensions,
    format: image.PixelFormat,
) errors.Error!u64 {
    const row_bytes = @as(u64, dimensions.width) * @as(u64, format.channelCount());
    if (row_bytes > std.math.maxInt(u32)) return error.OutputTooLarge;

    return row_bytes;
}

fn writePixels(
    out: []u8,
    format: image.PixelFormat,
    argb_pixels: []const vp8l_pixel.Pixel,
) void {
    const channel_count: usize = @intCast(format.channelCount());
    assert(out.len == argb_pixels.len * channel_count);

    var pixel_index: usize = 0;
    while (pixel_index < argb_pixels.len) : (pixel_index += 1) {
        writePixel(
            out[pixel_index * channel_count ..][0..channel_count],
            format,
            argb_pixels[pixel_index],
        );
    }
}

fn writePixel(out: []u8, format: image.PixelFormat, value: vp8l_pixel.Pixel) void {
    switch (format) {
        .rgb => {
            assert(out.len == 3);
            out[0] = vp8l_pixel.red(value);
            out[1] = vp8l_pixel.green(value);
            out[2] = vp8l_pixel.blue(value);
        },
        .rgba => {
            assert(out.len == 4);
            out[0] = vp8l_pixel.red(value);
            out[1] = vp8l_pixel.green(value);
            out[2] = vp8l_pixel.blue(value);
            out[3] = vp8l_pixel.alpha(value);
        },
        .bgra => {
            assert(out.len == 4);
            out[0] = vp8l_pixel.blue(value);
            out[1] = vp8l_pixel.green(value);
            out[2] = vp8l_pixel.red(value);
            out[3] = vp8l_pixel.alpha(value);
        },
        .argb => {
            assert(out.len == 4);
            out[0] = vp8l_pixel.alpha(value);
            out[1] = vp8l_pixel.red(value);
            out[2] = vp8l_pixel.green(value);
            out[3] = vp8l_pixel.blue(value);
        },
    }
}

fn writeVP8LHeader(
    payload: *[vp8l_header.byte_count]u8,
    width: u32,
    height: u32,
    has_alpha: bool,
) void {
    assert(width > 0);
    assert(height > 0);

    payload[0] = vp8l_header.signature;
    const bits = (width - 1) |
        ((height - 1) << 14) |
        (@as(u32, @intFromBool(has_alpha)) << 28);
    container.writeLittleU32(payload[1..vp8l_header.byte_count], bits);
}

fn writeSimplePrefixCode(writer: *bit_writer.BitWriter, symbol: u8) errors.Error!void {
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(if (symbol <= 1) 0 else 1);
    try writer.writeBits(symbol, if (symbol <= 1) 1 else 8);
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

fn makeConstantVP8L(
    out: []u8,
    dimensions: image.Dimensions,
    value: vp8l_pixel.Pixel,
) errors.Error![]const u8 {
    if (out.len < vp8l_header.byte_count) return error.OutputTooLarge;

    writeVP8LHeader(
        out[0..vp8l_header.byte_count],
        dimensions.width,
        dimensions.height,
        vp8l_pixel.alpha(value) != 255,
    );

    var writer = bit_writer.BitWriter.init(out[vp8l_header.byte_count..]);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeConstantPrefixCodeGroup(
        &writer,
        vp8l_pixel.green(value),
        vp8l_pixel.red(value),
        vp8l_pixel.blue(value),
        vp8l_pixel.alpha(value),
    );
    const image_data = try writer.finish();

    return out[0 .. vp8l_header.byte_count + image_data.len];
}

fn makeMetaPrefixVP8L(out: []u8, dimensions: image.Dimensions) errors.Error![]const u8 {
    if (out.len < vp8l_header.byte_count) return error.OutputTooLarge;

    writeVP8LHeader(out[0..vp8l_header.byte_count], dimensions.width, dimensions.height, false);

    var writer = bit_writer.BitWriter.init(out[vp8l_header.byte_count..]);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(1);
    try writer.writeBits(0, 3);

    try writer.writeBit(0);
    try writeConstantPrefixCodeGroup(&writer, 0, 0, 0, 0);

    try writeConstantPrefixCodeGroup(&writer, 2, 1, 3, 4);
    const image_data = try writer.finish();

    return out[0 .. vp8l_header.byte_count + image_data.len];
}

test "decodes a simple lossless WebP to RGBA" {
    const dimensions = try image.Dimensions.init(2, 1);
    var vp8l_payload: [32]u8 = undefined;
    const bitstream = try makeConstantVP8L(
        &vp8l_payload,
        dimensions,
        vp8l_pixel.fromChannels(4, 1, 2, 3),
    );
    const encoded = try mux.encodeStatic(std.testing.allocator, .{
        .canvas = dimensions,
        .format = .lossless,
        .bitstream = bitstream,
        .has_alpha = true,
    }, .{});
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeStatic(std.testing.allocator, encoded, .{});
    defer decoded.deinit();

    try std.testing.expectEqual(dimensions, decoded.buffer.dimensions);
    try std.testing.expectEqual(image.PixelFormat.rgba, decoded.buffer.format);
    try std.testing.expectEqual(@as(u32, 8), decoded.buffer.stride);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 1, 2, 3, 4 }, decoded.buffer.pixels);
}

test "decodes a simple lossless WebP to requested BGRA" {
    const dimensions = try image.Dimensions.init(1, 1);
    var vp8l_payload: [32]u8 = undefined;
    const bitstream = try makeConstantVP8L(
        &vp8l_payload,
        dimensions,
        vp8l_pixel.fromChannels(4, 1, 2, 3),
    );
    const encoded = try mux.encodeStatic(std.testing.allocator, .{
        .canvas = dimensions,
        .format = .lossless,
        .bitstream = bitstream,
        .has_alpha = true,
    }, .{});
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeStatic(std.testing.allocator, encoded, .{
        .output_format = .bgra,
    });
    defer decoded.deinit();

    try std.testing.expectEqual(image.PixelFormat.bgra, decoded.buffer.format);
    try std.testing.expectEqualSlices(u8, &.{ 3, 2, 1, 4 }, decoded.buffer.pixels);
}

test "static decode rejects unsupported lossy WebP" {
    const vp8 = [_]u8{ 0x10, 0, 0, 0x9d, 0x01, 0x2a, 1, 0, 1, 0 };
    const encoded = try mux.encodeStatic(std.testing.allocator, .{
        .canvas = try image.Dimensions.init(1, 1),
        .format = .lossy,
        .bitstream = &vp8,
    }, .{});
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(
        error.UnsupportedImageFormat,
        decodeStatic(std.testing.allocator, encoded, .{}),
    );
}

test "static decode applies allocation limit to meta-prefix group storage" {
    const dimensions = try image.Dimensions.init(3, 1);
    var vp8l_payload: [64]u8 = undefined;
    const bitstream = try makeMetaPrefixVP8L(&vp8l_payload, dimensions);
    const encoded = try mux.encodeStatic(std.testing.allocator, .{
        .canvas = dimensions,
        .format = .lossless,
        .bitstream = bitstream,
    }, .{});
    defer std.testing.allocator.free(encoded);

    try std.testing.expectError(
        error.AllocationLimitExceeded,
        decodeStatic(std.testing.allocator, encoded, .{
            .limits = .{
                .allocation_bytes_max = 2_000,
            },
        }),
    );
}

test "fuzz public static decode" {
    const testing_fuzz = @import("testing/fuzz.zig");

    const dimensions = try image.Dimensions.init(2, 1);
    var vp8l_payload: [32]u8 = undefined;
    const bitstream = try makeConstantVP8L(
        &vp8l_payload,
        dimensions,
        vp8l_pixel.fromChannels(4, 1, 2, 3),
    );
    const encoded = try mux.encodeStatic(std.testing.allocator, .{
        .canvas = dimensions,
        .format = .lossless,
        .bitstream = bitstream,
        .has_alpha = true,
    }, .{});
    defer std.testing.allocator.free(encoded);

    var seed_buffer: [128]u8 = undefined;
    const seed = testing_fuzz.sliceCorpusEntry(&seed_buffer, encoded);

    try std.testing.fuzz({}, fuzzDecodeStaticOne, .{ .corpus = &.{seed} });
}

fn fuzzDecodeStaticOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [2048]u8 = undefined;
    const input_len = smith.slice(&input_buffer);

    var decoded = decodeStatic(std.testing.allocator, input_buffer[0..input_len], .{
        .limits = .{
            .output_pixels_max = 1 << 16,
            .allocation_bytes_max = 1 << 22,
        },
    }) catch return;
    decoded.deinit();
}

fn decodeStaticAllocationProbe(gpa: std.mem.Allocator, encoded: []const u8) !void {
    var decoded = try decodeStatic(gpa, encoded, .{});
    decoded.deinit();
}

test "static decode survives allocation failure at every site" {
    const dimensions = try image.Dimensions.init(2, 1);
    var vp8l_payload: [32]u8 = undefined;
    const bitstream = try makeConstantVP8L(
        &vp8l_payload,
        dimensions,
        vp8l_pixel.fromChannels(4, 1, 2, 3),
    );
    const encoded = try mux.encodeStatic(std.testing.allocator, .{
        .canvas = dimensions,
        .format = .lossless,
        .bitstream = bitstream,
        .has_alpha = true,
    }, .{});
    defer std.testing.allocator.free(encoded);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeStaticAllocationProbe,
        .{encoded},
    );
}

test "meta-prefix static decode survives allocation failure at every site" {
    const dimensions = try image.Dimensions.init(3, 1);
    var vp8l_payload: [64]u8 = undefined;
    const bitstream = try makeMetaPrefixVP8L(&vp8l_payload, dimensions);
    const encoded = try mux.encodeStatic(std.testing.allocator, .{
        .canvas = dimensions,
        .format = .lossless,
        .bitstream = bitstream,
    }, .{});
    defer std.testing.allocator.free(encoded);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodeStaticAllocationProbe,
        .{encoded},
    );
}
