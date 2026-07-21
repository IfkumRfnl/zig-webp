//! Pixel-difference metrics (MSE / PSNR / SSIM) for encoder quality measurement.
//!
//! Pure functions over equal-length pixel buffers. These exist so the encode
//! test harness and the `zig-webp-encode-report` / `zig-webp-encode-lossy-report`
//! tools can quantify how close a reconstruction is to its source: lossless
//! round-trips score `inf` dB, while lossy encode (PLAN.MD step 8) is gated on
//! luma PSNR against `cwebp`. Windowed luma SSIM is an additional internal A/B
//! axis and is not gated.
//!
//! Conventions:
//! - Sample peak is 255 (8-bit channels).
//! - `psnr = 10 * log10(255^2 / mse)`, returning `inf` when `mse == 0`.
//! - Luma uses the integer BT.601 weights libwebp reports PSNR against
//!   (`(19595*R + 38470*G + 7471*B + 32768) >> 16`), so step-8 comparisons line
//!   up with `cwebp`'s own luma. RGB order is assumed (channel 0 = R), which
//!   holds for the `rgb`/`rgba` buffers the harness produces.
//! - SSIM is textbook Wang et al. 2004 on the BT.601 luma plane (uniform box
//!   window). It is *not* comparable to `cwebp -print_ssim` (different kernel).
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

/// Sliding-window size for `ssimLuma` when both extents are at least 8.
const ssim_window: usize = 8;
/// Top-left stride for fully-inside 8×8 windows. Edge strips narrower than one
/// window are uncovered; partial windows are never used.
const ssim_stride: usize = 4;
/// Stabilizers from Wang et al. 2004 for 8-bit samples: `(K1*L)^2`, `(K2*L)^2`
/// with `K1=0.01`, `K2=0.03`, `L=255`.
const ssim_c1: f64 = (0.01 * 255.0) * (0.01 * 255.0);
const ssim_c2: f64 = (0.03 * 255.0) * (0.03 * 255.0);

/// Mean structural similarity (SSIM) of the BT.601 luma plane between two
/// RGB(A) buffers.
///
/// Implements textbook Wang et al. 2004 with a uniform box window — **not**
/// libwebp's Gaussian-kernel SSIM (`cwebp -print_ssim`). Numbers from this
/// function are an internal encoder A/B axis only; they are not directly
/// comparable to cwebp's reported SSIM.
///
/// Windowing: when both `width` and `height` are ≥ 8, mean SSIM over every
/// 8×8 window whose top-left lies on the stride-4 grid and whose full extent
/// lies inside the image. When **either** extent is below 8, a single
/// whole-image window over the entire luma plane is used (never a hard-coded
/// 1.0). Variances and covariance are **population** statistics (`/N`, not
/// `/(N-1)`).
pub fn ssimLuma(a: []const u8, b: []const u8, width: usize, height: usize, channels: usize) f64 {
    assert(a.len == b.len);
    assert(channels >= 3);
    assert(a.len == width * height * channels);
    assert(width > 0);
    assert(height > 0);

    if (width < ssim_window or height < ssim_window) {
        // Mandatory whole-image window when either extent cannot hold 8×8.
        return windowSsimLuma(a, b, width, height, channels, 0, 0, width, height);
    }

    var sum: f64 = 0;
    var window_count: usize = 0;
    var origin_y: usize = 0;
    while (origin_y + ssim_window <= height) : (origin_y += ssim_stride) {
        var origin_x: usize = 0;
        while (origin_x + ssim_window <= width) : (origin_x += ssim_stride) {
            sum += windowSsimLuma(a, b, width, height, channels, origin_x, origin_y, ssim_window, ssim_window);
            window_count += 1;
        }
    }
    assert(window_count > 0);
    return sum / @as(f64, @floatFromInt(window_count));
}

/// Population SSIM for one axis-aligned luma window of size `win_w`×`win_h`
/// with top-left `(origin_x, origin_y)`.
fn windowSsimLuma(
    a: []const u8,
    b: []const u8,
    width: usize,
    height: usize,
    channels: usize,
    origin_x: usize,
    origin_y: usize,
    win_w: usize,
    win_h: usize,
) f64 {
    assert(win_w > 0);
    assert(win_h > 0);
    assert(origin_x + win_w <= width);
    assert(origin_y + win_h <= height);

    const pixel_n = win_w * win_h;
    const n: f64 = @floatFromInt(pixel_n);

    var sum_x: f64 = 0;
    var sum_y: f64 = 0;
    var sum_xx: f64 = 0;
    var sum_yy: f64 = 0;
    var sum_xy: f64 = 0;

    var row: usize = 0;
    while (row < win_h) : (row += 1) {
        const y = origin_y + row;
        var col: usize = 0;
        while (col < win_w) : (col += 1) {
            const x = origin_x + col;
            const offset = (y * width + x) * channels;
            const luma_a: f64 = @floatFromInt(lumaBt601(a[offset], a[offset + 1], a[offset + 2]));
            const luma_b: f64 = @floatFromInt(lumaBt601(b[offset], b[offset + 1], b[offset + 2]));
            sum_x += luma_a;
            sum_y += luma_b;
            sum_xx += luma_a * luma_a;
            sum_yy += luma_b * luma_b;
            sum_xy += luma_a * luma_b;
        }
    }

    const mu_x = sum_x / n;
    const mu_y = sum_y / n;
    // Population variance / covariance: E[X²] - μ² (and likewise for cov).
    const var_x = sum_xx / n - mu_x * mu_x;
    const var_y = sum_yy / n - mu_y * mu_y;
    const cov = sum_xy / n - mu_x * mu_y;

    const numerator = (2.0 * mu_x * mu_y + ssim_c1) * (2.0 * cov + ssim_c2);
    const denominator = (mu_x * mu_x + mu_y * mu_y + ssim_c1) * (var_x + var_y + ssim_c2);
    assert(denominator > 0);
    return numerator / denominator;
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

test "ssimLuma is exactly 1.0 for identical buffers" {
    // Whole-image path (< 8×8).
    const small = [_]u8{ 10, 20, 30, 40, 50, 60 };
    try testing.expectEqual(@as(f64, 1.0), ssimLuma(&small, &small, 2, 1, 3));

    // Sliding-window path (≥ 8×8): fill a gray 8×8 RGB plane.
    var large: [8 * 8 * 3]u8 = undefined;
    for (0..8 * 8) |i| {
        large[i * 3 + 0] = 90;
        large[i * 3 + 1] = 90;
        large[i * 3 + 2] = 90;
    }
    try testing.expectEqual(@as(f64, 1.0), ssimLuma(&large, &large, 8, 8, 3));
}

test "ssimLuma matches the closed-form zero-variance shift" {
    // 8×8 constant gray 100 vs constant gray 110. Gray (v,v,v) has BT.601
    // luma exactly v, so both planes are constant and variance is zero:
    // SSIM reduces to (2*μx*μy + C1) / (μx² + μy² + C1).
    var a: [8 * 8 * 3]u8 = undefined;
    var b: [8 * 8 * 3]u8 = undefined;
    for (0..8 * 8) |i| {
        a[i * 3 + 0] = 100;
        a[i * 3 + 1] = 100;
        a[i * 3 + 2] = 100;
        b[i * 3 + 0] = 110;
        b[i * 3 + 1] = 110;
        b[i * 3 + 2] = 110;
    }
    const mu_x: f64 = 100.0;
    const mu_y: f64 = 110.0;
    const expected = (2.0 * mu_x * mu_y + ssim_c1) / (mu_x * mu_x + mu_y * mu_y + ssim_c1);
    try testing.expectApproxEqAbs(expected, ssimLuma(&a, &b, 8, 8, 3), 1e-9);
}

test "ssimLuma is symmetric" {
    var a: [8 * 8 * 3]u8 = undefined;
    var b: [8 * 8 * 3]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x5514_0001);
    const random = prng.random();
    for (0..8 * 8) |i| {
        const va = random.int(u8);
        const vb = random.int(u8);
        a[i * 3 + 0] = va;
        a[i * 3 + 1] = va;
        a[i * 3 + 2] = va;
        b[i * 3 + 0] = vb;
        b[i * 3 + 1] = vb;
        b[i * 3 + 2] = vb;
    }
    try testing.expectEqual(ssimLuma(&a, &b, 8, 8, 3), ssimLuma(&b, &a, 8, 8, 3));
}

test "ssimLuma falls under heavier uniform noise" {
    var base: [16 * 16 * 3]u8 = undefined;
    var light: [16 * 16 * 3]u8 = undefined;
    var heavy: [16 * 16 * 3]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(0x5514_0002);
    const random = prng.random();
    for (0..16 * 16) |i| {
        const v = random.int(u8);
        base[i * 3 + 0] = v;
        base[i * 3 + 1] = v;
        base[i * 3 + 2] = v;
        const n_light: i32 = @as(i32, random.int(u8) % 5) - 2; // [-2, 2]
        const n_heavy: i32 = @as(i32, random.int(u8) % 41) - 20; // [-20, 20]
        const light_v: u8 = @intCast(std.math.clamp(@as(i32, v) + n_light, 0, 255));
        const heavy_v: u8 = @intCast(std.math.clamp(@as(i32, v) + n_heavy, 0, 255));
        light[i * 3 + 0] = light_v;
        light[i * 3 + 1] = light_v;
        light[i * 3 + 2] = light_v;
        heavy[i * 3 + 0] = heavy_v;
        heavy[i * 3 + 1] = heavy_v;
        heavy[i * 3 + 2] = heavy_v;
    }
    const ssim_light = ssimLuma(&base, &light, 16, 16, 3);
    const ssim_heavy = ssimLuma(&base, &heavy, 16, 16, 3);
    try testing.expect(ssim_heavy < ssim_light);
}

test "ssimLuma ignores the alpha channel" {
    // Same RGB, wildly different alpha -> perfect structural match on luma.
    const a = [_]u8{ 40, 80, 120, 0 };
    const b = [_]u8{ 40, 80, 120, 255 };
    try testing.expectEqual(@as(f64, 1.0), ssimLuma(&a, &b, 1, 1, 4));
}

test "ssimLuma is negative for complementary checkerboards" {
    // 8×8 0/255 checkerboard vs its complement: means match, covariance is
    // strongly negative, so SSIM lands in [-1, 0).
    var a: [8 * 8 * 3]u8 = undefined;
    var b: [8 * 8 * 3]u8 = undefined;
    for (0..8) |y| {
        for (0..8) |x| {
            const i = y * 8 + x;
            const on = (x + y) % 2 == 0;
            const va: u8 = if (on) 0 else 255;
            const vb: u8 = if (on) 255 else 0;
            a[i * 3 + 0] = va;
            a[i * 3 + 1] = va;
            a[i * 3 + 2] = va;
            b[i * 3 + 0] = vb;
            b[i * 3 + 1] = vb;
            b[i * 3 + 2] = vb;
        }
    }
    const value = ssimLuma(&a, &b, 8, 8, 3);
    try testing.expect(std.math.isFinite(value));
    try testing.expect(value >= -1.0);
    try testing.expect(value < 0.0);
}
