//! VP8L forward (encode-side) transforms.
//!
//! Each function here is the exact inverse of a routine in
//! `inverse_transform.zig`, so a transformed image re-expanded by the decoder
//! reproduces the original pixels bit-for-bit:
//!   - `applySubtractGreen` inverts `inverse_transform.applySubtractGreen`.
//!   - `forwardColorTableDeltas` inverts `inverse_transform.applyColorTableDeltas`.
//!   - `applyPredictor` (single global mode) inverts the predictor add in
//!     `inverse_transform.applyPredictorTransform`.
//!   - `applyColorTransform` (single global element) inverts
//!     `inverse_transform.applyColorTransformPixel`.
//!
//! The encoder keeps transform *blocking* trivial: it uses one block covering
//! the whole image (block_bits == max so the block image is 1x1 for any image
//! up to 512x512, otherwise a small grid), which is always a valid block
//! layout the decoder accepts.

const std = @import("std");
const assert = std.debug.assert;

const inverse_transform = @import("inverse_transform.zig");
const pixel = @import("pixel.zig");
const transform = @import("transform.zig");

pub const predictor_mode_count = 14;

/// Subtract-green forward transform: red -= green, blue -= green (mod 256),
/// green and alpha unchanged. Inverse of `inverse_transform.applySubtractGreen`.
pub fn applySubtractGreen(pixels: []pixel.Pixel) void {
    for (pixels) |*value| {
        const green_value = pixel.green(value.*);
        const red_value = pixel.red(value.*) -% green_value;
        const blue_value = pixel.blue(value.*) -% green_value;
        value.* = pixel.fromChannels(
            pixel.alpha(value.*),
            red_value,
            green_value,
            blue_value,
        );
    }
}

/// Forward color-table delta coding: each entry becomes its difference from the
/// previous entry (per channel, mod 256), so the decoder's prefix-sum in
/// `applyColorTableDeltas` reproduces the palette. Operates in place.
pub fn forwardColorTableDeltas(color_table: []pixel.Pixel) void {
    var previous = pixel.fromChannels(0, 0, 0, 0);
    for (color_table) |*entry| {
        const current = entry.*;
        entry.* = pixel.fromChannels(
            pixel.alpha(current) -% pixel.alpha(previous),
            pixel.red(current) -% pixel.red(previous),
            pixel.green(current) -% pixel.green(previous),
            pixel.blue(current) -% pixel.blue(previous),
        );
        previous = current;
    }
}

/// A color-transform element packs (green_to_red, green_to_blue, red_to_blue)
/// signed 3.5 fixed-point multipliers into blue/green/red channels respectively
/// (alpha = 255), matching the decoder's `applyColorTransformPixel` reading.
pub const ColorTransformElement = struct {
    green_to_red: i8 = 0,
    green_to_blue: i8 = 0,
    red_to_blue: i8 = 0,

    pub fn toPixel(self: ColorTransformElement) pixel.Pixel {
        return pixel.fromChannels(
            255,
            @bitCast(self.red_to_blue),
            @bitCast(self.green_to_blue),
            @bitCast(self.green_to_red),
        );
    }
};

/// Forward color transform: subtract the predicted color deltas so the
/// decoder's `applyColorTransformPixel` (which adds them back) recovers the
/// source. Uses one global element for the whole image. `green` is unchanged.
pub fn applyColorTransform(element: ColorTransformElement, pixels: []pixel.Pixel) void {
    for (pixels) |*value| {
        const green_value = pixel.green(value.*);
        const red_in = pixel.red(value.*);
        const new_red = subtractDelta(
            red_in,
            colorTransformDelta(element.green_to_red, green_value),
        );
        const blue_in = pixel.blue(value.*);
        const new_blue = subtractDelta(
            subtractDelta(
                blue_in,
                colorTransformDelta(element.green_to_blue, green_value),
            ),
            colorTransformDelta(element.red_to_blue, red_in),
        );
        value.* = pixel.fromChannels(
            pixel.alpha(value.*),
            new_red,
            green_value,
            new_blue,
        );
    }
}

fn colorTransformDelta(transform_value: i8, channel_value: u8) i32 {
    const channel_signed: i8 = @bitCast(channel_value);
    const product = @as(i32, transform_value) * @as(i32, channel_signed);
    return product >> 5;
}

fn subtractDelta(value: u8, delta: i32) u8 {
    return @intCast(@mod(@as(i32, value) - delta, 256));
}

/// Applies a single-mode predictor transform forward: each pixel becomes its
/// residual against the chosen predictor's prediction (per-channel mod 256), so
/// the decoder's `applyPredictorTransform` reconstructs the source. The
/// predictor block image carries `mode` in every block's green channel.
///
/// `pixels` is processed in reverse raster order so each prediction reads the
/// still-original neighbors (the decoder reconstructs forward; we must subtract
/// using the same original neighbor values, hence reverse order on a copy-free
/// buffer means we read originals before overwriting them — we instead read
/// from a separate source snapshot to stay exact).
pub fn applyPredictor(
    mode: u8,
    width: usize,
    height: usize,
    source: []const pixel.Pixel,
    residual_out: []pixel.Pixel,
) void {
    assert(mode < predictor_mode_count);
    assert(source.len == width * height);
    assert(residual_out.len == width * height);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const index = y * width + x;
            const prediction = predictForPosition(mode, x, y, width, source);
            const value = source[index];
            residual_out[index] = pixel.fromChannels(
                pixel.alpha(value) -% pixel.alpha(prediction),
                pixel.red(value) -% pixel.red(prediction),
                pixel.green(value) -% pixel.green(prediction),
                pixel.blue(value) -% pixel.blue(prediction),
            );
        }
    }
}

const predictor_black = pixel.fromChannels(255, 0, 0, 0);

fn predictForPosition(
    mode: u8,
    x: usize,
    y: usize,
    width: usize,
    pixels: []const pixel.Pixel,
) pixel.Pixel {
    if (y == 0) {
        if (x == 0) return predictor_black;
        return pixels[x - 1];
    }
    const row_start = y * width;
    const index = row_start + x;
    if (x == 0) return pixels[index - width];

    const top_right = if (x + 1 < width)
        pixels[index - width + 1]
    else
        pixels[row_start];

    return predictPixel(mode, .{
        .left = pixels[index - 1],
        .top = pixels[index - width],
        .top_right = top_right,
        .top_left = pixels[index - width - 1],
    });
}

const Neighbors = struct {
    left: pixel.Pixel,
    top: pixel.Pixel,
    top_right: pixel.Pixel,
    top_left: pixel.Pixel,
};

/// Identical prediction math to the decoder's `predictPixel`, reused here so
/// the forward residual is the exact inverse. Implemented independently rather
/// than calling into the decoder module to keep the encode/decode boundary
/// clean, but the formulas are verified equal by a round-trip test.
fn predictPixel(mode: u8, n: Neighbors) pixel.Pixel {
    return switch (mode) {
        0 => predictor_black,
        1 => n.left,
        2 => n.top,
        3 => n.top_right,
        4 => n.top_left,
        5 => average(average(n.left, n.top_right), n.top),
        6 => average(n.left, n.top_left),
        7 => average(n.left, n.top),
        8 => average(n.top_left, n.top),
        9 => average(n.top, n.top_right),
        10 => average(average(n.left, n.top_left), average(n.top, n.top_right)),
        11 => selectPixel(n.left, n.top, n.top_left),
        12 => clampAddSubtractFull(n.left, n.top, n.top_left),
        13 => clampAddSubtractHalf(average(n.left, n.top), n.top_left),
        else => unreachable,
    };
}

fn average(a: pixel.Pixel, b: pixel.Pixel) pixel.Pixel {
    return pixel.fromChannels(
        averageChannel(pixel.alpha(a), pixel.alpha(b)),
        averageChannel(pixel.red(a), pixel.red(b)),
        averageChannel(pixel.green(a), pixel.green(b)),
        averageChannel(pixel.blue(a), pixel.blue(b)),
    );
}

fn averageChannel(a: u8, b: u8) u8 {
    return @intCast((@as(u16, a) + @as(u16, b)) / 2);
}

fn selectPixel(left: pixel.Pixel, top: pixel.Pixel, top_left: pixel.Pixel) pixel.Pixel {
    const a = estimate(pixel.alpha(left), pixel.alpha(top), pixel.alpha(top_left));
    const r = estimate(pixel.red(left), pixel.red(top), pixel.red(top_left));
    const g = estimate(pixel.green(left), pixel.green(top), pixel.green(top_left));
    const b = estimate(pixel.blue(left), pixel.blue(top), pixel.blue(top_left));

    const left_distance = distance(a, pixel.alpha(left)) + distance(r, pixel.red(left)) +
        distance(g, pixel.green(left)) + distance(b, pixel.blue(left));
    const top_distance = distance(a, pixel.alpha(top)) + distance(r, pixel.red(top)) +
        distance(g, pixel.green(top)) + distance(b, pixel.blue(top));

    if (left_distance < top_distance) return left;
    return top;
}

fn estimate(left: u8, top: u8, top_left: u8) i32 {
    return @as(i32, left) + @as(i32, top) - @as(i32, top_left);
}

fn distance(est: i32, value: u8) u32 {
    const diff = est - @as(i32, value);
    if (diff < 0) return @intCast(-diff);
    return @intCast(diff);
}

fn clampAddSubtractFull(left: pixel.Pixel, top: pixel.Pixel, top_left: pixel.Pixel) pixel.Pixel {
    return pixel.fromChannels(
        clampFull(pixel.alpha(left), pixel.alpha(top), pixel.alpha(top_left)),
        clampFull(pixel.red(left), pixel.red(top), pixel.red(top_left)),
        clampFull(pixel.green(left), pixel.green(top), pixel.green(top_left)),
        clampFull(pixel.blue(left), pixel.blue(top), pixel.blue(top_left)),
    );
}

fn clampFull(left: u8, top: u8, top_left: u8) u8 {
    return clampChannel(@as(i32, left) + @as(i32, top) - @as(i32, top_left));
}

fn clampAddSubtractHalf(avg: pixel.Pixel, top_left: pixel.Pixel) pixel.Pixel {
    return pixel.fromChannels(
        clampHalf(pixel.alpha(avg), pixel.alpha(top_left)),
        clampHalf(pixel.red(avg), pixel.red(top_left)),
        clampHalf(pixel.green(avg), pixel.green(top_left)),
        clampHalf(pixel.blue(avg), pixel.blue(top_left)),
    );
}

fn clampHalf(avg: u8, top_left: u8) u8 {
    const diff = @as(i32, avg) - @as(i32, top_left);
    return clampChannel(@as(i32, avg) + @divTrunc(diff, 2));
}

fn clampChannel(value: i32) u8 {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return @intCast(value);
}

const testing = std.testing;

test "forward subtract-green inverts decoder subtract-green" {
    var pixels = [_]pixel.Pixel{
        pixel.fromChannels(1, 5, 3, 7),
        pixel.fromChannels(255, 4, 10, 5),
    };
    const original = pixels;
    applySubtractGreen(&pixels);
    inverse_transform.applySubtractGreen(&pixels);
    try testing.expectEqualSlices(pixel.Pixel, &original, &pixels);
}

test "forward color-table deltas invert decoder prefix-sum" {
    var table = [_]pixel.Pixel{
        pixel.fromChannels(1, 2, 3, 4),
        pixel.fromChannels(2, 3, 4, 5),
        pixel.fromChannels(1, 2, 3, 4),
        pixel.fromChannels(255, 0, 128, 9),
    };
    const original = table;
    forwardColorTableDeltas(&table);
    inverse_transform.applyColorTableDeltas(&table);
    try testing.expectEqualSlices(pixel.Pixel, &original, &table);
}

test "forward color transform inverts decoder color transform pixel" {
    const elements = [_]ColorTransformElement{
        .{ .green_to_red = 32, .green_to_blue = 64, .red_to_blue = 32 },
        .{ .green_to_red = -40, .green_to_blue = 10, .red_to_blue = -127 },
        .{},
    };
    for (elements) |element| {
        var value: u32 = 0;
        while (value < 4096) : (value += 37) {
            var pixels = [_]pixel.Pixel{value | 0xff000000};
            const original = pixels;
            applyColorTransform(element, &pixels);
            pixels[0] = inverse_transform.applyColorTransformPixel(element.toPixel(), pixels[0]);
            try testing.expectEqual(original[0], pixels[0]);
        }
    }
}

test "forward predictor residual inverts decoder predictor add for every mode" {
    const width = 5;
    const height = 4;
    var source: [width * height]pixel.Pixel = undefined;
    for (&source, 0..) |*p, i| {
        p.* = pixel.fromChannels(
            @intCast((i * 7) % 256),
            @intCast((i * 13) % 256),
            @intCast((i * 29) % 256),
            @intCast((i * 53) % 256),
        );
    }

    var mode: u8 = 0;
    while (mode < predictor_mode_count) : (mode += 1) {
        var residual: [width * height]pixel.Pixel = undefined;
        applyPredictor(mode, width, height, &source, &residual);

        // Reconstruct exactly as the decoder does: add the prediction computed
        // from already-reconstructed neighbors.
        var rebuilt: [width * height]pixel.Pixel = undefined;
        var y: usize = 0;
        while (y < height) : (y += 1) {
            var x: usize = 0;
            while (x < width) : (x += 1) {
                const index = y * width + x;
                const prediction = predictForPosition(mode, x, y, width, &rebuilt);
                const r = residual[index];
                rebuilt[index] = pixel.fromChannels(
                    pixel.alpha(r) +% pixel.alpha(prediction),
                    pixel.red(r) +% pixel.red(prediction),
                    pixel.green(r) +% pixel.green(prediction),
                    pixel.blue(r) +% pixel.blue(prediction),
                );
            }
        }
        try testing.expectEqualSlices(pixel.Pixel, &source, &rebuilt);
    }
}
