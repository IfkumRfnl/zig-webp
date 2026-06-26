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
const builtin = @import("builtin");
const assert = std.debug.assert;

const errors = @import("errors.zig");
const image = @import("image.zig");

const native_endian = builtin.cpu.arch.endian();

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

    // First output pixel mirrors column 0 (no left neighbour).
    {
        const top_left = loadUV(lines.top_u[0], lines.top_v[0]);
        const left = loadUV(lines.cur_u[0], lines.cur_v[0]);
        {
            const uv = (3 * top_left + left + 0x0002_0002) >> 2;
            storePixel(format, lines.top_dst[0..channels], lines.top_y[0], uv);
        }
        if (lines.bottom_y) |bottom_y| {
            const uv = (3 * left + top_left + 0x0002_0002) >> 2;
            storePixel(format, lines.bottom_dst.?[0..channels], bottom_y[0], uv);
        }
    }

    // Interior pairs. Each output pair at columns (2x-1, 2x) is a pure stencil
    // over chroma columns (x-1, x) — it never reads previously produced output
    // — so it vectorizes. The SIMD path consumes whole chunks of the 4-channel
    // formats and returns the first column it did not cover; the scalar loop
    // (bit-identical, the authoritative reference) finishes the remainder and
    // is the only path for 3-channel `rgb`.
    var x: usize = 1;
    // The SIMD store reinterprets a u32-per-pixel vector as bytes, which is
    // little-endian specific; big-endian (untested per PLAN.MD) takes the
    // scalar path, which is byte-for-byte the same.
    if (comptime channels == 4 and native_endian == .little) {
        x = upsampleInteriorSimd(format, lines, last_pixel_pair);
    }
    while (x <= last_pixel_pair) : (x += 1) {
        upsampleInteriorPair(format, lines, x);
    }

    // An even width leaves a final right-edge pixel; mirror the last column
    // (chroma column `last_pixel_pair`, the last one the loop touched).
    if (len & 1 == 0) {
        const last = last_pixel_pair;
        const top_left = loadUV(lines.top_u[last], lines.top_v[last]);
        const left = loadUV(lines.cur_u[last], lines.cur_v[last]);
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

// One interior output pair (scalar reference): columns (2x-1, 2x) from the 2x2
// chroma neighbourhood at (x-1, x). Stateless — reads chroma[x-1] directly —
// so it can resume after the SIMD path without carried state.
inline fn upsampleInteriorPair(comptime format: image.PixelFormat, lines: LinePair, x: usize) void {
    const channels: usize = comptime format.channelCount();
    const top_left = loadUV(lines.top_u[x - 1], lines.top_v[x - 1]);
    const left = loadUV(lines.cur_u[x - 1], lines.cur_v[x - 1]);
    const top = loadUV(lines.top_u[x], lines.top_v[x]);
    const cur = loadUV(lines.cur_u[x], lines.cur_v[x]);
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
}

// --- SIMD interior upsampling (4-channel, little-endian) -------------------
//
// Every lane reproduces `upsampleInteriorPair` exactly: the chroma diamond is
// integer add/shift, and the BT.601 matrix uses the same fixed-point `mulHi`
// (>>8) and `clip8` (== clamp(value >> 6, 0, 255), since `yuv_fix2 == 6`) as
// the scalar path. The output is therefore byte-identical to scalar — asserted
// by the byte-exact corpus-hash gate and a fixed-input equivalence unit test.
// Chroma `u`/`v` are kept in separate i32 lanes rather than the scalar packed
// u32 trick (which only existed to do both channels at once on a scalar ALU).

// Chroma columns processed per chunk; each yields twice as many output pixels.
const simd_chroma_cols = 8;
const simd_out_pixels = 2 * simd_chroma_cols;
const ChromaVec = @Vector(simd_chroma_cols, i32);
const PixelVec = @Vector(simd_out_pixels, i32);

/// Processes whole `simd_chroma_cols`-column chunks of the interior pairs and
/// returns the first chroma column the scalar loop must still cover.
fn upsampleInteriorSimd(
    comptime format: image.PixelFormat,
    lines: LinePair,
    last_pixel_pair: usize,
) usize {
    var x: usize = 1;
    while (x + simd_chroma_cols - 1 <= last_pixel_pair) : (x += simd_chroma_cols) {
        upsampleChunk(format, lines, x);
    }
    return x;
}

const Diagonals = struct { d12: ChromaVec, d03: ChromaVec };

/// The two shared diagonals of the diamond filter for one chroma channel:
/// `diag_12 = (avg + 2(t+l)) >> 3`, `diag_03 = (avg + 2(tl+c)) >> 3`, where
/// `avg = tl + t + l + c + 8`.
fn diamond(tl: ChromaVec, t: ChromaVec, l: ChromaVec, c: ChromaVec) Diagonals {
    const one: @Vector(simd_chroma_cols, u5) = @splat(1);
    const three: @Vector(simd_chroma_cols, u5) = @splat(3);
    const avg = tl + t + l + c + @as(ChromaVec, @splat(8));
    return .{
        .d12 = (avg + ((t + l) << one)) >> three,
        .d03 = (avg + ((tl + c) << one)) >> three,
    };
}

fn upsampleChunk(comptime format: image.PixelFormat, lines: LinePair, x: usize) void {
    const one: @Vector(simd_chroma_cols, u5) = @splat(1);

    const tlu = loadChroma(lines.top_u, x - 1);
    const tu = loadChroma(lines.top_u, x);
    const lu = loadChroma(lines.cur_u, x - 1);
    const cu = loadChroma(lines.cur_u, x);
    const tlv = loadChroma(lines.top_v, x - 1);
    const tv = loadChroma(lines.top_v, x);
    const lv = loadChroma(lines.cur_v, x - 1);
    const cv = loadChroma(lines.cur_v, x);

    const du = diamond(tlu, tu, lu, cu);
    const dv = diamond(tlv, tv, lv, cv);

    // Top row: out (2x-1) = (diag_12 + top_left), out (2x) = (diag_03 + top).
    {
        const u = interleave((du.d12 + tlu) >> one, (du.d03 + tu) >> one);
        const v = interleave((dv.d12 + tlv) >> one, (dv.d03 + tv) >> one);
        convertAndStore(format, lines.top_dst, lines.top_y, 2 * x - 1, u, v);
    }
    // Bottom row: out (2x-1) = (diag_03 + left), out (2x) = (diag_12 + cur).
    if (lines.bottom_y) |bottom_y| {
        const u = interleave((du.d03 + lu) >> one, (du.d12 + cu) >> one);
        const v = interleave((dv.d03 + lv) >> one, (dv.d12 + cv) >> one);
        convertAndStore(format, lines.bottom_dst.?, bottom_y, 2 * x - 1, u, v);
    }
}

/// Loads `simd_chroma_cols` bytes from `plane[off..]` widened to i32 lanes.
fn loadChroma(plane: []const u8, off: usize) ChromaVec {
    const bytes: @Vector(simd_chroma_cols, u8) = plane[off..][0..simd_chroma_cols].*;
    return @intCast(bytes);
}

/// Interleaves two per-column vectors into output order [a0, b0, a1, b1, ...].
fn interleave(a: ChromaVec, b: ChromaVec) PixelVec {
    const mask = comptime blk: {
        var m: [simd_out_pixels]i32 = undefined;
        for (0..simd_chroma_cols) |k| {
            m[2 * k] = @intCast(k);
            m[2 * k + 1] = ~@as(i32, @intCast(k));
        }
        break :blk @as(@Vector(simd_out_pixels, i32), m);
    };
    return @shuffle(i32, a, b, mask);
}

/// `(value * coeff) >> 8`, the `mulHi` of the scalar path, per lane.
fn mulHiVec(a: PixelVec, comptime coeff: i32) PixelVec {
    return (a * @as(PixelVec, @splat(coeff))) >> @as(@Vector(simd_out_pixels, u5), @splat(8));
}

/// `clip8` per lane: descale by `yuv_fix2` (6) and clamp to [0, 255].
fn clip8Vec(value: PixelVec) PixelVec {
    const descaled = value >> @as(@Vector(simd_out_pixels, u5), @splat(yuv_fix2));
    return @max(@min(descaled, @as(PixelVec, @splat(255))), @as(PixelVec, @splat(0)));
}

/// Converts `simd_out_pixels` (y, u, v) lanes to packed RGBA and stores them at
/// `dst[start..]` (four bytes per pixel). `u`/`v` are upsampled chroma in
/// [0,255]; `y_row[start..]` supplies luma.
fn convertAndStore(
    comptime format: image.PixelFormat,
    dst: []u8,
    y_row: []const u8,
    start: usize,
    u: PixelVec,
    v: PixelVec,
) void {
    const y: PixelVec = blk: {
        const bytes: @Vector(simd_out_pixels, u8) = y_row[start..][0..simd_out_pixels].*;
        break :blk @intCast(bytes);
    };

    const r = clip8Vec(mulHiVec(y, 19077) + mulHiVec(v, 26149) - @as(PixelVec, @splat(14234)));
    const g = clip8Vec(mulHiVec(y, 19077) - mulHiVec(u, 6419) - mulHiVec(v, 13320) + @as(PixelVec, @splat(8708)));
    const b = clip8Vec(mulHiVec(y, 19077) + mulHiVec(u, 33050) - @as(PixelVec, @splat(17685)));

    const ru: @Vector(simd_out_pixels, u32) = @intCast(r);
    const gu: @Vector(simd_out_pixels, u32) = @intCast(g);
    const bu: @Vector(simd_out_pixels, u32) = @intCast(b);
    const opaque_alpha: @Vector(simd_out_pixels, u32) = @splat(255);
    const eight: @Vector(simd_out_pixels, u5) = @splat(8);
    const sixteen: @Vector(simd_out_pixels, u5) = @splat(16);
    const twentyfour: @Vector(simd_out_pixels, u5) = @splat(24);

    // Little-endian: a u32 `c0 | c1<<8 | c2<<16 | c3<<24` stores as bytes
    // [c0, c1, c2, c3], matching `storePixel`'s channel order per format.
    const packed_pixels = switch (format) {
        .rgba => ru | (gu << eight) | (bu << sixteen) | (opaque_alpha << twentyfour),
        .bgra => bu | (gu << eight) | (ru << sixteen) | (opaque_alpha << twentyfour),
        .argb => opaque_alpha | (ru << eight) | (gu << sixteen) | (bu << twentyfour),
        .rgb => comptime unreachable,
    };
    @memcpy(dst[start * 4 ..][0 .. simd_out_pixels * 4], std.mem.asBytes(&packed_pixels));
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

//------------------------------------------------------------------------------
// RGB -> YUV 4:2:0 conversion (encode side, PLAN.MD step 8a).
//
// The BT.601 forward coefficients are libwebp's `VP8RGBToY/U/V`
// (`src/dsp/yuv.h`); chroma is a 2x2 box average. Unlike the decode direction
// this is not pinned bit-for-bit to libwebp — the step 8a gate compares the
// encoder's *reconstruction* against the decoder, which is identical by
// construction regardless of how the source chroma was downsampled, so an exact
// libwebp match here only affects PSNR. Color is computed from raw RGB with the
// alpha channel ignored, so a fully transparent pixel still contributes its
// hidden RGB (the transparent-RGB case step 8a must handle exactly).

/// Luma macroblock edge in pixels (16x16) and chroma macroblock edge (8x8).
pub const luma_block = 16;
pub const chroma_block = 8;

/// Owned macroblock-padded source planes: `luma` is `mb_width*16` by
/// `mb_height*16`, each chroma plane `mb_width*8` by `mb_height*8`, with partial
/// macroblocks filled by edge replication. The visible image is the top-left
/// `width` x `height` region. `view()` borrows these as decode-side `Planes`.
pub const YuvPlanes = struct {
    luma: []u8,
    chroma_u: []u8,
    chroma_v: []u8,
    luma_stride: usize,
    chroma_stride: usize,
    mb_width: u32,
    mb_height: u32,
    width: u32,
    height: u32,

    /// Allocates zero-initialized planes sized for `width` x `height` rounded up
    /// to whole macroblocks. Luma defaults to 0 and chroma to the neutral 128.
    pub fn initAlloc(gpa: std.mem.Allocator, width: u32, height: u32) std.mem.Allocator.Error!YuvPlanes {
        assert(width >= 1 and height >= 1);
        const mb_width = (width + luma_block - 1) / luma_block;
        const mb_height = (height + luma_block - 1) / luma_block;
        const luma_stride: usize = @as(usize, mb_width) * luma_block;
        const chroma_stride: usize = @as(usize, mb_width) * chroma_block;
        const luma_rows: usize = @as(usize, mb_height) * luma_block;
        const chroma_rows: usize = @as(usize, mb_height) * chroma_block;

        const luma = try gpa.alloc(u8, luma_stride * luma_rows);
        errdefer gpa.free(luma);
        const chroma_u = try gpa.alloc(u8, chroma_stride * chroma_rows);
        errdefer gpa.free(chroma_u);
        const chroma_v = try gpa.alloc(u8, chroma_stride * chroma_rows);

        @memset(luma, 0);
        @memset(chroma_u, 128);
        @memset(chroma_v, 128);

        return .{
            .luma = luma,
            .chroma_u = chroma_u,
            .chroma_v = chroma_v,
            .luma_stride = luma_stride,
            .chroma_stride = chroma_stride,
            .mb_width = mb_width,
            .mb_height = mb_height,
            .width = width,
            .height = height,
        };
    }

    pub fn deinit(self: *YuvPlanes, gpa: std.mem.Allocator) void {
        gpa.free(self.luma);
        gpa.free(self.chroma_u);
        gpa.free(self.chroma_v);
        self.* = undefined;
    }

    /// Borrows the planes as decode-side `Planes` (e.g. to upsample back to RGB).
    pub fn view(self: *const YuvPlanes) Planes {
        return .{
            .luma = self.luma,
            .chroma_u = self.chroma_u,
            .chroma_v = self.chroma_v,
            .luma_stride = self.luma_stride,
            .chroma_stride = self.chroma_stride,
            .width = self.width,
            .height = self.height,
        };
    }
};

pub fn yuv420AllocationBytes(width: u32, height: u32) errors.Error!u64 {
    if (width == 0) return error.InvalidCanvasSize;
    if (height == 0) return error.InvalidCanvasSize;

    const mb_width = (@as(u64, width) + luma_block - 1) / luma_block;
    const mb_height = (@as(u64, height) + luma_block - 1) / luma_block;
    const luma_stride = mb_width * luma_block;
    const chroma_stride = mb_width * chroma_block;
    const luma_rows = mb_height * luma_block;
    const chroma_rows = mb_height * chroma_block;

    var bytes = try mulByteCounts(luma_stride, luma_rows);
    bytes = try addByteCounts(bytes, try mulByteCounts(chroma_stride, chroma_rows));
    bytes = try addByteCounts(bytes, try mulByteCounts(chroma_stride, chroma_rows));
    return bytes;
}

fn addByteCounts(a: u64, b: u64) errors.Error!u64 {
    return std.math.add(u64, a, b) catch error.AllocationLimitExceeded;
}

fn mulByteCounts(a: u64, b: u64) errors.Error!u64 {
    return std.math.mul(u64, a, b) catch error.AllocationLimitExceeded;
}

/// Converts packed-ARGB source pixels (`0xAARRGGBB`, row-major, length
/// `width*height`; alpha ignored) into macroblock-padded YUV 4:2:0 source
/// planes. Partial macroblocks are filled by replicating the visible edge.
pub fn rgbaToYuv420Alloc(
    gpa: std.mem.Allocator,
    argb: []const u32,
    width: u32,
    height: u32,
) std.mem.Allocator.Error!YuvPlanes {
    const w: usize = width;
    const h: usize = height;
    assert(argb.len == w * h);

    var planes = try YuvPlanes.initAlloc(gpa, width, height);
    errdefer planes.deinit(gpa);

    const luma_stride = planes.luma_stride;
    // Luma over the visible region, then replicate the right edge across the
    // macroblock padding of each row.
    for (0..h) |y| {
        const dst = planes.luma[y * luma_stride ..];
        for (0..w) |x| {
            const p = argb[y * w + x];
            dst[x] = rgbToY(redOf(p), greenOf(p), blueOf(p));
        }
        const edge = dst[w - 1];
        for (w..luma_stride) |x| dst[x] = edge;
    }
    // Replicate the bottom edge row across the macroblock padding below.
    const luma_rows: usize = @as(usize, planes.mb_height) * luma_block;
    for (h..luma_rows) |y| {
        @memcpy(
            planes.luma[y * luma_stride ..][0..luma_stride],
            planes.luma[(h - 1) * luma_stride ..][0..luma_stride],
        );
    }

    // Chroma over the full padded grid; each cell box-averages its 2x2 source
    // window with coordinates clamped into the visible region (edge replicate).
    const chroma_stride = planes.chroma_stride;
    const chroma_rows: usize = @as(usize, planes.mb_height) * chroma_block;
    for (0..chroma_rows) |cy| {
        for (0..chroma_stride) |cx| {
            var r4: i32 = 0;
            var g4: i32 = 0;
            var b4: i32 = 0;
            for (0..2) |dy| {
                for (0..2) |dx| {
                    const sx = @min(2 * cx + dx, w - 1);
                    const sy = @min(2 * cy + dy, h - 1);
                    const p = argb[sy * w + sx];
                    r4 += redOf(p);
                    g4 += greenOf(p);
                    b4 += blueOf(p);
                }
            }
            planes.chroma_u[cy * chroma_stride + cx] = rgbSumToU(r4, g4, b4);
            planes.chroma_v[cy * chroma_stride + cx] = rgbSumToV(r4, g4, b4);
        }
    }

    return planes;
}

// Sharp-YUV chroma refinement: number of Jacobi correction passes. Sharp YUV is
// an iterative scheme, but it converges quickly; libwebp caps its own loop at a
// handful of passes. Four keeps the work bounded and deterministic while
// capturing nearly all of the achievable error reduction.
const sharp_iterations = 4;

// Diamond upsample of one subsampled chroma cell grid at a single full-resolution
// pixel, matching `upsampleLinePair`'s 9:3:3:1 weights. `cols`/`rows` bound the
// grid; out-of-range neighbours clamp to the edge (the decoder mirrors at the
// boundary, which for the outermost cell yields the same value). Returns the
// reconstructed chroma sample in [0, 255]. Used only by the sharp downsampler so
// the refinement targets exactly the filter the decoder will apply.
fn reconChromaAt(
    grid: []const u8,
    stride: usize,
    cols: usize,
    rows: usize,
    x: usize,
    y: usize,
) u8 {
    assert(cols >= 1);
    assert(rows >= 1);
    const cx = x >> 1;
    const cy = y >> 1;
    // The nearest cell is (cx, cy); the half-sample neighbours sit toward the
    // pixel's side of that cell. Even pixels lean to the lower-indexed cell,
    // odd pixels to the higher-indexed one (the fancy filter's phase).
    const nx: usize = if (x & 1 == 0) prevIndex(cx) else nextIndex(cx, cols);
    const ny: usize = if (y & 1 == 0) prevIndex(cy) else nextIndex(cy, rows);

    const a: i32 = grid[cy * stride + cx]; // nearest
    const b: i32 = grid[cy * stride + nx]; // horizontal neighbour
    const c: i32 = grid[ny * stride + cx]; // vertical neighbour
    const d: i32 = grid[ny * stride + nx]; // diagonal neighbour
    const sample = (9 * a + 3 * b + 3 * c + d + 8) >> 4;
    return @intCast(std.math.clamp(sample, 0, 255));
}

inline fn prevIndex(index: usize) usize {
    return if (index == 0) 0 else index - 1;
}

inline fn nextIndex(index: usize, count: usize) usize {
    return if (index + 1 < count) index + 1 else index;
}

/// Like `rgbaToYuv420Alloc`, but downsamples chroma with the sharp (iterative)
/// scheme instead of a plain 2x2 box average. Luma is identical to the box path
/// (it is full-resolution, not subsampled); only the subsampled U/V grids
/// differ. Sharp YUV starts from the box average and runs a fixed number of
/// Jacobi passes that drive the *upsampled* chroma (the filter the decoder will
/// apply) toward the full-resolution per-pixel chroma target, so saturated
/// colour edges survive 4:2:0 subsampling with less bleed. Deterministic and
/// bounded; partial macroblocks are edge-replicated exactly as the box path.
pub fn rgbaToYuv420SharpAlloc(
    gpa: std.mem.Allocator,
    argb: []const u32,
    width: u32,
    height: u32,
) std.mem.Allocator.Error!YuvPlanes {
    const w: usize = width;
    const h: usize = height;
    assert(argb.len == w * h);

    // Start from the box-average conversion: identical luma, and a chroma grid
    // that is already a good initial guess for the refinement.
    var planes = try rgbaToYuv420Alloc(gpa, argb, width, height);
    errdefer planes.deinit(gpa);

    const chroma_stride = planes.chroma_stride;
    const chroma_cols: usize = chroma_stride;
    const chroma_rows: usize = @as(usize, planes.mb_height) * chroma_block;
    const luma_cols: usize = @as(usize, planes.mb_width) * luma_block;
    const luma_rows: usize = @as(usize, planes.mb_height) * luma_block;

    // Full-resolution per-pixel chroma target over the padded grid. Source
    // coordinates clamp into the visible region (edge replicate), matching the
    // box path's padding so the sharp result agrees with box on flat content.
    const target_u = try gpa.alloc(u8, luma_cols * luma_rows);
    defer gpa.free(target_u);
    const target_v = try gpa.alloc(u8, luma_cols * luma_rows);
    defer gpa.free(target_v);
    for (0..luma_rows) |y| {
        const sy = @min(y, h - 1);
        for (0..luma_cols) |x| {
            const sx = @min(x, w - 1);
            const p = argb[sy * w + sx];
            const r = redOf(p);
            const g = greenOf(p);
            const b = blueOf(p);
            target_u[y * luma_cols + x] = rgbToU(r, g, b);
            target_v[y * luma_cols + x] = rgbToV(r, g, b);
        }
    }

    // Jacobi refinement: each pass measures, for every subsampled cell, the mean
    // residual between the full-resolution chroma target and what the diamond
    // upsampler currently reconstructs across that cell's 2x2 pixel footprint,
    // then nudges the cell by the rounded mean. Cells are the dominant weight in
    // their own footprint, so the upsampled chroma converges toward the target.
    for (0..sharp_iterations) |_| {
        refineChromaPass(planes.chroma_u, target_u, chroma_stride, chroma_cols, chroma_rows, luma_cols, luma_rows);
        refineChromaPass(planes.chroma_v, target_v, chroma_stride, chroma_cols, chroma_rows, luma_cols, luma_rows);
    }

    return planes;
}

// One correction pass over a single chroma plane. `grid` is the subsampled
// plane to refine in place; `target` is the full-resolution per-pixel chroma.
// For each cell we measure the mean residual between the target and what the
// diamond upsampler reconstructs across that cell's 2x2 pixel footprint, then
// add the rounded mean to the cell. Cells are updated in row-major order and
// read the current `grid`, so this is a Gauss-Seidel sweep (updates propagate
// within the pass) — deterministic for a fixed iteration order and convergent
// because each cell is the dominant 9/16 weight in its own footprint.
fn refineChromaPass(
    grid: []u8,
    target: []const u8,
    stride: usize,
    cols: usize,
    rows: usize,
    luma_cols: usize,
    luma_rows: usize,
) void {
    for (0..rows) |cy| {
        for (0..cols) |cx| {
            var residual_sum: i32 = 0;
            var count: i32 = 0;
            // The 2x2 full-resolution pixels this cell is the nearest neighbour
            // of. Bounded by the padded luma geometry so partial cells at the
            // padded edge still average only the pixels they own.
            for (0..2) |dy| {
                const y = 2 * cy + dy;
                if (y >= luma_rows) break;
                for (0..2) |dx| {
                    const x = 2 * cx + dx;
                    if (x >= luma_cols) break;
                    const recon: i32 = reconChromaAt(grid, stride, cols, rows, x, y);
                    const want: i32 = target[y * luma_cols + x];
                    residual_sum += want - recon;
                    count += 1;
                }
            }
            assert(count >= 1);
            // Round-to-nearest mean residual, added to the current cell value.
            const half = @divTrunc(count, 2);
            const delta = @divTrunc(residual_sum + (if (residual_sum >= 0) half else -half), count);
            const updated = @as(i32, grid[cy * stride + cx]) + delta;
            grid[cy * stride + cx] = @intCast(std.math.clamp(updated, 0, 255));
        }
    }
}

inline fn redOf(p: u32) i32 {
    return @intCast((p >> 16) & 0xff);
}
inline fn greenOf(p: u32) i32 {
    return @intCast((p >> 8) & 0xff);
}
inline fn blueOf(p: u32) i32 {
    return @intCast(p & 0xff);
}

// Per-pixel luma: libwebp `VP8RGBToY` with round-to-nearest and the 16-level
// black offset folded in, descaled by YUV_FIX (16). Result lands in [16, 235].
inline fn rgbToY(r: i32, g: i32, b: i32) u8 {
    const luma = 16839 * r + 33059 * g + 6420 * b;
    const y = (luma + (1 << 15) + (16 << 16)) >> 16;
    return @intCast(std.math.clamp(y, 0, 255));
}

// Chroma from a 2x2 sum: libwebp `VP8RGBToU/V` coefficients applied to the sum,
// descaled by YUV_FIX+2 (18 = 16 fixed-point + 2 for the /4 average), centered
// at 128 with round-to-nearest.
inline fn rgbSumToU(r4: i32, g4: i32, b4: i32) u8 {
    return clipUV(-9719 * r4 - 19081 * g4 + 28800 * b4);
}
inline fn rgbSumToV(r4: i32, g4: i32, b4: i32) u8 {
    return clipUV(28800 * r4 - 24116 * g4 - 4684 * b4);
}
inline fn clipUV(value: i32) u8 {
    const x = (value + (1 << 17) + (128 << 18)) >> 18;
    return @intCast(std.math.clamp(x, 0, 255));
}

// Per-pixel chroma: the same `VP8RGBToU/V` coefficients as `rgbSumToU/V` but
// applied to a single sample, so the descale is YUV_FIX (16) with no /4 average
// folded in. This is the full-resolution chroma target the sharp downsampler
// aims to reproduce after the decoder upsamples the subsampled grid.
inline fn rgbToU(r: i32, g: i32, b: i32) u8 {
    return clipChroma(-9719 * r - 19081 * g + 28800 * b);
}
inline fn rgbToV(r: i32, g: i32, b: i32) u8 {
    return clipChroma(28800 * r - 24116 * g - 4684 * b);
}
inline fn clipChroma(value: i32) u8 {
    const x = (value + (1 << 15) + (128 << 16)) >> 16;
    return @intCast(std.math.clamp(x, 0, 255));
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
test "SIMD rgba upsampling matches the scalar path byte-for-byte" {
    // A width past the SIMD chunk threshold ((w-1)>>1 >= 8 ⇒ w >= 17), odd so
    // the even-width tail is also exercised, and several rows so both the top
    // and bottom diamond branches run. The `.rgb` format takes the scalar path
    // (SIMD is 4-channel only), so its R/G/B must equal the `.rgba` SIMD path's
    // — a non-circular check of the SIMD diamond, interleave, and store.
    const width = 37;
    const height = 5;
    const chroma_width = (width + 1) / 2;
    const chroma_height = (height + 1) / 2;
    const luma_stride = width + 3;
    const chroma_stride = chroma_width + 2;

    var luma: [luma_stride * height]u8 = @splat(0);
    var chroma_u: [chroma_stride * chroma_height]u8 = @splat(0);
    var chroma_v: [chroma_stride * chroma_height]u8 = @splat(0);
    for (0..height) |y| {
        for (0..width) |x| luma[y * luma_stride + x] = @intCast((x * 7 + y * 29) & 0xff);
    }
    for (0..chroma_height) |y| {
        for (0..chroma_width) |x| {
            chroma_u[y * chroma_stride + x] = @intCast((x * 17 + y * 5) & 0xff);
            chroma_v[y * chroma_stride + x] = @intCast((200 -% (x * 11 + y * 23)) & 0xff);
        }
    }

    const planes = Planes{
        .luma = &luma,
        .chroma_u = &chroma_u,
        .chroma_v = &chroma_v,
        .luma_stride = luma_stride,
        .chroma_stride = chroma_stride,
        .width = width,
        .height = height,
    };

    var rgba: [width * height * 4]u8 = undefined;
    var rgb: [width * height * 3]u8 = undefined;
    upsampleFancy(.rgba, planes, &rgba, width * 4);
    upsampleFancy(.rgb, planes, &rgb, width * 3);

    for (0..width * height) |i| {
        try std.testing.expectEqualSlices(u8, rgb[i * 3 ..][0..3], rgba[i * 4 ..][0..3]);
        try std.testing.expectEqual(@as(u8, 255), rgba[i * 4 + 3]);
    }
}

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

// Forward RGB->YUV anchors, hand-computed from the libwebp coefficients above.
test "RGB to YUV converts hand-computed BT.601 anchors" {
    const Case = struct { argb: u32, y: u8, u: u8, v: u8 };
    const cases = [_]Case{
        .{ .argb = 0xff80_8080, .y = 126, .u = 128, .v = 128 }, // neutral grey
        .{ .argb = 0xffff_0000, .y = 82, .u = 90, .v = 240 }, // pure red
        .{ .argb = 0xff00_ff00, .y = 145, .u = 54, .v = 34 }, // pure green
        .{ .argb = 0xff00_00ff, .y = 41, .u = 240, .v = 110 }, // pure blue
    };
    for (cases) |case| {
        const argb = [_]u32{case.argb};
        var planes = try rgbaToYuv420Alloc(std.testing.allocator, &argb, 1, 1);
        defer planes.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.y, planes.luma[0]);
        try std.testing.expectEqual(case.u, planes.chroma_u[0]);
        try std.testing.expectEqual(case.v, planes.chroma_v[0]);
    }
}

// Color is computed from raw RGB regardless of alpha: a fully transparent red
// yields the same YUV as an opaque red (the transparent-RGB case).
test "RGB to YUV ignores alpha (transparent RGB is preserved)" {
    const opaque_red = [_]u32{0xffff_0000};
    const transparent_red = [_]u32{0x00ff_0000};
    var a = try rgbaToYuv420Alloc(std.testing.allocator, &opaque_red, 1, 1);
    defer a.deinit(std.testing.allocator);
    var b = try rgbaToYuv420Alloc(std.testing.allocator, &transparent_red, 1, 1);
    defer b.deinit(std.testing.allocator);
    try std.testing.expectEqual(a.luma[0], b.luma[0]);
    try std.testing.expectEqual(a.chroma_u[0], b.chroma_u[0]);
    try std.testing.expectEqual(a.chroma_v[0], b.chroma_v[0]);
}

// Odd dimensions pad to whole macroblocks by edge replication: a constant field
// stays constant through every plane sample, including the padding, and the
// padded geometry matches ceil(dim/16).
test "RGB to YUV pads partial macroblocks by replicating the edge" {
    const width = 17;
    const height = 17;
    var argb: [width * height]u32 = @splat(0xff3c_7818); // arbitrary constant color
    var planes = try rgbaToYuv420Alloc(std.testing.allocator, &argb, width, height);
    defer planes.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 2), planes.mb_width);
    try std.testing.expectEqual(@as(u32, 2), planes.mb_height);
    try std.testing.expectEqual(@as(usize, 32), planes.luma_stride);
    try std.testing.expectEqual(@as(usize, 16), planes.chroma_stride);

    const luma_first = planes.luma[0];
    for (planes.luma) |sample| try std.testing.expectEqual(luma_first, sample);
    const u_first = planes.chroma_u[0];
    for (planes.chroma_u) |sample| try std.testing.expectEqual(u_first, sample);
    const v_first = planes.chroma_v[0];
    for (planes.chroma_v) |sample| try std.testing.expectEqual(v_first, sample);

    _ = &argb;
}

// Forward then back (via the decoder-side fancy upsampler) recovers a constant
// field essentially exactly, exercising the full conversion pair.
test "RGB to YUV round-trips a constant field through the upsampler" {
    const width = 6;
    const height = 5;
    var argb: [width * height]u32 = @splat(0xff20_60a0);
    var planes = try rgbaToYuv420Alloc(std.testing.allocator, &argb, width, height);
    defer planes.deinit(std.testing.allocator);

    var rgba: [width * height * 4]u8 = undefined;
    upsampleFancy(.rgba, planes.view(), &rgba, width * 4);

    // The decode side does not recover the source bit-for-bit (YUV 4:2:0 is
    // lossy), but a constant field should land within a couple of levels.
    for (0..width * height) |pixel| {
        const got = rgba[pixel * 4 ..][0..4];
        try std.testing.expect(@abs(@as(i32, got[0]) - 0x20) <= 3);
        try std.testing.expect(@abs(@as(i32, got[1]) - 0x60) <= 3);
        try std.testing.expect(@abs(@as(i32, got[2]) - 0xa0) <= 3);
        try std.testing.expectEqual(@as(u8, 255), got[3]);
    }
    _ = &argb;
}

// The box-average converter is the project's pinned default; sharp YUV is opt-in
// and must not perturb it. This pins a non-trivial color gradient's box output
// so any accidental change to the box path (e.g. while editing the shared
// helpers) is caught here rather than silently shifting every default encode.
test "box-average RGB to YUV stays byte-stable on a color gradient" {
    const width = 8;
    const height = 6;
    var argb: [width * height]u32 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const r: u32 = @intCast((x * 31) & 0xff);
            const g: u32 = @intCast((y * 41) & 0xff);
            const b: u32 = @intCast(((x + y) * 19) & 0xff);
            argb[y * width + x] = 0xff00_0000 | (r << 16) | (g << 8) | b;
        }
    }
    var planes = try rgbaToYuv420Alloc(std.testing.allocator, &argb, width, height);
    defer planes.deinit(std.testing.allocator);

    // Hand-independent but exact: a checksum of every plane sample. If the box
    // path changes for any reason these sums move, failing the gate.
    var luma_sum: u64 = 0;
    for (planes.luma) |s| luma_sum += s;
    var u_sum: u64 = 0;
    for (planes.chroma_u) |s| u_sum += s;
    var v_sum: u64 = 0;
    for (planes.chroma_v) |s| v_sum += s;
    try std.testing.expectEqual(@as(u64, 40801), luma_sum);
    try std.testing.expectEqual(@as(u64, 8506), u_sum);
    try std.testing.expectEqual(@as(u64, 8045), v_sum);
}

// `reconChromaAt`'s closed-form 9:3:3:1 diamond must reproduce, sample for
// sample, the chroma the decoder's `upsampleFancy` emits — otherwise the sharp
// refinement would be optimizing against the wrong filter. We compare the two
// over a small non-constant chroma grid (constant luma isolates chroma).
test "reconChromaAt matches the decoder fancy chroma upsampler" {
    const width = 5;
    const height = 5;
    const chroma_width = (width + 1) / 2; // 3
    const chroma_height = (height + 1) / 2; // 3
    const luma = [_]u8{128} ** (width * height);
    // A varied chroma grid so every diamond weight is exercised.
    const chroma_u = [_]u8{ 20, 60, 120, 70, 130, 200, 30, 90, 150 };
    const chroma_v = [_]u8{ 200, 140, 80, 150, 90, 30, 120, 60, 10 };

    var rgb: [width * height * 3]u8 = undefined;
    upsampleFancy(.rgb, .{
        .luma = &luma,
        .chroma_u = &chroma_u,
        .chroma_v = &chroma_v,
        .luma_stride = width,
        .chroma_stride = chroma_width,
        .width = width,
        .height = height,
    }, &rgb, width * 3);

    for (0..height) |y| {
        for (0..width) |x| {
            const u = reconChromaAt(&chroma_u, chroma_width, chroma_width, chroma_height, x, y);
            const v = reconChromaAt(&chroma_v, chroma_width, chroma_width, chroma_height, x, y);
            // Reconstruct RGB from (128, u, v) and compare to the decoder pixel.
            const expect = rgb[(y * width + x) * 3 ..][0..3];
            const r = yuvToR(128, v);
            const g = yuvToG(128, u, v);
            const b = yuvToB(128, u);
            try std.testing.expectEqual(expect[0], r);
            try std.testing.expectEqual(expect[1], g);
            try std.testing.expectEqual(expect[2], b);
        }
    }
}

// Sharp YUV must agree with the box average on flat content: with no chroma
// detail there is nothing to refine, so the upsampled chroma already equals the
// target and every correction is zero. (Also guards the edge-replicated padding
// against a stray sharp-only difference.)
test "sharp YUV equals box average on a constant field" {
    const width = 13;
    const height = 11;
    var argb: [width * height]u32 = @splat(0xff20_60a0);
    var box = try rgbaToYuv420Alloc(std.testing.allocator, &argb, width, height);
    defer box.deinit(std.testing.allocator);
    var sharp = try rgbaToYuv420SharpAlloc(std.testing.allocator, &argb, width, height);
    defer sharp.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, box.luma, sharp.luma);
    try std.testing.expectEqualSlices(u8, box.chroma_u, sharp.chroma_u);
    try std.testing.expectEqualSlices(u8, box.chroma_v, sharp.chroma_v);
    _ = &argb;
}

// Sharp YUV leaves luma untouched: luma is full-resolution and never subsampled,
// so only the chroma grids may differ from the box path.
test "sharp YUV preserves the luma plane exactly" {
    const width = 16;
    const height = 16;
    var argb: [width * height]u32 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const v: u32 = @intCast(((x * 16) ^ (y * 9)) & 0xff);
            argb[y * width + x] = 0xff00_0000 | (v << 16) | ((255 - v) << 8) | (v / 2);
        }
    }
    var box = try rgbaToYuv420Alloc(std.testing.allocator, &argb, width, height);
    defer box.deinit(std.testing.allocator);
    var sharp = try rgbaToYuv420SharpAlloc(std.testing.allocator, &argb, width, height);
    defer sharp.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, box.luma, sharp.luma);
}

// The payoff test: on a saturated colour edge (the case 4:2:0 subsampling hurts
// most), the sharp converter's chroma must reconstruct closer to the source than
// the box average after the decoder upsamples. We measure RGB PSNR of source vs.
// (convert -> fancy-upsample) for each path, isolating the converter from the
// VP8 quantizer, and require sharp to be no worse (in practice clearly better).
test "sharp YUV improves chroma fidelity on a saturated color edge" {
    const metrics = @import("testing/metrics.zig");
    const gpa = std.testing.allocator;
    const width = 32;
    const height = 32;
    const argb = try gpa.alloc(u32, width * height);
    defer gpa.free(argb);
    // Vertical red/blue stripes 2px wide: a high-frequency, fully saturated
    // chroma edge that box subsampling smears badly.
    for (0..height) |y| {
        for (0..width) |x| {
            argb[y * width + x] = if ((x / 2) & 1 == 0) 0xffff_0000 else 0xff00_00ff;
        }
    }

    const source_rgb = try gpa.alloc(u8, width * height * 3);
    defer gpa.free(source_rgb);
    for (argb, 0..) |p, i| {
        source_rgb[i * 3 + 0] = @intCast((p >> 16) & 0xff);
        source_rgb[i * 3 + 1] = @intCast((p >> 8) & 0xff);
        source_rgb[i * 3 + 2] = @intCast(p & 0xff);
    }

    const box_rgb = try gpa.alloc(u8, width * height * 3);
    defer gpa.free(box_rgb);
    const sharp_rgb = try gpa.alloc(u8, width * height * 3);
    defer gpa.free(sharp_rgb);

    var box = try rgbaToYuv420Alloc(gpa, argb, width, height);
    defer box.deinit(gpa);
    upsampleFancy(.rgb, box.view(), box_rgb, width * 3);

    var sharp = try rgbaToYuv420SharpAlloc(gpa, argb, width, height);
    defer sharp.deinit(gpa);
    upsampleFancy(.rgb, sharp.view(), sharp_rgb, width * 3);

    const box_psnr = metrics.psnrBytes(box_rgb, source_rgb);
    const sharp_psnr = metrics.psnrBytes(sharp_rgb, source_rgb);
    // Sharp must not regress chroma fidelity; on this saturated red/blue stripe
    // edge it improves RGB PSNR from ~13.9 dB (box) to ~16.1 dB.
    try std.testing.expect(sharp_psnr >= box_psnr);
}
