//! Public static-image encode composition.
//!
//! Slice 1 covers lossless (VP8L) still encode from a caller-supplied pixel
//! buffer: it builds the VP8L bitstream (literals only) and muxes it into a
//! canonical simple `VP8L` WebP file. The result round-trips bit-exactly
//! through this library's decoder.

const std = @import("std");
const assert = std.debug.assert;

const errors = @import("errors.zig");
const features = @import("features.zig");
const image = @import("image.zig");
const mux = @import("mux.zig");
const options = @import("options.zig");
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
