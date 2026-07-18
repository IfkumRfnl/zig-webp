//! VP8L inverse transform application.

const std = @import("std");
const assert = std.debug.assert;

const errors = @import("../errors.zig");
const image = @import("../image.zig");
const pixel = @import("pixel.zig");
const transform = @import("transform.zig");

const predictor_mode_count = 14;
const predictor_black = pixel.fromChannels(255, 0, 0, 0);
const grouped_color_indexing_pixel_min = 100_000;

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

pub fn applyPredictorTransform(
    predictor_transform: transform.BlockTransform,
    predictor_data: []const pixel.Pixel,
    dimensions: image.Dimensions,
    pixels: []pixel.Pixel,
) errors.Error!void {
    try validateBlockTransform(predictor_transform, dimensions);

    const predictor_pixel_count = try predictor_transform.image.pixelCount();
    if (predictor_data.len < predictor_pixel_count) return error.InvalidVP8LTransform;

    const predictor_pixels = predictor_data[0..@intCast(predictor_pixel_count)];
    try validatePredictorModes(predictor_pixels);

    const pixel_count = try dimensions.pixelCount();
    if (pixels.len < pixel_count) return error.OutputTooLarge;

    const image_pixels = pixels[0..@intCast(pixel_count)];
    const width: usize = @intCast(dimensions.width);
    const height: usize = @intCast(dimensions.height);
    const transform_width: usize = @intCast(predictor_transform.image.width);
    const block_bits: u5 = @intCast(predictor_transform.block_bits);
    const block_size: usize = @as(usize, 1) << block_bits;

    if (height == 0 or width == 0) return;

    // First row ignores predictor modes: black at (0,0), then left residuals.
    image_pixels[0] = addPixelsModulo(image_pixels[0], predictor_black);
    {
        var x: usize = 1;
        while (x < width) : (x += 1) {
            image_pixels[x] = addPixelsModulo(image_pixels[x], image_pixels[x - 1]);
        }
    }

    var y: usize = 1;
    while (y < height) : (y += 1) {
        const row_start = y * width;
        // First column ignores modes and uses the pixel above.
        image_pixels[row_start] = addPixelsModulo(
            image_pixels[row_start],
            image_pixels[row_start - width],
        );

        const transform_y = y >> block_bits;
        const transform_row = transform_y * transform_width;
        var x: usize = 1;
        while (x < width) {
            const transform_x = x >> block_bits;
            const transform_index = transform_row + transform_x;
            assert(transform_index < predictor_pixels.len);

            const mode = pixel.green(predictor_pixels[transform_index]);
            assert(mode < predictor_mode_count);

            const into_tile = x & (block_size - 1);
            const run_len = @min(block_size - into_tile, width - x);
            assert(run_len > 0);
            const x_end = x + run_len;
            applyPredictorModeDispatch(mode, image_pixels, width, y, x, x_end);
            x = x_end;
        }
    }
}

pub fn applySubtractGreen(pixels: []pixel.Pixel) void {
    var index: usize = 0;
    while (index + predictor_vector_lanes <= pixels.len) : (index += predictor_vector_lanes) {
        const values = loadPixelVector(pixels, index);
        const channel_mask: PixelVector = @splat(0xff);
        const green = (values >> @splat(8)) & channel_mask;
        const red = ((values >> @splat(16)) + green) & channel_mask;
        const blue = (values + green) & channel_mask;
        storePixelVector(
            pixels,
            index,
            (values & @as(PixelVector, @splat(0xff00ff00))) |
                (red << @splat(16)) |
                blue,
        );
    }
    while (index < pixels.len) : (index += 1) {
        const value = pixels[index];
        const green_value = pixel.green(value);
        const red_value = pixel.red(value) +% green_value;
        const blue_value = pixel.blue(value) +% green_value;

        pixels[index] = pixel.fromChannels(
            pixel.alpha(value),
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

    const image_pixels = pixels[0..@intCast(pixel_count)];
    const width: usize = @intCast(dimensions.width);
    const height: usize = @intCast(dimensions.height);
    const transform_width: usize = @intCast(color_transform.image.width);
    const block_bits: u5 = @intCast(color_transform.block_bits);
    const block_size: usize = @as(usize, 1) << block_bits;

    if (height == 0 or width == 0) return;

    var y: usize = 0;
    var transform_row: usize = 0;
    while (y < height) : (y += 1) {
        if (y > 0 and (y & (block_size - 1)) == 0) {
            transform_row += transform_width;
        }

        var x: usize = 0;
        var transform_index = transform_row;
        while (x < width) {
            assert(transform_index < color_transform_data.len);
            const color_element = color_transform_data[transform_index];
            const run_len = @min(block_size, width - x);
            assert(run_len > 0);

            const row_index = y * width + x;
            var offset: usize = 0;
            while (offset + predictor_vector_lanes <= run_len) : (offset += predictor_vector_lanes) {
                const pixel_index = row_index + offset;
                storePixelVector(
                    image_pixels,
                    pixel_index,
                    applyColorTransformVector(
                        color_element,
                        loadPixelVector(image_pixels, pixel_index),
                    ),
                );
            }
            while (offset < run_len) : (offset += 1) {
                const pixel_index = row_index + offset;
                image_pixels[pixel_index] = applyColorTransformPixel(
                    color_element,
                    image_pixels[pixel_index],
                );
            }

            x += run_len;
            transform_index += 1;
        }
    }
}

pub fn applyColorTableDeltas(color_table: []pixel.Pixel) void {
    var previous = pixel.fromChannels(0, 0, 0, 0);
    for (color_table) |*entry| {
        const value = pixel.fromChannels(
            pixel.alpha(previous) +% pixel.alpha(entry.*),
            pixel.red(previous) +% pixel.red(entry.*),
            pixel.green(previous) +% pixel.green(entry.*),
            pixel.blue(previous) +% pixel.blue(entry.*),
        );
        entry.* = value;
        previous = value;
    }
}
pub fn applyColorIndexingTransformGreen(
    color_indexing: transform.ColorIndexing,
    color_table: []const pixel.Pixel,
    dimensions: image.Dimensions,
    packed_pixels: []const pixel.Pixel,
    output: []u8,
) errors.Error!void {
    try validateColorIndexingTransform(color_indexing, dimensions);
    if (color_table.len < color_indexing.color_table_size) {
        return error.InvalidVP8LTransform;
    }

    const pixel_count = try dimensions.pixelCount();
    if (output.len < pixel_count) return error.OutputTooLarge;
    const source_pixel_count = try color_indexing.image_after.pixelCount();
    if (packed_pixels.len < source_pixel_count) return error.OutputTooLarge;

    const output_width: usize = @intCast(dimensions.width);
    const source_width: usize = @intCast(color_indexing.image_after.width);
    const width_bits: u3 = color_indexing.width_bits;
    const index_bits: u4 = if (width_bits == 0)
        8
    else
        @intCast(@as(u8, 8) >> width_bits);
    const index_mask: u8 = @truncate((@as(u16, 1) << index_bits) - 1);
    const pixels_per_source: usize = @as(usize, 1) << width_bits;

    if (width_bits > 0) {
        var lookup: [256][8]u8 = undefined;
        for (0..256) |packed_value| {
            for (0..pixels_per_source) |lane| {
                const shift: u3 = @intCast(lane * index_bits);
                const color_index = (@as(u8, @intCast(packed_value)) >> shift) & index_mask;
                lookup[packed_value][lane] =
                    if (color_index < color_indexing.color_table_size)
                        pixel.green(color_table[color_index])
                    else
                        0;
            }
        }

        const height: usize = @intCast(dimensions.height);
        var y: usize = 0;
        while (y < height) : (y += 1) {
            const source_row_start = y * source_width;
            const output_row_start = y * output_width;
            var source_x: usize = 0;
            while (source_x < source_width) : (source_x += 1) {
                const packed_indices =
                    pixel.green(packed_pixels[source_row_start + source_x]);
                const output_start = source_x * pixels_per_source;
                const output_count = @min(pixels_per_source, output_width - output_start);
                @memcpy(
                    output[output_row_start + output_start ..][0..output_count],
                    lookup[packed_indices][0..output_count],
                );
            }
        }
        return;
    }

    const height: usize = @intCast(dimensions.height);
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const source_row_start = y * source_width;
        const output_row_start = y * output_width;
        var source_x: usize = 0;
        while (source_x < source_width) : (source_x += 1) {
            const packed_indices = pixel.green(packed_pixels[source_row_start + source_x]);
            const output_start = source_x * pixels_per_source;
            const output_end = @min(output_start + pixels_per_source, output_width);
            var output_x = output_start;
            while (output_x < output_end) : (output_x += 1) {
                const shift: u3 = @intCast((output_x - output_start) * index_bits);
                const color_index = (packed_indices >> shift) & index_mask;
                output[output_row_start + output_x] =
                    if (color_index < color_indexing.color_table_size)
                        pixel.green(color_table[color_index])
                    else
                        0;
            }
        }
    }
}

pub fn applyColorIndexingTransform(
    color_indexing: transform.ColorIndexing,
    color_table: []const pixel.Pixel,
    dimensions: image.Dimensions,
    pixels: []pixel.Pixel,
) errors.Error!void {
    try validateColorIndexingTransform(color_indexing, dimensions);
    if (color_table.len < color_indexing.color_table_size) return error.InvalidVP8LTransform;

    const pixel_count = try dimensions.pixelCount();
    if (pixels.len < pixel_count) return error.OutputTooLarge;

    const source_pixel_count = try color_indexing.image_after.pixelCount();
    if (pixels.len < source_pixel_count) return error.OutputTooLarge;

    const output_width: usize = @intCast(dimensions.width);
    const source_width: usize = @intCast(color_indexing.image_after.width);
    const width_bits: u3 = color_indexing.width_bits;
    const index_bits: u4 = if (width_bits == 0)
        8
    else
        @intCast(@as(u8, 8) >> width_bits);
    const index_mask: u8 = @truncate((@as(u16, 1) << index_bits) - 1);

    if (pixel_count < grouped_color_indexing_pixel_min or width_bits < 2) {
        var output_index: usize = @intCast(pixel_count);
        while (output_index > 0) {
            output_index -= 1;

            const x = output_index % output_width;
            const y = output_index / output_width;
            const source_x = x >> width_bits;
            const source_index = y * source_width + source_x;
            assert(source_index < source_pixel_count);

            const packed_index = pixel.green(pixels[source_index]);
            const shift: u3 = if (width_bits == 0)
                0
            else
                @intCast((x & ((@as(usize, 1) << width_bits) - 1)) * index_bits);
            const color_index = (packed_index >> shift) & index_mask;
            pixels[output_index] = if (color_index < color_indexing.color_table_size)
                color_table[color_index]
            else
                pixel.fromChannels(0, 0, 0, 0);
        }
        return;
    }

    const pixels_per_source: usize = @as(usize, 1) << width_bits;
    var y: usize = @intCast(dimensions.height);
    while (y > 0) {
        y -= 1;
        const source_row_start = y * source_width;
        const output_row_start = y * output_width;

        var source_x = source_width;
        while (source_x > 0) {
            source_x -= 1;
            const source_index = source_row_start + source_x;
            assert(source_index < source_pixel_count);
            const packed_indices = pixel.green(pixels[source_index]);

            const output_start = source_x * pixels_per_source;
            const output_end = @min(output_start + pixels_per_source, output_width);
            var output_x = output_end;
            while (output_x > output_start) {
                output_x -= 1;
                const shift: u3 = @intCast((output_x - output_start) * index_bits);
                const color_index = (packed_indices >> shift) & index_mask;
                pixels[output_row_start + output_x] =
                    if (color_index < color_indexing.color_table_size)
                        color_table[color_index]
                    else
                        pixel.fromChannels(0, 0, 0, 0);
            }
        }
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
inline fn applyColorTransformVector(
    color_transform_element: pixel.Pixel,
    values: PixelVector,
) PixelVector {
    const channel_mask: PixelVector = @splat(0xff);
    const green_unsigned = (values >> @splat(8)) & channel_mask;
    const green_signed = signExtendChannels(green_unsigned);

    const green_to_red: i8 = @bitCast(pixel.blue(color_transform_element));
    const green_to_blue: i8 = @bitCast(pixel.green(color_transform_element));
    const red_to_blue: i8 = @bitCast(pixel.red(color_transform_element));

    const red_unsigned = ((values >> @splat(16)) +
        @as(PixelVector, @bitCast(
            (green_signed * @as(PixelVectorSigned, @splat(green_to_red))) >> @splat(5),
        ))) & channel_mask;
    const red_signed = signExtendChannels(red_unsigned);
    const blue_unsigned = (values +
        @as(PixelVector, @bitCast(
            (green_signed * @as(PixelVectorSigned, @splat(green_to_blue))) >> @splat(5),
        )) +
        @as(PixelVector, @bitCast(
            (red_signed * @as(PixelVectorSigned, @splat(red_to_blue))) >> @splat(5),
        ))) & channel_mask;

    return (values & @as(PixelVector, @splat(0xff00ff00))) |
        (red_unsigned << @splat(16)) |
        blue_unsigned;
}

inline fn signExtendChannels(values: PixelVector) PixelVectorSigned {
    const shifted: PixelVectorSigned = @bitCast(values << @splat(24));
    return shifted >> @splat(24);
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

const PredictorPosition = struct {
    x: usize,
    y: usize,
    width: usize,
    pixels: []const pixel.Pixel,
};

const PredictorNeighbors = struct {
    left: pixel.Pixel,
    top: pixel.Pixel,
    top_right: pixel.Pixel,
    top_left: pixel.Pixel,
};

fn validatePredictorModes(predictor_data: []const pixel.Pixel) errors.Error!void {
    for (predictor_data) |entry| {
        if (pixel.green(entry) >= predictor_mode_count) return error.InvalidVP8LTransform;
    }
}

fn predictorForPosition(mode: u8, position: PredictorPosition) pixel.Pixel {
    assert(mode < predictor_mode_count);
    assert(position.width > 0);
    assert(position.x < position.width);

    if (position.y == 0) {
        if (position.x == 0) return predictor_black;

        return position.pixels[position.x - 1];
    }

    const row_start = position.y * position.width;
    const pixel_index = row_start + position.x;
    if (position.x == 0) return position.pixels[pixel_index - position.width];

    const top_right = if (position.x + 1 < position.width)
        position.pixels[pixel_index - position.width + 1]
    else
        position.pixels[row_start];

    return predictPixel(mode, .{
        .left = position.pixels[pixel_index - 1],
        .top = position.pixels[pixel_index - position.width],
        .top_right = top_right,
        .top_left = position.pixels[pixel_index - position.width - 1],
    });
}

fn predictPixel(mode: u8, neighbors: PredictorNeighbors) pixel.Pixel {
    assert(mode < predictor_mode_count);

    return switch (mode) {
        inline 0...13 => |comptime_mode| predictPixelMode(comptime_mode, neighbors),
        else => unreachable,
    };
}

fn predictPixelMode(comptime mode: u8, neighbors: PredictorNeighbors) pixel.Pixel {
    comptime assert(mode < predictor_mode_count);

    return switch (mode) {
        0 => predictor_black,
        1 => neighbors.left,
        2 => neighbors.top,
        3 => neighbors.top_right,
        4 => neighbors.top_left,
        5 => averagePixels(averagePixels(neighbors.left, neighbors.top_right), neighbors.top),
        6 => averagePixels(neighbors.left, neighbors.top_left),
        7 => averagePixels(neighbors.left, neighbors.top),
        8 => averagePixels(neighbors.top_left, neighbors.top),
        9 => averagePixels(neighbors.top, neighbors.top_right),
        10 => averagePixels(
            averagePixels(neighbors.left, neighbors.top_left),
            averagePixels(neighbors.top, neighbors.top_right),
        ),
        11 => selectPixel(neighbors.left, neighbors.top, neighbors.top_left),
        12 => clampAddSubtractFullPixel(neighbors.left, neighbors.top, neighbors.top_left),
        13 => clampAddSubtractHalfPixel(
            averagePixels(neighbors.left, neighbors.top),
            neighbors.top_left,
        ),
        else => comptime unreachable,
    };
}

fn applyPredictorModeDispatch(
    mode: u8,
    pixels: []pixel.Pixel,
    width: usize,
    y: usize,
    x_start: usize,
    x_end: usize,
) void {
    assert(mode < predictor_mode_count);
    switch (mode) {
        inline 0...13 => |comptime_mode| applyPredictorRun(comptime_mode, pixels, width, y, x_start, x_end),
        else => unreachable,
    }
}

fn modeUsesTopRight(comptime mode: u8) bool {
    return switch (mode) {
        3, 5, 9, 10 => true,
        else => false,
    };
}

fn applyPredictorRun(
    comptime mode: u8,
    pixels: []pixel.Pixel,
    width: usize,
    y: usize,
    x_start: usize,
    x_end: usize,
) void {
    comptime assert(mode < predictor_mode_count);
    assert(y >= 1);
    assert(x_start >= 1);
    assert(x_start < x_end);
    assert(x_end <= width);
    assert(width > 0);

    if (comptime modeIsVectorIndependent(mode)) {
        applyPredictorRunVector(mode, pixels, width, y, x_start, x_end);
        return;
    }

    const row_start = y * width;
    var x = x_start;
    while (x < x_end) : (x += 1) {
        const pixel_index = row_start + x;
        const neighbors = PredictorNeighbors{
            .left = pixels[pixel_index - 1],
            .top = pixels[pixel_index - width],
            .top_right = if (comptime modeUsesTopRight(mode))
                (if (x + 1 < width) pixels[pixel_index - width + 1] else pixels[row_start])
            else
                predictor_black,
            .top_left = pixels[pixel_index - width - 1],
        };
        pixels[pixel_index] = addPixelsModulo(pixels[pixel_index], predictPixelMode(mode, neighbors));
    }
}

const predictor_vector_lanes = 8;
const PixelVector = @Vector(predictor_vector_lanes, pixel.Pixel);
const PixelVectorSigned = @Vector(predictor_vector_lanes, i32);

fn modeIsVectorIndependent(comptime mode: u8) bool {
    return switch (mode) {
        0, 2, 3, 4, 8, 9 => true,
        else => false,
    };
}

fn applyPredictorRunVector(
    comptime mode: u8,
    pixels: []pixel.Pixel,
    width: usize,
    y: usize,
    x_start: usize,
    x_end: usize,
) void {
    comptime assert(modeIsVectorIndependent(mode));
    const row_start = y * width;
    const top_offset = row_start - width;
    const vector_end = if (comptime modeUsesTopRight(mode))
        @min(x_end, width - 1)
    else
        x_end;

    var x = x_start;
    while (x + predictor_vector_lanes <= vector_end) : (x += predictor_vector_lanes) {
        const pixel_index = row_start + x;
        const prediction: PixelVector = switch (mode) {
            0 => @splat(predictor_black),
            2 => loadPixelVector(pixels, top_offset + x),
            3 => loadPixelVector(pixels, top_offset + x + 1),
            4 => loadPixelVector(pixels, top_offset + x - 1),
            8 => averagePixelVectors(
                loadPixelVector(pixels, top_offset + x - 1),
                loadPixelVector(pixels, top_offset + x),
            ),
            9 => averagePixelVectors(
                loadPixelVector(pixels, top_offset + x),
                loadPixelVector(pixels, top_offset + x + 1),
            ),
            else => comptime unreachable,
        };
        storePixelVector(
            pixels,
            pixel_index,
            addPixelVectorsModulo(loadPixelVector(pixels, pixel_index), prediction),
        );
    }

    while (x < x_end) : (x += 1) {
        const pixel_index = row_start + x;
        const neighbors = PredictorNeighbors{
            .left = pixels[pixel_index - 1],
            .top = pixels[pixel_index - width],
            .top_right = if (comptime modeUsesTopRight(mode))
                (if (x + 1 < width) pixels[pixel_index - width + 1] else pixels[row_start])
            else
                predictor_black,
            .top_left = pixels[pixel_index - width - 1],
        };
        pixels[pixel_index] = addPixelsModulo(pixels[pixel_index], predictPixelMode(mode, neighbors));
    }
}

inline fn loadPixelVector(pixels: []const pixel.Pixel, start: usize) PixelVector {
    return @bitCast(pixels[start..][0..predictor_vector_lanes].*);
}

inline fn storePixelVector(pixels: []pixel.Pixel, start: usize, values: PixelVector) void {
    pixels[start..][0..predictor_vector_lanes].* = @bitCast(values);
}

inline fn addPixelVectorsModulo(residual: PixelVector, prediction: PixelVector) PixelVector {
    const even_mask: PixelVector = @splat(0x00ff00ff);
    const even = ((residual & even_mask) +% (prediction & even_mask)) & even_mask;
    const odd = (((residual >> @splat(8)) & even_mask) +%
        ((prediction >> @splat(8)) & even_mask)) & even_mask;
    return even | (odd << @splat(8));
}

inline fn averagePixelVectors(a: PixelVector, b: PixelVector) PixelVector {
    const channel_high_bits_clear: PixelVector = @splat(0xfefefefe);
    return (a & b) +% (((a ^ b) & channel_high_bits_clear) >> @splat(1));
}

/// Per-pixel reference application used by equivalence tests.
fn applyPredictorTransformReference(
    predictor_transform: transform.BlockTransform,
    predictor_data: []const pixel.Pixel,
    dimensions: image.Dimensions,
    pixels: []pixel.Pixel,
) errors.Error!void {
    try validateBlockTransform(predictor_transform, dimensions);

    const predictor_pixel_count = try predictor_transform.image.pixelCount();
    if (predictor_data.len < predictor_pixel_count) return error.InvalidVP8LTransform;

    const predictor_pixels = predictor_data[0..@intCast(predictor_pixel_count)];
    try validatePredictorModes(predictor_pixels);

    const pixel_count = try dimensions.pixelCount();
    if (pixels.len < pixel_count) return error.OutputTooLarge;

    const width: usize = @intCast(dimensions.width);
    const height: usize = @intCast(dimensions.height);
    const transform_width: usize = @intCast(predictor_transform.image.width);
    const block_bits: u5 = @intCast(predictor_transform.block_bits);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const pixel_index = y * width + x;
            const transform_x = x >> block_bits;
            const transform_y = y >> block_bits;
            const transform_index = transform_y * transform_width + transform_x;
            assert(transform_index < predictor_pixels.len);

            const mode = pixel.green(predictor_pixels[transform_index]);
            assert(mode < predictor_mode_count);

            const prediction = predictorForPosition(mode, .{
                .x = x,
                .y = y,
                .width = width,
                .pixels = pixels[0..@intCast(pixel_count)],
            });
            pixels[pixel_index] = addPixelsModulo(pixels[pixel_index], prediction);
        }
    }
}

/// Per-pixel reference application used by equivalence tests.
fn applyColorTransformReference(
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
    const block_bits: u5 = @intCast(color_transform.block_bits);
    const transform_width: usize = @intCast(color_transform.image.width);

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

fn addPixelsModulo(residual: pixel.Pixel, prediction: pixel.Pixel) pixel.Pixel {
    // Byte-parallel wrapping add: even/odd channels are isolated so carries land
    // in the intervening zero byte and are cleared by the mask.
    const even_mask: pixel.Pixel = 0x00ff00ff;
    const even = ((residual & even_mask) +% (prediction & even_mask)) & even_mask;
    const odd = (((residual >> 8) & even_mask) +% ((prediction >> 8) & even_mask)) & even_mask;
    return even | (odd << 8);
}

fn addPixelsModuloChannels(residual: pixel.Pixel, prediction: pixel.Pixel) pixel.Pixel {
    return pixel.fromChannels(
        pixel.alpha(residual) +% pixel.alpha(prediction),
        pixel.red(residual) +% pixel.red(prediction),
        pixel.green(residual) +% pixel.green(prediction),
        pixel.blue(residual) +% pixel.blue(prediction),
    );
}

fn averagePixels(a: pixel.Pixel, b: pixel.Pixel) pixel.Pixel {
    const channel_high_bits_clear: pixel.Pixel = 0xfefefefe;
    return (a & b) +% (((a ^ b) & channel_high_bits_clear) >> 1);
}

fn averageChannel(a: u8, b: u8) u8 {
    return @intCast((@as(u16, a) + @as(u16, b)) / 2);
}

fn selectPixel(left: pixel.Pixel, top: pixel.Pixel, top_left: pixel.Pixel) pixel.Pixel {
    const alpha_estimate = channelEstimate(
        pixel.alpha(left),
        pixel.alpha(top),
        pixel.alpha(top_left),
    );
    const red_estimate = channelEstimate(pixel.red(left), pixel.red(top), pixel.red(top_left));
    const green_estimate = channelEstimate(
        pixel.green(left),
        pixel.green(top),
        pixel.green(top_left),
    );
    const blue_estimate = channelEstimate(pixel.blue(left), pixel.blue(top), pixel.blue(top_left));

    const left_distance = channelDistance(alpha_estimate, pixel.alpha(left)) +
        channelDistance(red_estimate, pixel.red(left)) +
        channelDistance(green_estimate, pixel.green(left)) +
        channelDistance(blue_estimate, pixel.blue(left));
    const top_distance = channelDistance(alpha_estimate, pixel.alpha(top)) +
        channelDistance(red_estimate, pixel.red(top)) +
        channelDistance(green_estimate, pixel.green(top)) +
        channelDistance(blue_estimate, pixel.blue(top));

    if (left_distance < top_distance) return left;

    return top;
}

fn channelEstimate(left: u8, top: u8, top_left: u8) i32 {
    return @as(i32, left) + @as(i32, top) - @as(i32, top_left);
}

fn channelDistance(estimate: i32, value: u8) u32 {
    const difference = estimate - @as(i32, value);
    if (difference < 0) return @intCast(-difference);

    return @intCast(difference);
}

fn clampAddSubtractFullPixel(
    left: pixel.Pixel,
    top: pixel.Pixel,
    top_left: pixel.Pixel,
) pixel.Pixel {
    return pixel.fromChannels(
        clampAddSubtractFullChannel(pixel.alpha(left), pixel.alpha(top), pixel.alpha(top_left)),
        clampAddSubtractFullChannel(pixel.red(left), pixel.red(top), pixel.red(top_left)),
        clampAddSubtractFullChannel(pixel.green(left), pixel.green(top), pixel.green(top_left)),
        clampAddSubtractFullChannel(pixel.blue(left), pixel.blue(top), pixel.blue(top_left)),
    );
}

fn clampAddSubtractFullChannel(left: u8, top: u8, top_left: u8) u8 {
    return clampChannel(@as(i32, left) + @as(i32, top) - @as(i32, top_left));
}

fn clampAddSubtractHalfPixel(average: pixel.Pixel, top_left: pixel.Pixel) pixel.Pixel {
    return pixel.fromChannels(
        clampAddSubtractHalfChannel(pixel.alpha(average), pixel.alpha(top_left)),
        clampAddSubtractHalfChannel(pixel.red(average), pixel.red(top_left)),
        clampAddSubtractHalfChannel(pixel.green(average), pixel.green(top_left)),
        clampAddSubtractHalfChannel(pixel.blue(average), pixel.blue(top_left)),
    );
}

fn clampAddSubtractHalfChannel(average: u8, top_left: u8) u8 {
    const difference = @as(i32, average) - @as(i32, top_left);

    return clampChannel(@as(i32, average) + @divTrunc(difference, 2));
}

fn clampChannel(value: i32) u8 {
    if (value < 0) return 0;
    if (value > 255) return 255;

    return @intCast(value);
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

fn validateColorIndexingTransform(
    color_indexing: transform.ColorIndexing,
    dimensions: image.Dimensions,
) errors.Error!void {
    if (color_indexing.color_table_size == 0) return error.InvalidVP8LTransform;
    if (color_indexing.color_table_size > transform.color_table_size_max) {
        return error.InvalidVP8LTransform;
    }
    if (color_indexing.width_bits != colorTableWidthBits(color_indexing.color_table_size)) {
        return error.InvalidVP8LTransform;
    }
    if (color_indexing.color_table.width != color_indexing.color_table_size) {
        return error.InvalidVP8LTransform;
    }
    if (color_indexing.color_table.height != 1) return error.InvalidVP8LTransform;

    const width_scale = @as(u32, 1) << @as(u5, color_indexing.width_bits);
    if (color_indexing.image_after.width != divRoundUp(dimensions.width, width_scale)) {
        return error.InvalidVP8LTransform;
    }
    if (color_indexing.image_after.height != dimensions.height) {
        return error.InvalidVP8LTransform;
    }
}

fn colorTableWidthBits(color_table_size: u16) u2 {
    assert(color_table_size > 0);
    assert(color_table_size <= transform.color_table_size_max);

    if (color_table_size <= 2) return 3;
    if (color_table_size <= 4) return 2;
    if (color_table_size <= 16) return 1;

    return 0;
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

test "VP8L inverse predictor transform applies borders and average mode" {
    const dimensions = try image.Dimensions.init(3, 2);
    const predictor_transform = transform.BlockTransform{
        .block_bits = transform.block_bits_min,
        .block_size = @as(u32, 1) << transform.block_bits_min,
        .image = try image.Dimensions.init(1, 1),
    };
    const predictor_data = [_]pixel.Pixel{pixel.fromChannels(0, 0, 7, 0)};
    var pixels = [_]pixel.Pixel{
        pixel.fromChannels(0, 10, 10, 10),
        pixel.fromChannels(0, 10, 10, 10),
        pixel.fromChannels(0, 10, 10, 10),
        pixel.fromChannels(0, 10, 10, 10),
        pixel.fromChannels(0, 10, 10, 10),
        pixel.fromChannels(0, 10, 10, 10),
    };

    try applyPredictorTransform(predictor_transform, &predictor_data, dimensions, &pixels);

    try std.testing.expectEqual(pixel.fromChannels(255, 10, 10, 10), pixels[0]);
    try std.testing.expectEqual(pixel.fromChannels(255, 20, 20, 20), pixels[1]);
    try std.testing.expectEqual(pixel.fromChannels(255, 30, 30, 30), pixels[2]);
    try std.testing.expectEqual(pixel.fromChannels(255, 20, 20, 20), pixels[3]);
    try std.testing.expectEqual(pixel.fromChannels(255, 30, 30, 30), pixels[4]);
    try std.testing.expectEqual(pixel.fromChannels(255, 40, 40, 40), pixels[5]);
}

test "VP8L inverse predictor transform uses row start as right-column top-right" {
    const dimensions = try image.Dimensions.init(3, 2);
    const predictor_transform = transform.BlockTransform{
        .block_bits = transform.block_bits_min,
        .block_size = @as(u32, 1) << transform.block_bits_min,
        .image = try image.Dimensions.init(1, 1),
    };
    const predictor_data = [_]pixel.Pixel{pixel.fromChannels(0, 0, 3, 0)};
    var pixels = [_]pixel.Pixel{
        pixel.fromChannels(0, 10, 0, 0),
        pixel.fromChannels(0, 20, 0, 0),
        pixel.fromChannels(0, 30, 0, 0),
        pixel.fromChannels(0, 1, 0, 0),
        pixel.fromChannels(0, 2, 0, 0),
        pixel.fromChannels(0, 3, 0, 0),
    };

    try applyPredictorTransform(predictor_transform, &predictor_data, dimensions, &pixels);

    try std.testing.expectEqual(pixel.fromChannels(255, 10, 0, 0), pixels[0]);
    try std.testing.expectEqual(pixel.fromChannels(255, 30, 0, 0), pixels[1]);
    try std.testing.expectEqual(pixel.fromChannels(255, 60, 0, 0), pixels[2]);
    try std.testing.expectEqual(pixel.fromChannels(255, 11, 0, 0), pixels[3]);
    try std.testing.expectEqual(pixel.fromChannels(255, 62, 0, 0), pixels[4]);
    try std.testing.expectEqual(pixel.fromChannels(255, 14, 0, 0), pixels[5]);
}

test "VP8L predictor modes implement select and clamp arithmetic" {
    const select_neighbors = PredictorNeighbors{
        .left = pixel.fromChannels(10, 10, 10, 10),
        .top = pixel.fromChannels(20, 20, 20, 20),
        .top_right = pixel.fromChannels(0, 0, 0, 0),
        .top_left = pixel.fromChannels(0, 0, 0, 0),
    };
    const clamp_full_neighbors = PredictorNeighbors{
        .left = pixel.fromChannels(250, 250, 250, 250),
        .top = pixel.fromChannels(20, 20, 20, 20),
        .top_right = pixel.fromChannels(0, 0, 0, 0),
        .top_left = pixel.fromChannels(10, 10, 10, 10),
    };
    const clamp_half_neighbors = PredictorNeighbors{
        .left = pixel.fromChannels(20, 20, 20, 20),
        .top = pixel.fromChannels(30, 30, 30, 30),
        .top_right = pixel.fromChannels(0, 0, 0, 0),
        .top_left = pixel.fromChannels(100, 100, 100, 100),
    };

    try std.testing.expectEqual(
        pixel.fromChannels(20, 20, 20, 20),
        predictPixel(11, select_neighbors),
    );
    try std.testing.expectEqual(
        pixel.fromChannels(255, 255, 255, 255),
        predictPixel(12, clamp_full_neighbors),
    );
    try std.testing.expectEqual(
        pixel.fromChannels(0, 0, 0, 0),
        predictPixel(13, clamp_half_neighbors),
    );
}

test "VP8L inverse predictor transform rejects invalid modes before mutation" {
    const dimensions = try image.Dimensions.init(1, 1);
    const predictor_transform = transform.BlockTransform{
        .block_bits = transform.block_bits_min,
        .block_size = @as(u32, 1) << transform.block_bits_min,
        .image = try image.Dimensions.init(1, 1),
    };
    const predictor_data = [_]pixel.Pixel{pixel.fromChannels(0, 0, 14, 0)};
    var pixels = [_]pixel.Pixel{pixel.fromChannels(1, 2, 3, 4)};

    try std.testing.expectError(
        error.InvalidVP8LTransform,
        applyPredictorTransform(predictor_transform, &predictor_data, dimensions, &pixels),
    );
    try std.testing.expectEqual(pixel.fromChannels(1, 2, 3, 4), pixels[0]);
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

test "VP8L inverse color table reconstruction accumulates channel deltas" {
    var color_table = [_]pixel.Pixel{
        pixel.fromChannels(1, 2, 3, 4),
        pixel.fromChannels(1, 1, 1, 1),
        pixel.fromChannels(255, 255, 255, 255),
    };

    applyColorTableDeltas(&color_table);

    try std.testing.expectEqual(pixel.fromChannels(1, 2, 3, 4), color_table[0]);
    try std.testing.expectEqual(pixel.fromChannels(2, 3, 4, 5), color_table[1]);
    try std.testing.expectEqual(pixel.fromChannels(1, 2, 3, 4), color_table[2]);
}

test "VP8L inverse color indexing expands direct green-channel indices" {
    var color_table = [_]pixel.Pixel{pixel.fromChannels(0, 0, 0, 0)} ** 17;
    color_table[0] = pixel.fromChannels(1, 10, 0, 0);
    color_table[16] = pixel.fromChannels(2, 20, 0, 0);
    var pixels = [_]pixel.Pixel{
        pixel.fromChannels(0, 0, 0, 0),
        pixel.fromChannels(0, 0, 16, 0),
        pixel.fromChannels(0, 0, 17, 0),
    };
    const dimensions = try image.Dimensions.init(3, 1);
    const color_indexing = transform.ColorIndexing{
        .color_table_size = 17,
        .width_bits = 0,
        .color_table = try image.Dimensions.init(17, 1),
        .image_after = dimensions,
    };

    try applyColorIndexingTransform(color_indexing, &color_table, dimensions, &pixels);

    try std.testing.expectEqual(color_table[0], pixels[0]);
    try std.testing.expectEqual(color_table[16], pixels[1]);
    try std.testing.expectEqual(pixel.fromChannels(0, 0, 0, 0), pixels[2]);
}

test "VP8L inverse color indexing expands packed indices" {
    const color_table = [_]pixel.Pixel{
        pixel.fromChannels(1, 10, 0, 0),
        pixel.fromChannels(2, 20, 0, 0),
        pixel.fromChannels(3, 30, 0, 0),
        pixel.fromChannels(4, 40, 0, 0),
    };
    var pixels = [_]pixel.Pixel{
        pixel.fromChannels(0, 0, 0x39, 0),
        undefined,
        undefined,
    };
    const dimensions = try image.Dimensions.init(3, 1);
    const color_indexing = transform.ColorIndexing{
        .color_table_size = 4,
        .width_bits = 2,
        .color_table = try image.Dimensions.init(4, 1),
        .image_after = try image.Dimensions.init(1, 1),
    };

    try applyColorIndexingTransform(color_indexing, &color_table, dimensions, &pixels);

    try std.testing.expectEqual(color_table[1], pixels[0]);
    try std.testing.expectEqual(color_table[2], pixels[1]);
    try std.testing.expectEqual(color_table[3], pixels[2]);
}

test "VP8L inverse color indexing validates metadata and buffers" {
    const color_table = [_]pixel.Pixel{pixel.fromChannels(1, 2, 3, 4)};
    var pixels = [_]pixel.Pixel{pixel.fromChannels(0, 0, 0, 0)};
    const dimensions = try image.Dimensions.init(1, 1);

    try std.testing.expectError(
        error.InvalidVP8LTransform,
        applyColorIndexingTransform(.{
            .color_table_size = 2,
            .width_bits = 3,
            .color_table = try image.Dimensions.init(2, 1),
            .image_after = dimensions,
        }, &color_table, dimensions, &pixels),
    );
    try std.testing.expectError(
        error.OutputTooLarge,
        applyColorIndexingTransform(.{
            .color_table_size = 1,
            .width_bits = 3,
            .color_table = try image.Dimensions.init(1, 1),
            .image_after = try image.Dimensions.init(1, 1),
        }, &color_table, dimensions, &.{}),
    );
}

fn fillRandomPixels(random: std.Random, pixels: []pixel.Pixel) void {
    for (pixels) |*value| {
        value.* = pixel.fromChannels(
            random.int(u8),
            random.int(u8),
            random.int(u8),
            random.int(u8),
        );
    }
}

fn expectPixelsEqual(expected: []const pixel.Pixel, actual: []const pixel.Pixel) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual, 0..) |want, got, index| {
        if (want != got) {
            std.debug.print(
                "pixel mismatch at {d}: expected {x} got {x}\n",
                .{ index, want, got },
            );
            return error.TestExpectedEqual;
        }
    }
}

fn makeBlockTransform(width: u32, height: u32, block_bits: u4) !transform.BlockTransform {
    const block_size = @as(u32, 1) << @as(u5, block_bits);
    return .{
        .block_bits = block_bits,
        .block_size = block_size,
        .image = try image.Dimensions.init(
            divRoundUp(width, block_size),
            divRoundUp(height, block_size),
        ),
    };
}

test "VP8L inverse predictor transform matches reference across modes and tiles" {
    var prng = std.Random.DefaultPrng.init(0x5650384c);
    const random = prng.random();

    const widths = [_]u32{ 1, 2, 3, 4, 5, 7, 8, 9, 15, 16, 17 };
    const heights = [_]u32{ 1, 2, 3, 4, 5, 8, 9 };
    const block_bits_values = [_]u4{ 2, 3, 4 };

    var residual_buf: [17 * 9]pixel.Pixel = undefined;
    var optimized_buf: [17 * 9]pixel.Pixel = undefined;
    var reference_buf: [17 * 9]pixel.Pixel = undefined;
    var predictor_buf: [64]pixel.Pixel = undefined;

    for (widths) |width| {
        for (heights) |height| {
            for (block_bits_values) |block_bits| {
                const dimensions = try image.Dimensions.init(width, height);
                const predictor_transform = try makeBlockTransform(width, height, block_bits);
                const predictor_count = try predictor_transform.image.pixelCount();
                assert(predictor_count <= predictor_buf.len);

                const pixel_count = try dimensions.pixelCount();
                assert(pixel_count <= residual_buf.len);

                // Uniform mode coverage, including right-edge top-right modes.
                var mode: u8 = 0;
                while (mode < predictor_mode_count) : (mode += 1) {
                    @memset(predictor_buf[0..@intCast(predictor_count)], pixel.fromChannels(0, 0, mode, 0));
                    fillRandomPixels(random, residual_buf[0..@intCast(pixel_count)]);
                    @memcpy(optimized_buf[0..@intCast(pixel_count)], residual_buf[0..@intCast(pixel_count)]);
                    @memcpy(reference_buf[0..@intCast(pixel_count)], residual_buf[0..@intCast(pixel_count)]);

                    try applyPredictorTransform(
                        predictor_transform,
                        predictor_buf[0..@intCast(predictor_count)],
                        dimensions,
                        optimized_buf[0..@intCast(pixel_count)],
                    );
                    try applyPredictorTransformReference(
                        predictor_transform,
                        predictor_buf[0..@intCast(predictor_count)],
                        dimensions,
                        reference_buf[0..@intCast(pixel_count)],
                    );
                    try expectPixelsEqual(
                        reference_buf[0..@intCast(pixel_count)],
                        optimized_buf[0..@intCast(pixel_count)],
                    );
                }

                // Mixed tile modes stress tile-boundary mode switches.
                var predictor_index: usize = 0;
                while (predictor_index < predictor_count) : (predictor_index += 1) {
                    const mixed_mode: u8 = @intCast((predictor_index * 3 + width + height) % predictor_mode_count);
                    predictor_buf[predictor_index] = pixel.fromChannels(0, 0, mixed_mode, 0);
                }
                fillRandomPixels(random, residual_buf[0..@intCast(pixel_count)]);
                @memcpy(optimized_buf[0..@intCast(pixel_count)], residual_buf[0..@intCast(pixel_count)]);
                @memcpy(reference_buf[0..@intCast(pixel_count)], residual_buf[0..@intCast(pixel_count)]);

                try applyPredictorTransform(
                    predictor_transform,
                    predictor_buf[0..@intCast(predictor_count)],
                    dimensions,
                    optimized_buf[0..@intCast(pixel_count)],
                );
                try applyPredictorTransformReference(
                    predictor_transform,
                    predictor_buf[0..@intCast(predictor_count)],
                    dimensions,
                    reference_buf[0..@intCast(pixel_count)],
                );
                try expectPixelsEqual(
                    reference_buf[0..@intCast(pixel_count)],
                    optimized_buf[0..@intCast(pixel_count)],
                );
            }
        }
    }
}

test "VP8L addPixelsModulo matches channel-wise wrapping add" {
    var prng = std.Random.DefaultPrng.init(0xad50_0001);
    const random = prng.random();
    var i: u32 = 0;
    while (i < 10_000) : (i += 1) {
        const residual = random.int(pixel.Pixel);
        const prediction = random.int(pixel.Pixel);
        try std.testing.expectEqual(
            addPixelsModuloChannels(residual, prediction),
            addPixelsModulo(residual, prediction),
        );
    }
    try std.testing.expectEqual(
        addPixelsModuloChannels(0xffffffff, 0x02020202),
        addPixelsModulo(0xffffffff, 0x02020202),
    );
    try std.testing.expectEqual(
        addPixelsModuloChannels(0xffffffff, 0xffffffff),
        addPixelsModulo(0xffffffff, 0xffffffff),
    );
}

test "VP8L inverse predictor transform catches right-edge top-right tile errors" {
    // Width 5 / height 5 with block_bits=2 => 2x2 tiles; partial final tile + mode 3/5/9/10.
    const dimensions = try image.Dimensions.init(5, 5);
    const predictor_transform = try makeBlockTransform(5, 5, 2);
    var predictor_data = [_]pixel.Pixel{
        pixel.fromChannels(0, 0, 3, 0),
        pixel.fromChannels(0, 0, 5, 0),
        pixel.fromChannels(0, 0, 9, 0),
        pixel.fromChannels(0, 0, 10, 0),
    };
    assert(predictor_data.len == try predictor_transform.image.pixelCount());

    var prng = std.Random.DefaultPrng.init(0xe06e0001);
    const random = prng.random();
    var residual: [25]pixel.Pixel = undefined;
    var optimized: [25]pixel.Pixel = undefined;
    var reference: [25]pixel.Pixel = undefined;
    fillRandomPixels(random, &residual);
    @memcpy(&optimized, &residual);
    @memcpy(&reference, &residual);

    try applyPredictorTransform(predictor_transform, &predictor_data, dimensions, &optimized);
    try applyPredictorTransformReference(predictor_transform, &predictor_data, dimensions, &reference);
    try expectPixelsEqual(&reference, &optimized);
}

test "VP8L inverse transforms match reference at max block_bits with partial tiles" {
    // Format allows block_bits up to 9 (block_size 512). Pin the large-shift
    // tile-run path for both predictor and color when the image is smaller
    // than one tile (width/height not multiples of block_size).
    var prng = std.Random.DefaultPrng.init(0x626c6b39);
    const random = prng.random();

    const width: u32 = 17;
    const height: u32 = 9;
    const block_bits: u4 = transform.block_bits_max;
    const dimensions = try image.Dimensions.init(width, height);
    const block_transform = try makeBlockTransform(width, height, block_bits);
    try std.testing.expectEqual(@as(u32, 1), block_transform.image.width);
    try std.testing.expectEqual(@as(u32, 1), block_transform.image.height);

    const pixel_count: usize = @intCast(try dimensions.pixelCount());
    var residual: [17 * 9]pixel.Pixel = undefined;
    var optimized: [17 * 9]pixel.Pixel = undefined;
    var reference: [17 * 9]pixel.Pixel = undefined;
    fillRandomPixels(random, residual[0..pixel_count]);

    var mode: u8 = 0;
    while (mode < predictor_mode_count) : (mode += 1) {
        const predictor_data = [_]pixel.Pixel{pixel.fromChannels(0, 0, mode, 0)};
        @memcpy(optimized[0..pixel_count], residual[0..pixel_count]);
        @memcpy(reference[0..pixel_count], residual[0..pixel_count]);
        try applyPredictorTransform(block_transform, &predictor_data, dimensions, optimized[0..pixel_count]);
        try applyPredictorTransformReference(block_transform, &predictor_data, dimensions, reference[0..pixel_count]);
        try expectPixelsEqual(reference[0..pixel_count], optimized[0..pixel_count]);
    }

    var color_data = [_]pixel.Pixel{undefined};
    fillRandomPixels(random, &color_data);
    @memcpy(optimized[0..pixel_count], residual[0..pixel_count]);
    @memcpy(reference[0..pixel_count], residual[0..pixel_count]);
    try applyColorTransform(block_transform, &color_data, dimensions, optimized[0..pixel_count]);
    try applyColorTransformReference(block_transform, &color_data, dimensions, reference[0..pixel_count]);
    try expectPixelsEqual(reference[0..pixel_count], optimized[0..pixel_count]);
}

test "VP8L inverse color transform matches reference across tiles and odd widths" {
    var prng = std.Random.DefaultPrng.init(0x434f4c52);
    const random = prng.random();

    const widths = [_]u32{ 1, 3, 4, 5, 7, 8, 9, 16, 17 };
    const heights = [_]u32{ 1, 2, 3, 4, 5, 8 };
    const block_bits_values = [_]u4{ 2, 3, 4 };

    var residual_buf: [17 * 8]pixel.Pixel = undefined;
    var optimized_buf: [17 * 8]pixel.Pixel = undefined;
    var reference_buf: [17 * 8]pixel.Pixel = undefined;
    var color_buf: [64]pixel.Pixel = undefined;

    for (widths) |width| {
        for (heights) |height| {
            for (block_bits_values) |block_bits| {
                const dimensions = try image.Dimensions.init(width, height);
                const color_transform = try makeBlockTransform(width, height, block_bits);
                const transform_count = try color_transform.image.pixelCount();
                assert(transform_count <= color_buf.len);

                const pixel_count = try dimensions.pixelCount();
                assert(pixel_count <= residual_buf.len);

                fillRandomPixels(random, color_buf[0..@intCast(transform_count)]);
                fillRandomPixels(random, residual_buf[0..@intCast(pixel_count)]);
                @memcpy(optimized_buf[0..@intCast(pixel_count)], residual_buf[0..@intCast(pixel_count)]);
                @memcpy(reference_buf[0..@intCast(pixel_count)], residual_buf[0..@intCast(pixel_count)]);

                try applyColorTransform(
                    color_transform,
                    color_buf[0..@intCast(transform_count)],
                    dimensions,
                    optimized_buf[0..@intCast(pixel_count)],
                );
                try applyColorTransformReference(
                    color_transform,
                    color_buf[0..@intCast(transform_count)],
                    dimensions,
                    reference_buf[0..@intCast(pixel_count)],
                );
                try expectPixelsEqual(
                    reference_buf[0..@intCast(pixel_count)],
                    optimized_buf[0..@intCast(pixel_count)],
                );
            }
        }
    }
}
