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
    const y_base = @as(usize, mb_y) * 16 * y_stride + @as(usize, mb_x) * 16;

    switch (filter_type) {
        .none => unreachable,
        .simple => {
            // Vertical edges stay scalar (strided edge pixels). Horizontal
            // edges use contiguous-lane @Vector loads (along == 1).
            if (has_left) {
                simpleEdge(view.luma, y_base, 1, y_stride, 16, edge);
            }
            if (info.inner) {
                for (1..4) |k| {
                    simpleEdge(view.luma, y_base + 4 * k, 1, y_stride, 16, limit);
                }
            }
            if (has_top) {
                simpleEdgeH(16, view.luma, y_base, y_stride, edge);
            }
            if (info.inner) {
                for (1..4) |k| {
                    simpleEdgeH(16, view.luma, y_base + 4 * k * y_stride, y_stride, limit);
                }
            }
        },
        .complex => {
            const uv_stride = view.chroma_stride;
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
                complexEdgeH(16, view.luma, y_base, y_stride, edge, inner_limit, hev_threshold, true);
                complexEdgeH(8, view.chroma_u, uv_base, uv_stride, edge, inner_limit, hev_threshold, true);
                complexEdgeH(8, view.chroma_v, uv_base, uv_stride, edge, inner_limit, hev_threshold, true);
            }
            if (info.inner) {
                for (1..4) |k| {
                    complexEdgeH(16, view.luma, y_base + 4 * k * y_stride, y_stride, limit, inner_limit, hev_threshold, false);
                }
                complexEdgeH(8, view.chroma_u, uv_base + 4 * uv_stride, uv_stride, limit, inner_limit, hev_threshold, false);
                complexEdgeH(8, view.chroma_v, uv_base + 4 * uv_stride, uv_stride, limit, inner_limit, hev_threshold, false);
            }
        },
    }
}

/// Scalar-only twin of `filterMacroblock` for equivalence tests. Mirrors the
/// production edge order but always calls the scalar edge loops — never the
/// horizontal SIMD entry points. Not a production "disable SIMD" knob.
fn filterMacroblockScalar(
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

fn applyFrameScalar(
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
            info.inner = info.inner or has_nonzero[index];
            filterMacroblockScalar(view, filter_type, &info, mb_x, mb_y);
        }
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

// --- Horizontal SIMD (contiguous lanes, along == 1) -------------------------
//
// Each tap row p3..q3 is one contiguous Lanes-byte load at center+k*stride.
// Vertical edges (across == 1, along == stride) stay on the scalar path:
// gather/transpose of Lanes eight-byte tap groups is not clearly bounded
// enough to keep alongside the horizontal kernels without extra complexity.
//
// Plane padding is macroblock-aligned with no extra border (decoder
// FrameAllocationPlan). has_top/has_left keep 4-tap reads inside the plane;
// horizontal vector loads of Lanes bytes fit within the current macroblock
// column (16 luma / 8 chroma). Do not grow padding.
//
// i16 headroom: taps 0..255; a = 3*(q0-p0)+sclip1(p1-q1) ∈ [-893, 892];
// doFilter6 intermediate 27*a_clamped+63 with a_clamped ∈ [-128,127] ∈
// [-3393, 3492]. All fit signed 16-bit.

comptime {
    assert(893 < 32768);
    assert(3492 < 32768);
}

fn simpleEdgeH(comptime Lanes: usize, plane: []u8, base: usize, stride: usize, threshold: i32) void {
    comptime assert(Lanes == 8 or Lanes == 16);
    const threshold2: i16 = @intCast(2 * threshold + 1);

    const p1 = loadRow(Lanes, plane, base, stride, -2);
    const p0 = loadRow(Lanes, plane, base, stride, -1);
    const q0 = loadRow(Lanes, plane, base, stride, 0);
    const q1 = loadRow(Lanes, plane, base, stride, 1);

    const needs = needsFilterVec(Lanes, p1, p0, q0, q1, threshold2);
    const f2 = filter2Vec(Lanes, p1, p0, q0, q1);
    storeRow(Lanes, plane, base, stride, -1, @select(i16, needs, f2.p0, p0));
    storeRow(Lanes, plane, base, stride, 0, @select(i16, needs, f2.q0, q0));
}

fn complexEdgeH(
    comptime Lanes: usize,
    plane: []u8,
    base: usize,
    stride: usize,
    threshold: i32,
    inner_limit: i32,
    hev_threshold: i32,
    comptime macroblock_edge: bool,
) void {
    comptime assert(Lanes == 8 or Lanes == 16);
    const threshold2: i16 = @intCast(2 * threshold + 1);
    const inner: i16 = @intCast(inner_limit);
    const hev_thr: i16 = @intCast(hev_threshold);

    const p3 = loadRow(Lanes, plane, base, stride, -4);
    const p2 = loadRow(Lanes, plane, base, stride, -3);
    const p1 = loadRow(Lanes, plane, base, stride, -2);
    const p0 = loadRow(Lanes, plane, base, stride, -1);
    const q0 = loadRow(Lanes, plane, base, stride, 0);
    const q1 = loadRow(Lanes, plane, base, stride, 1);
    const q2 = loadRow(Lanes, plane, base, stride, 2);
    const q3 = loadRow(Lanes, plane, base, stride, 3);

    const needs2 = needsFilter2Vec(Lanes, p3, p2, p1, p0, q0, q1, q2, q3, threshold2, inner);
    const hev_mask = hevVec(Lanes, p1, p0, q0, q1, hev_thr);
    const f2 = filter2Vec(Lanes, p1, p0, q0, q1);

    if (macroblock_edge) {
        const f6 = filter6Vec(Lanes, p2, p1, p0, q0, q1, q2);
        storeRow(Lanes, plane, base, stride, -3, @select(i16, needs2, @select(i16, hev_mask, p2, f6.p2), p2));
        storeRow(Lanes, plane, base, stride, -2, @select(i16, needs2, @select(i16, hev_mask, p1, f6.p1), p1));
        storeRow(Lanes, plane, base, stride, -1, @select(i16, needs2, @select(i16, hev_mask, f2.p0, f6.p0), p0));
        storeRow(Lanes, plane, base, stride, 0, @select(i16, needs2, @select(i16, hev_mask, f2.q0, f6.q0), q0));
        storeRow(Lanes, plane, base, stride, 1, @select(i16, needs2, @select(i16, hev_mask, q1, f6.q1), q1));
        storeRow(Lanes, plane, base, stride, 2, @select(i16, needs2, @select(i16, hev_mask, q2, f6.q2), q2));
    } else {
        const f4 = filter4Vec(Lanes, p1, p0, q0, q1);
        storeRow(Lanes, plane, base, stride, -2, @select(i16, needs2, @select(i16, hev_mask, p1, f4.p1), p1));
        storeRow(Lanes, plane, base, stride, -1, @select(i16, needs2, @select(i16, hev_mask, f2.p0, f4.p0), p0));
        storeRow(Lanes, plane, base, stride, 0, @select(i16, needs2, @select(i16, hev_mask, f2.q0, f4.q0), q0));
        storeRow(Lanes, plane, base, stride, 1, @select(i16, needs2, @select(i16, hev_mask, q1, f4.q1), q1));
    }
}

fn loadRow(comptime Lanes: usize, plane: []const u8, base: usize, stride: usize, offset: i32) @Vector(Lanes, i16) {
    const signed = @as(i64, @intCast(base)) + @as(i64, offset) * @as(i64, @intCast(stride));
    assert(signed >= 0);
    const idx: usize = @intCast(signed);
    assert(idx + Lanes <= plane.len);
    const bytes: @Vector(Lanes, u8) = plane[idx..][0..Lanes].*;
    return @intCast(bytes);
}

fn storeRow(comptime Lanes: usize, plane: []u8, base: usize, stride: usize, offset: i32, values: @Vector(Lanes, i16)) void {
    const signed = @as(i64, @intCast(base)) + @as(i64, offset) * @as(i64, @intCast(stride));
    assert(signed >= 0);
    const idx: usize = @intCast(signed);
    assert(idx + Lanes <= plane.len);
    const clipped = clip255Vec(Lanes, values);
    const bytes: @Vector(Lanes, u8) = @intCast(clipped);
    plane[idx..][0..Lanes].* = bytes;
}

fn andBool(comptime Lanes: usize, a: @Vector(Lanes, bool), b: @Vector(Lanes, bool)) @Vector(Lanes, bool) {
    return @select(bool, a, b, @as(@Vector(Lanes, bool), @splat(false)));
}

fn orBool(comptime Lanes: usize, a: @Vector(Lanes, bool), b: @Vector(Lanes, bool)) @Vector(Lanes, bool) {
    return @select(bool, a, @as(@Vector(Lanes, bool), @splat(true)), b);
}

fn absVec(comptime Lanes: usize, value: @Vector(Lanes, i16)) @Vector(Lanes, i16) {
    // @abs on signed vectors yields unsigned lanes in Zig 0.16; keep i16 to
    // match the scalar `abs` helper used by the reference kernels.
    const zero: @Vector(Lanes, i16) = @splat(0);
    return @select(i16, value < zero, -value, value);
}

fn needsFilterVec(
    comptime Lanes: usize,
    p1: @Vector(Lanes, i16),
    p0: @Vector(Lanes, i16),
    q0: @Vector(Lanes, i16),
    q1: @Vector(Lanes, i16),
    threshold: i16,
) @Vector(Lanes, bool) {
    const thr: @Vector(Lanes, i16) = @splat(threshold);
    const four: @Vector(Lanes, i16) = @splat(4);
    return four * absVec(Lanes, p0 - q0) + absVec(Lanes, p1 - q1) <= thr;
}

fn needsFilter2Vec(
    comptime Lanes: usize,
    p3: @Vector(Lanes, i16),
    p2: @Vector(Lanes, i16),
    p1: @Vector(Lanes, i16),
    p0: @Vector(Lanes, i16),
    q0: @Vector(Lanes, i16),
    q1: @Vector(Lanes, i16),
    q2: @Vector(Lanes, i16),
    q3: @Vector(Lanes, i16),
    threshold: i16,
    inner_limit: i16,
) @Vector(Lanes, bool) {
    const thr: @Vector(Lanes, i16) = @splat(threshold);
    const lim: @Vector(Lanes, i16) = @splat(inner_limit);
    const four: @Vector(Lanes, i16) = @splat(4);
    const edge_ok = four * absVec(Lanes, p0 - q0) + absVec(Lanes, p1 - q1) <= thr;
    const interior = andBool(
        Lanes,
        absVec(Lanes, p3 - p2) <= lim,
        andBool(
            Lanes,
            absVec(Lanes, p2 - p1) <= lim,
            andBool(
                Lanes,
                absVec(Lanes, p1 - p0) <= lim,
                andBool(
                    Lanes,
                    absVec(Lanes, q3 - q2) <= lim,
                    andBool(Lanes, absVec(Lanes, q2 - q1) <= lim, absVec(Lanes, q1 - q0) <= lim),
                ),
            ),
        ),
    );
    return andBool(Lanes, edge_ok, interior);
}

fn hevVec(
    comptime Lanes: usize,
    p1: @Vector(Lanes, i16),
    p0: @Vector(Lanes, i16),
    q0: @Vector(Lanes, i16),
    q1: @Vector(Lanes, i16),
    threshold: i16,
) @Vector(Lanes, bool) {
    const thr: @Vector(Lanes, i16) = @splat(threshold);
    return orBool(Lanes, absVec(Lanes, p1 - p0) > thr, absVec(Lanes, q1 - q0) > thr);
}

fn filter2Vec(
    comptime Lanes: usize,
    p1: @Vector(Lanes, i16),
    p0: @Vector(Lanes, i16),
    q0: @Vector(Lanes, i16),
    q1: @Vector(Lanes, i16),
) struct { p0: @Vector(Lanes, i16), q0: @Vector(Lanes, i16) } {
    const Vec = @Vector(Lanes, i16);
    const a = @as(Vec, @splat(3)) * (q0 - p0) + sclip1Vec(Lanes, p1 - q1);
    const a1 = sclip2Vec(Lanes, @divFloor(a + @as(Vec, @splat(4)), @as(Vec, @splat(8))));
    const a2 = sclip2Vec(Lanes, @divFloor(a + @as(Vec, @splat(3)), @as(Vec, @splat(8))));
    return .{ .p0 = p0 + a2, .q0 = q0 - a1 };
}

fn filter4Vec(
    comptime Lanes: usize,
    p1: @Vector(Lanes, i16),
    p0: @Vector(Lanes, i16),
    q0: @Vector(Lanes, i16),
    q1: @Vector(Lanes, i16),
) struct { p1: @Vector(Lanes, i16), p0: @Vector(Lanes, i16), q0: @Vector(Lanes, i16), q1: @Vector(Lanes, i16) } {
    const Vec = @Vector(Lanes, i16);
    const a = @as(Vec, @splat(3)) * (q0 - p0);
    const a1 = sclip2Vec(Lanes, @divFloor(a + @as(Vec, @splat(4)), @as(Vec, @splat(8))));
    const a2 = sclip2Vec(Lanes, @divFloor(a + @as(Vec, @splat(3)), @as(Vec, @splat(8))));
    const a3 = @divFloor(a1 + @as(Vec, @splat(1)), @as(Vec, @splat(2)));
    return .{ .p1 = p1 + a3, .p0 = p0 + a2, .q0 = q0 - a1, .q1 = q1 - a3 };
}

fn filter6Vec(
    comptime Lanes: usize,
    p2: @Vector(Lanes, i16),
    p1: @Vector(Lanes, i16),
    p0: @Vector(Lanes, i16),
    q0: @Vector(Lanes, i16),
    q1: @Vector(Lanes, i16),
    q2: @Vector(Lanes, i16),
) struct {
    p2: @Vector(Lanes, i16),
    p1: @Vector(Lanes, i16),
    p0: @Vector(Lanes, i16),
    q0: @Vector(Lanes, i16),
    q1: @Vector(Lanes, i16),
    q2: @Vector(Lanes, i16),
} {
    const Vec = @Vector(Lanes, i16);
    const a = sclip1Vec(Lanes, @as(Vec, @splat(3)) * (q0 - p0) + sclip1Vec(Lanes, p1 - q1));
    const sixty_three: Vec = @splat(63);
    const one_twenty_eight: Vec = @splat(128);
    const a1 = @divFloor(@as(Vec, @splat(27)) * a + sixty_three, one_twenty_eight);
    const a2 = @divFloor(@as(Vec, @splat(18)) * a + sixty_three, one_twenty_eight);
    const a3 = @divFloor(@as(Vec, @splat(9)) * a + sixty_three, one_twenty_eight);
    return .{
        .p2 = p2 + a3,
        .p1 = p1 + a2,
        .p0 = p0 + a1,
        .q0 = q0 - a1,
        .q1 = q1 - a2,
        .q2 = q2 - a3,
    };
}

fn sclip1Vec(comptime Lanes: usize, value: @Vector(Lanes, i16)) @Vector(Lanes, i16) {
    return @min(@max(value, @as(@Vector(Lanes, i16), @splat(-128))), @as(@Vector(Lanes, i16), @splat(127)));
}

fn sclip2Vec(comptime Lanes: usize, value: @Vector(Lanes, i16)) @Vector(Lanes, i16) {
    return @min(@max(value, @as(@Vector(Lanes, i16), @splat(-16))), @as(@Vector(Lanes, i16), @splat(15)));
}

fn clip255Vec(comptime Lanes: usize, value: @Vector(Lanes, i16)) @Vector(Lanes, i16) {
    return @min(@max(value, @as(@Vector(Lanes, i16), @splat(0))), @as(@Vector(Lanes, i16), @splat(255)));
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

fn fillAsymmetricPlane(plane: []u8, stride: usize, rows: usize, cols: usize, seed: u32) void {
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        var x: usize = 0;
        while (x < cols) : (x += 1) {
            // Asymmetric in x versus y so a mistaken transpose still fails
            // even when both axes share similar statistics.
            // Vertical neighbor delta is (91 + 13*x) mod 256; over luma x in
            // 0..31 the minimum absolute delta is 4, so hev_threshold in
            // {0,1,2} is always exceeded — this fill exercises the HEV/filter2
            // branch, not filter4/filter6.
            const mixed = seed +% @as(u32, @intCast(x)) *% 37 +% @as(u32, @intCast(y)) *% 91 +% @as(u32, @intCast(x * y)) *% 13;
            plane[y * stride + x] = @truncate(mixed);
        }
    }
}

/// Gentle vertical ramp used to reach the !hev path (filter4/filter6).
/// `row_delta` is the exact |p[y+1]-p[y]| (no wrap for the small frames under
/// test); keep it <= hev_threshold so complex edges select the wide filters.
fn fillSmoothRampPlane(plane: []u8, stride: usize, rows: usize, cols: usize, seed: u32, row_delta: u8) void {
    var y: usize = 0;
    while (y < rows) : (y += 1) {
        var x: usize = 0;
        while (x < cols) : (x += 1) {
            // Bound the base so base + y*row_delta stays inside 0..255 for the
            // macroblock-padded frames the equivalence tests allocate (≤32 rows).
            const base = (seed +% @as(u32, @intCast(x)) *% 3) % 200;
            const value = base + @as(u32, @intCast(y)) * row_delta;
            assert(value <= 255);
            plane[y * stride + x] = @intCast(value);
        }
    }
}

fn blankMacroblock() modes.Macroblock {
    return .{
        .segment_id = 0,
        .skip = false,
        .luma_mode = .dc,
        .chroma_mode = .dc,
        .subblock_modes = @splat(.dc),
    };
}

fn strengthsFor(level: u8, sharpness: u8) Strengths {
    var header: frame_header.Header = undefined;
    header.segmentation = frame_header.Segmentation.disabled;
    header.loop_filter = .{
        .simple = false,
        .level = level,
        .sharpness = sharpness,
        .delta_enabled = false,
        .ref_frame_deltas = @splat(0),
        .mode_deltas = @splat(0),
    };
    return computeStrengths(&header);
}

fn expectPlanesEqual(a: []const u8, b: []const u8) !void {
    try testing.expectEqual(a.len, b.len);
    try testing.expectEqualSlices(u8, a, b);
}

const EquivalenceFill = enum { asymmetric, smooth_ramp };

fn runEquivalenceCase(
    columns: u32,
    rows: u32,
    filter_type: Type,
    level: u8,
    sharpness: u8,
    inner: bool,
    seed: u32,
) !void {
    try runEquivalenceCaseFill(columns, rows, filter_type, level, sharpness, inner, seed, .asymmetric);
}

fn runEquivalenceCaseFill(
    columns: u32,
    rows: u32,
    filter_type: Type,
    level: u8,
    sharpness: u8,
    inner: bool,
    seed: u32,
    fill: EquivalenceFill,
) !void {
    const y_stride: usize = columns * 16;
    const uv_stride: usize = columns * 8;
    const y_rows: usize = rows * 16;
    const uv_rows: usize = rows * 8;
    const y_len = y_stride * y_rows;
    const uv_len = uv_stride * uv_rows;

    const luma_s = try testing.allocator.alloc(u8, y_len);
    defer testing.allocator.free(luma_s);
    const luma_v = try testing.allocator.alloc(u8, y_len);
    defer testing.allocator.free(luma_v);
    const u_s = try testing.allocator.alloc(u8, uv_len);
    defer testing.allocator.free(u_s);
    const u_v = try testing.allocator.alloc(u8, uv_len);
    defer testing.allocator.free(u_v);
    const v_s = try testing.allocator.alloc(u8, uv_len);
    defer testing.allocator.free(v_s);
    const v_v = try testing.allocator.alloc(u8, uv_len);
    defer testing.allocator.free(v_v);

    switch (fill) {
        .asymmetric => {
            fillAsymmetricPlane(luma_s, y_stride, y_rows, y_stride, seed);
            fillAsymmetricPlane(u_s, uv_stride, uv_rows, uv_stride, seed ^ 0xa5a5a5a5);
            fillAsymmetricPlane(v_s, uv_stride, uv_rows, uv_stride, seed ^ 0x5a5a5a5a);
        },
        .smooth_ramp => {
            // row_delta 1 keeps |p1-p0|==1 <= hev_threshold for levels ≥15.
            fillSmoothRampPlane(luma_s, y_stride, y_rows, y_stride, seed, 1);
            fillSmoothRampPlane(u_s, uv_stride, uv_rows, uv_stride, seed ^ 0xa5a5a5a5, 1);
            fillSmoothRampPlane(v_s, uv_stride, uv_rows, uv_stride, seed ^ 0x5a5a5a5a, 1);
        },
    }
    @memcpy(luma_v, luma_s);
    @memcpy(u_v, u_s);
    @memcpy(v_v, v_s);

    const mb_count = columns * rows;
    const macroblocks = try testing.allocator.alloc(modes.Macroblock, mb_count);
    defer testing.allocator.free(macroblocks);
    const has_nonzero = try testing.allocator.alloc(bool, mb_count);
    defer testing.allocator.free(has_nonzero);

    for (macroblocks, has_nonzero) |*mb, *nz| {
        mb.* = blankMacroblock();
        if (inner) {
            // B_PRED forces inner edges via resolveInfo; nonzero residue also
            // ORs the per-MB inner flag in applyFrame.
            mb.luma_mode = .subblocks;
            nz.* = true;
        } else {
            nz.* = false;
        }
    }

    const grid: modes.MacroblockGrid = .{ .columns = columns, .rows = rows };
    const strengths = strengthsFor(level, sharpness);

    applyFrameScalar(.{
        .luma = luma_s,
        .chroma_u = u_s,
        .chroma_v = v_s,
        .luma_stride = y_stride,
        .chroma_stride = uv_stride,
    }, grid, macroblocks, has_nonzero, &strengths, filter_type);

    applyFrame(.{
        .luma = luma_v,
        .chroma_u = u_v,
        .chroma_v = v_v,
        .luma_stride = y_stride,
        .chroma_stride = uv_stride,
    }, grid, macroblocks, has_nonzero, &strengths, filter_type);

    try expectPlanesEqual(luma_s, luma_v);
    try expectPlanesEqual(u_s, u_v);
    try expectPlanesEqual(v_s, v_v);
}

test "SIMD horizontal edges match scalar on randomized asymmetric frames" {
    const levels = [_]u8{ 10, 25, 63 };
    const sharpnesses = [_]u8{ 0, 4, 7 };
    const types = [_]Type{ .simple, .complex };
    var seed: u32 = 0x0246_8ace;

    // 2x2 exercises left/top neighbors plus inner macroblock edges.
    for (types) |filter_type| {
        for (levels) |level| {
            for (sharpnesses) |sharpness| {
                for ([_]bool{ false, true }) |inner| {
                    try runEquivalenceCase(2, 2, filter_type, level, sharpness, inner, seed);
                    seed +%= 0x9e3779b9;
                }
            }
        }
    }
}

test "SIMD horizontal edges honor boundary macroblock guards" {
    // 1x1: no left/top neighbors — only possible edges are inner ones.
    // 2x1: left neighbor on the second MB, still no top neighbor.
    // 1x2: top neighbor on the second row, still no left neighbor.
    const levels = [_]u8{ 10, 25, 63 };
    const sharpnesses = [_]u8{ 0, 4, 7 };
    var seed: u32 = 0x1357_9bdf;

    for ([_]Type{ .simple, .complex }) |filter_type| {
        for (levels) |level| {
            for (sharpnesses) |sharpness| {
                for ([_]bool{ false, true }) |inner| {
                    try runEquivalenceCase(1, 1, filter_type, level, sharpness, inner, seed);
                    seed +%= 0x7f4a7c15;
                    try runEquivalenceCase(2, 1, filter_type, level, sharpness, inner, seed);
                    seed +%= 0x9e3779b9;
                    try runEquivalenceCase(1, 2, filter_type, level, sharpness, inner, seed);
                    seed +%= 0x6a09e667;
                }
            }
        }
    }
}

test "SIMD horizontal edges match scalar on smooth ramps (low HEV)" {
    // Asymmetric fill always exceeds hev_threshold at the tested levels, so it
    // never selects filter4Vec/filter6Vec. A unit vertical ramp keeps hev false
    // while needsFilter2 still passes at high strength — defending those kernels.
    const levels = [_]u8{ 25, 40, 63 };
    const sharpnesses = [_]u8{ 0, 4, 7 };
    var seed: u32 = 0x0f1e_2d3c;

    for (levels) |level| {
        for (sharpnesses) |sharpness| {
            for ([_]bool{ false, true }) |inner| {
                try runEquivalenceCaseFill(2, 2, .complex, level, sharpness, inner, seed, .smooth_ramp);
                seed +%= 0x9e3779b9;
                // Top-only grid: macroblock-edge filter6 without a left edge.
                try runEquivalenceCaseFill(1, 2, .complex, level, sharpness, inner, seed, .smooth_ramp);
                seed +%= 0x7f4a7c15;
            }
        }
    }
}
