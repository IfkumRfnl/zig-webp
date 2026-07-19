//! Public static image decode composition.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const native_endian = builtin.cpu.arch.endian();

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
const vp8l_image_data = @import("vp8l/image_data.zig");
const vp8l_meta_prefix = @import("vp8l/meta_prefix.zig");
const vp8l_transform = @import("vp8l/transform.zig");

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
/// checks run before any pixel is decoded. Both codecs allocate only their
/// reconstruction scratch from `gpa`; neither the caller-owned destination nor
/// a packed output copy is charged against
/// `decode_options.limits.allocation_bytes_max`.
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
    try decodeLossyToBuffer(gpa, source, dest, into_options, 0);
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

const lossless_stack_pixel_count = 10_000;

fn decodeLossless(
    gpa: std.mem.Allocator,
    source: ImageSource,
    decode_options: options.DecoderOptions,
) errors.Error!image.OwnedBuffer {
    const pixel_count = try source.dimensions.pixelCount();
    if (pixel_count <= lossless_stack_pixel_count) {
        return decodeLosslessStack(gpa, source, decode_options);
    }
    return decodeLosslessWithScratch(gpa, source, decode_options, &.{});
}

noinline fn decodeLosslessStack(
    gpa: std.mem.Allocator,
    source: ImageSource,
    decode_options: options.DecoderOptions,
) errors.Error!image.OwnedBuffer {
    var pixel_scratch: [lossless_stack_pixel_count]vp8l_pixel.Pixel = undefined;
    return decodeLosslessWithScratch(gpa, source, decode_options, &pixel_scratch);
}

fn decodeLosslessWithScratch(
    gpa: std.mem.Allocator,
    source: ImageSource,
    decode_options: options.DecoderOptions,
    pixel_scratch: []vp8l_pixel.Pixel,
) errors.Error!image.OwnedBuffer {
    const dimensions = source.dimensions;
    const output_len = try outputByteLength(dimensions, decode_options.output_format);
    var allocation_bytes: u64 = 0;
    const output_count = try reserveElements(
        u8,
        output_len,
        &allocation_bytes,
        decode_options,
    );
    const out = try gpa.alloc(u8, output_count);
    errdefer gpa.free(out);

    const output_pixels = alignedOutputPixels(out, decode_options.output_format);
    var working_set: LosslessWorkingSet = undefined;
    if (output_pixels) |pixels| {
        try working_set.init(
            gpa,
            source,
            decode_options,
            pixels,
            output_len,
            pixel_scratch,
        );
    } else {
        try working_set.init(
            gpa,
            source,
            decode_options,
            null,
            output_len,
            pixel_scratch,
        );
    }
    defer working_set.deinit();

    if (output_pixels) |pixels| {
        convertPixelsInPlace(decode_options.output_format, pixels);
    } else {
        writePixels(out, decode_options.output_format, working_set.argb_pixels);
    }

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

fn decodeLosslessInto(
    gpa: std.mem.Allocator,
    source: ImageSource,
    dest: image.Buffer,
    decode_options: options.DecoderOptions,
) errors.Error!void {
    const pixel_count = try source.dimensions.pixelCount();
    if (pixel_count <= lossless_stack_pixel_count) {
        return decodeLosslessIntoStack(gpa, source, dest, decode_options);
    }
    return decodeLosslessIntoWithScratch(gpa, source, dest, decode_options, &.{});
}

noinline fn decodeLosslessIntoStack(
    gpa: std.mem.Allocator,
    source: ImageSource,
    dest: image.Buffer,
    decode_options: options.DecoderOptions,
) errors.Error!void {
    var pixel_scratch: [lossless_stack_pixel_count]vp8l_pixel.Pixel = undefined;
    return decodeLosslessIntoWithScratch(gpa, source, dest, decode_options, &pixel_scratch);
}

fn decodeLosslessIntoWithScratch(
    gpa: std.mem.Allocator,
    source: ImageSource,
    dest: image.Buffer,
    decode_options: options.DecoderOptions,
    pixel_scratch: []vp8l_pixel.Pixel,
) errors.Error!void {
    const output_pixels = directOutputPixels(dest);
    var working_set: LosslessWorkingSet = undefined;
    try working_set.init(
        gpa,
        source,
        decode_options,
        output_pixels,
        0,
        pixel_scratch,
    );
    defer working_set.deinit();

    if (output_pixels) |pixels| {
        convertPixelsInPlace(dest.format, pixels);
    } else {
        writePixelsInto(dest, working_set.argb_pixels);
    }
}

const LosslessWorkingSet = struct {
    gpa: std.mem.Allocator,
    pixel_storage: []vp8l_pixel.Pixel,
    pixel_storage_owned: bool,
    argb_pixels: []vp8l_pixel.Pixel,
    argb_pixels_owned: bool,
    transform_pixels: []vp8l_pixel.Pixel,
    entropy_image: []vp8l_pixel.Pixel,

    fn init(
        target: *LosslessWorkingSet,
        gpa: std.mem.Allocator,
        source: ImageSource,
        decode_options: options.DecoderOptions,
        argb_pixels_external: ?[]vp8l_pixel.Pixel,
        output_allocation_bytes: u64,
        pixel_scratch: []vp8l_pixel.Pixel,
    ) errors.Error!void {
        target.* = .{
            .gpa = gpa,
            .pixel_storage = &.{},
            .pixel_storage_owned = false,
            .argb_pixels = &.{},
            .argb_pixels_owned = false,
            .transform_pixels = &.{},
            .entropy_image = &.{},
        };
        errdefer target.deinit();

        const pixel_count = try source.dimensions.pixelCount();
        var allocation_bytes: u64 = 0;
        _ = try reserveElements(
            u8,
            output_allocation_bytes,
            &allocation_bytes,
            decode_options,
        );
        const argb_count = if (argb_pixels_external) |pixels| blk: {
            if (pixels.len != pixel_count) return error.OutputTooLarge;
            target.argb_pixels = pixels;
            break :blk pixels.len;
        } else try reserveElements(
            vp8l_pixel.Pixel,
            pixel_count,
            &allocation_bytes,
            decode_options,
        );
        const vp8l_stream = if (source.bitstream.len > vp8l_header.byte_count)
            source.bitstream[vp8l_header.byte_count..]
        else
            &.{};
        const transform_count = try reserveElements(
            vp8l_pixel.Pixel,
            try transformPixelCapacityForStream(source.dimensions, vp8l_stream),
            &allocation_bytes,
            decode_options,
        );
        const entropy_count = try reserveElements(
            vp8l_pixel.Pixel,
            if (pixel_count < 16384) 0 else try entropyPixelCapacity(source.dimensions),
            &allocation_bytes,
            decode_options,
        );

        var pixel_storage_count: usize = if (argb_pixels_external == null) argb_count else 0;
        if (transform_count > std.math.maxInt(usize) - pixel_storage_count) {
            return error.AllocationLimitExceeded;
        }
        pixel_storage_count += transform_count;
        if (entropy_count > std.math.maxInt(usize) - pixel_storage_count) {
            return error.AllocationLimitExceeded;
        }
        pixel_storage_count += entropy_count;

        if (pixel_storage_count <= pixel_scratch.len) {
            target.pixel_storage = pixel_scratch[0..pixel_storage_count];
            if (argb_pixels_external == null) {
                target.argb_pixels = target.pixel_storage[0..argb_count];
            }
            const transform_start = if (argb_pixels_external == null) argb_count else 0;
            target.transform_pixels =
                target.pixel_storage[transform_start..][0..transform_count];
            const entropy_start = transform_start + transform_count;
            target.entropy_image = target.pixel_storage[entropy_start..][0..entropy_count];
        } else if (pixel_count < 16384 and source.bitstream.len >= 128) {
            if (argb_pixels_external == null) {
                target.argb_pixels = try gpa.alloc(vp8l_pixel.Pixel, argb_count);
                target.argb_pixels_owned = true;
            }
            target.transform_pixels = try gpa.alloc(vp8l_pixel.Pixel, transform_count);
            target.entropy_image = try gpa.alloc(vp8l_pixel.Pixel, entropy_count);
        } else {
            target.pixel_storage = try gpa.alloc(vp8l_pixel.Pixel, pixel_storage_count);
            target.pixel_storage_owned = true;
            if (argb_pixels_external == null) {
                target.argb_pixels = target.pixel_storage[0..argb_count];
            }
            const transform_start = if (argb_pixels_external == null) argb_count else 0;
            target.transform_pixels =
                target.pixel_storage[transform_start..][0..transform_count];
            const entropy_start = transform_start + transform_count;
            target.entropy_image = target.pixel_storage[entropy_start..][0..entropy_count];
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
        try vp8l_decoder.decodeARGBAllocDiscardSummary(
            gpa,
            source.bitstream,
            target.argb_pixels,
            &work_buffers,
        );
    }

    fn deinit(self: *LosslessWorkingSet) void {
        if (self.pixel_storage_owned) {
            self.gpa.free(self.pixel_storage);
        } else if (self.pixel_storage.len == 0) {
            if (self.entropy_image.len > 0) self.gpa.free(self.entropy_image);
            if (self.transform_pixels.len > 0) self.gpa.free(self.transform_pixels);
            if (self.argb_pixels_owned) self.gpa.free(self.argb_pixels);
        }
    }
};

fn decodeLossy(
    gpa: std.mem.Allocator,
    source: ImageSource,
    decode_options: options.DecoderOptions,
) errors.Error!image.OwnedBuffer {
    var allocation_bytes: u64 = 0;
    const output_len = try outputByteLength(source.dimensions, decode_options.output_format);
    const output_count = try reserveElements(
        u8,
        output_len,
        &allocation_bytes,
        decode_options,
    );
    const out = try gpa.alloc(u8, output_count);
    errdefer gpa.free(out);

    const stride: u32 = @intCast(try rowByteLength(
        source.dimensions,
        decode_options.output_format,
    ));
    const dest = image.Buffer{
        .pixels = out,
        .dimensions = source.dimensions,
        .stride = stride,
        .format = decode_options.output_format,
    };
    try decodeLossyToBuffer(gpa, source, dest, decode_options, allocation_bytes);

    return .{
        .gpa = gpa,
        .buffer = dest,
    };
}

fn decodeLossyToBuffer(
    gpa: std.mem.Allocator,
    source: ImageSource,
    dest: image.Buffer,
    decode_options: options.DecoderOptions,
    allocation_bytes_initial: u64,
) errors.Error!void {
    assert(dest.dimensions.width == source.dimensions.width);
    assert(dest.dimensions.height == source.dimensions.height);
    assert(dest.format == decode_options.output_format);

    var allocation_bytes = allocation_bytes_initial;
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

    var alpha_plane: ?[]u8 = null;
    defer if (alpha_plane) |plane| gpa.free(plane);
    if (dest.format.channelCount() == 4) {
        if (source.alpha) |alpha_payload| {
            const pixel_count: usize = @intCast(try source.dimensions.pixelCount());
            const alpha_count = try reserveElements(
                u8,
                pixel_count,
                &allocation_bytes,
                decode_options,
            );
            const plane = try gpa.alloc(u8, alpha_count);
            errdefer gpa.free(plane);
            _ = try alpha.decodePlaneAllocWithOptions(
                gpa,
                alpha_payload,
                source.dimensions,
                plane,
                .{
                    .allocation_bytes_max = decode_options.limits.allocation_bytes_max - allocation_bytes,
                },
            );
            alpha_plane = plane;
        }
    }

    color.upsampleFancy(dest.format, .{
        .luma = frame.luma,
        .chroma_u = frame.chroma_u,
        .chroma_v = frame.chroma_v,
        .luma_stride = frame.luma_stride,
        .chroma_stride = frame.chroma_stride,
        .width = frame.width,
        .height = frame.height,
    }, dest.pixels, dest.stride);

    if (alpha_plane) |plane| {
        composeAlpha(
            dest.pixels,
            dest.format,
            dest.stride,
            source.dimensions,
            plane,
        );
    }
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
    assert(format.channelCount() == 4);
    const width: usize = @intCast(dimensions.width);
    const height: usize = @intCast(dimensions.height);
    assert(alpha_plane.len == width * height);
    const alpha_offset: usize = switch (format) {
        .rgb => unreachable,
        .rgba, .bgra => 3,
        .argb => 0,
    };

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const out_row = out[y * @as(usize, stride) ..][0 .. width * 4];
        const alpha_row = alpha_plane[y * width ..][0..width];
        for (alpha_row, 0..) |value, x| {
            out_row[x * 4 + alpha_offset] = value;
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

fn blockImagePixelCapacity(
    dimensions: image.Dimensions,
    block_bits: u4,
) errors.Error!u64 {
    const block_size = @as(u64, 1) << @intCast(block_bits);
    const width: u64 = dimensions.width;
    const height: u64 = dimensions.height;
    const block_width = @divFloor(width, block_size) + @intFromBool(width % block_size != 0);
    const block_height = @divFloor(height, block_size) + @intFromBool(height % block_size != 0);
    return std.math.mul(u64, block_width, block_height) catch
        error.AllocationLimitExceeded;
}

// Predictor and color are the only block transforms and each kind may occur
// once. Their minimum block size is 4x4. A color-indexing transform contributes
// at most 256 pixels and can only shrink the width seen by later transforms, so
// two block images at the original dimensions plus one table covers every order.
fn transformPixelCapacity(dimensions: image.Dimensions) errors.Error!u64 {
    const block_count = try blockImagePixelCapacity(
        dimensions,
        vp8l_transform.block_bits_min,
    );
    const two_block_images = std.math.mul(u64, block_count, 2) catch
        return error.AllocationLimitExceeded;
    return std.math.add(
        u64,
        two_block_images,
        vp8l_transform.color_table_size_max,
    ) catch error.AllocationLimitExceeded;
}

// The main image can only be narrower after color indexing. The minimum
// meta-prefix block size is 4x4, so original dimensions are conservative.
fn entropyPixelCapacity(dimensions: image.Dimensions) errors.Error!u64 {
    return blockImagePixelCapacity(dimensions, vp8l_meta_prefix.prefix_bits_min);
}

fn transformPixelCapacityForStream(
    dimensions: image.Dimensions,
    stream: []const u8,
) errors.Error!u64 {
    if (stream.len > 0 and (stream[0] & 1) == 0) return 0;
    return transformPixelCapacity(dimensions);
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

fn alignedOutputPixels(
    out: []u8,
    format: image.PixelFormat,
) ?[]vp8l_pixel.Pixel {
    if (format.channelCount() != @sizeOf(vp8l_pixel.Pixel)) return null;
    if (out.len % @sizeOf(vp8l_pixel.Pixel) != 0) return null;
    if (@intFromPtr(out.ptr) % @alignOf(vp8l_pixel.Pixel) != 0) return null;

    const aligned: []align(@alignOf(vp8l_pixel.Pixel)) u8 = @alignCast(out);
    return std.mem.bytesAsSlice(vp8l_pixel.Pixel, aligned);
}

fn directOutputPixels(dest: image.Buffer) ?[]vp8l_pixel.Pixel {
    if (dest.format.channelCount() != @sizeOf(vp8l_pixel.Pixel)) return null;

    const row_bytes = @as(u64, dest.dimensions.width) * @sizeOf(vp8l_pixel.Pixel);
    if (dest.stride != row_bytes) return null;
    const output_len_u64 = row_bytes * @as(u64, dest.dimensions.height);
    if (output_len_u64 > dest.pixels.len) return null;
    const output_len: usize = @intCast(output_len_u64);

    return alignedOutputPixels(dest.pixels[0..output_len], dest.format);
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

const output_vector_pixels = 8;
const OutputPixelVector = @Vector(output_vector_pixels, vp8l_pixel.Pixel);

fn convertPixelsInPlace(
    format: image.PixelFormat,
    pixels: []vp8l_pixel.Pixel,
) void {
    if (comptime native_endian == .little) {
        if (format == .bgra) return;
    } else {
        if (format == .argb) return;
    }

    switch (format) {
        .rgba => convertPixelsInPlaceFormat(.rgba, pixels),
        .bgra => convertPixelsInPlaceFormat(.bgra, pixels),
        .argb => convertPixelsInPlaceFormat(.argb, pixels),
        .rgb => unreachable,
    }
}

fn convertPixelsInPlaceFormat(
    comptime format: image.PixelFormat,
    pixels: []vp8l_pixel.Pixel,
) void {
    comptime assert(format.channelCount() == 4);

    var pixel_index: usize = 0;
    while (pixel_index + output_vector_pixels <= pixels.len) : (pixel_index += output_vector_pixels) {
        const source: OutputPixelVector =
            pixels[pixel_index..][0..output_vector_pixels].*;
        pixels[pixel_index..][0..output_vector_pixels].* =
            packOutputPixels(format, source);
    }
    while (pixel_index < pixels.len) : (pixel_index += 1) {
        pixels[pixel_index] = packOutputPixel(format, pixels[pixel_index]);
    }
}

fn packOutputPixel(
    comptime format: image.PixelFormat,
    source: vp8l_pixel.Pixel,
) vp8l_pixel.Pixel {
    comptime assert(format.channelCount() == 4);

    if (comptime native_endian == .little) {
        return switch (format) {
            .rgba => (source & 0xff00_ff00) |
                ((source & 0x00ff_0000) >> 16) |
                ((source & 0x0000_00ff) << 16),
            .bgra => source,
            .argb => @byteSwap(source),
            .rgb => comptime unreachable,
        };
    }
    return switch (format) {
        .rgba => (source << 8) | (source >> 24),
        .bgra => @byteSwap(source),
        .argb => source,
        .rgb => comptime unreachable,
    };
}

fn writeRgbaRows(dest: image.Buffer, argb_pixels: []const vp8l_pixel.Pixel) void {
    writeFourByteRows(.rgba, dest, argb_pixels);
}

fn writeBgraRows(dest: image.Buffer, argb_pixels: []const vp8l_pixel.Pixel) void {
    writeFourByteRows(.bgra, dest, argb_pixels);
}

fn writeArgbRows(dest: image.Buffer, argb_pixels: []const vp8l_pixel.Pixel) void {
    writeFourByteRows(.argb, dest, argb_pixels);
}

fn writeFourByteRows(
    comptime format: image.PixelFormat,
    dest: image.Buffer,
    argb_pixels: []const vp8l_pixel.Pixel,
) void {
    comptime assert(format.channelCount() == 4);

    const width: usize = @intCast(dest.dimensions.width);
    const stride: usize = @intCast(dest.stride);
    var y: usize = 0;
    while (y < dest.dimensions.height) : (y += 1) {
        const source_row = argb_pixels[y * width ..][0..width];
        const target_row = dest.pixels[y * stride ..][0 .. width * 4];
        var x: usize = 0;
        while (x + output_vector_pixels <= width) : (x += output_vector_pixels) {
            const source: OutputPixelVector =
                source_row[x..][0..output_vector_pixels].*;
            const packed_pixels = packOutputPixels(format, source);
            @memcpy(
                target_row[x * 4 ..][0 .. output_vector_pixels * 4],
                std.mem.asBytes(&packed_pixels),
            );
        }
        while (x < width) : (x += 1) {
            writePixel(target_row[x * 4 ..][0..4], format, source_row[x]);
        }
    }
}

fn packOutputPixels(
    comptime format: image.PixelFormat,
    source: OutputPixelVector,
) OutputPixelVector {
    comptime assert(format.channelCount() == 4);

    const eight: @Vector(output_vector_pixels, u5) = @splat(8);
    const sixteen: @Vector(output_vector_pixels, u5) = @splat(16);
    const twenty_four: @Vector(output_vector_pixels, u5) = @splat(24);
    const byte_swapped =
        ((source & @as(OutputPixelVector, @splat(0xff00_0000))) >> twenty_four) |
        ((source & @as(OutputPixelVector, @splat(0x00ff_0000))) >> eight) |
        ((source & @as(OutputPixelVector, @splat(0x0000_ff00))) << eight) |
        ((source & @as(OutputPixelVector, @splat(0x0000_00ff))) << twenty_four);

    if (comptime native_endian == .little) {
        return switch (format) {
            .rgba => (source & @as(OutputPixelVector, @splat(0xff00_ff00))) |
                ((source & @as(OutputPixelVector, @splat(0x00ff_0000))) >> sixteen) |
                ((source & @as(OutputPixelVector, @splat(0x0000_00ff))) << sixteen),
            .bgra => source,
            .argb => byte_swapped,
            .rgb => comptime unreachable,
        };
    }
    return switch (format) {
        .rgba => (source << eight) | (source >> twenty_four),
        .bgra => byte_swapped,
        .argb => source,
        .rgb => comptime unreachable,
    };
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

    const pixel_count = try dimensions.pixelCount();
    // This stream has no transforms and is below the large-image entropy
    // scratch threshold, so only the ARGB reconstruction plus packed output
    // precede prefix-group allocation.
    const pre_group_bytes =
        @as(u64, @sizeOf(vp8l_pixel.Pixel)) * pixel_count +
        @as(u64, image.PixelFormat.rgba.channelCount()) * pixel_count;
    const group_limit =
        pre_group_bytes + @as(u64, @sizeOf(vp8l_image_data.PrefixCodeGroup)) - 1;

    try std.testing.expectError(
        error.AllocationLimitExceeded,
        decodeStatic(std.testing.allocator, encoded, .{
            .limits = .{
                .allocation_bytes_max = group_limit,
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

test "decodeStaticInto writes every lossy format without touching slack" {
    const corpus = @import("testing/corpus.zig");

    const bytes = corpus.readFileAlloc(std.testing.allocator, "test.webp", .{}) catch |err| switch (err) {
        error.CorpusUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(bytes);

    const formats = [_]image.PixelFormat{ .rgb, .rgba, .bgra, .argb };
    const sentinel: u8 = 0xa5;
    for (formats) |format| {
        var expected = try decodeStatic(std.testing.allocator, bytes, .{
            .output_format = format,
        });
        defer expected.deinit();

        const row_bytes: usize = @intCast(try expected.buffer.rowBytes());
        const stride = row_bytes + 5;
        const height: usize = @intCast(expected.buffer.dimensions.height);
        const tail_bytes = 7;
        const dest_pixels = try std.testing.allocator.alloc(
            u8,
            stride * height + tail_bytes,
        );
        defer std.testing.allocator.free(dest_pixels);
        @memset(dest_pixels, sentinel);

        const dest = image.Buffer{
            .pixels = dest_pixels,
            .dimensions = expected.buffer.dimensions,
            .stride = @intCast(stride),
            .format = format,
        };
        try decodeStaticInto(std.testing.allocator, bytes, dest, .{
            .output_format = .bgra,
        });

        var y: usize = 0;
        while (y < height) : (y += 1) {
            const expected_row = expected.buffer.pixels[y * row_bytes ..][0..row_bytes];
            const actual_row = dest_pixels[y * stride ..][0..row_bytes];
            try std.testing.expectEqualSlices(u8, expected_row, actual_row);
            for (dest_pixels[y * stride + row_bytes ..][0 .. stride - row_bytes]) |value| {
                try std.testing.expectEqual(sentinel, value);
            }
        }
        for (dest_pixels[stride * height ..]) |value| {
            try std.testing.expectEqual(sentinel, value);
        }
    }
}

test "decodeStaticInto does not charge caller-owned lossy output" {
    const corpus = @import("testing/corpus.zig");

    const bytes = corpus.readFileAlloc(std.testing.allocator, "test.webp", .{}) catch |err| switch (err) {
        error.CorpusUnavailable => return error.SkipZigTest,
        else => return err,
    };
    defer std.testing.allocator.free(bytes);

    const source = try parseStaticSource(std.testing.allocator, bytes, .{});
    var parsed: vp8_frame_header.Parsed = undefined;
    try vp8_frame_header.parse(source.bitstream, &parsed);
    const frame_allocation_bytes = try vp8_decoder.allocationBytesParsed(&parsed, .{
        .apply_loop_filter = true,
    });

    const output_len: usize = @intCast(try outputByteLength(source.dimensions, .rgba));
    const dest_pixels = try std.testing.allocator.alloc(u8, output_len);
    defer std.testing.allocator.free(dest_pixels);
    const dest = image.Buffer{
        .pixels = dest_pixels,
        .dimensions = source.dimensions,
        .stride = @intCast(try rowByteLength(source.dimensions, .rgba)),
        .format = .rgba,
    };

    try decodeStaticInto(std.testing.allocator, bytes, dest, .{
        .limits = .{
            .allocation_bytes_max = frame_allocation_bytes,
        },
    });
    try std.testing.expectError(
        error.AllocationLimitExceeded,
        decodeStatic(std.testing.allocator, bytes, .{
            .limits = .{
                .allocation_bytes_max = frame_allocation_bytes,
            },
        }),
    );
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

test "four-byte row vectors match scalar conversion exhaustively" {
    const formats = [_]image.PixelFormat{ .rgba, .bgra, .argb };
    const widths = [_]u32{ 1, 7, 8, 9, 15, 16, 17 };
    const sentinel: u8 = 0xa5;

    inline for (formats) |format| {
        for (widths) |width| {
            const dimensions = try image.Dimensions.init(width, 2);
            const width_usize: usize = @intCast(width);
            const row_bytes = width_usize * 4;
            const stride = row_bytes + 5;
            var alpha_value: u16 = 0;
            while (alpha_value <= 255) : (alpha_value += 1) {
                var source: [17 * 2]vp8l_pixel.Pixel = undefined;
                for (source[0 .. width_usize * 2], 0..) |*pixel, pixel_index| {
                    pixel.* = vp8l_pixel.fromChannels(
                        @intCast(alpha_value),
                        @truncate(pixel_index * 73 + alpha_value),
                        @truncate(pixel_index * 29 + alpha_value * 3),
                        @truncate(pixel_index * 11 + alpha_value * 7),
                    );
                }

                var expected: [17 * 2 * 4]u8 = undefined;
                writePixels(
                    expected[0 .. row_bytes * 2],
                    format,
                    source[0 .. width_usize * 2],
                );

                var in_place = source;
                const in_place_pixels = in_place[0 .. width_usize * 2];
                convertPixelsInPlace(format, in_place_pixels);
                try std.testing.expectEqualSlices(
                    u8,
                    expected[0 .. row_bytes * 2],
                    std.mem.sliceAsBytes(in_place_pixels),
                );

                var storage: [1 + (17 * 4 + 5) * 2 + 7]u8 = @splat(sentinel);
                const target = storage[1..][0 .. stride * 2 + 7];
                writeFourByteRows(format, .{
                    .pixels = target,
                    .dimensions = dimensions,
                    .stride = @intCast(stride),
                    .format = format,
                }, source[0 .. width_usize * 2]);

                try std.testing.expectEqualSlices(
                    u8,
                    expected[0..row_bytes],
                    target[0..row_bytes],
                );
                try std.testing.expectEqualSlices(
                    u8,
                    expected[row_bytes .. row_bytes * 2],
                    target[stride..][0..row_bytes],
                );
                for (target[row_bytes..stride]) |byte| {
                    try std.testing.expectEqual(sentinel, byte);
                }
                for (target[stride + row_bytes .. stride * 2]) |byte| {
                    try std.testing.expectEqual(sentinel, byte);
                }

                for (target[stride * 2 ..]) |byte| {
                    try std.testing.expectEqual(sentinel, byte);
                }
            }
        }
    }
}

test "direct VP8L output requires tight aligned four-byte storage" {
    const dimensions = try image.Dimensions.init(2, 1);
    var storage: [2 * 4 + 7]u8 align(@alignOf(vp8l_pixel.Pixel)) = undefined;

    const eligible = image.Buffer{
        .pixels = &storage,
        .dimensions = dimensions,
        .stride = 2 * 4,
        .format = .rgba,
    };
    const pixels = directOutputPixels(eligible) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), pixels.len);

    var padded = eligible;
    padded.stride += 4;
    try std.testing.expectEqual(null, directOutputPixels(padded));

    var rgb = eligible;
    rgb.format = .rgb;
    rgb.stride = 2 * 3;
    try std.testing.expectEqual(null, directOutputPixels(rgb));

    var unaligned = eligible;
    unaligned.pixels = storage[1..];
    try std.testing.expectEqual(null, directOutputPixels(unaligned));
}

test "VP8L scratch capacities cover rounded blocks and format maxima" {
    const rounded = try image.Dimensions.init(5, 9);
    try std.testing.expectEqual(@as(u64, 6), try entropyPixelCapacity(rounded));
    try std.testing.expectEqual(@as(u64, 268), try transformPixelCapacity(rounded));

    const maximum = try image.Dimensions.init(
        vp8l_header.dimension_limit,
        vp8l_header.dimension_limit,
    );
    try std.testing.expectEqual(
        @as(u64, 16_777_216),
        try entropyPixelCapacity(maximum),
    );
    try std.testing.expectEqual(
        @as(u64, 33_554_688),
        try transformPixelCapacity(maximum),
    );

    const single = try image.Dimensions.init(1, 1);
    try std.testing.expectEqual(@as(u64, 258), try transformPixelCapacity(single));
    try std.testing.expectEqual(
        @as(u64, 0),
        try transformPixelCapacityForStream(single, &.{0}),
    );
}

test "lossless decodeStaticInto budgets probed reconstruction scratch" {
    const dimensions = try image.Dimensions.init(8, 8);
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
    // The direct decodeInto path does not charge caller-owned output. For this
    // tiny stream, the demuxer's temporary chunk-list allocation is the limit.
    // Owned decode charges only its final output, not another ARGB image.
    const output_bytes = pixel_count * @sizeOf(vp8l_pixel.Pixel);
    var dest_pixels: [8 * 8 * 4]u8 = undefined;
    const dest = image.Buffer{
        .pixels = &dest_pixels,
        .dimensions = dimensions,
        .stride = 8 * 4,
        .format = .rgba,
    };

    try decodeStaticInto(std.testing.allocator, encoded, dest, .{
        .limits = .{ .allocation_bytes_max = output_bytes },
    });
    try std.testing.expectError(error.AllocationLimitExceeded, decodeStaticInto(
        std.testing.allocator,
        encoded,
        dest,
        .{ .limits = .{ .allocation_bytes_max = output_bytes - 1 } },
    ));
    var decoded = try decodeStatic(std.testing.allocator, encoded, .{
        .limits = .{ .allocation_bytes_max = output_bytes },
    });
    decoded.deinit();
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
