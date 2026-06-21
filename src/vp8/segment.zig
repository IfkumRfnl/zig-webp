//! VP8 lossy encoder segment analysis — step 8b-3b adaptive per-segment quant.
//!
//! Buckets macroblocks into up to four segments by luma complexity and gives
//! each segment its own quantizer, so the encoder can spend bits where they
//! reduce distortion most. This is the encode-side complement to the decoder's
//! per-segment dequant (`quant.segmentFactors`): the plan `analyze` returns is
//! written into the frame header (`frame_header.writeSegmentation`) and the
//! per-macroblock segment id (`modes.encodeKeyFrameModes`), and the encoder
//! reconstructs every macroblock with that segment's factors — so the step 8a
//! self-consistency gate still holds.
//!
//! The assignment mirrors libwebp's intent — a 1-D k-means over a per-macroblock
//! complexity metric — without copying its code or float math: complexity is the
//! summed |AC| of the source luma subblocks, clustering is integer k-means, and
//! the per-segment quantizer spread is a measured constant. Adaptive quant is a
//! quality refinement, never a correctness lever: any segment assignment the
//! header faithfully describes round-trips bit-for-bit, so the only risk this
//! module carries is a worse (not an invalid) frame.

const std = @import("std");
const assert = std.debug.assert;

const color = @import("../color.zig");
const forward_transform = @import("forward_transform.zig");
const frame_header = @import("frame_header.zig");
const modes = @import("modes.zig");
const quant = @import("quant.zig");

pub const segment_count = frame_header.segment_count; // 4
const luma_block = 16;
const coeff_count = 16;

/// Maximum k-means refinement passes (libwebp uses 6). Each pass is one linear
/// scan over the macroblocks, so this caps the analysis cost at a small multiple
/// of one pass.
const max_iterations = 6;

/// Half-width of the per-segment quantizer spread, in quantizer-index steps: the
/// flattest segment is coded `dquant_spread` indices coarser than the frame base
/// and the busiest `dquant_spread` finer, with the middle segments interpolated.
/// Spending bits on busier macroblocks (finer quant) is the SSE-optimal direction
/// — they have the steeper rate-distortion slope — and the opposite, perceptual
/// direction measured worse on raw luma PSNR. The magnitude is deliberately gentle:
/// on the photo corpus the matched-size luma-PSNR gain over uniform quant peaks
/// across spreads 2..5 (≈+0.1 dB) and turns negative by spread 12, where the
/// coarsened segments lose more than the refined ones gain. Tuned by measurement;
/// see the 8b-3b PROGRESS row.
const dquant_spread = 4;

pub const Plan = struct {
    /// When false the caller emits the plain single-quantizer frame and treats
    /// every macroblock as segment 0 (byte-identical to the pre-8b-3b encoder).
    enabled: bool,
    /// Frame-header segmentation block to emit; meaningful only when `enabled`.
    segmentation: frame_header.Segmentation,
};

/// Buckets every macroblock into one of up to four segments by luma complexity
/// and assigns each segment its own quantizer. Writes the per-macroblock segment
/// id (raster order) into `segment_ids` and returns the frame-header segmentation
/// block. `complexity` is caller-provided scratch; both slices are exactly
/// `grid.macroblockCount()` long.
///
/// The plan is returned disabled — and every segment id zeroed — when the frame
/// carries too little variation to benefit: a single complexity cluster, or a
/// spread so small every quantizer delta rounds to zero. The caller then emits
/// the single-quantizer frame unchanged.
pub fn analyze(
    source: *const color.YuvPlanes,
    grid: modes.MacroblockGrid,
    base_quant_index: u8,
    complexity: []i32,
    segment_ids: []u2,
) Plan {
    const mb_count = grid.macroblockCount();
    assert(complexity.len == mb_count);
    assert(segment_ids.len == mb_count);
    assert(base_quant_index <= quant.index_max);

    @memset(segment_ids, 0);
    if (mb_count == 0) return disabled;

    // --- Per-macroblock complexity: summed |AC| of the source luma subblocks.
    const stride = source.luma_stride;
    var row: u32 = 0;
    while (row < grid.rows) : (row += 1) {
        var col: u32 = 0;
        while (col < grid.columns) : (col += 1) {
            complexity[row * grid.columns + col] = macroblockComplexity(
                source.luma,
                stride,
                @as(usize, col) * luma_block,
                @as(usize, row) * luma_block,
            );
        }
    }

    // --- Cluster into <=4 segments by complexity.
    var centers: [segment_count]i64 = undefined;
    const used = assignSegments(complexity, segment_ids, &centers);
    if (used <= 1) {
        @memset(segment_ids, 0);
        return disabled;
    }

    // --- Per-segment quantizer: a delta on the frame base, spread by complexity.
    const span = centers[used - 1] - centers[0];
    if (span <= 0) {
        @memset(segment_ids, 0);
        return disabled;
    }

    var quantizer_deltas = [_]i8{0} ** segment_count;
    var any_nonzero = false;
    for (0..used) |s| {
        // delta_index runs +dquant_spread at the flattest center down to
        // -dquant_spread at the busiest, so the busier a segment the finer its
        // quantizer; the mean stays near the frame base.
        const offset = centers[s] - centers[0];
        const delta_index = dquant_spread - @divTrunc(2 * dquant_spread * offset, span);
        const resolved = std.math.clamp(
            @as(i64, base_quant_index) + delta_index,
            0,
            quant.index_max,
        );
        const delta = resolved - base_quant_index;
        quantizer_deltas[s] = @intCast(delta);
        if (delta != 0) any_nonzero = true;
    }
    if (!any_nonzero) {
        @memset(segment_ids, 0);
        return disabled;
    }

    var counts = [_]u32{0} ** segment_count;
    for (segment_ids) |id| counts[id] += 1;

    var segmentation = frame_header.Segmentation.disabled;
    segmentation.enabled = true;
    segmentation.update_map = true;
    segmentation.absolute_values = false; // deltas on the frame base quantizer
    segmentation.quantizer_deltas = quantizer_deltas;
    segmentation.filter_strength_deltas = @splat(0); // loop filter stays frame-uniform
    segmentation.tree_probabilities = segmentTreeProbabilities(counts);
    return .{ .enabled = true, .segmentation = segmentation };
}

const disabled = Plan{ .enabled = false, .segmentation = .disabled };

/// Summed magnitude of the AC coefficients across a macroblock's sixteen 4x4
/// luma subblocks — a texture/activity proxy. The forward DCT of the raw pixels
/// puts the block mean in coefficient 0 and the detail in 1..15; flat blocks
/// score near zero, busy blocks high. The planes are macroblock-padded, so a
/// full 16x16 always exists.
fn macroblockComplexity(luma: []const u8, stride: usize, mb_x: usize, mb_y: usize) i32 {
    var energy: i64 = 0;
    for (0..luma_block) |sub| {
        const sub_x = (sub % 4) * 4;
        const sub_y = (sub / 4) * 4;
        var block: [coeff_count]i16 = undefined;
        for (0..4) |r| {
            for (0..4) |c| {
                block[r * 4 + c] = luma[(mb_y + sub_y + r) * stride + mb_x + sub_x + c];
            }
        }
        var coeffs: [coeff_count]i16 = undefined;
        forward_transform.forwardDct(&block, &coeffs);
        for (1..coeff_count) |k| energy += @abs(@as(i32, coeffs[k]));
    }
    return @intCast(@min(energy, std.math.maxInt(i32)));
}

/// Partitions the per-macroblock `complexity` values into up to `segment_count`
/// clusters by 1-D k-means, writes the (complexity-ascending) segment id of each
/// macroblock into `segment_ids`, fills `centers_out[0..used]` with the sorted
/// cluster centers, and returns the number of distinct non-empty clusters.
fn assignSegments(
    complexity: []const i32,
    segment_ids: []u2,
    centers_out: *[segment_count]i64,
) usize {
    var min_c: i32 = complexity[0];
    var max_c: i32 = complexity[0];
    for (complexity) |c| {
        min_c = @min(min_c, c);
        max_c = @max(max_c, c);
    }
    if (min_c == max_c) {
        centers_out[0] = min_c;
        return 1;
    }

    const num = segment_count;
    var centers: [segment_count]i64 = undefined;
    for (0..num) |k| {
        centers[k] = @as(i64, min_c) +
            @divTrunc((2 * @as(i64, @intCast(k)) + 1) * (@as(i64, max_c) - min_c), 2 * num);
    }

    var iter: usize = 0;
    while (iter < max_iterations) : (iter += 1) {
        var sums = [_]i64{0} ** segment_count;
        var counts = [_]u64{0} ** segment_count;
        for (complexity) |c| {
            const k = nearestCenter(centers[0..num], c);
            sums[k] += c;
            counts[k] += 1;
        }
        var moved = false;
        for (0..num) |k| {
            if (counts[k] == 0) continue;
            const total: i64 = @intCast(counts[k]);
            const new_center = @divTrunc(sums[k] + @divTrunc(total, 2), total);
            if (new_center != centers[k]) moved = true;
            centers[k] = new_center;
        }
        if (!moved) break;
    }

    // Compact to the distinct non-empty centers, sorted ascending, so segment 0
    // is always the flattest. Distinct clusters can converge to one value; dedup
    // keeps each surviving segment the unique nearest for its own center.
    var final_counts = [_]u64{0} ** segment_count;
    for (complexity) |c| final_counts[nearestCenter(centers[0..num], c)] += 1;

    var live: [segment_count]i64 = undefined;
    var live_n: usize = 0;
    for (0..num) |k| {
        if (final_counts[k] != 0) {
            live[live_n] = centers[k];
            live_n += 1;
        }
    }
    insertionSort(live[0..live_n]);
    var distinct: usize = 0;
    for (0..live_n) |i| {
        if (distinct == 0 or live[i] != live[distinct - 1]) {
            live[distinct] = live[i];
            distinct += 1;
        }
    }
    if (distinct <= 1) {
        centers_out[0] = live[0];
        return 1;
    }

    for (complexity, 0..) |c, i| {
        segment_ids[i] = @intCast(nearestCenter(live[0..distinct], c));
    }
    for (0..distinct) |k| centers_out[k] = live[k];
    return distinct;
}

fn nearestCenter(centers: []const i64, value: i32) usize {
    var best: usize = 0;
    var best_distance = absDiff(centers[0], value);
    for (centers[1..], 1..) |center, k| {
        const distance = absDiff(center, value);
        if (distance < best_distance) {
            best_distance = distance;
            best = k;
        }
    }
    return best;
}

fn absDiff(a: i64, b: i32) i64 {
    return @intCast(@abs(a - @as(i64, b)));
}

fn insertionSort(values: []i64) void {
    for (1..values.len) |i| {
        const value = values[i];
        var j = i;
        while (j > 0 and values[j - 1] > value) : (j -= 1) values[j] = values[j - 1];
        values[j] = value;
    }
}

/// The three segment-map tree probabilities from the realized segment counts,
/// mirroring libwebp's `SetSegmentProbas`/`GetProba`. The `segment_id_tree`
/// reads probability 0 at the root (segments {0,1} vs {2,3}), 1 in the left
/// subtree (0 vs 1), and 2 in the right (2 vs 3).
fn segmentTreeProbabilities(counts: [segment_count]u32) [frame_header.segment_tree_probability_count]u8 {
    return .{
        getProba(counts[0] + counts[1], counts[2] + counts[3]),
        getProba(counts[0], counts[1]),
        getProba(counts[2], counts[3]),
    };
}

/// P(bit == 0) ≈ a / (a + b), scaled to 1..255. With no samples the branch is
/// never coded, so 255 (libwebp's default) is fine; the result is floored at 1
/// so the boolean coder never sees an impossible-symbol probability of 0.
fn getProba(a: u32, b: u32) u8 {
    const total = a + b;
    if (total == 0) return 255;
    const prob = (@as(u64, 255) * a + total / 2) / total;
    return @intCast(std.math.clamp(prob, 1, 255));
}

// --- Tests ------------------------------------------------------------------

test "assignSegments separates two complexity clusters, flattest first" {
    // Eight low-complexity and eight high-complexity macroblocks.
    var complexity: [16]i32 = undefined;
    for (0..8) |i| complexity[i] = @intCast(10 + i);
    for (8..16) |i| complexity[i] = @intCast(1000 + i);

    var segment_ids: [16]u2 = undefined;
    var centers: [segment_count]i64 = undefined;
    const used = assignSegments(&complexity, &segment_ids, &centers);
    try std.testing.expect(used >= 2);

    // The low-complexity block lands in a lower segment id than the high one
    // (ids are complexity-ascending), and centers are sorted.
    try std.testing.expect(segment_ids[0] < segment_ids[15]);
    try std.testing.expect(centers[0] < centers[used - 1]);
    for (0..8) |i| try std.testing.expectEqual(segment_ids[0], segment_ids[i]);
    for (8..16) |i| try std.testing.expectEqual(segment_ids[15], segment_ids[i]);
}

test "assignSegments collapses uniform complexity to one segment" {
    var complexity: [9]i32 = @splat(42);
    var segment_ids: [9]u2 = undefined;
    var centers: [segment_count]i64 = undefined;
    try std.testing.expectEqual(@as(usize, 1), assignSegments(&complexity, &segment_ids, &centers));
}

test "getProba scales counts to a valid probability" {
    try std.testing.expectEqual(@as(u8, 255), getProba(0, 0)); // no samples
    try std.testing.expectEqual(@as(u8, 128), getProba(1, 1)); // even split
    try std.testing.expect(getProba(0, 100) >= 1); // never an impossible 0
    try std.testing.expect(getProba(100, 0) == 255); // all on the 0 branch
}

test "analyze adapts quantizers for mixed content and disables for flat" {
    const gpa = std.testing.allocator;
    const width = 64;
    const height = 32;
    const grid = modes.MacroblockGrid.init(.{ .width = width, .height = height });
    const mb_count = grid.macroblockCount();

    const complexity = try gpa.alloc(i32, mb_count);
    defer gpa.free(complexity);
    const segment_ids = try gpa.alloc(u2, mb_count);
    defer gpa.free(segment_ids);

    // Flat left half, high-frequency right half.
    const argb = try gpa.alloc(u32, width * height);
    defer gpa.free(argb);
    for (0..height) |y| {
        for (0..width) |x| {
            const v: u32 = if (x < width / 2) 0x40 else @intCast(((x *% 53) ^ (y *% 97)) & 0xff);
            argb[y * width + x] = 0xff00_0000 | (v << 16) | (v << 8) | v;
        }
    }
    var mixed = try color.rgbaToYuv420Alloc(gpa, argb, width, height);
    defer mixed.deinit(gpa);

    const base = quant.baseQuantIndexForQuality(75);
    const plan = analyze(&mixed, grid, base, complexity, segment_ids);
    try std.testing.expect(plan.enabled);
    try std.testing.expect(plan.segmentation.enabled);
    try std.testing.expect(plan.segmentation.update_map);
    try std.testing.expect(!plan.segmentation.absolute_values);
    // The flat-half and busy-half macroblocks must land in different segments.
    var distinct = std.AutoHashMap(u2, void).init(gpa);
    defer distinct.deinit();
    for (segment_ids) |id| try distinct.put(id, {});
    try std.testing.expect(distinct.count() >= 2);
    // Filter deltas stay zero so the in-loop filter is unchanged by segmentation.
    try std.testing.expectEqual([segment_count]i8{ 0, 0, 0, 0 }, plan.segmentation.filter_strength_deltas);

    // A uniform field carries no variation, so segmentation is left off.
    @memset(argb, 0xff20_6080);
    var flat = try color.rgbaToYuv420Alloc(gpa, argb, width, height);
    defer flat.deinit(gpa);
    const flat_plan = analyze(&flat, grid, base, complexity, segment_ids);
    try std.testing.expect(!flat_plan.enabled);
    for (segment_ids) |id| try std.testing.expectEqual(@as(u2, 0), id);
}
