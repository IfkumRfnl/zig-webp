//! VP8 inverse transforms (RFC 6386 sections 14.2 through 14.5).
//!
//! Implements the exact-integer inverse 4x4 DCT, the inverse 4x4
//! Walsh-Hadamard transform for the Y2 block, and the add-to-prediction
//! step with 8-bit clamping. Structure and constants are cross-checked
//! between RFC 6386, `references/libwebp`, and `references/ffmpeg`; the
//! unit-test vectors were generated independently from the RFC pseudocode.
//!
//! All internal arithmetic uses wrapping i32 operations: conformant streams
//! never engage the wrap (their intermediates fit comfortably), and hostile
//! streams (whose coefficients already wrapped at the dequantized i16
//! store) degrade to two's-complement wraparound instead of panicking,
//! matching what optimized C builds of the oracle do in practice.

const std = @import("std");
const assert = std.debug.assert;

pub const coefficient_count = 16;
pub const block_edge_pixels = 4;

// RFC 6386 section 14.4 fixed-point constants: sqrt(2)*cos(pi/8) and
// sqrt(2)*sin(pi/8) in Q16. The cosine constant stores K - 1 so the
// multiplier fits 16 bits; mulCos adds the input back in.
const cospi8_sqrt2_minus1 = 20091;
const sinpi8_sqrt2 = 35468;

comptime {
    assert(cospi8_sqrt2_minus1 == 20091);
    assert(sinpi8_sqrt2 == 35468);
}

fn mulCos(a: i32) i32 {
    return ((a *% cospi8_sqrt2_minus1) >> 16) +% a;
}

fn mulSin(a: i32) i32 {
    return (a *% sinpi8_sqrt2) >> 16;
}

/// Inverse 4x4 DCT of `coefficients` (raster order) added into the 4x4
/// pixel region at `destination[0..]` with row `stride`, clamping each sum
/// to [0, 255]. The region must already hold the prediction pixels.
/// Always running the full transform is bit-identical to libwebp's
/// DC-only/AC3 fast paths, so no dispatch is needed for correctness.
pub fn addInverseDct(
    coefficients: *const [coefficient_count]i16,
    destination: []u8,
    stride: u32,
) void {
    assert(stride >= block_edge_pixels);
    assert(destination.len >= 3 * stride + block_edge_pixels);

    // Pass 1: transform each column; the temporary holds the result
    // transposed so pass 2 reads rows at the same index shape.
    var transposed: [coefficient_count]i32 = undefined;
    for (0..4) |i| {
        const row_0: i32 = coefficients[i];
        const row_1: i32 = coefficients[4 + i];
        const row_2: i32 = coefficients[8 + i];
        const row_3: i32 = coefficients[12 + i];
        const a = row_0 +% row_2;
        const b = row_0 -% row_2;
        const c = mulSin(row_1) -% mulCos(row_3);
        const d = mulCos(row_1) +% mulSin(row_3);
        transposed[4 * i + 0] = a +% d;
        transposed[4 * i + 1] = b +% c;
        transposed[4 * i + 2] = b -% c;
        transposed[4 * i + 3] = a -% d;
    }

    // Pass 2: transform each row with the lone (x + 4) >> 3 rounder, then
    // add to prediction and clamp.
    for (0..4) |i| {
        const dc = transposed[i] +% 4;
        const a = dc +% transposed[8 + i];
        const b = dc -% transposed[8 + i];
        const c = mulSin(transposed[4 + i]) -% mulCos(transposed[12 + i]);
        const d = mulCos(transposed[4 + i]) +% mulSin(transposed[12 + i]);

        const row = destination[i * stride ..];
        addClamped(&row[0], (a +% d) >> 3);
        addClamped(&row[1], (b +% c) >> 3);
        addClamped(&row[2], (b -% c) >> 3);
        addClamped(&row[3], (a -% d) >> 3);
    }
}

fn addClamped(pixel: *u8, residual: i32) void {
    const sum = @as(i32, pixel.*) +% residual;
    pixel.* = @intCast(std.math.clamp(sum, 0, 255));
}

/// Inverse 4x4 Walsh-Hadamard transform of the dequantized Y2 block
/// (RFC 6386 section 14.3). Output element at row i, column j is the DC
/// coefficient of luma subblock 4*i + j; the caller scatters `out` into
/// position 0 of each luma block before running the luma DCTs.
pub fn inverseWalshHadamard(
    coefficients: *const [coefficient_count]i16,
    out: *[coefficient_count]i16,
) void {
    // Pass 1: columns, pairing rows (0,3) and (1,2) — different wiring
    // than the DCT's (0,2)/(1,3).
    var rows: [coefficient_count]i32 = undefined;
    for (0..4) |i| {
        const row_0: i32 = coefficients[i];
        const row_1: i32 = coefficients[4 + i];
        const row_2: i32 = coefficients[8 + i];
        const row_3: i32 = coefficients[12 + i];
        const a0 = row_0 +% row_3;
        const a1 = row_1 +% row_2;
        const a2 = row_1 -% row_2;
        const a3 = row_0 -% row_3;
        rows[i] = a0 +% a1;
        rows[4 + i] = a3 +% a2;
        rows[8 + i] = a0 -% a1;
        rows[12 + i] = a3 -% a2;
    }

    // Pass 2: rows, with the (x + 3) >> 3 rounder folded into element 0
    // (it contributes positively to all four outputs).
    for (0..4) |i| {
        const dc = rows[4 * i] +% 3;
        const a0 = dc +% rows[4 * i + 3];
        const a1 = rows[4 * i + 1] +% rows[4 * i + 2];
        const a2 = rows[4 * i + 1] -% rows[4 * i + 2];
        const a3 = dc -% rows[4 * i + 3];
        out[4 * i + 0] = @truncate((a0 +% a1) >> 3);
        out[4 * i + 1] = @truncate((a3 +% a2) >> 3);
        out[4 * i + 2] = @truncate((a0 -% a1) >> 3);
        out[4 * i + 3] = @truncate((a3 -% a2) >> 3);
    }
}

// --- Tests -------------------------------------------------------------
//
// Vectors generated independently from the RFC 6386 pseudocode (and
// re-derived a second time before being committed here); they do not
// originate from any reference C implementation.

fn expectDct(coefficients: [coefficient_count]i16, expected: [coefficient_count]i32) !void {
    // A mid-gray prediction keeps sums in range so the residual is
    // recoverable from the clamped output.
    var pixels: [4 * 16]u8 = @splat(128);
    addInverseDct(&coefficients, &pixels, 16);
    for (0..4) |y| {
        for (0..4) |x| {
            const actual = @as(i32, pixels[y * 16 + x]) - 128;
            try std.testing.expectEqual(expected[y * 4 + x], actual);
        }
    }
}

test "inverse DCT broadcasts rounded DC-only blocks" {
    var coefficients: [coefficient_count]i16 = @splat(0);
    coefficients[0] = 8;
    try expectDct(coefficients, @splat(1)); // (8+4)>>3 = 1.

    // Negative DC exercises the arithmetic (floor) shift: (-13+4)>>3 = -2,
    // where truncating division would give -1.
    coefficients[0] = -13;
    try expectDct(coefficients, @splat(-2));
}

test "inverse DCT applies the asymmetric fixed-point multipliers" {
    var coefficients: [coefficient_count]i16 = @splat(0);
    coefficients[1] = 100; // mulSin(100) = 54, mulCos(100) = 130.
    try expectDct(coefficients, .{
        16, 7, -7, -16,
        16, 7, -7, -16,
        16, 7, -7, -16,
        16, 7, -7, -16,
    });
}

test "inverse DCT transforms a mixed block" {
    const coefficients = [coefficient_count]i16{
        40, -28, 11, 0,
        23, -1,  0,  0,
        -7, 5,   0,  0,
        0,  0,   0,  0,
    };
    try expectDct(coefficients, .{
        5,  5,  8, 13,
        3,  4,  8, 14,
        1,  1,  5, 11,
        -2, -2, 1, 5,
    });
}

test "inverse DCT handles large magnitudes with i32 headroom" {
    const coefficients = [coefficient_count]i16{
        2047, -2048, 1234, -567,
        890,  -123,  456,  -789,
        321,  -654,  987,  -210,
        543,  -876,  109,  -432,
    };
    // Residuals exceed the clamp range, so verify through the clamped
    // reconstruction with the prediction pattern from the spec.
    var pixels: [4 * 16]u8 = undefined;
    for (0..4) |x| {
        pixels[0 * 16 + x] = 250;
        pixels[1 * 16 + x] = 3;
        pixels[2 * 16 + x] = 128;
        pixels[3 * 16 + x] = 128;
    }
    addInverseDct(&coefficients, &pixels, 16);

    const expected = [4][4]u8{
        .{ 255, 255, 255, 255 },
        .{ 168, 161, 132, 255 },
        .{ 0, 255, 255, 255 },
        .{ 134, 0, 255, 255 },
    };
    for (0..4) |y| {
        for (0..4) |x| {
            try std.testing.expectEqual(expected[y][x], pixels[y * 16 + x]);
        }
    }
}

test "inverse DCT leaves prediction untouched for all-zero blocks" {
    const coefficients: [coefficient_count]i16 = @splat(0);
    var pixels: [4 * 8]u8 = undefined;
    for (&pixels, 0..) |*pixel, index| pixel.* = @truncate(index * 7);
    const before = pixels;
    addInverseDct(&coefficients, &pixels, 8);
    try std.testing.expectEqual(before, pixels);
}

test "inverse WHT broadcasts rounded DC-only blocks" {
    var coefficients: [coefficient_count]i16 = @splat(0);
    coefficients[0] = 64;
    var out: [coefficient_count]i16 = undefined;
    inverseWalshHadamard(&coefficients, &out);
    try std.testing.expectEqual([_]i16{8} ** 16, out); // (64+3)>>3 = 8.

    // (-9+3)>>3 = -1 under the arithmetic shift, 0 under truncation.
    coefficients[0] = -9;
    inverseWalshHadamard(&coefficients, &out);
    try std.testing.expectEqual([_]i16{-1} ** 16, out);
}

test "inverse WHT transforms mixed blocks with the (0,3)/(1,2) pairing" {
    const coefficients = [coefficient_count]i16{
        128,  -64,  32,  -16,
        8,    -4,   2,   -1,
        100,  50,   25,  12,
        -200, -100, -50, -25,
    };
    var out: [coefficient_count]i16 = undefined;
    inverseWalshHadamard(&coefficients, &out);
    try std.testing.expectEqual([coefficient_count]i16{
        -13, -8,  14, 24,
        34,  20,  24, 40,
        -61, -37, 3,  5,
        80,  48,  31, 52,
    }, out);

    // The all-ones block concentrates into a single rounded corner value.
    const ones: [coefficient_count]i16 = @splat(1);
    inverseWalshHadamard(&ones, &out);
    var expected: [coefficient_count]i16 = @splat(0);
    expected[0] = 2; // (16+3)>>3.
    try std.testing.expectEqual(expected, out);
}

test "transforms tolerate extreme wrapped coefficients without panicking" {
    // Hostile streams can wrap the dequantized i16 store to its extremes;
    // the transforms must degrade to wraparound, never panic.
    const extreme: [coefficient_count]i16 = @splat(std.math.minInt(i16));
    var pixels: [4 * 16]u8 = @splat(128);
    addInverseDct(&extreme, &pixels, 16);
    var out: [coefficient_count]i16 = undefined;
    inverseWalshHadamard(&extreme, &out);
}
