//! VP8 YUV 4:2:0 to packed RGB conversion with fancy chroma upsampling.
//!
//! This is the conversion layer of the VP8 decode pipeline (PLAN.MD step 5):
//! the reconstruction layer produces bit-exact YUV planes, and this module
//! turns them into displayable pixels. Unlike reconstruction, YUV-to-RGB is
//! implementation-defined, so correctness is pinned to libwebp's output rather
//! than to RFC 6386. Both halves are transcribed from `references/libwebp`:
//!
//!   - the BT.601 fixed-point conversion from `src/dsp/yuv.h` (the scalar
//!     `VP8YUVToR/G/B` path, bit-exact with libwebp's SSE2/NEON variants), and
//!   - the "fancy" bilinear upsampler from `src/dsp/upsampling.c`
//!     (`UPSAMPLE_FUNC`) driven exactly like `src/dec/io_dec.c`'s
//!     `EmitFancyRGB`, including its mirror-at-the-boundary edge handling.
//!
//! Validated byte-for-byte against `dwebp -pam` (which defaults to fancy
//! upsampling) over the lossy corpus; see PROGRESS.MD. Output alpha is set
//! opaque here — composing decoded alpha over lossy color is a later stage.

const std = @import("std");
const assert = std.debug.assert;

const image = @import("image.zig");

// Fixed-point precision for the YUV->RGB conversion (`YUV_FIX2` in libwebp).
const yuv_fix2 = 6;
// Mask covering the valid pre-shift range [0, 256 << yuv_fix2); a value with
// any bit outside this mask is out of range and saturates in `clip8`.
const yuv_mask2: i32 = (256 << yuv_fix2) - 1;

/// Borrowed reconstructed VP8 4:2:0 planes to upsample and convert. The
/// visible image is the top-left `width` x `height` region of `luma` and the
/// ceil(width/2) x ceil(height/2) region of each chroma plane. Rows are
/// addressed through the explicit strides, so macroblock-padded planes (as
/// produced by `vp8/decoder.zig`) can be passed directly.
pub const Planes = struct {
    luma: []const u8,
    chroma_u: []const u8,
    chroma_v: []const u8,
    luma_stride: usize,
    chroma_stride: usize,
    width: u32,
    height: u32,
};

/// Converts `planes` into packed pixels written to `out`, one row every
/// `out_stride` bytes, in the requested `format`, using libwebp's default
/// fancy (bilinear) chroma upsampling. Where the format carries alpha it is
/// set fully opaque; composing decoded alpha planes is a separate stage.
///
/// `out` must hold at least `out_stride * (height - 1) + width * channels`
/// bytes, and `out_stride` at least `width * channels`.
pub fn upsampleFancy(
    format: image.PixelFormat,
    planes: Planes,
    out: []u8,
    out_stride: usize,
) void {
    // Dispatch the runtime format once so the per-pixel store and stride are
    // monomorphized (push the `switch` up, keep the hot loop branch-free).
    switch (format) {
        inline else => |comptime_format| upsampleFancyTyped(
            comptime_format,
            planes,
            out,
            out_stride,
        ),
    }
}

fn upsampleFancyTyped(
    comptime format: image.PixelFormat,
    planes: Planes,
    out: []u8,
    out_stride: usize,
) void {
    const channels: usize = comptime format.channelCount();
    const width: usize = planes.width;
    const height: usize = planes.height;
    assert(width >= 1);
    assert(height >= 1);

    // RFC half-sample rule: chroma covers ceil(dim/2) so the edge column/row
    // of odd-sized images is not dropped.
    const chroma_width = (width + 1) / 2;
    const chroma_height = (height + 1) / 2;
    const row_bytes = width * channels;

    assert(planes.luma_stride >= width);
    assert(planes.chroma_stride >= chroma_width);
    assert(out_stride >= row_bytes);
    assert(planes.luma.len >= (height - 1) * planes.luma_stride + width);
    assert(planes.chroma_u.len >= (chroma_height - 1) * planes.chroma_stride + chroma_width);
    assert(planes.chroma_v.len >= (chroma_height - 1) * planes.chroma_stride + chroma_width);
    assert(out.len >= (height - 1) * out_stride + row_bytes);

    const luma_stride = planes.luma_stride;
    const chroma_stride = planes.chroma_stride;

    // First output row is special-cased: there is no chroma row above it, so
    // the row above is mirrored (top == cur), matching `EmitFancyRGB`.
    upsampleLinePair(format, width, .{
        .top_y = row(planes.luma, luma_stride, 0, width),
        .bottom_y = null,
        .top_u = row(planes.chroma_u, chroma_stride, 0, chroma_width),
        .top_v = row(planes.chroma_v, chroma_stride, 0, chroma_width),
        .cur_u = row(planes.chroma_u, chroma_stride, 0, chroma_width),
        .cur_v = row(planes.chroma_v, chroma_stride, 0, chroma_width),
        .top_dst = rowMut(out, out_stride, 0, row_bytes),
        .bottom_dst = null,
    });

    // Each interior call interpolates between chroma rows `k` (above) and
    // `k + 1` (below), emitting output rows `2k + 1` and `2k + 2`. The loop is
    // bounded by `height`; it stops once the lower output row would fall on or
    // past the last row.
    var k: usize = 0;
    while (2 * k + 2 < height) : (k += 1) {
        assert(k + 1 < chroma_height);
        upsampleLinePair(format, width, .{
            .top_y = row(planes.luma, luma_stride, 2 * k + 1, width),
            .bottom_y = row(planes.luma, luma_stride, 2 * k + 2, width),
            .top_u = row(planes.chroma_u, chroma_stride, k, chroma_width),
            .top_v = row(planes.chroma_v, chroma_stride, k, chroma_width),
            .cur_u = row(planes.chroma_u, chroma_stride, k + 1, chroma_width),
            .cur_v = row(planes.chroma_v, chroma_stride, k + 1, chroma_width),
            .top_dst = rowMut(out, out_stride, 2 * k + 1, row_bytes),
            .bottom_dst = rowMut(out, out_stride, 2 * k + 2, row_bytes),
        });
    }

    // An even-height image leaves one trailing output row whose chroma row
    // below would be out of range; mirror the last chroma row for it.
    if (height & 1 == 0) {
        const last_chroma = chroma_height - 1;
        upsampleLinePair(format, width, .{
            .top_y = row(planes.luma, luma_stride, height - 1, width),
            .bottom_y = null,
            .top_u = row(planes.chroma_u, chroma_stride, last_chroma, chroma_width),
            .top_v = row(planes.chroma_v, chroma_stride, last_chroma, chroma_width),
            .cur_u = row(planes.chroma_u, chroma_stride, last_chroma, chroma_width),
            .cur_v = row(planes.chroma_v, chroma_stride, last_chroma, chroma_width),
            .top_dst = rowMut(out, out_stride, height - 1, row_bytes),
            .bottom_dst = null,
        });
    }
}

// One invocation's worth of borrowed rows: a luma row (and optional second
// luma row), the chroma rows above (`top_*`) and at the current level
// (`cur_*`), and the one or two destination rows they feed. Bundled into a
// struct so the eight same-typed slices cannot be transposed at the call site.
const LinePair = struct {
    top_y: []const u8,
    bottom_y: ?[]const u8,
    top_u: []const u8,
    top_v: []const u8,
    cur_u: []const u8,
    cur_v: []const u8,
    top_dst: []u8,
    bottom_dst: ?[]u8,
};

// Produces one or two output rows of `len` pixels from a 2x2 neighbourhood of
// chroma samples, weighting u/v by the fancy filter's diamond
//   ([9a + 3b + 3c + d, 3a + 9b + 3c + d] + 8) / 16   (top row)
//   ([3a + b + 9c + 3d, a + 3b + 3c + 9d] + 8) / 16   (bottom row)
// u and v are packed into a single u32 (u in the low 16 bits, v in the high
// 16 bits) so both channels are filtered with identical weights at once; no
// intermediate exceeds 16 bits per channel, so the lanes never interfere.
// Transcribed from `UPSAMPLE_FUNC` in `references/libwebp/src/dsp/upsampling.c`.
fn upsampleLinePair(comptime format: image.PixelFormat, len: usize, lines: LinePair) void {
    const channels: usize = comptime format.channelCount();
    assert(len >= 1);

    const last_pixel_pair = (len - 1) >> 1;
    var top_left = loadUV(lines.top_u[0], lines.top_v[0]);
    var left = loadUV(lines.cur_u[0], lines.cur_v[0]);

    {
        const uv = (3 * top_left + left + 0x0002_0002) >> 2;
        storePixel(format, lines.top_dst[0..channels], lines.top_y[0], uv);
    }
    if (lines.bottom_y) |bottom_y| {
        const uv = (3 * left + top_left + 0x0002_0002) >> 2;
        storePixel(format, lines.bottom_dst.?[0..channels], bottom_y[0], uv);
    }

    var x: usize = 1;
    while (x <= last_pixel_pair) : (x += 1) {
        const top = loadUV(lines.top_u[x], lines.top_v[x]);
        const cur = loadUV(lines.cur_u[x], lines.cur_v[x]);
        // Invariants shared by the two diagonals of this output quad.
        const avg = top_left + top + left + cur + 0x0008_0008;
        const diag_12 = (avg + 2 * (top + left)) >> 3;
        const diag_03 = (avg + 2 * (top_left + cur)) >> 3;
        {
            const uv0 = (diag_12 + top_left) >> 1;
            const uv1 = (diag_03 + top) >> 1;
            storePixel(format, sub(lines.top_dst, 2 * x - 1, channels), lines.top_y[2 * x - 1], uv0);
            storePixel(format, sub(lines.top_dst, 2 * x, channels), lines.top_y[2 * x], uv1);
        }
        if (lines.bottom_y) |bottom_y| {
            const uv0 = (diag_03 + left) >> 1;
            const uv1 = (diag_12 + cur) >> 1;
            storePixel(format, sub(lines.bottom_dst.?, 2 * x - 1, channels), bottom_y[2 * x - 1], uv0);
            storePixel(format, sub(lines.bottom_dst.?, 2 * x, channels), bottom_y[2 * x], uv1);
        }
        top_left = top;
        left = cur;
    }

    // An even width leaves a final right-edge pixel; mirror the last column.
    if (len & 1 == 0) {
        {
            const uv = (3 * top_left + left + 0x0002_0002) >> 2;
            storePixel(format, sub(lines.top_dst, len - 1, channels), lines.top_y[len - 1], uv);
        }
        if (lines.bottom_y) |bottom_y| {
            const uv = (3 * left + top_left + 0x0002_0002) >> 2;
            storePixel(format, sub(lines.bottom_dst.?, len - 1, channels), bottom_y[len - 1], uv);
        }
    }
}

// Packs u into the low 16 bits and v into the high 16 bits of a u32.
inline fn loadUV(u: u8, v: u8) u32 {
    return @as(u32, u) | (@as(u32, v) << 16);
}

// The `index`-th channel-sized window of a row.
inline fn sub(plane: []u8, index: usize, channels: usize) []u8 {
    return plane[index * channels ..][0..channels];
}

inline fn row(plane: []const u8, stride: usize, index: usize, len: usize) []const u8 {
    return plane[index * stride ..][0..len];
}

inline fn rowMut(plane: []u8, stride: usize, index: usize, len: usize) []u8 {
    return plane[index * stride ..][0..len];
}

// Converts one (y, packed-uv) sample to the requested pixel format and writes
// it to `dst`. `packed_uv` holds the upsampled u (low 16 bits) and v (high 16
// bits); both lanes are in [0, 255] after the diamond filter.
inline fn storePixel(comptime format: image.PixelFormat, dst: []u8, y: u8, packed_uv: u32) void {
    const luma: i32 = y;
    const u: i32 = @intCast(packed_uv & 0xff);
    const v: i32 = @intCast(packed_uv >> 16);
    const r = yuvToR(luma, v);
    const g = yuvToG(luma, u, v);
    const b = yuvToB(luma, u);
    switch (format) {
        .rgb => {
            assert(dst.len == 3);
            dst[0] = r;
            dst[1] = g;
            dst[2] = b;
        },
        .rgba => {
            assert(dst.len == 4);
            dst[0] = r;
            dst[1] = g;
            dst[2] = b;
            dst[3] = 255;
        },
        .bgra => {
            assert(dst.len == 4);
            dst[0] = b;
            dst[1] = g;
            dst[2] = r;
            dst[3] = 255;
        },
        .argb => {
            assert(dst.len == 4);
            dst[0] = 255;
            dst[1] = r;
            dst[2] = g;
            dst[3] = b;
        },
    }
}

// BT.601 fixed-point YUV->RGB (libwebp `src/dsp/yuv.h`), where `.` is the
// `mulHi` operator that keeps 8 fractional bits before the final descale:
//   R = (19077.y             + 26149.v - 14234) >> 6
//   G = (19077.y -  6419.u - 13320.v +  8708) >> 6
//   B = (19077.y + 33050.u            - 17685) >> 6
inline fn yuvToR(y: i32, v: i32) u8 {
    return clip8(mulHi(y, 19077) + mulHi(v, 26149) - 14234);
}

inline fn yuvToG(y: i32, u: i32, v: i32) u8 {
    return clip8(mulHi(y, 19077) - mulHi(u, 6419) - mulHi(v, 13320) + 8708);
}

inline fn yuvToB(y: i32, u: i32) u8 {
    return clip8(mulHi(y, 19077) + mulHi(u, 33050) - 17685);
}

// `_mm_mulhi_epu16` emulation: ((sample << 8) * coeff) >> 16, simplified to
// (sample * coeff) >> 8 since the sample is an 8-bit, non-negative value.
inline fn mulHi(value: i32, coeff: i32) i32 {
    return (value * coeff) >> 8;
}

// Descales by `yuv_fix2` and clamps to [0, 255]. A value whose bits all fall
// inside `yuv_mask2` is in range and shifts directly; anything else saturates.
inline fn clip8(value: i32) u8 {
    if ((value & ~yuv_mask2) == 0) {
        return @intCast(value >> yuv_fix2);
    }
    if (value < 0) {
        return 0;
    }
    return 255;
}

// A 1x1 frame collapses the upsampler to a single conversion of (y, u, v):
// the boundary mirror makes every neighbour equal, and the diamond filter is
// constant-preserving, so this isolates the BT.601 arithmetic. Anchors are
// computed by hand from the `src/dsp/yuv.h` formula (see the doc comments).
test "YUV to RGB conversion matches the hand-computed BT.601 anchors" {
    const Case = struct { y: u8, u: u8, v: u8, rgb: [3]u8 };
    const cases = [_]Case{
        .{ .y = 16, .u = 128, .v = 128, .rgb = .{ 0, 0, 0 } }, // black point
        .{ .y = 235, .u = 128, .v = 128, .rgb = .{ 255, 255, 255 } }, // white point
        .{ .y = 128, .u = 128, .v = 128, .rgb = .{ 130, 130, 130 } }, // neutral grey
        .{ .y = 120, .u = 100, .v = 150, .rgb = .{ 156, 114, 65 } }, // off-axis colour
    };

    for (cases) |case| {
        const luma = [_]u8{case.y};
        const chroma_u = [_]u8{case.u};
        const chroma_v = [_]u8{case.v};
        var out: [3]u8 = undefined;
        upsampleFancy(.rgb, .{
            .luma = &luma,
            .chroma_u = &chroma_u,
            .chroma_v = &chroma_v,
            .luma_stride = 1,
            .chroma_stride = 1,
            .width = 1,
            .height = 1,
        }, &out, out.len);
        try std.testing.expectEqualSlices(u8, &case.rgb, &out);
    }
}

// The off-axis grey above yields distinct R, G, B, so it pins the per-format
// channel order (and the opaque alpha fill) independently of the math.
test "pixel format selects channel order and opaque alpha" {
    const luma = [_]u8{120};
    const chroma_u = [_]u8{100};
    const chroma_v = [_]u8{150};
    const planes = Planes{
        .luma = &luma,
        .chroma_u = &chroma_u,
        .chroma_v = &chroma_v,
        .luma_stride = 1,
        .chroma_stride = 1,
        .width = 1,
        .height = 1,
    };

    var rgba: [4]u8 = undefined;
    upsampleFancy(.rgba, planes, &rgba, rgba.len);
    try std.testing.expectEqualSlices(u8, &.{ 156, 114, 65, 255 }, &rgba);

    var bgra: [4]u8 = undefined;
    upsampleFancy(.bgra, planes, &bgra, bgra.len);
    try std.testing.expectEqualSlices(u8, &.{ 65, 114, 156, 255 }, &bgra);

    var argb: [4]u8 = undefined;
    upsampleFancy(.argb, planes, &argb, argb.len);
    try std.testing.expectEqualSlices(u8, &.{ 255, 156, 114, 65 }, &argb);
}

// A uniform field must survive every code path unchanged: the first/last row
// mirrors, the interior pair loop, and both odd dimensions. Strides are wider
// than the visible region with the padding poisoned, so any stray read of the
// macroblock padding would corrupt the result.
test "a constant YUV field upsamples to a constant RGBA field" {
    const width = 5;
    const height = 3;
    const chroma_width = (width + 1) / 2;
    const chroma_height = (height + 1) / 2;
    const luma_stride = width + 3;
    const chroma_stride = chroma_width + 2;

    var luma: [luma_stride * height]u8 = @splat(0xaa);
    var chroma_u: [chroma_stride * chroma_height]u8 = @splat(0xaa);
    var chroma_v: [chroma_stride * chroma_height]u8 = @splat(0xaa);
    // Fill only the visible region with the constant; leave the stride padding
    // poisoned at 0xaa.
    for (0..height) |y| @memset(luma[y * luma_stride ..][0..width], 128);
    for (0..chroma_height) |y| {
        @memset(chroma_u[y * chroma_stride ..][0..chroma_width], 128);
        @memset(chroma_v[y * chroma_stride ..][0..chroma_width], 128);
    }

    var out: [width * height * 4]u8 = undefined;
    upsampleFancy(.rgba, .{
        .luma = &luma,
        .chroma_u = &chroma_u,
        .chroma_v = &chroma_v,
        .luma_stride = luma_stride,
        .chroma_stride = chroma_stride,
        .width = width,
        .height = height,
    }, &out, width * 4);

    var pixel: usize = 0;
    while (pixel < width * height) : (pixel += 1) {
        try std.testing.expectEqualSlices(u8, &.{ 130, 130, 130, 255 }, out[pixel * 4 ..][0..4]);
    }
}

// Locks the horizontal diamond weights independently of the oracle: a 3-wide,
// 1-tall frame with chroma [40, 80] interpolates to per-pixel chroma
// [40, 50, 70] (hand-derived from `UPSAMPLE_FUNC`), then converts. The first
// row mirrors vertically, so only the horizontal filter is exercised.
test "horizontal fancy upsampling interpolates the diamond weights" {
    const luma = [_]u8{ 128, 128, 128 };
    const chroma_u = [_]u8{ 40, 80 };
    const chroma_v = [_]u8{ 40, 80 };

    var out: [3 * 4]u8 = undefined;
    upsampleFancy(.rgba, .{
        .luma = &luma,
        .chroma_u = &chroma_u,
        .chroma_v = &chroma_v,
        .luma_stride = 3,
        .chroma_stride = 2,
        .width = 3,
        .height = 1,
    }, &out, out.len);

    try std.testing.expectEqualSlices(u8, &.{
        0, 236, 0, 255, // chroma (40, 40)
        6, 224, 0, 255, // chroma (50, 50)
        38, 200, 13, 255, // chroma (70, 70)
    }, &out);
}
