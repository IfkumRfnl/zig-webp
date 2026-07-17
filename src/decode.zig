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
const vp8_frame_header = @import("vp8/frame_header.zig");
const vp8l_decoder = @import("vp8l/decoder.zig");
const vp8l_header = @import("vp8l/header.zig");
const vp8l_pixel = @import("vp8l/pixel.zig");

/// Shared demux prologue for the public static decode entry points: parses
/// the container, rejects animations, and locates the still bitstream. The
/// returned `ImageSource` borrows only from `bytes` (chunk payloads are
/// slices of the input), so the demux result is torn down before returning.
fn parseStaticSource(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    decode_options: options.DecoderOptions,
) errors.Error!ImageSource {
    var parsed = try demux.parse(gpa, bytes, .{
        .limits = decode_options.limits,
    });
    defer parsed.deinit();

    if (parsed.features.is_animation) return error.UnsupportedAnimationDecode;

    const format = parsed.features.format orelse return error.MissingImageData;
    const image_chunk = parsed.features.image_data orelse return error.MissingImageData;

    return .{
        .format = format,
        .bitstream = image_chunk.payload(bytes),
        .alpha = if (parsed.features.alpha) |location| location.payload(bytes) else null,
        .dimensions = parsed.features.canvas,
    };
}

pub fn decodeStatic(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    decode_options: options.DecoderOptions,
) errors.Error!image.OwnedBuffer {
    const source = try parseStaticSource(gpa, bytes, decode_options);
    return decodeImage(gpa, source, decode_options);
}

/// Decodes a complete still WebP file into the caller-owned `dest` buffer,
/// row-major, honoring `dest.stride`. `dest.format` is authoritative;
/// `decode_options.output_format` is ignored on this path. `dest` must pass
/// `Buffer.validate()` and `dest.dimensions` must exactly equal the file's
/// canvas dimensions — any mismatch returns `error.InvalidCanvasSize`. Both
/// checks run before any pixel is decoded. Lossless decoding allocates only
/// VP8L reconstruction scratch from `gpa`; the caller-owned destination and no
/// packed output copy are charged against
/// `decode_options.limits.allocation_bytes_max`. Lossy decoding retains the
/// owned intermediate used by `decodeStatic`.
/// Bytes in `dest.pixels` outside the written rows (stride padding, tail
/// slack) are left untouched. Animated inputs fail with
/// `error.UnsupportedAnimationDecode`.
pub fn decodeStaticInto(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    dest: image.Buffer,
    decode_options: options.DecoderOptions,
) errors.Error!void {
    try dest.validate();

    const source = try parseStaticSource(gpa, bytes, decode_options);
    if (dest.dimensions.width != source.dimensions.width) return error.InvalidCanvasSize;
    if (dest.dimensions.height != source.dimensions.height) return error.InvalidCanvasSize;

    return switch (source.format) {
        .lossless => decodeLosslessInto(gpa, source, dest, decode_options),
        .lossy => decodeLossyInto(gpa, source, dest, decode_options),
    };
}

fn decodeLossyInto(
    gpa: std.mem.Allocator,
    source: ImageSource,
    dest: image.Buffer,
    decode_options: options.DecoderOptions,
) errors.Error!void {
    var into_options = decode_options;
    into_options.output_format = dest.format;
    var decoded = try decodeLossy(gpa, source, into_options);
    defer decoded.deinit();

    assert(decoded.buffer.format == dest.format);
    const row_bytes: usize = @intCast(try dest.rowBytes());
    assert(decoded.buffer.stride == row_bytes);

    var y: usize = 0;
    while (y < dest.dimensions.height) : (y += 1) {
        const source_row = decoded.buffer.pixels[y * row_bytes ..][0..row_bytes];
        const target_row = dest.pixels[y * @as(usize, dest.stride) ..][0..row_bytes];
        @memcpy(target_row, source_row);
    }
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
    const dimensions = source.dimensions;
    const output_len = try outputByteLength(dimensions, decode_options.output_format);

    var working_set: LosslessWorkingSet = undefined;
    try working_set.init(gpa, source, decode_options, output_len);
    defer working_set.deinit();

    const out = working_set.packed_output.?;
    writePixels(out, decode_options.output_format, working_set.argb_pixels);

    const stride: u32 = @intCast(try rowByteLength(dimensions, decode_options.output_format));
    _ = working_set.takePackedOutput();
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

fn decodeLosslessInto(
    gpa: std.mem.Allocator,
    source: ImageSource,
    dest: image.Buffer,
    decode_options: options.DecoderOptions,
) errors.Error!void {
    var working_set: LosslessWorkingSet = undefined;
    try working_set.init(gpa, source, decode_options, null);
    defer working_set.deinit();

    writePixelsInto(dest, working_set.argb_pixels);
}

const LosslessWorkingSet = struct {
    gpa: std.mem.Allocator,
    argb_pixels: []vp8l_pixel.Pixel,
    transform_pixels: []vp8l_pixel.Pixel,
    entropy_image: []vp8l_pixel.Pixel,
    packed_output: ?[]u8,

    fn init(
        target: *LosslessWorkingSet,
        gpa: std.mem.Allocator,
        source: ImageSource,
        decode_options: options.DecoderOptions,
        packed_output_len: ?u64,
    ) errors.Error!void {
        target.* = .{
            .gpa = gpa,
            .argb_pixels = &.{},
            .transform_pixels = &.{},
            .entropy_image = &.{},
            .packed_output = null,
        };
        errdefer target.deinit();

        const pixel_count = try source.dimensions.pixelCount();
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
        const packed_output_count: ?usize = if (packed_output_len) |len|
            try reserveElements(u8, len, &allocation_bytes, decode_options)
        else
            null;

        target.argb_pixels = try gpa.alloc(vp8l_pixel.Pixel, argb_count);
        target.transform_pixels = try gpa.alloc(vp8l_pixel.Pixel, transform_count);
        target.entropy_image = try gpa.alloc(vp8l_pixel.Pixel, entropy_count);
        if (packed_output_count) |count| {
            target.packed_output = try gpa.alloc(u8, count);
        }

        const allocation_bytes_remaining =
            decode_options.limits.allocation_bytes_max - allocation_bytes;
        var work_buffers = vp8l_decoder.WorkBuffers{
            .transform_pixels = target.transform_pixels,
            .entropy_image = target.entropy_image,
            .prefix_group_options = .{
                .allocation_bytes_max = allocation_bytes_remaining,
            },
        };
        _ = try vp8l_decoder.decodeARGBAlloc(
            gpa,
            source.bitstream,
            target.argb_pixels,
            &work_buffers,
        );
    }

    fn deinit(self: *LosslessWorkingSet) void {
        if (self.packed_output) |out| self.gpa.free(out);
        if (self.entropy_image.len > 0) self.gpa.free(self.entropy_image);
        if (self.transform_pixels.len > 0) self.gpa.free(self.transform_pixels);
        if (self.argb_pixels.len > 0) self.gpa.free(self.argb_pixels);
    }

    fn takePackedOutput(self: *LosslessWorkingSet) []u8 {
        const out = self.packed_output.?;
        self.packed_output = null;
        return out;
    }
};

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

    var parsed: vp8_frame_header.Parsed = undefined;
    try vp8_frame_header.parse(source.bitstream, &parsed);
    const frame_allocation_bytes = try vp8_decoder.allocationBytesParsed(&parsed, .{
        .apply_loop_filter = true,
    });
    try reserveBytes(frame_allocation_bytes, &allocation_bytes, decode_options);

    // Reconstruct the YUV planes (key-frame decode through the in-loop filter,
    // matching plain `dwebp`). The frame's own dimensions equal `dimensions`:
    // the container rejects any canvas/rect that disagrees with the VP8 header.
    var frame = try vp8_decoder.decodeFrameParsed(gpa, &parsed, .{
        .apply_loop_filter = true,
        .allocation_bytes_max = frame_allocation_bytes,
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
            _ = try alpha.decodePlaneAllocWithOptions(
                gpa,
                alpha_payload,
                dimensions,
                alpha_plane,
                .{
                    .allocation_bytes_max = decode_options.limits.allocation_bytes_max - allocation_bytes,
                },
            );
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
    try reserveBytes(bytes, allocation_bytes, decode_options);

    return @intCast(count);
}

fn reserveBytes(
    bytes: u64,
    allocation_bytes: *u64,
    decode_options: options.DecoderOptions,
) errors.Error!void {
    if (bytes > std.math.maxInt(u64) - allocation_bytes.*) {
        return error.AllocationLimitExceeded;
    }

    allocation_bytes.* += bytes;
    try decode_options.limits.validateAllocationBytes(allocation_bytes.*);
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
fn writePixelsInto(dest: image.Buffer, argb_pixels: []const vp8l_pixel.Pixel) void {
    const pixel_count: usize = @intCast(dest.dimensions.pixelCount() catch unreachable);
    assert(argb_pixels.len == pixel_count);

    switch (dest.format) {
        .rgb => writeRgbRows(dest, argb_pixels),
        .rgba => writeRgbaRows(dest, argb_pixels),
        .bgra => writeBgraRows(dest, argb_pixels),
        .argb => writeArgbRows(dest, argb_pixels),
    }
}

fn writeRgbRows(dest: image.Buffer, argb_pixels: []const vp8l_pixel.Pixel) void {
    const width: usize = @intCast(dest.dimensions.width);
    const stride: usize = @intCast(dest.stride);
    var y: usize = 0;
    while (y < dest.dimensions.height) : (y += 1) {
        const source_row = argb_pixels[y * width ..][0..width];
        const target_row = dest.pixels[y * stride ..][0 .. width * 3];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const value = source_row[x];
            target_row[x * 3] = vp8l_pixel.red(value);
            target_row[x * 3 + 1] = vp8l_pixel.green(value);
            target_row[x * 3 + 2] = vp8l_pixel.blue(value);
        }
    }
}

fn writeRgbaRows(dest: image.Buffer, argb_pixels: []const vp8l_pixel.Pixel) void {
    const width: usize = @intCast(dest.dimensions.width);
    const stride: usize = @intCast(dest.stride);
    var y: usize = 0;
    while (y < dest.dimensions.height) : (y += 1) {
        const source_row = argb_pixels[y * width ..][0..width];
        const target_row = dest.pixels[y * stride ..][0 .. width * 4];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const value = source_row[x];
            target_row[x * 4] = vp8l_pixel.red(value);
            target_row[x * 4 + 1] = vp8l_pixel.green(value);
            target_row[x * 4 + 2] = vp8l_pixel.blue(value);
            target_row[x * 4 + 3] = vp8l_pixel.alpha(value);
        }
    }
}

fn writeBgraRows(dest: image.Buffer, argb_pixels: []const vp8l_pixel.Pixel) void {
    const width: usize = @intCast(dest.dimensions.width);
    const stride: usize = @intCast(dest.stride);
    var y: usize = 0;
    while (y < dest.dimensions.height) : (y += 1) {
        const source_row = argb_pixels[y * width ..][0..width];
        const target_row = dest.pixels[y * stride ..][0 .. width * 4];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const value = source_row[x];
            target_row[x * 4] = vp8l_pixel.blue(value);
            target_row[x * 4 + 1] = vp8l_pixel.green(value);
            target_row[x * 4 + 2] = vp8l_pixel.red(value);
            target_row[x * 4 + 3] = vp8l_pixel.alpha(value);
        }
    }
}

fn writeArgbRows(dest: image.Buffer, argb_pixels: []const vp8l_pixel.Pixel) void {
    const width: usize = @intCast(dest.dimensions.width);
    const stride: usize = @intCast(dest.stride);
    var y: usize = 0;
    while (y < dest.dimensions.height) : (y += 1) {
        const source_row = argb_pixels[y * width ..][0..width];
        const target_row = dest.pixels[y * stride ..][0 .. width * 4];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const value = source_row[x];
            target_row[x * 4] = vp8l_pixel.alpha(value);
            target_row[x * 4 + 1] = vp8l_pixel.red(value);
            target_row[x * 4 + 2] = vp8l_pixel.green(value);
            target_row[x * 4 + 3] = vp8l_pixel.blue(value);
        }
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

test "bounded mutation exploration of static decode" {
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

    try testing_fuzz.runMutations(fuzzDecodeStaticOne, encoded, .{ .prng_seed = 0x11d_0001 });
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

fn decodeStaticIntoAllocationProbe(gpa: std.mem.Allocator, encoded: []const u8) !void {
    var dest_pixels: [2 * 4]u8 = undefined;
    try decodeStaticInto(gpa, encoded, .{
        .pixels = &dest_pixels,
        .dimensions = .{ .width = 2, .height = 1 },
        .stride = 2 * 4,
        .format = .rgba,
    }, .{});
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

test "decodeStaticInto matches decodeStatic on a lossless corpus file" {
    const corpus = @import("testing/corpus.zig");

    const bytes = corpus.readFileAlloc(std.testing.allocator, "lossless1.webp", .{}) catch |err| switch (err) {
        error.CorpusUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(bytes);

    var expected = try decodeStatic(std.testing.allocator, bytes, .{});
    defer expected.deinit();

    const dest_pixels = try std.testing.allocator.alloc(u8, expected.buffer.pixels.len);
    defer std.testing.allocator.free(dest_pixels);
    const dest = image.Buffer{
        .pixels = dest_pixels,
        .dimensions = expected.buffer.dimensions,
        .stride = expected.buffer.stride,
        .format = .rgba,
    };

    try decodeStaticInto(std.testing.allocator, bytes, dest, .{});
    try std.testing.expectEqualSlices(u8, expected.buffer.pixels, dest.pixels);
}

test "decodeStaticInto matches decodeStatic on a lossy corpus file" {
    const corpus = @import("testing/corpus.zig");

    const bytes = corpus.readFileAlloc(std.testing.allocator, "test.webp", .{}) catch |err| switch (err) {
        error.CorpusUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(bytes);

    var expected = try decodeStatic(std.testing.allocator, bytes, .{});
    defer expected.deinit();

    const dest_pixels = try std.testing.allocator.alloc(u8, expected.buffer.pixels.len);
    defer std.testing.allocator.free(dest_pixels);
    const dest = image.Buffer{
        .pixels = dest_pixels,
        .dimensions = expected.buffer.dimensions,
        .stride = expected.buffer.stride,
        .format = .rgba,
    };

    try decodeStaticInto(std.testing.allocator, bytes, dest, .{});
    try std.testing.expectEqualSlices(u8, expected.buffer.pixels, dest.pixels);
}

test "decodeStaticInto honors stride and leaves padding untouched" {
    const dimensions = try image.Dimensions.init(2, 2);
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

    // Stride 16 with 8-byte rows leaves 8 padding bytes after row 0, plus 8
    // bytes of tail slack after row 1; all 16 sentinel bytes must survive.
    const stride: u32 = 16;
    var dest_pixels: [2 * 16]u8 = @splat(0xaa);
    const dest = image.Buffer{
        .pixels = &dest_pixels,
        .dimensions = dimensions,
        .stride = stride,
        .format = .rgba,
    };

    try decodeStaticInto(std.testing.allocator, encoded, dest, .{});

    const row = [_]u8{ 1, 2, 3, 4, 1, 2, 3, 4 };
    const padding = [_]u8{0xaa} ** 8;
    try std.testing.expectEqualSlices(u8, &row, dest_pixels[0..8]);
    try std.testing.expectEqualSlices(u8, &padding, dest_pixels[8..16]);
    try std.testing.expectEqualSlices(u8, &row, dest_pixels[16..24]);
    try std.testing.expectEqualSlices(u8, &padding, dest_pixels[24..32]);
}

test "decodeStaticInto writes every lossless format without touching slack" {
    const dimensions = try image.Dimensions.init(3, 2);
    var vp8l_payload: [32]u8 = undefined;
    const bitstream = try makeConstantVP8L(
        &vp8l_payload,
        dimensions,
        vp8l_pixel.fromChannels(0x44, 0x11, 0x22, 0x33),
    );
    const encoded = try mux.encodeStatic(std.testing.allocator, .{
        .canvas = dimensions,
        .format = .lossless,
        .bitstream = bitstream,
        .has_alpha = true,
    }, .{});
    defer std.testing.allocator.free(encoded);

    const formats = [_]image.PixelFormat{ .rgb, .rgba, .bgra, .argb };
    const row_padding_cases = [_]usize{ 0, 5 };
    const sentinel: u8 = 0xa5;
    for (formats) |format| {
        var expected = try decodeStatic(std.testing.allocator, encoded, .{
            .output_format = format,
        });
        defer expected.deinit();

        const row_bytes = @as(usize, dimensions.width) * format.channelCount();
        for (row_padding_cases) |row_padding| {
            const stride = row_bytes + row_padding;
            const required_len = stride + row_bytes;
            const tail_len = 7;
            var storage: [64]u8 = @splat(sentinel);
            const dest_pixels = storage[1..][0 .. required_len + tail_len];
            const dest = image.Buffer{
                .pixels = dest_pixels,
                .dimensions = dimensions,
                .stride = @intCast(stride),
                .format = format,
            };

            try decodeStaticInto(std.testing.allocator, encoded, dest, .{});

            var y: usize = 0;
            while (y < dimensions.height) : (y += 1) {
                const expected_row = expected.buffer.pixels[y * row_bytes ..][0..row_bytes];
                const actual_row = dest_pixels[y * stride ..][0..row_bytes];
                try std.testing.expectEqualSlices(u8, expected_row, actual_row);
            }
            for (dest_pixels[row_bytes..stride]) |byte| {
                try std.testing.expectEqual(sentinel, byte);
            }
            for (dest_pixels[required_len..]) |byte| {
                try std.testing.expectEqual(sentinel, byte);
            }
        }
    }
}

test "lossless decodeStaticInto budgets only reconstruction scratch" {
    const dimensions = try image.Dimensions.init(3, 2);
    var vp8l_payload: [32]u8 = undefined;
    const bitstream = try makeConstantVP8L(
        &vp8l_payload,
        dimensions,
        vp8l_pixel.fromChannels(0x44, 0x11, 0x22, 0x33),
    );
    const encoded = try mux.encodeStatic(std.testing.allocator, .{
        .canvas = dimensions,
        .format = .lossless,
        .bitstream = bitstream,
        .has_alpha = true,
    }, .{});
    defer std.testing.allocator.free(encoded);

    const pixel_count = try dimensions.pixelCount();
    const scratch_pixel_count = pixel_count * 3 + 257;
    const scratch_bytes = scratch_pixel_count * @sizeOf(vp8l_pixel.Pixel);
    var dest_pixels: [3 * 2 * 4]u8 = undefined;
    const dest = image.Buffer{
        .pixels = &dest_pixels,
        .dimensions = dimensions,
        .stride = 3 * 4,
        .format = .rgba,
    };

    try decodeStaticInto(std.testing.allocator, encoded, dest, .{
        .limits = .{ .allocation_bytes_max = scratch_bytes },
    });
    try std.testing.expectError(error.AllocationLimitExceeded, decodeStaticInto(
        std.testing.allocator,
        encoded,
        dest,
        .{ .limits = .{ .allocation_bytes_max = scratch_bytes - 1 } },
    ));
    try std.testing.expectError(error.AllocationLimitExceeded, decodeStatic(
        std.testing.allocator,
        encoded,
        .{ .limits = .{ .allocation_bytes_max = scratch_bytes } },
    ));
}

test "lossless decodeStaticInto survives allocation failure at every site" {
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
        decodeStaticIntoAllocationProbe,
        .{encoded},
    );
}

test "lossless decodeStaticInto preserves malformed stream errors" {
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

    const payload_offset = container.riff_header_size + container.chunk_header_size;
    encoded[payload_offset] = 0;

    var dest_pixels: [2 * 4]u8 = undefined;
    const dest = image.Buffer{
        .pixels = &dest_pixels,
        .dimensions = dimensions,
        .stride = 2 * 4,
        .format = .rgba,
    };
    try std.testing.expectError(
        error.InvalidVP8LHeader,
        decodeStaticInto(std.testing.allocator, encoded, dest, .{}),
    );

    encoded[payload_offset] = vp8l_header.signature;
    const truncated_payload_len = vp8l_header.byte_count;
    const truncated_file_len =
        container.riff_header_size + container.chunk_header_size + truncated_payload_len + 1;
    container.writeLittleU32(
        encoded[container.riff_header_size + 4 ..][0..4],
        truncated_payload_len,
    );
    container.writeLittleU32(encoded[4..8], truncated_file_len - 8);
    encoded[payload_offset + truncated_payload_len] = 0;
    const truncated = encoded[0..truncated_file_len];

    try std.testing.expectError(
        error.TruncatedBitstream,
        decodeStaticInto(std.testing.allocator, truncated, dest, .{}),
    );
}

test "decodeStaticInto lets dest.format override output_format" {
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

    var expected = try decodeStatic(std.testing.allocator, encoded, .{
        .output_format = .bgra,
    });
    defer expected.deinit();

    var dest_pixels: [4]u8 = undefined;
    const dest = image.Buffer{
        .pixels = &dest_pixels,
        .dimensions = dimensions,
        .stride = 4,
        .format = .bgra,
    };

    // The options ask for rgba; the caller's buffer format must win.
    try decodeStaticInto(std.testing.allocator, encoded, dest, .{
        .output_format = .rgba,
    });
    try std.testing.expectEqualSlices(u8, expected.buffer.pixels, &dest_pixels);
}

test "decodeStaticInto rejects dimension mismatches" {
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

    // Larger and smaller than the 2x1 canvas must both be rejected.
    var dest_pixels: [3 * 4]u8 = undefined;
    try std.testing.expectError(error.InvalidCanvasSize, decodeStaticInto(
        std.testing.allocator,
        encoded,
        .{
            .pixels = &dest_pixels,
            .dimensions = try image.Dimensions.init(3, 1),
            .stride = 12,
            .format = .rgba,
        },
        .{},
    ));
    try std.testing.expectError(error.InvalidCanvasSize, decodeStaticInto(
        std.testing.allocator,
        encoded,
        .{
            .pixels = &dest_pixels,
            .dimensions = try image.Dimensions.init(1, 1),
            .stride = 4,
            .format = .rgba,
        },
        .{},
    ));
}

test "decodeStaticInto rejects undersized pixel slices" {
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

    // 2x1 rgba needs 8 bytes; 7 must fail `dest.validate()` up front.
    var dest_pixels: [7]u8 = undefined;
    try std.testing.expectError(error.OutputTooLarge, decodeStaticInto(
        std.testing.allocator,
        encoded,
        .{
            .pixels = &dest_pixels,
            .dimensions = dimensions,
            .stride = 8,
            .format = .rgba,
        },
        .{},
    ));
}

test "decodeStaticInto rejects animated input" {
    const animation_encode = @import("animation_encode.zig");

    const dimensions = try image.Dimensions.init(2, 2);
    var frame_pixels: [2 * 2 * 4]u8 = @splat(0x80);
    const frame = animation_encode.FrameSource{
        .buffer = .{
            .pixels = &frame_pixels,
            .dimensions = dimensions,
            .stride = 2 * 4,
            .format = .rgba,
        },
        .duration_ms = 100,
        .format = .lossless,
    };
    const sources = [_]animation_encode.FrameSource{ frame, frame };
    const encoded = try animation_encode.encodeAnimationFromBuffers(
        std.testing.allocator,
        &sources,
        .{ .canvas = dimensions },
    );
    defer std.testing.allocator.free(encoded);

    var dest_pixels: [2 * 2 * 4]u8 = undefined;
    try std.testing.expectError(error.UnsupportedAnimationDecode, decodeStaticInto(
        std.testing.allocator,
        encoded,
        .{
            .pixels = &dest_pixels,
            .dimensions = dimensions,
            .stride = 2 * 4,
            .format = .rgba,
        },
        .{},
    ));
}
