//! VP8 forward (encode-side) transforms.
//!
//! Each function is the encode-side pair of a routine in `transform.zig`:
//!   - `forwardDct` pairs with `transform.addInverseDct`.
//!   - `forwardWalshHadamard` pairs with `transform.inverseWalshHadamard`.
//!
//! The constants are re-derived from RFC 6386's forward DCT (the same form
//! libwebp's `VP8FTransform`/`VP8FTransformWHT` use): they are chosen so the
//! forward/inverse pair round-trips a residual block back to itself within a
//! unit or two, which the tests at the bottom lock down. Note this is a
//! *quality* property — the step 8a correctness gate only needs the encoder to
//! reconstruct through `transform.zig` exactly as the decoder does, which it
//! gets for free by reusing the inverse routines.
//!
//! Residuals are source-minus-prediction values, always in [-255, 255] because
//! both operands are 8-bit, so the intermediates fit i32 without wrapping
//! (unlike the inverse path, which must tolerate hostile wrapped coefficients).

const std = @import("std");
const assert = std.debug.assert;

const transform = @import("transform.zig");

pub const coefficient_count = transform.coefficient_count;

/// Forward 4x4 DCT. `residual` holds source-minus-prediction values in raster
/// order (each in [-255, 255]); `out` receives the DCT coefficients in raster
/// order, ready for quantization. Inverse of the DCT step in
/// `transform.addInverseDct` (which runs the inverse DCT and adds the result to
/// the prediction; dequantization happens earlier, at token decode).
pub fn forwardDct(
    residual: *const [coefficient_count]i16,
    out: *[coefficient_count]i16,
) void {
    var tmp: [coefficient_count]i32 = undefined;

    // Pass 1: rows. Each iteration transforms one 4-pixel row into one row of
    // `tmp` (row-major), mirroring the inverse DCT's column-first first pass.
    for (0..4) |i| {
        const d0: i32 = residual[i * 4 + 0];
        const d1: i32 = residual[i * 4 + 1];
        const d2: i32 = residual[i * 4 + 2];
        const d3: i32 = residual[i * 4 + 3];
        const a0 = d0 + d3;
        const a1 = d1 + d2;
        const a2 = d1 - d2;
        const a3 = d0 - d3;
        tmp[0 + i * 4] = (a0 + a1) * 8;
        tmp[1 + i * 4] = (a2 * 2217 + a3 * 5352 + 1812) >> 9;
        tmp[2 + i * 4] = (a0 - a1) * 8;
        tmp[3 + i * 4] = (a3 * 2217 - a2 * 5352 + 937) >> 9;
    }

    // Pass 2: columns, with the asymmetric (a3 != 0) correction libwebp uses to
    // keep the DC/AC split symmetric with the inverse rounding.
    for (0..4) |i| {
        const a0 = tmp[0 + i] + tmp[12 + i];
        const a1 = tmp[4 + i] + tmp[8 + i];
        const a2 = tmp[4 + i] - tmp[8 + i];
        const a3 = tmp[0 + i] - tmp[12 + i];
        out[0 + i] = @intCast((a0 + a1 + 7) >> 4);
        out[4 + i] = @intCast(((a2 * 2217 + a3 * 5352 + 12000) >> 16) + @intFromBool(a3 != 0));
        out[8 + i] = @intCast((a0 - a1 + 7) >> 4);
        out[12 + i] = @intCast((a3 * 2217 - a2 * 5352 + 51000) >> 16);
    }
}

/// Forward 4x4 Walsh-Hadamard transform of the 16 luma DC coefficients
/// (`dcs[4*i + j]` is the DC of luma subblock `4*i + j`, raster order). `out`
/// receives the Y2 block in raster order, ready for quantization. Inverse of
/// `transform.inverseWalshHadamard` (which dequantizes the Y2 block and
/// scatters the recovered DCs back into the luma subblocks).
pub fn forwardWalshHadamard(
    dcs: *const [coefficient_count]i16,
    out: *[coefficient_count]i16,
) void {
    var tmp: [coefficient_count]i32 = undefined;

    // Pass 1: columns of the DC grid, pairing (0,2)/(1,3) — the forward wiring
    // matched to the inverse's (0,3)/(1,2) row pairing in the second pass.
    for (0..4) |i| {
        const v0: i32 = dcs[i * 4 + 0];
        const v1: i32 = dcs[i * 4 + 1];
        const v2: i32 = dcs[i * 4 + 2];
        const v3: i32 = dcs[i * 4 + 3];
        const a0 = v0 + v2;
        const a1 = v1 + v3;
        const a2 = v1 - v3;
        const a3 = v0 - v2;
        tmp[0 + i * 4] = a0 + a1;
        tmp[1 + i * 4] = a3 + a2;
        tmp[2 + i * 4] = a3 - a2;
        tmp[3 + i * 4] = a0 - a1;
    }

    // Pass 2: the final >> 1 splits the 2D Hadamard normalization with the
    // inverse's >> 3, so the round-trip scale is unity.
    for (0..4) |i| {
        const a0 = tmp[0 + i] + tmp[8 + i];
        const a1 = tmp[4 + i] + tmp[12 + i];
        const a2 = tmp[4 + i] - tmp[12 + i];
        const a3 = tmp[0 + i] - tmp[8 + i];
        out[0 + i] = @intCast((a0 + a1) >> 1);
        out[4 + i] = @intCast((a3 + a2) >> 1);
        out[8 + i] = @intCast((a3 - a2) >> 1);
        out[12 + i] = @intCast((a0 - a1) >> 1);
    }
}

// --- Tests -------------------------------------------------------------
//
// The forward transforms are locked against the committed inverse routines:
// a residual that is forward-transformed and then inverse-transformed (with no
// quantization) must come back within a unit or two. This catches a mis-keyed
// constant before the full encoder is wired, so a transform bug cannot later
// masquerade as a token/context bug.

const testing = std.testing;

/// Forward-DCT `residual`, then inverse-DCT the result through
/// `transform.addInverseDct` over a mid-gray prediction, and return the
/// recovered residual. The mid-gray base keeps every sum inside [0, 255] for
/// residuals up to +/-127 so the clamp never fires.
fn roundTripDct(residual: [coefficient_count]i16) [coefficient_count]i32 {
    var coefficients: [coefficient_count]i16 = undefined;
    forwardDct(&residual, &coefficients);

    var pixels: [4 * 4]u8 = @splat(128);
    transform.addInverseDct(&coefficients, &pixels, 4);

    var recovered: [coefficient_count]i32 = undefined;
    for (0..coefficient_count) |k| recovered[k] = @as(i32, pixels[k]) - 128;
    return recovered;
}

fn expectRoundTripDct(residual: [coefficient_count]i16, tolerance: i32) !void {
    const recovered = roundTripDct(residual);
    for (0..coefficient_count) |k| {
        const delta = recovered[k] - residual[k];
        if (@abs(delta) > tolerance) {
            std.debug.print("DCT round-trip coeff {d}: residual {d} recovered {d} (delta {d} > {d})\n", .{
                k, residual[k], recovered[k], delta, tolerance,
            });
            return error.RoundTripTooLossy;
        }
    }
}

test "forward DCT of a zero residual is bias-only and reconstructs to zero" {
    // The +1812/+937 rounding biases leave a tiny non-zero coefficient even for
    // a zero residual (matching libwebp); it is at most a unit and quantizes
    // back to zero, and the inverse pass recovers an exact zero residual.
    var out: [coefficient_count]i16 = undefined;
    forwardDct(&@as([coefficient_count]i16, @splat(0)), &out);
    for (out) |coefficient| try testing.expect(@abs(coefficient) <= 1);
    try expectRoundTripDct(@splat(0), 0);
}

test "forward/inverse DCT round-trips a flat residual" {
    try expectRoundTripDct(@splat(20), 2);
    try expectRoundTripDct(@splat(-37), 2);
}

test "forward/inverse DCT round-trips gradients and impulses" {
    var ramp: [coefficient_count]i16 = undefined;
    for (0..coefficient_count) |k| ramp[k] = @intCast(@as(i32, @intCast(k)) * 8 - 60);
    try expectRoundTripDct(ramp, 2);

    var impulse: [coefficient_count]i16 = @splat(0);
    impulse[5] = 100;
    try expectRoundTripDct(impulse, 2);

    var checker: [coefficient_count]i16 = undefined;
    for (0..coefficient_count) |k| checker[k] = if ((k / 4 + k % 4) % 2 == 0) 90 else -90;
    try expectRoundTripDct(checker, 2);
}

test "forward/inverse DCT round-trips a pseudo-random sweep" {
    var state: u32 = 0x1234_5678;
    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        var residual: [coefficient_count]i16 = undefined;
        for (0..coefficient_count) |k| {
            state = state *% 1664525 +% 1013904223;
            // Keep amplitude <= 127 so the mid-gray reconstruction never clamps.
            residual[k] = @intCast(@as(i32, @intCast((state >> 9) % 255)) - 127);
        }
        try expectRoundTripDct(residual, 2);
    }
}

test "forward/inverse WHT round-trips the DC grid" {
    const tolerance: i32 = 2;
    var state: u32 = 0x0bad_f00d;
    var trial: usize = 0;
    while (trial < 200) : (trial += 1) {
        var dcs: [coefficient_count]i16 = undefined;
        for (0..coefficient_count) |k| {
            state = state *% 1664525 +% 1013904223;
            // DC coefficients of luma blocks span roughly +/-2040.
            dcs[k] = @intCast(@as(i32, @intCast((state >> 8) % 4081)) - 2040);
        }

        var y2: [coefficient_count]i16 = undefined;
        forwardWalshHadamard(&dcs, &y2);

        var recovered: [coefficient_count]i16 = undefined;
        transform.inverseWalshHadamard(&y2, &recovered);

        for (0..coefficient_count) |k| {
            const delta = @as(i32, recovered[k]) - dcs[k];
            if (@abs(delta) > tolerance) {
                std.debug.print("WHT round-trip {d}: dc {d} recovered {d}\n", .{ k, dcs[k], recovered[k] });
                return error.RoundTripTooLossy;
            }
        }
    }
}
