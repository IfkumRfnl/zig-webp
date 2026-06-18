//! Pixel-difference metrics (MSE / PSNR) for encoder quality measurement.
//!
//! Pure functions over equal-length pixel buffers. These exist so the encode
//! test harness and the `zig-webp-encode-report` tool can quantify how close a
//! reconstruction is to its source: lossless round-trips score `inf` dB, while
//! lossy encode (PLAN.MD step 8) is gated on luma PSNR against `cwebp`.
//!
//! Conventions:
//! - Sample peak is 255 (8-bit channels).
//! - `psnr = 10 * log10(255^2 / mse)`, returning `inf` when `mse == 0`.
//! - Luma uses the integer BT.601 weights libwebp reports PSNR against
//!   (`(19595*R + 38470*G + 7471*B + 32768) >> 16`), so step-8 comparisons line
//!   up with `cwebp`'s own luma. RGB order is assumed (channel 0 = R), which
//!   holds for the `rgb`/`rgba` buffers the harness produces.
//!
//! The module lives under `src/testing/` (PLAN.MD lists it for step 10); it is
//! introduced early to give the encoder work a measurement baseline.

const std = @import("std");
const assert = std.debug.assert;

/// Mean squared error across every byte of two equal-length buffers, treating
/// each channel sample independently and equally weighted.
pub fn mseBytes(a: []const u8, b: []const u8) f64 {
    assert(a.len == b.len);
    if (a.len == 0) return 0;

    var sum: u64 = 0;
    for (a, b) |sa, sb| {
        const diff: i32 = @as(i32, sa) - @as(i32, sb);
        sum += @intCast(diff * diff);
    }
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(a.len));
}

/// Converts a mean squared error to PSNR in dB (peak 255). Returns positive
/// infinity for a zero error (a bit-exact match).
pub fn psnrFromMse(mse: f64) f64 {
    if (mse <= 0) return std.math.inf(f64);
    return 10.0 * std.math.log10(255.0 * 255.0 / mse);
}

/// PSNR in dB over all channel bytes (peak 255).
pub fn psnrBytes(a: []const u8, b: []const u8) f64 {
    return psnrFromMse(mseBytes(a, b));
}

/// Integer BT.601 luma of an RGB sample, matching libwebp's `VP8RGBToY`
/// rounding so PSNR-Y lines up with `cwebp`'s reported figures.
pub fn lumaBt601(r: u8, g: u8, b: u8) u8 {
    const y: u32 = (19595 * @as(u32, r) + 38470 * @as(u32, g) + 7471 * @as(u32, b) + 32768) >> 16;
    return @intCast(@min(y, 255));
}

/// Mean squared error of the BT.601 luma plane between two RGB(A) buffers.
/// `channels` is the per-pixel sample count (3 for `rgb`, 4 for `rgba`); the
/// first three samples of each pixel are taken as R, G, B in that order.
pub fn lumaMse(a: []const u8, b: []const u8, channels: usize) f64 {
    assert(a.len == b.len);
    assert(channels >= 3);
    assert(a.len % channels == 0);
    const pixel_count = a.len / channels;
    if (pixel_count == 0) return 0;

    var sum: u64 = 0;
    var i: usize = 0;
    while (i < a.len) : (i += channels) {
        const ya = lumaBt601(a[i], a[i + 1], a[i + 2]);
        const yb = lumaBt601(b[i], b[i + 1], b[i + 2]);
        const diff: i32 = @as(i32, ya) - @as(i32, yb);
        sum += @intCast(diff * diff);
    }
    return @as(f64, @floatFromInt(sum)) / @as(f64, @floatFromInt(pixel_count));
}

/// Luma PSNR in dB (peak 255) between two RGB(A) buffers.
pub fn psnrLuma(a: []const u8, b: []const u8, channels: usize) f64 {
    return psnrFromMse(lumaMse(a, b, channels));
}

const testing = std.testing;

test "identical buffers have zero error and infinite PSNR" {
    const a = [_]u8{ 10, 20, 30, 40, 50, 60 };
    try testing.expectEqual(@as(f64, 0), mseBytes(&a, &a));
    try testing.expect(std.math.isInf(psnrBytes(&a, &a)));
}

test "empty buffers are well-defined" {
    const empty = [_]u8{};
    try testing.expectEqual(@as(f64, 0), mseBytes(&empty, &empty));
    try testing.expect(std.math.isInf(psnrBytes(&empty, &empty)));
}

test "mseBytes matches a hand-computed value" {
    // Differences of 3 and 4 over two samples: (9 + 16) / 2 = 12.5.
    const a = [_]u8{ 100, 100 };
    const b = [_]u8{ 103, 104 };
    try testing.expectApproxEqAbs(@as(f64, 12.5), mseBytes(&a, &b), 1e-9);

    // PSNR for that MSE: 10*log10(65025/12.5) ≈ 37.1617 dB.
    try testing.expectApproxEqAbs(@as(f64, 37.16170), psnrBytes(&a, &b), 1e-4);
}

test "psnrFromMse hits the textbook 1-LSB reference" {
    // A uniform error of 1 LSB gives MSE 1 and PSNR 10*log10(65025) ≈ 48.13 dB.
    try testing.expectApproxEqAbs(@as(f64, 48.13089), psnrFromMse(1.0), 1e-4);
}

test "lumaBt601 reproduces libwebp rounding at the primaries" {
    try testing.expectEqual(@as(u8, 0), lumaBt601(0, 0, 0));
    try testing.expectEqual(@as(u8, 255), lumaBt601(255, 255, 255));
    // (19595*255 + 32768) >> 16 = 76; (38470*255 + 32768) >> 16 = 150;
    // (7471*255 + 32768) >> 16 = 29. These are libwebp's VP8RGBToY values.
    try testing.expectEqual(@as(u8, 76), lumaBt601(255, 0, 0));
    try testing.expectEqual(@as(u8, 150), lumaBt601(0, 255, 0));
    try testing.expectEqual(@as(u8, 29), lumaBt601(0, 0, 255));
}

test "lumaMse ignores the alpha channel" {
    // Same RGB, wildly different alpha -> zero luma error.
    const a = [_]u8{ 40, 80, 120, 0 };
    const b = [_]u8{ 40, 80, 120, 255 };
    try testing.expectEqual(@as(f64, 0), lumaMse(&a, &b, 4));
    try testing.expect(std.math.isInf(psnrLuma(&a, &b, 4)));
}
