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
