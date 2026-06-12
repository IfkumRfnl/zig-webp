//! VP8 intra prediction kernels (RFC 6386 section 12).
//!
//! Pure prediction functions over explicit neighbor values: the caller
//! (frame reconstruction) gathers neighbors from the unfiltered
//! reconstruction and applies the out-of-frame synthetic rules (127 above,
//! 129 left, the fixed top-right for right-edge subblocks) before calling
//! in. Formulas are transcribed from the RFC 6386 section 12 pseudocode
//! and cross-checked kernel-by-kernel against `references/libwebp` and
//! `references/ffmpeg` (whose mode enumerations are permutations of the
//! RFC order used here).

const std = @import("std");
const assert = std.debug.assert;

const modes = @import("modes.zig");

pub const subblock_edge_pixels = 4;

/// Synthetic border pixel above the frame (RFC 6386 section 12 intro);
/// also fills the above-right extension on the top macroblock row.
pub const border_above = 127;
/// Synthetic border pixel left of the frame; also the above-left corner
/// below the top macroblock row.
pub const border_left = 129;

fn avg2(x: u32, y: u32) u8 {
    return @intCast((x + y + 1) >> 1);
}

fn avg3(x: u32, y: u32, z: u32) u8 {
    return @intCast((x + 2 * y + z + 2) >> 2);
}

fn clamp255(v: i32) u8 {
    return @intCast(std.math.clamp(v, 0, 255));
}

/// Which real neighbors exist for full-block DC prediction. The DC mode
/// changes its pixel set and denominator at frame edges instead of
/// averaging synthetic border values (unlike every other mode).
pub const EdgePresence = struct {
    has_above: bool,
    has_left: bool,
};

/// Predicts one full block (16x16 luma or 8x8 chroma) into `destination`
/// rows of `size` pixels with row `stride`. `above`, `left`, and
/// `above_left` must already hold the synthetic border values at frame
/// edges; DC ignores the synthetic sides via `edges`.
pub fn predictFullBlock(
    comptime size: u32,
    mode: modes.ChromaMode,
    above: *const [size]u8,
    left: *const [size]u8,
    above_left: u8,
    edges: EdgePresence,
    destination: []u8,
    stride: u32,
) void {
    comptime assert(size == 16 or size == 8);
    assert(stride >= size);
    assert(destination.len >= (size - 1) * stride + size);

    switch (mode) {
        .dc => {
            const value = fullBlockDcValue(size, above, left, edges);
            for (0..size) |row| {
                @memset(destination[row * stride ..][0..size], value);
            }
        },
        .vertical => {
            for (0..size) |row| {
                @memcpy(destination[row * stride ..][0..size], above);
            }
        },
        .horizontal => {
            for (0..size) |row| {
                @memset(destination[row * stride ..][0..size], left[row]);
            }
        },
        .true_motion => {
            for (0..size) |row| {
                const base = @as(i32, left[row]) - above_left;
                const out = destination[row * stride ..];
                for (0..size) |column| {
                    out[column] = clamp255(base + above[column]);
                }
            }
        },
    }
}

fn fullBlockDcValue(
    comptime size: u32,
    above: *const [size]u8,
    left: *const [size]u8,
    edges: EdgePresence,
) u8 {
    comptime assert(size == 16 or size == 8);
    const log2_size = if (size == 16) 4 else 3;

    var sum: u32 = 0;
    var shift: u5 = log2_size;
    if (edges.has_above) {
        for (above) |pixel| sum += pixel;
        if (edges.has_left) {
            for (left) |pixel| sum += pixel;
            shift = log2_size + 1;
        }
    } else if (edges.has_left) {
        for (left) |pixel| sum += pixel;
    } else {
        // The top-left macroblock has no real neighbors at all.
        return 128;
    }
    return @intCast((sum + (@as(u32, 1) << (shift - 1))) >> shift);
}

/// Neighbors of one 4x4 luma subblock, gathered by the caller per RFC 6386
/// section 12.3: `above_left` is the P pixel, `above`/`above_right` the
/// eight pixels of the row above, `left` the column to the left. For
/// right-edge subblocks (3, 7, 11, 15) `above_right` must be the fixed
/// top-right of the macroblock row, never in-macroblock pixels.
pub const SubblockNeighbors = struct {
    above_left: u8,
    above: [subblock_edge_pixels]u8,
    above_right: [subblock_edge_pixels]u8,
    left: [subblock_edge_pixels]u8,
};

/// Predicts one 4x4 luma subblock into `destination` (4 rows of 4 pixels
/// with row `stride`).
pub fn predictSubblock(
    mode: modes.SubblockMode,
    neighbors: *const SubblockNeighbors,
    destination: []u8,
    stride: u32,
) void {
    assert(stride >= subblock_edge_pixels);
    assert(destination.len >= 3 * stride + subblock_edge_pixels);

    const p: u32 = neighbors.above_left;
    const a0: u32 = neighbors.above[0];
    const a1: u32 = neighbors.above[1];
    const a2: u32 = neighbors.above[2];
    const a3: u32 = neighbors.above[3];
    const a4: u32 = neighbors.above_right[0];
    const a5: u32 = neighbors.above_right[1];
    const a6: u32 = neighbors.above_right[2];
    const a7: u32 = neighbors.above_right[3];
    const l0: u32 = neighbors.left[0];
    const l1: u32 = neighbors.left[1];
    const l2: u32 = neighbors.left[2];
    const l3: u32 = neighbors.left[3];

    var block: [16]u8 = undefined;
    switch (mode) {
        .dc => {
            // Always eight pixels with rounder 4; the synthetic 127/129
            // values participate at frame edges (unlike full-block DC).
            const value: u8 =
                @intCast((a0 + a1 + a2 + a3 + l0 + l1 + l2 + l3 + 4) >> 3);
            block = @splat(value);
        },
        .true_motion => {
            for (0..4) |row| {
                const base = @as(i32, neighbors.left[row]) - neighbors.above_left;
                for (0..4) |column| {
                    block[row * 4 + column] = clamp255(base + neighbors.above[column]);
                }
            }
        },
        .vertical => {
            // 3-tap smoothed above row; the first tap reads P and the last
            // reads the first above-right pixel.
            const smoothed = [4]u8{
                avg3(p, a0, a1),
                avg3(a0, a1, a2),
                avg3(a1, a2, a3),
                avg3(a2, a3, a4),
            };
            for (0..4) |row| block[row * 4 ..][0..4].* = smoothed;
        },
        .horizontal => {
            const smoothed = [4]u8{
                avg3(p, l0, l1),
                avg3(l0, l1, l2),
                avg3(l1, l2, l3),
                avg3(l2, l3, l3),
            };
            for (0..4) |row| block[row * 4 ..][0..4].* = @splat(smoothed[row]);
        },
        .left_down => {
            block[0] = avg3(a0, a1, a2);
            block[1] = avg3(a1, a2, a3);
            block[4] = block[1];
            block[2] = avg3(a2, a3, a4);
            block[5] = block[2];
            block[8] = block[2];
            block[3] = avg3(a3, a4, a5);
            block[6] = block[3];
            block[9] = block[3];
            block[12] = block[3];
            block[7] = avg3(a4, a5, a6);
            block[10] = block[7];
            block[13] = block[7];
            block[11] = avg3(a5, a6, a7);
            block[14] = block[11];
            block[15] = avg3(a6, a7, a7);
        },
        .right_down => {
            block[12] = avg3(l3, l2, l1);
            block[13] = avg3(l2, l1, l0);
            block[8] = block[13];
            block[14] = avg3(l1, l0, p);
            block[9] = block[14];
            block[4] = block[14];
            block[15] = avg3(l0, p, a0);
            block[10] = block[15];
            block[5] = block[15];
            block[0] = block[15];
            block[11] = avg3(p, a0, a1);
            block[6] = block[11];
            block[1] = block[11];
            block[7] = avg3(a0, a1, a2);
            block[2] = block[7];
            block[3] = avg3(a1, a2, a3);
        },
        .vertical_right => {
            block[0] = avg2(p, a0);
            block[9] = block[0];
            block[1] = avg2(a0, a1);
            block[10] = block[1];
            block[2] = avg2(a1, a2);
            block[11] = block[2];
            block[3] = avg2(a2, a3);
            block[12] = avg3(l2, l1, l0);
            block[8] = avg3(l1, l0, p);
            block[4] = avg3(l0, p, a0);
            block[13] = block[4];
            block[5] = avg3(p, a0, a1);
            block[14] = block[5];
            block[6] = avg3(a0, a1, a2);
            block[15] = block[6];
            block[7] = avg3(a1, a2, a3);
        },
        .vertical_left => {
            block[0] = avg2(a0, a1);
            block[1] = avg2(a1, a2);
            block[8] = block[1];
            block[2] = avg2(a2, a3);
            block[9] = block[2];
            block[3] = avg2(a3, a4);
            block[10] = block[3];
            block[4] = avg3(a0, a1, a2);
            block[5] = avg3(a1, a2, a3);
            block[12] = block[5];
            block[6] = avg3(a2, a3, a4);
            block[13] = block[6];
            block[7] = avg3(a3, a4, a5);
            block[14] = block[7];
            // The last two pixels break the diagonal pattern (normative;
            // this is where the H.264 vertical-left kernel differs).
            block[11] = avg3(a4, a5, a6);
            block[15] = avg3(a5, a6, a7);
        },
        .horizontal_down => {
            block[0] = avg2(p, l0);
            block[6] = block[0];
            block[4] = avg2(l0, l1);
            block[10] = block[4];
            block[8] = avg2(l1, l2);
            block[14] = block[8];
            block[12] = avg2(l2, l3);
            block[3] = avg3(a0, a1, a2);
            block[2] = avg3(p, a0, a1);
            block[1] = avg3(l0, p, a0);
            block[7] = block[1];
            block[5] = avg3(l1, l0, p);
            block[11] = block[5];
            block[9] = avg3(l2, l1, l0);
            block[15] = block[9];
            block[13] = avg3(l3, l2, l1);
        },
        .horizontal_up => {
            block[0] = avg2(l0, l1);
            block[1] = avg3(l0, l1, l2);
            block[2] = avg2(l1, l2);
            block[4] = block[2];
            block[3] = avg3(l1, l2, l3);
            block[5] = block[3];
            block[6] = avg2(l2, l3);
            block[8] = block[6];
            block[7] = avg3(l2, l3, l3);
            block[9] = block[7];
            // The bottom-right region is an unfiltered copy of l3.
            block[10] = neighbors.left[3];
            block[11] = neighbors.left[3];
            block[12] = neighbors.left[3];
            block[13] = neighbors.left[3];
            block[14] = neighbors.left[3];
            block[15] = neighbors.left[3];
        },
    }

    for (0..4) |row| {
        destination[row * stride ..][0..4].* = block[row * 4 ..][0..4].*;
    }
}

// --- Tests -------------------------------------------------------------

const test_neighbors = SubblockNeighbors{
    .above_left = 10,
    .above = .{ 20, 30, 40, 50 },
    .above_right = .{ 60, 70, 80, 90 },
    .left = .{ 100, 110, 120, 130 },
};

test "predicts every 4x4 subblock mode against independent vectors" {
    // Expected outputs computed directly from the RFC 6386 section 12.3
    // formula tables with distinct neighbor values, independently of this
    // implementation.
    const expectations = [_]struct {
        mode: modes.SubblockMode,
        pixels: [16]u8,
    }{
        .{ .mode = .dc, .pixels = .{
            75, 75, 75, 75, 75, 75, 75, 75,
            75, 75, 75, 75, 75, 75, 75, 75,
        } },
        .{ .mode = .true_motion, .pixels = .{
            110, 120, 130, 140, 120, 130, 140, 150,
            130, 140, 150, 160, 140, 150, 160, 170,
        } },
        .{ .mode = .vertical, .pixels = .{
            20, 30, 40, 50, 20, 30, 40, 50,
            20, 30, 40, 50, 20, 30, 40, 50,
        } },
        .{ .mode = .horizontal, .pixels = .{
            80,  80,  80,  80,  110, 110, 110, 110,
            120, 120, 120, 120, 128, 128, 128, 128,
        } },
        .{ .mode = .left_down, .pixels = .{
            30, 40, 50, 60, 40, 50, 60, 70,
            50, 60, 70, 80, 60, 70, 80, 88,
        } },
        .{ .mode = .right_down, .pixels = .{
            35,  20, 30, 40, 80,  35,  20, 30,
            110, 80, 35, 20, 120, 110, 80, 35,
        } },
        .{ .mode = .vertical_right, .pixels = .{
            15, 25, 35, 45, 35,  20, 30, 40,
            80, 15, 25, 35, 110, 35, 20, 30,
        } },
        .{ .mode = .vertical_left, .pixels = .{
            25, 35, 45, 55, 30, 40, 50, 60,
            35, 45, 55, 70, 40, 50, 60, 80,
        } },
        .{ .mode = .horizontal_down, .pixels = .{
            55,  35,  20,  30, 105, 80,  55,  35,
            115, 110, 105, 80, 125, 120, 115, 110,
        } },
        .{ .mode = .horizontal_up, .pixels = .{
            105, 110, 115, 120, 115, 120, 125, 128,
            125, 128, 130, 130, 130, 130, 130, 130,
        } },
    };

    for (expectations) |expectation| {
        var out: [4 * 8]u8 = @splat(0xAA);
        predictSubblock(expectation.mode, &test_neighbors, &out, 8);
        for (0..4) |row| {
            try std.testing.expectEqualSlices(
                u8,
                expectation.pixels[row * 4 ..][0..4],
                out[row * 8 ..][0..4],
            );
            // The stride gap stays untouched.
            try std.testing.expectEqual(@as(u8, 0xAA), out[row * 8 + 4]);
        }
    }
}

test "subblock prediction honors the synthetic border identities" {
    // B_VE over an all-127 above row stays 127 (top macroblock row).
    var top_row = SubblockNeighbors{
        .above_left = border_above,
        .above = @splat(border_above),
        .above_right = @splat(border_above),
        .left = @splat(border_left),
    };
    var out: [16]u8 = undefined;
    predictSubblock(.vertical, &top_row, &out, 4);
    try std.testing.expectEqual([_]u8{border_above} ** 16, out);

    // B_DC of subblock 0 at macroblock (0,0): (4*127 + 4*129 + 4) >> 3 = 128.
    predictSubblock(.dc, &top_row, &out, 4);
    try std.testing.expectEqual([_]u8{128} ** 16, out);

    // TM at macroblock (0,0): clamp(129 + 127 - 127) = 129 everywhere.
    predictSubblock(.true_motion, &top_row, &out, 4);
    try std.testing.expectEqual([_]u8{border_left} ** 16, out);
}

test "subblock true-motion clamps both directions" {
    const neighbors = SubblockNeighbors{
        .above_left = 255,
        .above = .{ 0, 255, 128, 1 },
        .above_right = @splat(0),
        .left = .{ 0, 255, 10, 250 },
    };
    var out: [16]u8 = undefined;
    predictSubblock(.true_motion, &neighbors, &out, 4);

    // Row 0: 0 - 255 + above -> all clamp at 0 except above=255 -> 0.
    try std.testing.expectEqual([_]u8{ 0, 0, 0, 0 }, out[0..4].*);
    // Row 1: 255 - 255 + above = above.
    try std.testing.expectEqual([_]u8{ 0, 255, 128, 1 }, out[4..8].*);
    // Row 3: 250 - 255 + above clamps high for above=255.
    try std.testing.expectEqual([_]u8{ 0, 250, 123, 0 }, out[12..16].*);
}

test "predicts full blocks with DC edge variants" {
    var above16: [16]u8 = @splat(100);
    var left16: [16]u8 = @splat(50);

    var out: [16 * 16]u8 = undefined;
    // Interior: (16*100 + 16*50 + 16) >> 5 = 75.
    predictFullBlock(16, .dc, &above16, &left16, 99, .{
        .has_above = true,
        .has_left = true,
    }, &out, 16);
    try std.testing.expectEqual([_]u8{75} ** 256, out);

    // No above: (16*50 + 8) >> 4 = 50.
    predictFullBlock(16, .dc, &above16, &left16, 99, .{
        .has_above = false,
        .has_left = true,
    }, &out, 16);
    try std.testing.expectEqual(@as(u8, 50), out[0]);

    // No left: (16*100 + 8) >> 4 = 100.
    predictFullBlock(16, .dc, &above16, &left16, 99, .{
        .has_above = true,
        .has_left = false,
    }, &out, 16);
    try std.testing.expectEqual(@as(u8, 100), out[0]);

    // No neighbors at all: constant 128.
    predictFullBlock(16, .dc, &above16, &left16, 99, .{
        .has_above = false,
        .has_left = false,
    }, &out, 16);
    try std.testing.expectEqual(@as(u8, 128), out[255]);

    // Rounding: above sums to 8*31+4 = 252 -> (252+... for chroma variant.
    var above8: [8]u8 = @splat(31);
    var left8: [8]u8 = @splat(0);
    var out8: [8 * 8]u8 = undefined;
    // (8*31 + 8*0 + 8) >> 4 = 16.
    predictFullBlock(8, .dc, &above8, &left8, 0, .{
        .has_above = true,
        .has_left = true,
    }, &out8, 8);
    try std.testing.expectEqual([_]u8{16} ** 64, out8);
}

test "predicts full vertical, horizontal, and true-motion blocks" {
    var above: [8]u8 = .{ 1, 2, 3, 4, 5, 6, 7, 8 };
    var left: [8]u8 = .{ 10, 20, 30, 40, 50, 60, 70, 80 };

    var out: [8 * 8]u8 = undefined;
    predictFullBlock(8, .vertical, &above, &left, 4, .{
        .has_above = true,
        .has_left = true,
    }, &out, 8);
    for (0..8) |row| {
        try std.testing.expectEqualSlices(u8, &above, out[row * 8 ..][0..8]);
    }

    predictFullBlock(8, .horizontal, &above, &left, 4, .{
        .has_above = true,
        .has_left = true,
    }, &out, 8);
    for (0..8) |row| {
        try std.testing.expectEqual([_]u8{left[row]} ** 8, out[row * 8 ..][0..8].*);
    }

    predictFullBlock(8, .true_motion, &above, &left, 4, .{
        .has_above = true,
        .has_left = true,
    }, &out, 8);
    // B[r][c] = clamp(left[r] + above[c] - 4).
    try std.testing.expectEqual(@as(u8, 7), out[0]); // 10 + 1 - 4.
    try std.testing.expectEqual(@as(u8, 84), out[7 * 8 + 7]); // 80 + 8 - 4.

    // TM degenerate identities from the synthetic borders.
    var border_above_row: [8]u8 = @splat(border_above);
    var real_left: [8]u8 = .{ 9, 18, 27, 36, 45, 54, 63, 72 };
    predictFullBlock(8, .true_motion, &border_above_row, &real_left, border_above, .{
        .has_above = false,
        .has_left = true,
    }, &out, 8);
    // A = P = 127 -> output equals the left column (degenerates to H).
    for (0..8) |row| {
        try std.testing.expectEqual([_]u8{real_left[row]} ** 8, out[row * 8 ..][0..8].*);
    }
}
