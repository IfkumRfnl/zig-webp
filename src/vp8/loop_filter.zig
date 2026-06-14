//! VP8 in-loop deblocking filter (RFC 6386 section 15).
//!
//! Runs as a single pass over the fully reconstructed, macroblock-padded YUV
//! planes: intra prediction only ever reads unfiltered pixels (the decoder
//! snapshots the above row before filtering touches it), so deferring every
//! edge to the end is bit-identical to libwebp's row-interleaved pipeline as
//! long as macroblocks are visited in raster order and, within each one, the
//! four edge groups run left / inner-vertical / top / inner-horizontal. The
//! kernels and the per-segment strength derivation are transcribed from
//! `references/libwebp` (`src/dsp/dec.c`, `src/dec/frame_dec.c`) and
//! cross-checked against the normative RFC 6386 section 15 text.

const std = @import("std");
const assert = std.debug.assert;

const frame_header = @import("frame_header.zig");
const modes = @import("modes.zig");

pub const segment_count = frame_header.segment_count;

/// Frame-level filter selection (RFC 6386 section 15.1). A zero base level
/// disables filtering entirely, regardless of per-segment deltas, matching
/// libwebp's `filter_type` resolution.
pub const Type = enum { none, simple, complex };

pub fn filterType(header: *const frame_header.Header) Type {
    if (header.loop_filter.level == 0) return .none;
    if (header.loop_filter.simple) return .simple;
    return .complex;
}

/// Resolved strength for one (segment, prediction-size) class. `limit == 0`
/// marks a class that is not filtered (its level resolved to zero). `inner`
/// is the base interior-edge flag (set only for B_PRED); the per-macroblock
/// pass ORs it with "the macroblock carries nonzero coefficients".
pub const FilterInfo = struct {
    limit: i32,
    inner_limit: i32,
    hev_threshold: i32,
    inner: bool,
};

/// Strengths indexed by `[segment_id][is_i4x4]`, where `is_i4x4` is 1 for
/// B_PRED macroblocks and 0 for the whole-block 16x16 luma modes.
pub const Strengths = [segment_count][2]FilterInfo;

/// Precomputes every (segment, prediction-size) strength once per frame
/// (RFC 6386 section 15.4, mirroring libwebp's `PrecomputeFilterStrengths`).
pub fn computeStrengths(header: *const frame_header.Header) Strengths {
    const loop_filter = &header.loop_filter;
    const segmentation = &header.segmentation;

    var strengths: Strengths = undefined;
    var segment: usize = 0;
    while (segment < segment_count) : (segment += 1) {
        // Per-segment base level: an absolute replacement or a delta on the
        // frame level when segmentation is active, else the frame level.
        const base_level: i32 = if (segmentation.enabled) base: {
            var level: i32 = segmentation.filter_strength_deltas[segment];
            if (!segmentation.absolute_values) {
                level += loop_filter.level;
            }
            break :base level;
        } else loop_filter.level;

        for (0..2) |is_i4x4| {
            var level = base_level;
            if (loop_filter.delta_enabled) {
                // Key frames are always intra, so only the intra reference
                // delta (index 0) applies; the B_PRED mode delta (index 0)
                // applies to the 4x4 class.
                level += loop_filter.ref_frame_deltas[0];
                if (is_i4x4 == 1) {
                    level += loop_filter.mode_deltas[0];
                }
            }
            strengths[segment][is_i4x4] = resolveInfo(level, loop_filter.sharpness, is_i4x4 == 1);
        }
    }
    return strengths;
}

fn resolveInfo(level_unclamped: i32, sharpness: u8, inner: bool) FilterInfo {
    const level = std.math.clamp(level_unclamped, 0, 63);
    if (level == 0) {
        return .{ .limit = 0, .inner_limit = 0, .hev_threshold = 0, .inner = inner };
    }

    // Interior limit: sharpness narrows it, then a floor of 1 (RFC 15.2).
    var inner_limit = level;
    if (sharpness > 0) {
        inner_limit >>= if (sharpness > 4) 2 else 1;
        const cap: i32 = 9 - @as(i32, sharpness);
        if (inner_limit > cap) {
            inner_limit = cap;
        }
    }
    if (inner_limit < 1) {
        inner_limit = 1;
    }

    const hev_threshold: i32 = if (level >= 40) 2 else if (level >= 15) 1 else 0;
    return .{
        .limit = 2 * level + inner_limit,
        .inner_limit = inner_limit,
        .hev_threshold = hev_threshold,
        .inner = inner,
    };
}

/// Mutable view of the reconstructed, macroblock-padded planes.
pub const FrameView = struct {
    luma: []u8,
    chroma_u: []u8,
    chroma_v: []u8,
    luma_stride: usize,
    chroma_stride: usize,
};

/// Filters the whole frame in place. `has_nonzero[i]` is the residual flag
/// (`decodeMacroblock`'s return) for macroblock `i` in raster order.
pub fn applyFrame(
    view: FrameView,
    grid: modes.MacroblockGrid,
    macroblocks: []const modes.Macroblock,
    has_nonzero: []const bool,
    strengths: *const Strengths,
    filter_type: Type,
) void {
    assert(filter_type != .none);
    assert(macroblocks.len == grid.macroblockCount());
    assert(has_nonzero.len == macroblocks.len);

    var mb_y: u32 = 0;
    while (mb_y < grid.rows) : (mb_y += 1) {
        var mb_x: u32 = 0;
        while (mb_x < grid.columns) : (mb_x += 1) {
            const index = mb_y * grid.columns + mb_x;
            const macroblock = &macroblocks[index];
            const is_i4x4 = macroblock.luma_mode == .subblocks;
            const template = &strengths[macroblock.segment_id][@intFromBool(is_i4x4)];
            if (template.limit == 0) continue;

            var info = template.*;
            // libwebp: f_inner |= !skip, where !skip is exactly "had nonzero
            // coefficients" once explicit skips are folded in.
            info.inner = info.inner or has_nonzero[index];
            filterMacroblock(view, filter_type, &info, mb_x, mb_y);
        }
    }
}

fn filterMacroblock(
    view: FrameView,
    filter_type: Type,
    info: *const FilterInfo,
    mb_x: u32,
    mb_y: u32,
) void {
    assert(filter_type != .none);
    const limit = info.limit;
    assert(limit >= 3);

    const edge = limit + 4;
    const inner_limit = info.inner_limit;
    const hev_threshold = info.hev_threshold;
    const has_left = mb_x > 0;
    const has_top = mb_y > 0;

    const y_stride = view.luma_stride;
    const y_step: i32 = @intCast(y_stride);
    const y_base = @as(usize, mb_y) * 16 * y_stride + @as(usize, mb_x) * 16;

    switch (filter_type) {
        .none => unreachable,
        .simple => {
            if (has_left) {
                simpleEdge(view.luma, y_base, 1, y_stride, 16, edge);
            }
            if (info.inner) {
                for (1..4) |k| {
                    simpleEdge(view.luma, y_base + 4 * k, 1, y_stride, 16, limit);
                }
            }
            if (has_top) {
                simpleEdge(view.luma, y_base, y_step, 1, 16, edge);
            }
            if (info.inner) {
                for (1..4) |k| {
                    simpleEdge(view.luma, y_base + 4 * k * y_stride, y_step, 1, 16, limit);
                }
            }
        },
        .complex => {
            const uv_stride = view.chroma_stride;
            const uv_step: i32 = @intCast(uv_stride);
            const uv_base = @as(usize, mb_y) * 8 * uv_stride + @as(usize, mb_x) * 8;

            if (has_left) {
                complexEdge(view.luma, y_base, 1, y_stride, 16, edge, inner_limit, hev_threshold, true);
                complexEdge(view.chroma_u, uv_base, 1, uv_stride, 8, edge, inner_limit, hev_threshold, true);
                complexEdge(view.chroma_v, uv_base, 1, uv_stride, 8, edge, inner_limit, hev_threshold, true);
            }
            if (info.inner) {
                for (1..4) |k| {
                    complexEdge(view.luma, y_base + 4 * k, 1, y_stride, 16, limit, inner_limit, hev_threshold, false);
                }
                complexEdge(view.chroma_u, uv_base + 4, 1, uv_stride, 8, limit, inner_limit, hev_threshold, false);
                complexEdge(view.chroma_v, uv_base + 4, 1, uv_stride, 8, limit, inner_limit, hev_threshold, false);
            }
            if (has_top) {
                complexEdge(view.luma, y_base, y_step, 1, 16, edge, inner_limit, hev_threshold, true);
                complexEdge(view.chroma_u, uv_base, uv_step, 1, 8, edge, inner_limit, hev_threshold, true);
                complexEdge(view.chroma_v, uv_base, uv_step, 1, 8, edge, inner_limit, hev_threshold, true);
            }
            if (info.inner) {
                for (1..4) |k| {
                    complexEdge(view.luma, y_base + 4 * k * y_stride, y_step, 1, 16, limit, inner_limit, hev_threshold, false);
                }
                complexEdge(view.chroma_u, uv_base + 4 * uv_stride, uv_step, 1, 8, limit, inner_limit, hev_threshold, false);
                complexEdge(view.chroma_v, uv_base + 4 * uv_stride, uv_step, 1, 8, limit, inner_limit, hev_threshold, false);
            }
        },
    }
}

// --- Edge dispatch ----------------------------------------------------------
//
// `across` steps from one side of the edge to the other (it is the index
// delta used for the p[-k]/q[+k] taps); `along` walks the `count` pixels that
// lie on the edge. Both are positive at every call site, but `across` is
// signed because the kernels index negative offsets relative to the edge.

fn simpleEdge(
    plane: []u8,
    base: usize,
    across: i32,
    along: usize,
    count: usize,
    threshold: i32,
) void {
    const threshold2 = 2 * threshold + 1;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const center = base + i * along;
        if (needsFilter(plane, center, across, threshold2)) {
            doFilter2(plane, center, across);
        }
    }
}

fn complexEdge(
    plane: []u8,
    base: usize,
    across: i32,
    along: usize,
    count: usize,
    threshold: i32,
    inner_limit: i32,
    hev_threshold: i32,
    comptime macroblock_edge: bool,
) void {
    const threshold2 = 2 * threshold + 1;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const center = base + i * along;
        if (!needsFilter2(plane, center, across, threshold2, inner_limit)) continue;
        if (hev(plane, center, across, hev_threshold)) {
            doFilter2(plane, center, across);
        } else if (macroblock_edge) {
            doFilter6(plane, center, across);
        } else {
            doFilter4(plane, center, across);
        }
    }
}

// --- Kernels ----------------------------------------------------------------
//
// `center` indexes q0 (the first pixel after the edge); the edge sits between
// p0 = center - across and q0 = center. All arithmetic is i32; the shifts are
// floor divisions (arithmetic right shifts), spelled with @divFloor to make
// the rounding-toward-negative-infinity intent explicit.

fn tap(plane: []const u8, center: usize, across: i32, offset: i32) i32 {
    const signed = @as(i64, @intCast(center)) + @as(i64, offset) * @as(i64, across);
    assert(signed >= 0);
    return plane[@intCast(signed)];
}

fn store(plane: []u8, center: usize, across: i32, offset: i32, value: i32) void {
    const signed = @as(i64, @intCast(center)) + @as(i64, offset) * @as(i64, across);
    assert(signed >= 0);
    plane[@intCast(signed)] = clip255(value);
}

/// Common edge-strength test for the simple filter (RFC 6386 section 15.2).
fn needsFilter(plane: []const u8, center: usize, across: i32, threshold: i32) bool {
    const p1 = tap(plane, center, across, -2);
    const p0 = tap(plane, center, across, -1);
    const q0 = tap(plane, center, across, 0);
    const q1 = tap(plane, center, across, 1);
    return 4 * abs(p0 - q0) + abs(p1 - q1) <= threshold;
}

/// Edge plus interior smoothness test for the normal filter (RFC 15.3).
fn needsFilter2(
    plane: []const u8,
    center: usize,
    across: i32,
    threshold: i32,
    inner_limit: i32,
) bool {
    const p3 = tap(plane, center, across, -4);
    const p2 = tap(plane, center, across, -3);
    const p1 = tap(plane, center, across, -2);
    const p0 = tap(plane, center, across, -1);
    const q0 = tap(plane, center, across, 0);
    const q1 = tap(plane, center, across, 1);
    const q2 = tap(plane, center, across, 2);
    const q3 = tap(plane, center, across, 3);
    if (4 * abs(p0 - q0) + abs(p1 - q1) > threshold) return false;
    return abs(p3 - p2) <= inner_limit and
        abs(p2 - p1) <= inner_limit and
        abs(p1 - p0) <= inner_limit and
        abs(q3 - q2) <= inner_limit and
        abs(q2 - q1) <= inner_limit and
        abs(q1 - q0) <= inner_limit;
}

/// High edge variance test: true selects the 2-tap filter on a normal edge.
fn hev(plane: []const u8, center: usize, across: i32, threshold: i32) bool {
    const p1 = tap(plane, center, across, -2);
    const p0 = tap(plane, center, across, -1);
    const q0 = tap(plane, center, across, 0);
    const q1 = tap(plane, center, across, 1);
    return abs(p1 - p0) > threshold or abs(q1 - q0) > threshold;
}

/// 4 pixels in, 2 out: the simple filter and the high-variance normal case.
fn doFilter2(plane: []u8, center: usize, across: i32) void {
    const p1 = tap(plane, center, across, -2);
    const p0 = tap(plane, center, across, -1);
    const q0 = tap(plane, center, across, 0);
    const q1 = tap(plane, center, across, 1);
    const a = 3 * (q0 - p0) + sclip1(p1 - q1);
    const a1 = sclip2(@divFloor(a + 4, 8));
    const a2 = sclip2(@divFloor(a + 3, 8));
    store(plane, center, across, -1, p0 + a2);
    store(plane, center, across, 0, q0 - a1);
}

/// 4 pixels in, 4 out: the low-variance normal filter on interior edges.
fn doFilter4(plane: []u8, center: usize, across: i32) void {
    const p1 = tap(plane, center, across, -2);
    const p0 = tap(plane, center, across, -1);
    const q0 = tap(plane, center, across, 0);
    const q1 = tap(plane, center, across, 1);
    const a = 3 * (q0 - p0);
    const a1 = sclip2(@divFloor(a + 4, 8));
    const a2 = sclip2(@divFloor(a + 3, 8));
    const a3 = @divFloor(a1 + 1, 2);
    store(plane, center, across, -2, p1 + a3);
    store(plane, center, across, -1, p0 + a2);
    store(plane, center, across, 0, q0 - a1);
    store(plane, center, across, 1, q1 - a3);
}

/// 6 pixels in, 6 out: the low-variance normal filter on macroblock edges.
fn doFilter6(plane: []u8, center: usize, across: i32) void {
    const p2 = tap(plane, center, across, -3);
    const p1 = tap(plane, center, across, -2);
    const p0 = tap(plane, center, across, -1);
    const q0 = tap(plane, center, across, 0);
    const q1 = tap(plane, center, across, 1);
    const q2 = tap(plane, center, across, 2);
    const a = sclip1(3 * (q0 - p0) + sclip1(p1 - q1));
    const a1 = @divFloor(27 * a + 63, 128);
    const a2 = @divFloor(18 * a + 63, 128);
    const a3 = @divFloor(9 * a + 63, 128);
    store(plane, center, across, -3, p2 + a3);
    store(plane, center, across, -2, p1 + a2);
    store(plane, center, across, -1, p0 + a1);
    store(plane, center, across, 0, q0 - a1);
    store(plane, center, across, 1, q1 - a2);
    store(plane, center, across, 2, q2 - a3);
}

fn abs(value: i32) i32 {
    return if (value < 0) -value else value;
}

fn clip255(value: i32) u8 {
    if (value < 0) return 0;
    if (value > 255) return 255;
    return @intCast(value);
}

fn sclip1(value: i32) i32 {
    return std.math.clamp(value, -128, 127);
}

fn sclip2(value: i32) i32 {
    return std.math.clamp(value, -16, 15);
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;

test "filter type follows the frame level and simple flag" {
    var header: frame_header.Header = undefined;
    header.loop_filter = .{
        .simple = false,
        .level = 0,
        .sharpness = 0,
        .delta_enabled = false,
        .ref_frame_deltas = @splat(0),
        .mode_deltas = @splat(0),
    };
    try testing.expectEqual(Type.none, filterType(&header));

    header.loop_filter.level = 10;
    header.loop_filter.simple = true;
    try testing.expectEqual(Type.simple, filterType(&header));

    header.loop_filter.simple = false;
    try testing.expectEqual(Type.complex, filterType(&header));
}

test "strength derivation matches the RFC 15.4 formula" {
    var header: frame_header.Header = undefined;
    header.segmentation = frame_header.Segmentation.disabled;
    header.loop_filter = .{
        .simple = false,
        .level = 26,
        .sharpness = 3,
        .delta_enabled = false,
        .ref_frame_deltas = @splat(0),
        .mode_deltas = @splat(0),
    };

    const strengths = computeStrengths(&header);
    // level 26, sharpness 3: ilevel = 26 >> 1 = 13, capped at 9 - 3 = 6.
    // limit = 2*26 + 6 = 58; hev = 1 (15 <= 26 < 40). Both classes share the
    // base level (no deltas); only `inner` differs.
    const whole = strengths[0][0];
    try testing.expectEqual(@as(i32, 6), whole.inner_limit);
    try testing.expectEqual(@as(i32, 58), whole.limit);
    try testing.expectEqual(@as(i32, 1), whole.hev_threshold);
    try testing.expectEqual(false, whole.inner);
    try testing.expectEqual(true, strengths[0][1].inner);
}

test "strength derivation folds in segment and loop-filter deltas" {
    var segmentation = frame_header.Segmentation.disabled;
    segmentation.enabled = true;
    segmentation.absolute_values = false;
    segmentation.filter_strength_deltas = .{ 4, -40, 0, 0 };

    var header: frame_header.Header = undefined;
    header.segmentation = segmentation;
    header.loop_filter = .{
        .simple = false,
        .level = 40,
        .sharpness = 0,
        .delta_enabled = true,
        .ref_frame_deltas = .{ 2, 0, 0, 0 },
        .mode_deltas = .{ -10, 0, 0, 0 },
    };

    const strengths = computeStrengths(&header);
    // Segment 0, 16x16: 40 + 4 (delta) + 2 (intra ref) = 46 -> hev 2,
    // limit = 2*46 + 46 = 138 (no sharpness, ilevel = level).
    try testing.expectEqual(@as(i32, 138), strengths[0][0].limit);
    try testing.expectEqual(@as(i32, 2), strengths[0][0].hev_threshold);
    // Segment 0, B_PRED also subtracts the mode delta: 46 - 10 = 36 -> hev 1.
    try testing.expectEqual(@as(i32, 36 * 3), strengths[0][1].limit);
    try testing.expectEqual(@as(i32, 1), strengths[0][1].hev_threshold);
    // Segment 1: 40 - 40 + 2 = 2 -> nonzero but tiny; limit = 2*2 + 2 = 6.
    try testing.expectEqual(@as(i32, 6), strengths[1][0].limit);
    // A class whose level clamps to 0 is marked unfiltered.
    segmentation.filter_strength_deltas = .{ 0, 0, 0, -100 };
    header.segmentation = segmentation;
    header.loop_filter.delta_enabled = false;
    const clamped = computeStrengths(&header);
    try testing.expectEqual(@as(i32, 0), clamped[3][0].limit);
}

test "a flat plane is unchanged by every kernel" {
    // NeedsFilter passes on a flat edge (all deltas zero), but the kernels
    // then compute zero adjustments, so the pixels must survive untouched.
    var plane: [16]u8 = @splat(128);
    doFilter2(&plane, 8, 1);
    doFilter4(&plane, 8, 1);
    doFilter6(&plane, 8, 1);
    try testing.expectEqual([_]u8{128} ** 16, plane);
}

test "doFilter2 smooths a single step edge symmetrically" {
    // A clean step 120|136 across the edge. By hand (libwebp DoFilter2):
    // a = 3*(136-120) + sclip1(120-136) = 48 - 16 = 32; a1 = a2 = 32 >> 3 = 4,
    // so p0 -> 124 and q0 -> 132.
    var plane = [_]u8{ 120, 120, 136, 136 };
    doFilter2(&plane, 2, 1);
    try testing.expectEqual([_]u8{ 120, 124, 132, 136 }, plane);
}

test "needsFilter2 rejects edges that exceed the interior limit" {
    // Monotone ramp with step 5: the edge test passes for a generous
    // threshold, but an interior limit below 5 rejects it.
    var plane: [8]u8 = undefined;
    for (&plane, 0..) |*pixel, index| pixel.* = @intCast(100 + index * 5);
    try testing.expect(needsFilter2(&plane, 4, 1, 1000, 5));
    try testing.expect(!needsFilter2(&plane, 4, 1, 1000, 4));
}
