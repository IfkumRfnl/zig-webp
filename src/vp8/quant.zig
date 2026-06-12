//! VP8 dequantization factors (RFC 6386 sections 9.6 and 14.1).
//!
//! Resolves the frame-level quantizer indices and per-segment adjustments
//! into the six dequantization factors each macroblock multiplies into its
//! decoded coefficients. The lookup tables are transcribed from RFC 6386
//! section 14.1 and cross-checked value-for-value against
//! `references/libwebp` (`quant_dec.c`) and `references/ffmpeg`
//! (`vp8data.h`).

const std = @import("std");
const assert = std.debug.assert;

const frame_header = @import("frame_header.zig");

pub const index_max = 127;
pub const uv_dc_factor_max = 132;
pub const y2_ac_factor_min = 8;

/// RFC 6386 section 14.1 dc_qlookup.
pub const dc_lookup = [index_max + 1]u16{
    4,   5,   6,   7,   8,   9,   10,  10,  11,  12,  13,  14,  15,  16,
    17,  17,  18,  19,  20,  20,  21,  21,  22,  22,  23,  23,  24,  25,
    25,  26,  27,  28,  29,  30,  31,  32,  33,  34,  35,  36,  37,  37,
    38,  39,  40,  41,  42,  43,  44,  45,  46,  46,  47,  48,  49,  50,
    51,  52,  53,  54,  55,  56,  57,  58,  59,  60,  61,  62,  63,  64,
    65,  66,  67,  68,  69,  70,  71,  72,  73,  74,  75,  76,  76,  77,
    78,  79,  80,  81,  82,  83,  84,  85,  86,  87,  88,  89,  91,  93,
    95,  96,  98,  100, 101, 102, 104, 106, 108, 110, 112, 114, 116, 118,
    122, 124, 126, 128, 130, 132, 134, 136, 138, 140, 143, 145, 148, 151,
    154, 157,
};

/// RFC 6386 section 14.1 ac_qlookup.
pub const ac_lookup = [index_max + 1]u16{
    4,   5,   6,   7,   8,   9,   10,  11,  12,  13,  14,  15,  16,  17,
    18,  19,  20,  21,  22,  23,  24,  25,  26,  27,  28,  29,  30,  31,
    32,  33,  34,  35,  36,  37,  38,  39,  40,  41,  42,  43,  44,  45,
    46,  47,  48,  49,  50,  51,  52,  53,  54,  55,  56,  57,  58,  60,
    62,  64,  66,  68,  70,  72,  74,  76,  78,  80,  82,  84,  86,  88,
    90,  92,  94,  96,  98,  100, 102, 104, 106, 108, 110, 112, 114, 116,
    119, 122, 125, 128, 131, 134, 137, 140, 143, 146, 149, 152, 155, 158,
    161, 164, 167, 170, 173, 177, 181, 185, 189, 193, 197, 201, 205, 209,
    213, 217, 221, 225, 229, 234, 239, 245, 249, 254, 259, 264, 269, 274,
    279, 284,
};

comptime {
    assert(dc_lookup[0] == 4);
    assert(dc_lookup[117] == 132);
    assert(dc_lookup[index_max] == 157);
    assert(ac_lookup[0] == 4);
    assert(ac_lookup[index_max] == 284);

    // Both tables are nondecreasing; the uv_dc clamp below relies on it.
    for (1..index_max + 1) |index| {
        assert(dc_lookup[index] >= dc_lookup[index - 1]);
        assert(ac_lookup[index] >= ac_lookup[index - 1]);
    }

    // libwebp computes the y2_ac factor as (x * 101581) >> 16 while the RFC
    // reference decoder uses x * 155 / 100; they agree on every table value.
    for (ac_lookup) |value| {
        assert(value * 155 / 100 == (@as(u32, value) * 101581) >> 16);
    }
}

/// The six dequantization factors of one segment. Each multiplies the
/// coefficient at position 0 (DC) or positions 1..15 (AC) of the named
/// plane; Y2 factors apply to the second-order Walsh-Hadamard block.
pub const Factors = struct {
    y1_dc: u16,
    y1_ac: u16,
    y2_dc: u16,
    y2_ac: u16,
    uv_dc: u16,
    uv_ac: u16,
};

/// Resolves the dequantization factors for all four segments from the frame
/// header. When segmentation is disabled every segment carries the
/// frame-level factors, so callers can always index by segment id.
pub fn segmentFactors(header: *const frame_header.Header) [frame_header.segment_count]Factors {
    var factors: [frame_header.segment_count]Factors = undefined;
    for (&factors, 0..) |*segment_factors, segment_index| {
        const base_index = segmentQuantizerIndex(
            &header.segmentation,
            header.quant_indices.y_ac_index,
            segment_index,
        );
        segment_factors.* = resolveFactors(&header.quant_indices, base_index);
    }
    return factors;
}

fn segmentQuantizerIndex(
    segmentation: *const frame_header.Segmentation,
    y_ac_index: u8,
    segment_index: usize,
) i32 {
    assert(segment_index < frame_header.segment_count);
    assert(y_ac_index <= index_max);

    if (!segmentation.enabled) return y_ac_index;

    const delta: i32 = segmentation.quantizer_deltas[segment_index];
    if (segmentation.absolute_values) return delta;
    return @as(i32, y_ac_index) + delta;
}

fn resolveFactors(quant_indices: *const frame_header.QuantIndices, base_index: i32) Factors {
    const y2_ac_scaled =
        @as(u32, lookupAc(base_index + quant_indices.y2_ac_delta)) * 155 / 100;

    return .{
        .y1_dc = lookupDc(base_index + quant_indices.y_dc_delta),
        .y1_ac = lookupAc(base_index),
        .y2_dc = lookupDc(base_index + quant_indices.y2_dc_delta) * 2,
        .y2_ac = @intCast(@max(y2_ac_scaled, y2_ac_factor_min)),
        .uv_dc = @min(lookupDc(base_index + quant_indices.uv_dc_delta), uv_dc_factor_max),
        .uv_ac = lookupAc(base_index + quant_indices.uv_ac_delta),
    };
}

fn lookupDc(index: i32) u16 {
    return dc_lookup[clampIndex(index)];
}

fn lookupAc(index: i32) u16 {
    return ac_lookup[clampIndex(index)];
}

fn clampIndex(index: i32) usize {
    return @intCast(std.math.clamp(index, 0, index_max));
}

// --- Tests -------------------------------------------------------------

fn testHeader(
    quant_indices: frame_header.QuantIndices,
    segmentation: frame_header.Segmentation,
) frame_header.Header {
    const token_probs = @import("token_probs.zig");
    return .{
        .tag = .{ .version = 0, .first_partition_size = 0 },
        .picture = .{
            .dimensions = .{ .width = 16, .height = 16 },
            .width_scale = 0,
            .height_scale = 0,
        },
        .color_space = 0,
        .clamping_type = 0,
        .segmentation = segmentation,
        .loop_filter = .{
            .simple = false,
            .level = 0,
            .sharpness = 0,
            .delta_enabled = false,
            .ref_frame_deltas = @splat(0),
            .mode_deltas = @splat(0),
        },
        .quant_indices = quant_indices,
        .refresh_entropy_probs = true,
        .coefficient_probabilities = token_probs.default_probabilities,
        .skip_enabled = false,
        .skip_probability = 0,
    };
}

const zero_deltas = frame_header.QuantIndices{
    .y_ac_index = 0,
    .y_dc_delta = 0,
    .y2_dc_delta = 0,
    .y2_ac_delta = 0,
    .uv_dc_delta = 0,
    .uv_ac_delta = 0,
};

test "resolves frame-level factors without segmentation" {
    var quant_indices = zero_deltas;
    quant_indices.y_ac_index = 64;
    quant_indices.y_dc_delta = 4;
    quant_indices.y2_dc_delta = -2;
    quant_indices.y2_ac_delta = 3;
    quant_indices.uv_dc_delta = -4;
    quant_indices.uv_ac_delta = 2;
    const header = testHeader(quant_indices, frame_header.Segmentation.disabled);

    const factors = segmentFactors(&header);

    const expected = Factors{
        .y1_dc = dc_lookup[68],
        .y1_ac = ac_lookup[64],
        .y2_dc = dc_lookup[62] * 2,
        .y2_ac = @intCast(@as(u32, ac_lookup[67]) * 155 / 100),
        .uv_dc = dc_lookup[60],
        .uv_ac = ac_lookup[66],
    };
    // Without segmentation every segment shares the frame-level factors.
    for (factors) |segment_factors| {
        try std.testing.expectEqual(expected, segment_factors);
    }
}

test "clamps quantizer indices at both table ends" {
    var quant_indices = zero_deltas;
    quant_indices.y_ac_index = 127;
    quant_indices.y_dc_delta = 15;
    quant_indices.uv_dc_delta = 15;
    quant_indices.y2_dc_delta = -15;
    const header = testHeader(quant_indices, frame_header.Segmentation.disabled);

    const factors = segmentFactors(&header);

    try std.testing.expectEqual(dc_lookup[index_max], factors[0].y1_dc);
    try std.testing.expectEqual(ac_lookup[index_max], factors[0].y1_ac);
    try std.testing.expectEqual(dc_lookup[112] * 2, factors[0].y2_dc);
    // The uv_dc factor saturates at 132 even though the index stays in range.
    try std.testing.expectEqual(@as(u16, uv_dc_factor_max), factors[0].uv_dc);

    var low_indices = zero_deltas;
    low_indices.y_dc_delta = -15;
    const low_header = testHeader(low_indices, frame_header.Segmentation.disabled);
    const low_factors = segmentFactors(&low_header);
    try std.testing.expectEqual(dc_lookup[0], low_factors[0].y1_dc);
}

test "enforces the y2_ac scaling floor" {
    // ac_lookup[0] * 155 / 100 = 6, which the floor raises to 8.
    const header = testHeader(zero_deltas, frame_header.Segmentation.disabled);
    const factors = segmentFactors(&header);
    try std.testing.expectEqual(@as(u16, y2_ac_factor_min), factors[0].y2_ac);
    try std.testing.expectEqual(dc_lookup[0] * 2, factors[0].y2_dc);
}

test "applies relative and absolute segment quantizers" {
    var quant_indices = zero_deltas;
    quant_indices.y_ac_index = 40;

    var relative = frame_header.Segmentation.disabled;
    relative.enabled = true;
    relative.absolute_values = false;
    relative.quantizer_deltas = .{ 0, 10, -10, 127 };
    const relative_header = testHeader(quant_indices, relative);
    const relative_factors = segmentFactors(&relative_header);

    try std.testing.expectEqual(ac_lookup[40], relative_factors[0].y1_ac);
    try std.testing.expectEqual(ac_lookup[50], relative_factors[1].y1_ac);
    try std.testing.expectEqual(ac_lookup[30], relative_factors[2].y1_ac);
    // 40 + 127 clamps to the top of the table.
    try std.testing.expectEqual(ac_lookup[index_max], relative_factors[3].y1_ac);

    var absolute = relative;
    absolute.absolute_values = true;
    absolute.quantizer_deltas = .{ 0, 64, 127, -5 };
    const absolute_header = testHeader(quant_indices, absolute);
    const absolute_factors = segmentFactors(&absolute_header);

    // Absolute values replace the frame index entirely.
    try std.testing.expectEqual(ac_lookup[0], absolute_factors[0].y1_ac);
    try std.testing.expectEqual(ac_lookup[64], absolute_factors[1].y1_ac);
    try std.testing.expectEqual(ac_lookup[index_max], absolute_factors[2].y1_ac);
    // Negative absolute indices clamp to the bottom of the table.
    try std.testing.expectEqual(ac_lookup[0], absolute_factors[3].y1_ac);
}
