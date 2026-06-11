//! VP8L inverse transform application.

const std = @import("std");
const assert = std.debug.assert;

const errors = @import("../errors.zig");
const image = @import("../image.zig");
const pixel = @import("pixel.zig");
const transform = @import("transform.zig");

pub fn applyTransform(
    transform_value: transform.Transform,
    dimensions: image.Dimensions,
    pixels: []pixel.Pixel,
) errors.Error!void {
    const pixel_count = try dimensions.pixelCount();
    if (pixels.len < pixel_count) return error.OutputTooLarge;

    const image_pixels = pixels[0..@intCast(pixel_count)];
    switch (transform_value) {
        .subtract_green => applySubtractGreen(image_pixels),
        .predictor,
        .color,
        .color_indexing,
        => return error.UnsupportedVP8LImageData,
    }
}

pub fn applySubtractGreen(pixels: []pixel.Pixel) void {
    for (pixels) |*value| {
        const green_value = pixel.green(value.*);
        const red_value = pixel.red(value.*) +% green_value;
        const blue_value = pixel.blue(value.*) +% green_value;

        value.* = pixel.fromChannels(
            pixel.alpha(value.*),
            red_value,
            green_value,
            blue_value,
        );
    }
}

pub fn applyColorTransform(
    color_transform: transform.BlockTransform,
    color_transform_data: []const pixel.Pixel,
    dimensions: image.Dimensions,
    pixels: []pixel.Pixel,
) errors.Error!void {
    try validateBlockTransform(color_transform, dimensions);

    const transform_pixel_count = try color_transform.image.pixelCount();
    if (color_transform_data.len < transform_pixel_count) return error.InvalidVP8LTransform;

    const pixel_count = try dimensions.pixelCount();
    if (pixels.len < pixel_count) return error.OutputTooLarge;

    const width: usize = @intCast(dimensions.width);
    const transform_width: usize = @intCast(color_transform.image.width);
    const block_bits: u5 = @intCast(color_transform.block_bits);

    var pixel_index: usize = 0;
    while (pixel_index < pixel_count) : (pixel_index += 1) {
        const x = pixel_index % width;
        const y = pixel_index / width;
        const transform_x = x >> block_bits;
        const transform_y = y >> block_bits;
        const transform_index = transform_y * transform_width + transform_x;
        assert(transform_index < color_transform_data.len);

        pixels[pixel_index] = applyColorTransformPixel(
            color_transform_data[transform_index],
            pixels[pixel_index],
        );
    }
}

pub fn applyColorTransformPixel(
    color_transform_element: pixel.Pixel,
    value: pixel.Pixel,
) pixel.Pixel {
    const green_to_red = pixel.blue(color_transform_element);
    const green_to_blue = pixel.green(color_transform_element);
    const red_to_blue = pixel.red(color_transform_element);

    const green_value = pixel.green(value);
    const red_value = addDelta(
        pixel.red(value),
        colorTransformDelta(green_to_red, green_value),
    );
    const blue_value = addDelta(
        addDelta(
            pixel.blue(value),
            colorTransformDelta(green_to_blue, green_value),
        ),
        colorTransformDelta(red_to_blue, red_value),
    );

    return pixel.fromChannels(
        pixel.alpha(value),
        red_value,
        green_value,
        blue_value,
    );
}

fn colorTransformDelta(transform_byte: u8, channel_byte: u8) i32 {
    const transform_signed: i8 = @bitCast(transform_byte);
    const channel_signed: i8 = @bitCast(channel_byte);
    const product = @as(i32, transform_signed) * @as(i32, channel_signed);

    return product >> 5;
}

fn addDelta(value: u8, delta: i32) u8 {
    return @intCast(@mod(@as(i32, value) + delta, 256));
}

fn validateBlockTransform(
    block_transform: transform.BlockTransform,
    dimensions: image.Dimensions,
) errors.Error!void {
    if (block_transform.block_bits < transform.block_bits_min) return error.InvalidVP8LTransform;
    if (block_transform.block_bits > transform.block_bits_max) return error.InvalidVP8LTransform;
    if (block_transform.block_size != (@as(u32, 1) << @as(u5, block_transform.block_bits))) {
        return error.InvalidVP8LTransform;
    }
    if (block_transform.image.width != divRoundUp(dimensions.width, block_transform.block_size)) {
        return error.InvalidVP8LTransform;
    }
    if (block_transform.image.height != divRoundUp(dimensions.height, block_transform.block_size)) {
        return error.InvalidVP8LTransform;
    }
}

fn divRoundUp(numerator: u32, denominator: u32) u32 {
    assert(numerator > 0);
    assert(denominator > 0);

    return ((numerator - 1) / denominator) + 1;
}

comptime {
    assert(@bitSizeOf(pixel.Pixel) == 32);
}

test "VP8L inverse subtract-green adds green to red and blue modulo 256" {
    var pixels = [_]pixel.Pixel{
        pixel.fromChannels(1, 2, 3, 4),
        pixel.fromChannels(255, 250, 10, 251),
    };

    applySubtractGreen(&pixels);

    try std.testing.expectEqual(pixel.fromChannels(1, 5, 3, 7), pixels[0]);
    try std.testing.expectEqual(pixel.fromChannels(255, 4, 10, 5), pixels[1]);
}

test "VP8L inverse transform dispatcher applies subtract-green within dimensions" {
    var pixels = [_]pixel.Pixel{
        pixel.fromChannels(1, 2, 3, 4),
        pixel.fromChannels(9, 9, 9, 9),
    };

    try applyTransform(
        .{ .subtract_green = {} },
        try image.Dimensions.init(1, 1),
        &pixels,
    );

    try std.testing.expectEqual(pixel.fromChannels(1, 5, 3, 7), pixels[0]);
    try std.testing.expectEqual(pixel.fromChannels(9, 9, 9, 9), pixels[1]);
}

test "VP8L inverse transform dispatcher rejects unimplemented transforms" {
    var pixels = [_]pixel.Pixel{pixel.fromChannels(1, 2, 3, 4)};
    const dimensions = try image.Dimensions.init(1, 1);
    const block = transform.BlockTransform{
        .block_bits = transform.block_bits_min,
        .block_size = @as(u32, 1) << transform.block_bits_min,
        .image = dimensions,
    };

    try std.testing.expectError(
        error.UnsupportedVP8LImageData,
        applyTransform(.{ .predictor = block }, dimensions, &pixels),
    );
}

test "VP8L inverse color transform applies signed 3.5 fixed-point deltas" {
    const transform_pixel = pixel.fromChannels(
        255,
        32,
        64,
        32,
    );
    const value = pixel.fromChannels(7, 10, 5, 20);

    try std.testing.expectEqual(
        pixel.fromChannels(7, 15, 5, 45),
        applyColorTransformPixel(transform_pixel, value),
    );
}

test "VP8L inverse color transform wraps negative deltas modulo 256" {
    const transform_pixel = pixel.fromChannels(
        255,
        0,
        0,
        0xff,
    );
    const value = pixel.fromChannels(7, 1, 64, 20);

    try std.testing.expectEqual(
        pixel.fromChannels(7, 255, 64, 20),
        applyColorTransformPixel(transform_pixel, value),
    );
}

test "VP8L inverse color transform applies per-block coefficients" {
    var pixels = [_]pixel.Pixel{
        pixel.fromChannels(1, 10, 5, 20),
        pixel.fromChannels(2, 10, 5, 20),
        pixel.fromChannels(3, 10, 5, 20),
        pixel.fromChannels(4, 10, 5, 20),
        pixel.fromChannels(5, 1, 64, 20),
    };
    const color_transform_data = [_]pixel.Pixel{
        pixel.fromChannels(255, 32, 64, 32),
        pixel.fromChannels(255, 0, 0, 0xff),
    };
    const dimensions = try image.Dimensions.init(5, 1);
    const color_transform = transform.BlockTransform{
        .block_bits = transform.block_bits_min,
        .block_size = @as(u32, 1) << transform.block_bits_min,
        .image = try image.Dimensions.init(2, 1),
    };

    try applyColorTransform(color_transform, &color_transform_data, dimensions, &pixels);

    try std.testing.expectEqual(pixel.fromChannels(1, 15, 5, 45), pixels[0]);
    try std.testing.expectEqual(pixel.fromChannels(2, 15, 5, 45), pixels[1]);
    try std.testing.expectEqual(pixel.fromChannels(3, 15, 5, 45), pixels[2]);
    try std.testing.expectEqual(pixel.fromChannels(4, 15, 5, 45), pixels[3]);
    try std.testing.expectEqual(pixel.fromChannels(5, 255, 64, 20), pixels[4]);
}

test "VP8L inverse color transform validates block metadata and buffers" {
    var pixels = [_]pixel.Pixel{pixel.fromChannels(1, 2, 3, 4)};
    const transform_data = [_]pixel.Pixel{pixel.fromChannels(255, 0, 0, 0)};
    const dimensions = try image.Dimensions.init(1, 1);
    const bad_transform = transform.BlockTransform{
        .block_bits = transform.block_bits_min,
        .block_size = 1,
        .image = try image.Dimensions.init(1, 1),
    };

    try std.testing.expectError(
        error.InvalidVP8LTransform,
        applyColorTransform(bad_transform, &transform_data, dimensions, &pixels),
    );
    try std.testing.expectError(
        error.OutputTooLarge,
        applyColorTransform(.{
            .block_bits = transform.block_bits_min,
            .block_size = @as(u32, 1) << transform.block_bits_min,
            .image = try image.Dimensions.init(1, 1),
        }, &transform_data, dimensions, &.{}),
    );
}
