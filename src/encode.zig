//! Public static-image encode composition.
//!
//! Slice 1 covers lossless (VP8L) still encode from a caller-supplied pixel
//! buffer: it builds the VP8L bitstream (literals only) and muxes it into a
//! canonical simple `VP8L` WebP file. The result round-trips bit-exactly
//! through this library's decoder.

const std = @import("std");
const assert = std.debug.assert;

const color = @import("color.zig");
const container = @import("container.zig");
const errors = @import("errors.zig");
const features = @import("features.zig");
const image = @import("image.zig");
const limits = @import("limits.zig");
const mux = @import("mux.zig");
const options = @import("options.zig");
const vp8_encoder = @import("vp8/encoder.zig");
const vp8_quant = @import("vp8/quant.zig");
const vp8l_encoder = @import("vp8l/encoder.zig");
const vp8l_pixel = @import("vp8l/pixel.zig");

/// Encodes a caller-supplied pixel buffer into a complete lossless (VP8L) WebP
/// file. The buffer's `format` may be any 4-channel layout (`rgba`, `bgra`,
/// `argb`) or `rgb` (treated as fully opaque); pixels are read row-major using
/// the buffer's `stride`. The returned bytes are caller-owned (free with `gpa`).
///
/// `encode_options.format` must be `.lossless`; lossy encode is a later step.
pub fn encodeStaticLossless(
    gpa: std.mem.Allocator,
    buffer: image.Buffer,
    encode_options: options.EncoderOptions,
) errors.Error![]u8 {
    if (encode_options.format != .lossless) return error.UnsupportedImageFormat;
    try buffer.validate();

    const dimensions = buffer.dimensions;
    const pixel_count: usize = @intCast(try dimensions.pixelCount());

    try encode_options.limits.validateCanvas(dimensions.width, dimensions.height, false);
    const argb = try gpa.alloc(vp8l_pixel.Pixel, pixel_count);
    defer gpa.free(argb);
    gatherArgb(buffer, argb);

    const bitstream = try vp8l_encoder.encodeAlloc(gpa, dimensions, argb);
    defer gpa.free(bitstream);

    return mux.encodeStatic(gpa, .{
        .canvas = dimensions,
        .format = .lossless,
        .bitstream = bitstream,
    }, .{ .limits = encode_options.limits });
}

/// Encodes a caller-supplied pixel buffer into a complete lossy (VP8) WebP file
/// with the step 8a baseline encoder: a fixed all-DC mode decision, no loop
/// filter, and default coefficient probabilities. The buffer's `format` may be
/// any supported layout; the alpha channel is dropped (lossy alpha via `ALPH`
/// is step 8c), so RGBA input encodes color only. `encode_options.quality`
/// (0..100) selects the quantizer. `encode_options.format` must be `.lossy`.
/// The returned bytes are caller-owned (free with `gpa`).
pub fn encodeStaticLossy(
    gpa: std.mem.Allocator,
    buffer: image.Buffer,
    encode_options: options.EncoderOptions,
) errors.Error![]u8 {
    if (encode_options.format != .lossy) return error.UnsupportedImageFormat;
    try buffer.validate();

    const dimensions = buffer.dimensions;
    if (dimensions.width > vp8_encoder.dimension_max or
        dimensions.height > vp8_encoder.dimension_max)
    {
        return error.InvalidCanvasSize;
    }
    try encode_options.limits.validateCanvas(dimensions.width, dimensions.height, false);
    const pixel_count_u64 = try dimensions.pixelCount();
    try validateLossyInitialAllocationBudget(
        dimensions,
        pixel_count_u64,
        encode_options.limits,
    );
    const pixel_count: usize = @intCast(pixel_count_u64);

    const argb = try gpa.alloc(vp8l_pixel.Pixel, pixel_count);
    defer gpa.free(argb);
    gatherArgb(buffer, argb);

    var source = if (encode_options.use_sharp_yuv)
        try color.rgbaToYuv420SharpAlloc(gpa, argb, dimensions.width, dimensions.height)
    else
        try color.rgbaToYuv420Alloc(gpa, argb, dimensions.width, dimensions.height);
    defer source.deinit(gpa);

    const base_quant_index = vp8_quant.baseQuantIndexForQuality(encode_options.quality);
    var result = try vp8_encoder.encodeAlloc(gpa, &source, .{
        .base_quant_index = base_quant_index,
        .method = encode_options.method,
    });
    defer result.deinit(gpa);

    try validateLossyMuxAllocationBudget(
        dimensions,
        pixel_count_u64,
        result.bitstream.len,
        encode_options.limits,
    );

    return mux.encodeStatic(gpa, .{
        .canvas = dimensions,
        .format = .lossy,
        .bitstream = result.bitstream,
    }, .{ .limits = encode_options.limits });
}

/// Encodes a packed-ARGB pixel array (`0xAARRGGBB`, row-major, length
/// `width*height`) into a raw VP8 bitstream — the payload of a `VP8 ` chunk,
/// without the RIFF container. `quality` is 0..100. Most callers want
/// `encodeStaticLossy`; this is for tooling that muxes the bitstream itself.
/// Returns caller-owned bytes (free with `gpa`).
pub fn encodeVP8Bitstream(
    gpa: std.mem.Allocator,
    dimensions: image.Dimensions,
    pixels: []const vp8l_pixel.Pixel,
    quality: u8,
) errors.Error![]u8 {
    if (dimensions.width > vp8_encoder.dimension_max or
        dimensions.height > vp8_encoder.dimension_max)
    {
        return error.InvalidCanvasSize;
    }
    if (pixels.len != @as(usize, @intCast(try dimensions.pixelCount()))) {
        return error.InvalidCanvasSize;
    }

    var source = try color.rgbaToYuv420Alloc(gpa, pixels, dimensions.width, dimensions.height);
    defer source.deinit(gpa);

    var result = try vp8_encoder.encodeAlloc(gpa, &source, .{
        .base_quant_index = vp8_quant.baseQuantIndexForQuality(quality),
    });
    result.reconstruction.deinit(gpa);
    return result.bitstream;
}

const AllocationBudget = struct {
    resource_limits: limits.ResourceLimits,
    bytes: u64 = 0,

    fn init(resource_limits: limits.ResourceLimits) AllocationBudget {
        return .{ .resource_limits = resource_limits };
    }

    fn reserveElements(
        self: *AllocationBudget,
        comptime T: type,
        count: u64,
    ) errors.Error!void {
        try self.reserveBytes(try elementByteCount(T, count));
    }

    fn reserveBytes(self: *AllocationBudget, bytes: u64) errors.Error!void {
        if (bytes > std.math.maxInt(u64) - self.bytes) return error.AllocationLimitExceeded;
        self.bytes += bytes;
        try self.resource_limits.validateAllocationBytes(self.bytes);
    }
};

fn validateLossyInitialAllocationBudget(
    dimensions: image.Dimensions,
    pixel_count: u64,
    resource_limits: limits.ResourceLimits,
) errors.Error!void {
    var budget = AllocationBudget.init(resource_limits);
    try budget.reserveElements(vp8l_pixel.Pixel, pixel_count);
    try budget.reserveBytes(try color.yuv420AllocationBytes(dimensions.width, dimensions.height));
    try budget.reserveBytes(try vp8_encoder.allocationBytesMax(dimensions));
}

fn validateLossyMuxAllocationBudget(
    dimensions: image.Dimensions,
    pixel_count: u64,
    bitstream_len: usize,
    resource_limits: limits.ResourceLimits,
) errors.Error!void {
    var budget = AllocationBudget.init(resource_limits);
    try budget.reserveElements(vp8l_pixel.Pixel, pixel_count);

    const yuv_bytes = try color.yuv420AllocationBytes(dimensions.width, dimensions.height);
    try budget.reserveBytes(yuv_bytes);
    try budget.reserveBytes(yuv_bytes);
    try budget.reserveBytes(@intCast(bitstream_len));
    try budget.reserveBytes(try simpleLossyWebPFileBytes(bitstream_len));
}

fn simpleLossyWebPFileBytes(bitstream_len: usize) errors.Error!u64 {
    const payload_size: u64 = @intCast(bitstream_len);
    if (payload_size > std.math.maxInt(u32)) return error.ChunkTooLarge;

    var bytes = @as(u64, container.riff_header_size + container.chunk_header_size);
    bytes = try addByteCounts(bytes, payload_size);
    bytes = try addByteCounts(bytes, payload_size & 1);
    return bytes;
}

fn elementByteCount(comptime T: type, count: u64) errors.Error!u64 {
    if (count > std.math.maxInt(u64) / @sizeOf(T)) return error.AllocationLimitExceeded;
    return count * @sizeOf(T);
}

fn addByteCounts(a: u64, b: u64) errors.Error!u64 {
    return std.math.add(u64, a, b) catch error.AllocationLimitExceeded;
}

/// Reads the caller buffer's pixels (any supported format, honoring stride)
/// into packed ARGB `vp8l_pixel.Pixel` values in row-major order.
fn gatherArgb(buffer: image.Buffer, argb: []vp8l_pixel.Pixel) void {
    const width: usize = buffer.dimensions.width;
    const height: usize = buffer.dimensions.height;
    const stride: usize = buffer.stride;
    const channels: usize = @intCast(buffer.format.channelCount());
    assert(argb.len == width * height);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = buffer.pixels[y * stride ..][0 .. width * channels];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const sample = row[x * channels ..][0..channels];
            argb[y * width + x] = pixelFromSample(buffer.format, sample);
        }
    }
}

fn pixelFromSample(format: image.PixelFormat, sample: []const u8) vp8l_pixel.Pixel {
    return switch (format) {
        .rgb => vp8l_pixel.fromChannels(255, sample[0], sample[1], sample[2]),
        .rgba => vp8l_pixel.fromChannels(sample[3], sample[0], sample[1], sample[2]),
        .bgra => vp8l_pixel.fromChannels(sample[3], sample[2], sample[1], sample[0]),
        .argb => vp8l_pixel.fromChannels(sample[0], sample[1], sample[2], sample[3]),
    };
}

/// Allocates a row-major packed-ARGB copy of `buffer` (any supported format,
/// honoring stride) — the input the YUV converter and the VP8/VP8L encoders
/// take. Caller owns the result (free with `gpa`).
pub fn gatherArgbAlloc(
    gpa: std.mem.Allocator,
    buffer: image.Buffer,
) std.mem.Allocator.Error![]vp8l_pixel.Pixel {
    const pixel_count: usize = @as(usize, buffer.dimensions.width) * buffer.dimensions.height;
    const argb = try gpa.alloc(vp8l_pixel.Pixel, pixel_count);
    errdefer gpa.free(argb);
    gatherArgb(buffer, argb);
    return argb;
}

const testing = std.testing;

test "encodeStaticLossless round-trips RGBA through the decoder" {
    const decode = @import("decode.zig");

    const width = 5;
    const height = 4;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const base = (y * width + x) * 4;
            pixels[base + 0] = @intCast((x * 50) % 256);
            pixels[base + 1] = @intCast((y * 60) % 256);
            pixels[base + 2] = @intCast((x + y) * 10);
            pixels[base + 3] = @intCast(200 + x);
        }
    }

    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    const encoded = try encodeStaticLossless(testing.allocator, buffer, .{});
    defer testing.allocator.free(encoded);

    var decoded = try decode.decodeStatic(testing.allocator, encoded, .{ .output_format = .rgba });
    defer decoded.deinit();

    try testing.expectEqual(dims.width, decoded.buffer.dimensions.width);
    try testing.expectEqual(dims.height, decoded.buffer.dimensions.height);
    try testing.expectEqualSlices(u8, &pixels, decoded.buffer.pixels);
}

test "encodeStaticLossless honors stride and bgra input" {
    const decode = @import("decode.zig");

    const width = 3;
    const height = 2;
    const stride = width * 4 + 5; // padded rows
    const dims = try image.Dimensions.init(width, height);
    var pixels: [stride * height]u8 = undefined;
    @memset(&pixels, 0);
    for (0..height) |y| {
        for (0..width) |x| {
            const base = y * stride + x * 4;
            pixels[base + 0] = @intCast(10 + x); // B
            pixels[base + 1] = @intCast(20 + y); // G
            pixels[base + 2] = @intCast(30 + x + y); // R
            pixels[base + 3] = @intCast(100 + x); // A
        }
    }

    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = stride,
        .format = .bgra,
    };

    const encoded = try encodeStaticLossless(testing.allocator, buffer, .{});
    defer testing.allocator.free(encoded);

    var decoded = try decode.decodeStatic(testing.allocator, encoded, .{ .output_format = .bgra });
    defer decoded.deinit();

    // Compare per-pixel (decoded output is tightly packed; source has padding).
    for (0..height) |y| {
        for (0..width) |x| {
            const src = pixels[y * stride + x * 4 ..][0..4];
            const out = decoded.buffer.pixels[(y * width + x) * 4 ..][0..4];
            try testing.expectEqualSlices(u8, src, out);
        }
    }
}

test "encodeStaticLossless rejects lossy format requests" {
    const dims = try image.Dimensions.init(1, 1);
    var pixels = [_]u8{ 1, 2, 3, 4 };
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = 4,
        .format = .rgba,
    };
    try testing.expectError(
        error.UnsupportedImageFormat,
        encodeStaticLossless(testing.allocator, buffer, .{ .format = .lossy }),
    );
}

fn encodeAllocationProbe(gpa: std.mem.Allocator, buffer: image.Buffer) !void {
    const encoded = try encodeStaticLossless(gpa, buffer, .{});
    gpa.free(encoded);
}

test "lossless static encode survives allocation failure at every site" {
    const width = 4;
    const height = 3;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height * 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i % 256);

    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    try testing.checkAllAllocationFailures(testing.allocator, encodeAllocationProbe, .{buffer});
}

test "encodeStaticLossy produces a decodable VP8 WebP at the source size" {
    const decode = @import("decode.zig");

    const width = 18;
    const height = 10;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const base = (y * width + x) * 4;
            pixels[base + 0] = @intCast((x * 14) % 256);
            pixels[base + 1] = @intCast((y * 25) % 256);
            pixels[base + 2] = @intCast(((x + y) * 8) % 256);
            pixels[base + 3] = 255;
        }
    }

    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    const encoded = try encodeStaticLossy(testing.allocator, buffer, .{ .format = .lossy });
    defer testing.allocator.free(encoded);

    // It must decode without error at the right size (lossy, so not bit-exact;
    // fidelity is covered by the encoder self-consistency and corpus PSNR tests).
    var decoded = try decode.decodeStatic(testing.allocator, encoded, .{ .output_format = .rgba });
    defer decoded.deinit();
    try testing.expectEqual(dims.width, decoded.buffer.dimensions.width);
    try testing.expectEqual(dims.height, decoded.buffer.dimensions.height);
}

test "encodeStaticLossy rejects non-lossy format requests" {
    const dims = try image.Dimensions.init(1, 1);
    var pixels = [_]u8{ 1, 2, 3, 4 };
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = 4,
        .format = .rgba,
    };
    try testing.expectError(
        error.UnsupportedImageFormat,
        encodeStaticLossy(testing.allocator, buffer, .{ .format = .lossless }),
    );
}

test "encodeStaticLossy counts VP8 scratch against allocation limits" {
    const width = 32;
    const height = 32;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height * 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i % 256);

    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    var pre_vp8_budget = AllocationBudget.init(.{
        .allocation_bytes_max = std.math.maxInt(u64),
    });
    const pixel_count = try dims.pixelCount();
    try pre_vp8_budget.reserveElements(vp8l_pixel.Pixel, pixel_count);
    try pre_vp8_budget.reserveBytes(try color.yuv420AllocationBytes(width, height));

    try testing.expectError(
        error.AllocationLimitExceeded,
        encodeStaticLossy(testing.allocator, buffer, .{
            .format = .lossy,
            .limits = .{ .allocation_bytes_max = pre_vp8_budget.bytes + 1 },
        }),
    );
}

fn encodeLossyAllocationProbe(gpa: std.mem.Allocator, buffer: image.Buffer) !void {
    const encoded = try encodeStaticLossy(gpa, buffer, .{ .format = .lossy });
    gpa.free(encoded);
}

test "lossy static encode survives allocation failure at every site" {
    const width = 17; // partial macroblock exercises the padding path too
    const height = 9;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height * 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i % 256);

    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    try testing.checkAllAllocationFailures(testing.allocator, encodeLossyAllocationProbe, .{buffer});
}
