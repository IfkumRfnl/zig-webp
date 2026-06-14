//! Public static image decode composition.

const std = @import("std");
const assert = std.debug.assert;

const alpha = @import("alpha.zig");
const bit_writer = @import("bit_writer.zig");
const color = @import("color.zig");
const container = @import("container.zig");
const demux = @import("demux.zig");
const errors = @import("errors.zig");
const features = @import("features.zig");
const image = @import("image.zig");
const mux = @import("mux.zig");
const options = @import("options.zig");
const vp8_decoder = @import("vp8/decoder.zig");
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
    const image_chunk = parsed.features.image_data orelse return error.MissingImageData;

    return decodeImage(gpa, .{
        .format = format,
        .bitstream = image_chunk.payload(bytes),
        .alpha = if (parsed.features.alpha) |location| location.payload(bytes) else null,
        .dimensions = parsed.features.canvas,
    }, decode_options);
}

/// A single still image's bitstream plus the chunk-level context needed to
/// decode it, independent of how the container located them. Both the public
/// static decode path and the per-frame animation decoder build one of these
/// and hand it to `decodeImage`, so animation reuses the still codecs through
/// this interface rather than reaching into VP8/VP8L internals.
pub const ImageSource = struct {
    /// Lossy (`VP8 `) or lossless (`VP8L`) coding of `bitstream`.
    format: features.FormatKind,
    /// The raw VP8/VP8L bitstream payload (without its RIFF chunk header).
    bitstream: []const u8,
    /// Optional separate ALPH payload. Only meaningful for lossy images;
    /// lossless carries its own alpha and ignores this field.
    alpha: ?[]const u8 = null,
    /// Output dimensions. Must equal the bitstream's own dimensions; the
    /// container guarantees this for stills and for animation frame rects.
    dimensions: image.Dimensions,
};

/// Decodes one still image (lossy or lossless, with optional separate ALPH)
/// into an owned pixel buffer in `decode_options.output_format`. This is the
/// shared primitive behind `decodeStatic` and per-frame animation decode.
/// The caller frees the result via `OwnedBuffer.deinit`.
pub fn decodeImage(
    gpa: std.mem.Allocator,
    source: ImageSource,
    decode_options: options.DecoderOptions,
) errors.Error!image.OwnedBuffer {
    return switch (source.format) {
        .lossless => decodeLossless(gpa, source, decode_options),
        .lossy => decodeLossy(gpa, source, decode_options),
    };
}

fn decodeLossless(
    gpa: std.mem.Allocator,
    source: ImageSource,
    decode_options: options.DecoderOptions,
) errors.Error!image.OwnedBuffer {
    const payload = source.bitstream;
    const dimensions = source.dimensions;
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

fn decodeLossy(
    gpa: std.mem.Allocator,
    source: ImageSource,
    decode_options: options.DecoderOptions,
) errors.Error!image.OwnedBuffer {
    const dimensions = source.dimensions;
    const format = decode_options.output_format;

    var allocation_bytes: u64 = 0;
    const output_len = try outputByteLength(dimensions, format);
    const output_count = try reserveElements(u8, output_len, &allocation_bytes, decode_options);

    // Reconstruct the YUV planes (key-frame decode through the in-loop filter,
    // matching plain `dwebp`). The frame's own dimensions equal `dimensions`:
    // the container rejects any canvas/rect that disagrees with the VP8 header.
    var frame = try vp8_decoder.decodeFrame(gpa, source.bitstream, .{
        .apply_loop_filter = true,
    });
    defer frame.deinit();

    const out = try gpa.alloc(u8, output_count);
    errdefer gpa.free(out);

    const stride: u32 = @intCast(try rowByteLength(dimensions, format));

    color.upsampleFancy(format, .{
        .luma = frame.luma,
        .chroma_u = frame.chroma_u,
        .chroma_v = frame.chroma_v,
        .luma_stride = frame.luma_stride,
        .chroma_stride = frame.chroma_stride,
        .width = frame.width,
        .height = frame.height,
    }, out, stride);

    // `upsampleFancy` writes opaque alpha; compose the decoded ALPH plane over
    // it when the file carries one and the output format has an alpha channel.
    // RGB output drops alpha, matching libwebp.
    if (format.channelCount() == 4) {
        if (source.alpha) |alpha_payload| {
            const pixel_count: usize = @intCast(try dimensions.pixelCount());
            const alpha_count = try reserveElements(u8, pixel_count, &allocation_bytes, decode_options);
            const alpha_plane = try gpa.alloc(u8, alpha_count);
            defer gpa.free(alpha_plane);
            _ = try alpha.decodePlaneAlloc(gpa, alpha_payload, dimensions, alpha_plane);
            composeAlpha(out, format, stride, dimensions, alpha_plane);
        }
    }

    return .{
        .gpa = gpa,
        .buffer = .{
            .pixels = out,
            .dimensions = dimensions,
            .stride = stride,
            .format = format,
        },
    };
}

/// Overwrites the alpha channel of a freshly converted lossy frame with the
/// decoded ALPH plane (one byte per pixel, row-major). The plane is placed
/// verbatim; lossy WebP carries straight (non-premultiplied) alpha, so RGB is
/// left untouched.
fn composeAlpha(
    out: []u8,
    format: image.PixelFormat,
    stride: u32,
    dimensions: image.Dimensions,
    alpha_plane: []const u8,
) void {
    const channels = 4;
    const alpha_offset: usize = switch (format) {
        .rgba, .bgra => 3,
        .argb => 0,
        .rgb => unreachable,
    };

    const width: usize = dimensions.width;
    const height: usize = dimensions.height;
    assert(alpha_plane.len == width * height);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const out_row = out[y * stride ..][0 .. width * channels];
        const alpha_row = alpha_plane[y * width ..][0..width];
        for (alpha_row, 0..) |sample, x| {
            out_row[x * channels + alpha_offset] = sample;
        }
    }
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

test "decodeImage decodes a raw lossless bitstream without a container" {
    const dimensions = try image.Dimensions.init(2, 1);
    var vp8l_payload: [32]u8 = undefined;
    const bitstream = try makeConstantVP8L(
        &vp8l_payload,
        dimensions,
        vp8l_pixel.fromChannels(4, 1, 2, 3),
    );

    // Feed the primitive the raw VP8L bitstream directly (no RIFF wrapper), as
    // the animation frame decoder will once it locates a frame's sub-chunk.
    var decoded = try decodeImage(std.testing.allocator, .{
        .format = .lossless,
        .bitstream = bitstream,
        .dimensions = dimensions,
    }, .{});
    defer decoded.deinit();

    try std.testing.expectEqual(dimensions, decoded.buffer.dimensions);
    try std.testing.expectEqual(image.PixelFormat.rgba, decoded.buffer.format);
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

test "decodes a lossy WebP to opaque RGBA" {
    const corpus = @import("testing/corpus.zig");

    const bytes = corpus.readFileAlloc(std.testing.allocator, "test.webp", .{}) catch |err| switch (err) {
        error.CorpusUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(bytes);

    var decoded = try decodeStatic(std.testing.allocator, bytes, .{});
    defer decoded.deinit();

    try std.testing.expectEqual(image.PixelFormat.rgba, decoded.buffer.format);

    // A plain lossy file carries no ALPH chunk, so every pixel stays opaque.
    var i: usize = 3;
    while (i < decoded.buffer.pixels.len) : (i += 4) {
        try std.testing.expectEqual(@as(u8, 255), decoded.buffer.pixels[i]);
    }
}

test "composes alpha over lossy color" {
    const corpus = @import("testing/corpus.zig");

    const bytes = corpus.readFileAlloc(std.testing.allocator, "lossy_alpha1.webp", .{}) catch |err| switch (err) {
        error.CorpusUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(bytes);

    var decoded = try decodeStatic(std.testing.allocator, bytes, .{});
    defer decoded.deinit();

    try std.testing.expectEqual(image.PixelFormat.rgba, decoded.buffer.format);

    // Independently decode the ALPH plane and confirm every output alpha byte
    // matches it: composition must place the decoded plane verbatim.
    var parsed = try demux.parse(std.testing.allocator, bytes, .{});
    defer parsed.deinit();

    const location = parsed.features.alpha orelse return error.TestUnexpectedResult;
    const dimensions = parsed.features.canvas;
    const pixel_count: usize = @intCast(try dimensions.pixelCount());

    const plane = try std.testing.allocator.alloc(u8, pixel_count);
    defer std.testing.allocator.free(plane);
    _ = try alpha.decodePlaneAlloc(std.testing.allocator, location.payload(bytes), dimensions, plane);

    for (plane, 0..) |expected, idx| {
        try std.testing.expectEqual(expected, decoded.buffer.pixels[idx * 4 + 3]);
    }
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
