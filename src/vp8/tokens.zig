//! VP8 DCT/WHT coefficient token decoding (RFC 6386 section 13).
//!
//! Decodes the residual coefficient tokens of one macroblock from a token
//! partition, producing dequantized coefficient blocks in raster order plus
//! the nonzero bookkeeping that later reconstruction stages (transform
//! selection, loop filter skip decisions) and neighboring macroblocks
//! (probability contexts) depend on. The fixed tables are transcribed from
//! RFC 6386 and cross-checked against `references/libwebp` and
//! `references/ffmpeg`; the per-block algorithm mirrors the normative text
//! (the RFC's own illustrative pseudocode in section 13.3 is known-buggy and
//! is deliberately not followed).

const std = @import("std");
const assert = std.debug.assert;

const bool_reader = @import("bool_reader.zig");
const bool_writer = @import("bool_writer.zig");
const cost = @import("cost.zig");
const errors = @import("../errors.zig");
const quant = @import("quant.zig");
const token_probs = @import("token_probs.zig");

pub const Error = errors.Error;

pub const coefficient_count = 16;
pub const luma_block_count = 16;
pub const chroma_block_count = 4;

pub const plane_y_after_y2 = 0;
pub const plane_y2 = 1;
pub const plane_chroma = 2;
pub const plane_y_no_y2 = 3;

/// RFC 6386 section 13.3 coeff_bands: coefficient position to probability
/// band. The 17th entry is a sentinel for the position-16 lookup that
/// follows a nonzero coefficient at position 15; its row is never used to
/// read bits (libwebp ships the same sentinel in its kBands table).
pub const coefficient_bands = [coefficient_count + 1]u8{
    0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0,
};

/// Zigzag scan: decode-order coefficient index to raster position within
/// the 4x4 block (RFC 6386 section 20.16; identical in libwebp and ffmpeg).
pub const zigzag = [coefficient_count]u8{
    0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15,
};

// RFC 6386 section 13.2 extra-bit probabilities, MSB first. (The RFC
// appendix stores the same numbers reversed because its loop runs
// backwards; this is the section 13.2 order.)
const category1_probabilities = [1]u8{159};
const category2_probabilities = [2]u8{ 165, 145 };
const category3_probabilities = [3]u8{ 173, 148, 140 };
const category4_probabilities = [4]u8{ 176, 155, 140, 135 };
const category5_probabilities = [5]u8{ 180, 157, 141, 134, 130 };
const category6_probabilities = [11]u8{
    254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129,
};

const large_category_probabilities = [4][]const u8{
    &category3_probabilities,
    &category4_probabilities,
    &category5_probabilities,
    &category6_probabilities,
};

pub const value_max = 2114;

comptime {
    // Category bases are 3 + (8 << category); category 3 (cat6) reaches
    // 67 + (1 << 11) - 1 = 2114. The RFC's "67 - 2048" enum comment is wrong.
    assert(3 + (8 << 3) == 67);
    assert(67 + (1 << 11) - 1 == value_max);
    assert(coefficient_bands.len == 17);
    assert(coefficient_bands[16] == 0);
}

/// One decoded 4x4 coefficient block: dequantized values in raster order
/// and the end-of-block position (the coefficient index where EOB was read,
/// or 16 when all positions were coded).
pub const Block = struct {
    coefficients: [coefficient_count]i16,
    last_position: u8,

    pub const empty: Block = .{
        .coefficients = @splat(0),
        .last_position = 0,
    };
};

/// All residual blocks of one macroblock. `y2` is only meaningful when
/// `has_y2` is set (luma mode is not B_PRED); luma blocks then carry no
/// DC coefficient of their own until the inverse WHT scatters `y2` into
/// position 0 of each (transform stage).
pub const MacroblockCoefficients = struct {
    has_y2: bool,
    y2: Block,
    luma: [luma_block_count]Block,
    chroma_u: [chroma_block_count]Block,
    chroma_v: [chroma_block_count]Block,

    pub const empty: MacroblockCoefficients = .{
        .has_y2 = false,
        .y2 = .empty,
        .luma = @splat(Block.empty),
        .chroma_u = @splat(Block.empty),
        .chroma_v = @splat(Block.empty),
    };
};

/// Per-edge nonzero flags consumed as probability contexts by the next
/// macroblock. One instance tracks the left edge (reset each row) and one
/// per macroblock column tracks the above edge.
pub const NonzeroFlags = struct {
    luma: [4]bool,
    chroma_u: [2]bool,
    chroma_v: [2]bool,
    y2: bool,

    pub const zero: NonzeroFlags = .{
        .luma = @splat(false),
        .chroma_u = @splat(false),
        .chroma_v = @splat(false),
        .y2 = false,
    };
};

pub const MacroblockOptions = struct {
    probabilities: *const token_probs.Table,
    factors: *const quant.Factors,
    /// Luma mode is not B_PRED, so a Y2 block precedes the luma blocks.
    has_y2: bool,
    /// Resolved skip: header skip coding enabled AND the macroblock's
    /// skip flag. When set, no tokens are read at all.
    skip: bool,
};

/// Decodes all residual blocks of one macroblock from `reader` (the token
/// partition of the macroblock's row). Updates `left` and `above` nonzero
/// contexts exactly as libwebp does, including the skipped-macroblock rule
/// that leaves Y2 context untouched for B_PRED macroblocks. Returns true
/// when any block carries a nonzero coefficient (false = the loop filter
/// treats the macroblock like a skipped one).
pub fn decodeMacroblock(
    reader: *bool_reader.BoolReader,
    options: MacroblockOptions,
    left: *NonzeroFlags,
    above: *NonzeroFlags,
    coefficients: *MacroblockCoefficients,
) Error!bool {
    coefficients.* = .empty;
    coefficients.has_y2 = options.has_y2;

    if (options.skip) {
        left.luma = @splat(false);
        left.chroma_u = @splat(false);
        left.chroma_v = @splat(false);
        above.luma = @splat(false);
        above.chroma_u = @splat(false);
        above.chroma_v = @splat(false);
        // A skipped B_PRED macroblock has no Y2 block, so the Y2 context of
        // the most recent macroblock that had one must persist (RFC 13.3;
        // libwebp clears nz_dc only for non-B_PRED skips).
        if (options.has_y2) {
            left.y2 = false;
            above.y2 = false;
        }
        return false;
    }

    var any_nonzero = false;

    if (options.has_y2) {
        const context = contextFromFlags(left.y2, above.y2);
        const y2_factors = [2]u16{ options.factors.y2_dc, options.factors.y2_ac };
        coefficients.y2.last_position = try decodeBlock(
            reader,
            &options.probabilities[plane_y2],
            context,
            0,
            y2_factors,
            &coefficients.y2.coefficients,
        );
        const nonzero = coefficients.y2.last_position > 0;
        left.y2 = nonzero;
        above.y2 = nonzero;
        any_nonzero = any_nonzero or nonzero;
    }

    const luma_plane: usize = if (options.has_y2) plane_y_after_y2 else plane_y_no_y2;
    const luma_first: u8 = if (options.has_y2) 1 else 0;
    const luma_factors = [2]u16{ options.factors.y1_dc, options.factors.y1_ac };
    for (0..4) |sub_y| {
        for (0..4) |sub_x| {
            const context = contextFromFlags(left.luma[sub_y], above.luma[sub_x]);
            const block = &coefficients.luma[sub_y * 4 + sub_x];
            block.last_position = try decodeBlock(
                reader,
                &options.probabilities[luma_plane],
                context,
                luma_first,
                luma_factors,
                &block.coefficients,
            );
            const nonzero = block.last_position > luma_first;
            left.luma[sub_y] = nonzero;
            above.luma[sub_x] = nonzero;
            any_nonzero = any_nonzero or nonzero;
        }
    }

    const chroma_factors = [2]u16{ options.factors.uv_dc, options.factors.uv_ac };
    inline for (.{ "chroma_u", "chroma_v" }) |field| {
        for (0..2) |sub_y| {
            for (0..2) |sub_x| {
                const left_flags = &@field(left, field);
                const above_flags = &@field(above, field);
                const context = contextFromFlags(left_flags[sub_y], above_flags[sub_x]);
                const block = &@field(coefficients, field)[sub_y * 2 + sub_x];
                block.last_position = try decodeBlock(
                    reader,
                    &options.probabilities[plane_chroma],
                    context,
                    0,
                    chroma_factors,
                    &block.coefficients,
                );
                const nonzero = block.last_position > 0;
                left_flags[sub_y] = nonzero;
                above_flags[sub_x] = nonzero;
                any_nonzero = any_nonzero or nonzero;
            }
        }
    }

    return any_nonzero;
}

fn contextFromFlags(left_nonzero: bool, above_nonzero: bool) u2 {
    return @as(u2, @intFromBool(left_nonzero)) + @intFromBool(above_nonzero);
}

/// Decodes one 4x4 block's tokens into `coefficients` (must be pre-zeroed),
/// dequantizing at store time: position 0 uses `dequant[0]`, positions 1..15
/// use `dequant[1]`, stored at the zigzag raster position as wrapping i16
/// (matching libwebp's int16_t store). Returns the end-of-block position.
pub fn decodeBlock(
    reader: *bool_reader.BoolReader,
    plane_probabilities: *const [token_probs.band_count][token_probs.context_count][token_probs.probability_count]u8,
    first_context: u2,
    first_position: u8,
    dequant: [2]u16,
    coefficients: *[coefficient_count]i16,
) Error!u8 {
    assert(first_position <= 1);
    assert(first_context <= 2);

    var position = first_position;
    var probabilities = &plane_probabilities[coefficient_bands[position]][first_context];
    while (position < coefficient_count) {
        if ((try reader.readBool(probabilities[0])) == 0) {
            // End of block. At the first position this means an empty block.
            return position;
        }

        // A zero run: after each DCT_0 the end-of-block branch is skipped
        // (tree restart at index 2) and the context pins to 0 while the
        // band advances with the position.
        while ((try reader.readBool(probabilities[1])) == 0) {
            position += 1;
            if (position == coefficient_count) {
                // A run of zeros to position 16 carries no terminating EOB;
                // both oracles return 16 (block counts as nonzero).
                return coefficient_count;
            }
            probabilities = &plane_probabilities[coefficient_bands[position]][0];
        }

        var value: u32 = undefined;
        var next_context: u2 = undefined;
        if ((try reader.readBool(probabilities[2])) == 0) {
            value = 1;
            next_context = 1;
        } else {
            value = try readLargeValue(reader, probabilities);
            next_context = 2;
        }
        // Position 15 looks up the sentinel band here; the row is never
        // used because the loop exits.
        probabilities = &plane_probabilities[coefficient_bands[position + 1]][next_context];

        const sign = try reader.readBit();
        const magnitude: i32 = @intCast(value);
        const signed_value: i32 = if (sign == 1) -magnitude else magnitude;
        const factor: i32 = dequant[@intFromBool(position > 0)];
        coefficients[zigzag[position]] = @truncate(signed_value * factor);
        position += 1;
    }
    return coefficient_count;
}

/// Decodes a coefficient magnitude of 2 or more (RFC 6386 section 13.2,
/// tokens DCT_2..DCT_4 and the six extra-bit categories).
fn readLargeValue(
    reader: *bool_reader.BoolReader,
    probabilities: *const [token_probs.probability_count]u8,
) Error!u32 {
    if ((try reader.readBool(probabilities[3])) == 0) {
        if ((try reader.readBool(probabilities[4])) == 0) return 2;
        return 3 + @as(u32, try reader.readBool(probabilities[5]));
    }

    if ((try reader.readBool(probabilities[6])) == 0) {
        if ((try reader.readBool(probabilities[7])) == 0) {
            return 5 + @as(u32, try reader.readBool(category1_probabilities[0]));
        }
        const high = try reader.readBool(category2_probabilities[0]);
        const low = try reader.readBool(category2_probabilities[1]);
        return 7 + 2 * @as(u32, high) + low;
    }

    const bit1 = try reader.readBool(probabilities[8]);
    const bit0 = try reader.readBool(probabilities[9 + @as(usize, bit1)]);
    const category: u5 = 2 * @as(u5, bit1) + bit0;
    var value: u32 = 0;
    for (large_category_probabilities[category]) |probability| {
        value = 2 * value + try reader.readBool(probability);
    }
    return value + 3 + (@as(u32, 8) << category);
}

// --- Token encoding (the bit-exact inverse of the decoding above) -----------
//
// The encoder emits coefficient tokens through the boolean writer in the exact
// structure decodeBlock/decodeMacroblock read them back, sharing the band,
// zigzag, and category tables so the two halves cannot drift.

// Emits a block's scan-order signed coefficient values (already trimmed to the
// last nonzero) as tokens: pre-dequantization magnitudes with sign, in decode
// (zigzag) order, terminated by EOB unless position 16 is reached.
fn writeBlockTokens(
    writer: *bool_writer.BoolWriter,
    plane_probabilities: *const [token_probs.band_count][token_probs.context_count][token_probs.probability_count]u8,
    first_context: u2,
    first_position: u8,
    values: []const i32,
) !void {
    var position = first_position;
    var probabilities = &plane_probabilities[coefficient_bands[position]][first_context];
    var index: usize = 0;
    var previous_was_zero = false;
    while (index < values.len) : (index += 1) {
        const value = values[index];
        const magnitude: u32 = @abs(value);
        assert(position < coefficient_count);

        if (!previous_was_zero) {
            try writer.writeBool(probabilities[0], 1); // Not EOB.
        }
        if (magnitude == 0) {
            try writer.writeBool(probabilities[1], 0);
            position += 1;
            if (position == coefficient_count) return;
            probabilities = &plane_probabilities[coefficient_bands[position]][0];
            previous_was_zero = true;
            continue;
        }
        try writer.writeBool(probabilities[1], 1);

        var next_context: u2 = undefined;
        if (magnitude == 1) {
            try writer.writeBool(probabilities[2], 0);
            next_context = 1;
        } else {
            try writer.writeBool(probabilities[2], 1);
            try writeLargeValue(writer, probabilities, magnitude);
            next_context = 2;
        }
        probabilities = &plane_probabilities[coefficient_bands[position + 1]][next_context];
        try writer.writeBit(if (value < 0) 1 else 0);
        position += 1;
        previous_was_zero = false;
    }
    if (position < coefficient_count) {
        assert(!previous_was_zero);
        try writer.writeBool(probabilities[0], 0); // EOB.
    }
}

fn writeLargeValue(
    writer: *bool_writer.BoolWriter,
    probabilities: *const [token_probs.probability_count]u8,
    magnitude: u32,
) !void {
    assert(magnitude >= 2);
    assert(magnitude <= value_max);

    if (magnitude <= 4) {
        try writer.writeBool(probabilities[3], 0);
        if (magnitude == 2) {
            try writer.writeBool(probabilities[4], 0);
            return;
        }
        try writer.writeBool(probabilities[4], 1);
        try writer.writeBool(probabilities[5], @intCast(magnitude - 3));
        return;
    }
    try writer.writeBool(probabilities[3], 1);
    if (magnitude <= 10) {
        try writer.writeBool(probabilities[6], 0);
        if (magnitude <= 6) {
            try writer.writeBool(probabilities[7], 0);
            try writer.writeBool(category1_probabilities[0], @intCast(magnitude - 5));
            return;
        }
        try writer.writeBool(probabilities[7], 1);
        const residual = magnitude - 7;
        try writer.writeBool(category2_probabilities[0], @intCast(residual >> 1));
        try writer.writeBool(category2_probabilities[1], @intCast(residual & 1));
        return;
    }
    try writer.writeBool(probabilities[6], 1);
    const category: u5 = if (magnitude <= 18) 0 else if (magnitude <= 34) 1 else if (magnitude <= 66) 2 else 3;
    try writer.writeBool(probabilities[8], @intCast(category >> 1));
    try writer.writeBool(probabilities[9 + (category >> 1)], @intCast(category & 1));
    const extra_probabilities = large_category_probabilities[category];
    const residual = magnitude - 3 - (@as(u32, 8) << category);
    var bit_index: usize = extra_probabilities.len;
    for (extra_probabilities) |probability| {
        bit_index -= 1;
        try writer.writeBool(probability, @intCast((residual >> @intCast(bit_index)) & 1));
    }
}

/// Emits one 4x4 block's coefficient tokens from quantized `levels` in raster
/// order (`levels[p]` is the signed level at raster position p). Position 0 is
/// skipped when `first_position == 1` (luma blocks that carry their DC in Y2).
/// Returns the end-of-block position exactly as `decodeBlock` would report it,
/// so the caller derives the nonzero context the decoder will derive. Inverse
/// of `decodeBlock`.
pub fn writeBlock(
    writer: *bool_writer.BoolWriter,
    plane_probabilities: *const [token_probs.band_count][token_probs.context_count][token_probs.probability_count]u8,
    first_context: u2,
    first_position: u8,
    levels: *const [coefficient_count]i16,
) Error!u8 {
    assert(first_position <= 1);
    assert(first_context <= 2);

    // Reorder raster levels into scan order, tracking the last nonzero so the
    // tail of zeros is dropped (an EOB stands in for it).
    var values: [coefficient_count]i32 = undefined;
    var len: usize = 0;
    var position: usize = first_position;
    while (position < coefficient_count) : (position += 1) {
        const level: i32 = levels[zigzag[position]];
        values[position - first_position] = level;
        if (level != 0) len = position - first_position + 1;
    }

    try writeBlockTokens(writer, plane_probabilities, first_context, first_position, values[0..len]);
    return first_position + @as(u8, @intCast(len));
}

/// Estimated cost, in 1/256-bit units, of coding one 4x4 block's quantized
/// `levels` with `writeBlock`. Mirrors `writeBlock`/`writeBlockTokens`/
/// `writeLargeValue` token-for-token, summing `cost.boolCost` instead of
/// emitting, so it is the exact ideal bit cost of that coding (the arithmetic
/// coder's emitted bytes differ only by rounding). The encoder's
/// rate-distortion mode decision sums these over a macroblock's blocks.
pub fn blockCost(
    plane_probabilities: *const [token_probs.band_count][token_probs.context_count][token_probs.probability_count]u8,
    first_context: u2,
    first_position: u8,
    levels: *const [coefficient_count]i16,
) u32 {
    assert(first_position <= 1);
    assert(first_context <= 2);

    var values: [coefficient_count]i32 = undefined;
    var len: usize = 0;
    var position: usize = first_position;
    while (position < coefficient_count) : (position += 1) {
        const level: i32 = levels[zigzag[position]];
        values[position - first_position] = level;
        if (level != 0) len = position - first_position + 1;
    }

    return blockTokensCost(plane_probabilities, first_context, first_position, values[0..len]);
}

// Cost mirror of `writeBlockTokens`: same control flow, `cost.boolCost` in
// place of every `writeBool` and `cost.bit_cost` for the equiprobable sign bit.
fn blockTokensCost(
    plane_probabilities: *const [token_probs.band_count][token_probs.context_count][token_probs.probability_count]u8,
    first_context: u2,
    first_position: u8,
    values: []const i32,
) u32 {
    var bits: u32 = 0;
    var position = first_position;
    var probabilities = &plane_probabilities[coefficient_bands[position]][first_context];
    var index: usize = 0;
    var previous_was_zero = false;
    while (index < values.len) : (index += 1) {
        const value = values[index];
        const magnitude: u32 = @abs(value);
        assert(position < coefficient_count);

        if (!previous_was_zero) bits += cost.boolCost(probabilities[0], 1); // Not EOB.
        if (magnitude == 0) {
            bits += cost.boolCost(probabilities[1], 0);
            position += 1;
            if (position == coefficient_count) return bits;
            probabilities = &plane_probabilities[coefficient_bands[position]][0];
            previous_was_zero = true;
            continue;
        }
        bits += cost.boolCost(probabilities[1], 1);

        var next_context: u2 = undefined;
        if (magnitude == 1) {
            bits += cost.boolCost(probabilities[2], 0);
            next_context = 1;
        } else {
            bits += cost.boolCost(probabilities[2], 1);
            bits += largeValueCost(probabilities, magnitude);
            next_context = 2;
        }
        probabilities = &plane_probabilities[coefficient_bands[position + 1]][next_context];
        bits += cost.bit_cost; // sign bit, equiprobable
        position += 1;
        previous_was_zero = false;
    }
    if (position < coefficient_count) {
        assert(!previous_was_zero);
        bits += cost.boolCost(probabilities[0], 0); // EOB.
    }
    return bits;
}

// Cost mirror of `writeLargeValue`.
fn largeValueCost(probabilities: *const [token_probs.probability_count]u8, magnitude: u32) u32 {
    assert(magnitude >= 2);
    assert(magnitude <= value_max);

    var bits: u32 = 0;
    if (magnitude <= 4) {
        bits += cost.boolCost(probabilities[3], 0);
        if (magnitude == 2) {
            bits += cost.boolCost(probabilities[4], 0);
            return bits;
        }
        bits += cost.boolCost(probabilities[4], 1);
        bits += cost.boolCost(probabilities[5], @intCast(magnitude - 3));
        return bits;
    }
    bits += cost.boolCost(probabilities[3], 1);
    if (magnitude <= 10) {
        bits += cost.boolCost(probabilities[6], 0);
        if (magnitude <= 6) {
            bits += cost.boolCost(probabilities[7], 0);
            bits += cost.boolCost(category1_probabilities[0], @intCast(magnitude - 5));
            return bits;
        }
        bits += cost.boolCost(probabilities[7], 1);
        const residual = magnitude - 7;
        bits += cost.boolCost(category2_probabilities[0], @intCast(residual >> 1));
        bits += cost.boolCost(category2_probabilities[1], @intCast(residual & 1));
        return bits;
    }
    bits += cost.boolCost(probabilities[6], 1);
    const category: u5 = if (magnitude <= 18) 0 else if (magnitude <= 34) 1 else if (magnitude <= 66) 2 else 3;
    bits += cost.boolCost(probabilities[8], @intCast(category >> 1));
    bits += cost.boolCost(probabilities[9 + (category >> 1)], @intCast(category & 1));
    const extra_probabilities = large_category_probabilities[category];
    const residual = magnitude - 3 - (@as(u32, 8) << category);
    var bit_index: usize = extra_probabilities.len;
    for (extra_probabilities) |probability| {
        bit_index -= 1;
        bits += cost.boolCost(probability, @intCast((residual >> @intCast(bit_index)) & 1));
    }
    return bits;
}

/// Quantized coefficient levels of one macroblock in raster order, the encode
/// counterpart of `MacroblockCoefficients` (which holds dequantized values).
pub const MacroblockLevels = struct {
    y2: [coefficient_count]i16 = @splat(0),
    luma: [luma_block_count][coefficient_count]i16 = @splat(@splat(0)),
    chroma_u: [chroma_block_count][coefficient_count]i16 = @splat(@splat(0)),
    chroma_v: [chroma_block_count][coefficient_count]i16 = @splat(@splat(0)),
};

/// Emits all residual tokens of one macroblock, mirroring `decodeMacroblock`
/// block-for-block: the same Y2/luma/chroma order, the same context derivation,
/// and the same `left`/`above` nonzero updates (including the skipped-block
/// rule). `options.factors` is unused here (levels are already quantized).
/// Returns true when any block carries a nonzero coefficient.
pub fn writeMacroblock(
    writer: *bool_writer.BoolWriter,
    options: MacroblockOptions,
    left: *NonzeroFlags,
    above: *NonzeroFlags,
    levels: *const MacroblockLevels,
) Error!bool {
    if (options.skip) {
        left.luma = @splat(false);
        left.chroma_u = @splat(false);
        left.chroma_v = @splat(false);
        above.luma = @splat(false);
        above.chroma_u = @splat(false);
        above.chroma_v = @splat(false);
        if (options.has_y2) {
            left.y2 = false;
            above.y2 = false;
        }
        return false;
    }

    var any_nonzero = false;

    if (options.has_y2) {
        const context = contextFromFlags(left.y2, above.y2);
        const last = try writeBlock(writer, &options.probabilities[plane_y2], context, 0, &levels.y2);
        const nonzero = last > 0;
        left.y2 = nonzero;
        above.y2 = nonzero;
        any_nonzero = any_nonzero or nonzero;
    }

    const luma_plane: usize = if (options.has_y2) plane_y_after_y2 else plane_y_no_y2;
    const luma_first: u8 = if (options.has_y2) 1 else 0;
    for (0..4) |sub_y| {
        for (0..4) |sub_x| {
            const context = contextFromFlags(left.luma[sub_y], above.luma[sub_x]);
            const last = try writeBlock(
                writer,
                &options.probabilities[luma_plane],
                context,
                luma_first,
                &levels.luma[sub_y * 4 + sub_x],
            );
            const nonzero = last > luma_first;
            left.luma[sub_y] = nonzero;
            above.luma[sub_x] = nonzero;
            any_nonzero = any_nonzero or nonzero;
        }
    }

    inline for (.{ "chroma_u", "chroma_v" }) |field| {
        for (0..2) |sub_y| {
            for (0..2) |sub_x| {
                const left_flags = &@field(left, field);
                const above_flags = &@field(above, field);
                const context = contextFromFlags(left_flags[sub_y], above_flags[sub_x]);
                const last = try writeBlock(
                    writer,
                    &options.probabilities[plane_chroma],
                    context,
                    0,
                    &@field(levels, field)[sub_y * 2 + sub_x],
                );
                const nonzero = last > 0;
                left_flags[sub_y] = nonzero;
                above_flags[sub_x] = nonzero;
                any_nonzero = any_nonzero or nonzero;
            }
        }
    }

    return any_nonzero;
}

const test_factors = quant.Factors{
    .y1_dc = 8,
    .y1_ac = 6,
    .y2_dc = 20,
    .y2_ac = 9,
    .uv_dc = 7,
    .uv_ac = 5,
};

fn testBlockRoundTrip(
    plane: usize,
    first_context: u2,
    first_position: u8,
    dequant: [2]u16,
    values: []const i32,
    expected: [coefficient_count]i16,
    expected_last: u8,
) !void {
    const probabilities = &token_probs.default_probabilities[plane];

    var buffer: [256]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&buffer);
    try writeBlockTokens(&writer, probabilities, first_context, first_position, values);
    try writer.writeLiteral(0x9, 4); // Sentinel.
    const encoded = try writer.finish();

    var reader = bool_reader.BoolReader.init(encoded);
    var coefficients: [coefficient_count]i16 = @splat(0);
    const last = try decodeBlock(
        &reader,
        probabilities,
        first_context,
        first_position,
        dequant,
        &coefficients,
    );

    try std.testing.expectEqual(expected_last, last);
    try std.testing.expectEqual(expected, coefficients);
    try std.testing.expectEqual(@as(u32, 0x9), try reader.readLiteral(4));
}

test "decodes an empty block from an immediate end-of-block" {
    try testBlockRoundTrip(plane_y_no_y2, 0, 0, .{ 8, 6 }, &.{}, @splat(0), 0);
    // A first=1 block with an immediate EOB ends at position 1.
    try testBlockRoundTrip(plane_y_after_y2, 2, 1, .{ 8, 6 }, &.{}, @splat(0), 1);
}

test "decodes and dequantizes small coefficient values" {
    // DC +1 (factor 8), then AC -2 at position 1 (factor 6), EOB.
    var expected: [coefficient_count]i16 = @splat(0);
    expected[zigzag[0]] = 8;
    expected[zigzag[1]] = -12;
    try testBlockRoundTrip(plane_y_no_y2, 0, 0, .{ 8, 6 }, &.{ 1, -2 }, expected, 2);
}

test "decodes zero runs with the post-zero tree restart" {
    // +3, three zeros, -4, EOB: exercises the EOB-skip-after-zero rule and
    // the band advance with pinned context inside the run.
    var expected: [coefficient_count]i16 = @splat(0);
    expected[zigzag[0]] = 3 * 8;
    expected[zigzag[4]] = -4 * 6;
    try testBlockRoundTrip(plane_y_no_y2, 1, 0, .{ 8, 6 }, &.{ 3, 0, 0, 0, -4 }, expected, 5);
}

test "decodes every extra-bit category at its range edges" {
    const edges = [_]i32{ 2, 4, 5, 6, 7, 10, 11, 18, 19, 34, 35, 66, 67, value_max };
    for (edges) |edge| {
        var expected: [coefficient_count]i16 = @splat(0);
        expected[zigzag[0]] = @intCast(edge * 8);
        try testBlockRoundTrip(plane_y_no_y2, 0, 0, .{ 8, 6 }, &.{edge}, expected, 1);

        var negative_expected: [coefficient_count]i16 = @splat(0);
        negative_expected[zigzag[0]] = @intCast(-edge * 8);
        try testBlockRoundTrip(plane_y_no_y2, 0, 0, .{ 8, 6 }, &.{-edge}, negative_expected, 1);
    }
}

test "wraps oversized dequantized products like a 16-bit store" {
    // 2114 * 157 = 331898 = 0x5107A; the low 16 bits reinterpret as 0x107A.
    var expected: [coefficient_count]i16 = @splat(0);
    expected[zigzag[0]] = @bitCast(@as(u16, @truncate(@as(u32, 2114 * 157))));
    try testBlockRoundTrip(plane_y_no_y2, 0, 0, .{ 157, 157 }, &.{2114}, expected, 1);
}

test "decodes a fully populated block through the position-16 sentinel" {
    const values = [coefficient_count]i32{
        1, -1, 2, -2, 3, -3, 4, -4, 5, -5, 6, -6, 7, -7, 8, -9,
    };
    var expected: [coefficient_count]i16 = @splat(0);
    for (values, 0..) |value, position| {
        const factor: i32 = if (position == 0) 8 else 6;
        expected[zigzag[position]] = @intCast(value * factor);
    }
    try testBlockRoundTrip(plane_y_no_y2, 0, 0, .{ 8, 6 }, &values, expected, 16);
}

test "treats a trailing zero run to position 16 as a nonzero block" {
    // One coded value then zeros through position 15: no EOB is coded and
    // the decode returns 16.
    const values = [coefficient_count]i32{
        5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    };
    var expected: [coefficient_count]i16 = @splat(0);
    expected[zigzag[0]] = 5 * 8;
    try testBlockRoundTrip(plane_y_no_y2, 0, 0, .{ 8, 6 }, &values, expected, 16);
}

fn encodeTestMacroblock(
    writer: *bool_writer.BoolWriter,
    options: MacroblockOptions,
    left: *NonzeroFlags,
    above: *NonzeroFlags,
    y2_values: []const i32,
    luma_values: *const [luma_block_count][]const i32,
    chroma_u_values: *const [chroma_block_count][]const i32,
    chroma_v_values: *const [chroma_block_count][]const i32,
) !void {
    assert(!options.skip);
    const probabilities = options.probabilities;

    if (options.has_y2) {
        const context = contextFromFlags(left.y2, above.y2);
        try writeBlockTokens(writer, &probabilities[plane_y2], context, 0, y2_values);
        const nonzero = blockHasNonzero(y2_values);
        left.y2 = nonzero;
        above.y2 = nonzero;
    }

    const luma_plane: usize = if (options.has_y2) plane_y_after_y2 else plane_y_no_y2;
    const luma_first: u8 = if (options.has_y2) 1 else 0;
    for (0..4) |sub_y| {
        for (0..4) |sub_x| {
            const context = contextFromFlags(left.luma[sub_y], above.luma[sub_x]);
            const values = luma_values[sub_y * 4 + sub_x];
            try writeBlockTokens(writer, &probabilities[luma_plane], context, luma_first, values);
            const nonzero = blockHasNonzero(values);
            left.luma[sub_y] = nonzero;
            above.luma[sub_x] = nonzero;
        }
    }

    inline for (.{ "chroma_u", "chroma_v" }, .{ chroma_u_values, chroma_v_values }) |field, plane_values| {
        for (0..2) |sub_y| {
            for (0..2) |sub_x| {
                const left_flags = &@field(left, field);
                const above_flags = &@field(above, field);
                const context = contextFromFlags(left_flags[sub_y], above_flags[sub_x]);
                const values = plane_values[sub_y * 2 + sub_x];
                try writeBlockTokens(writer, &probabilities[plane_chroma], context, 0, values);
                const nonzero = blockHasNonzero(values);
                left_flags[sub_y] = nonzero;
                above_flags[sub_x] = nonzero;
            }
        }
    }
}

fn blockHasNonzero(values: []const i32) bool {
    for (values) |value| {
        if (value != 0) return true;
    }
    return false;
}

test "decodes a macroblock with Y2 and tracks contexts across blocks" {
    var encode_left = NonzeroFlags.zero;
    var encode_above = NonzeroFlags.zero;
    var buffer: [1024]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&buffer);

    const options = MacroblockOptions{
        .probabilities = &token_probs.default_probabilities,
        .factors = &test_factors,
        .has_y2 = true,
        .skip = false,
    };

    const empty: []const i32 = &.{};
    var luma_values: [luma_block_count][]const i32 = @splat(empty);
    luma_values[0] = &.{ 0, 2, -1 }; // Position 0 skipped: values start at 1.
    luma_values[5] = &.{ 0, 0, 7 };
    luma_values[15] = &.{ 0, -35 };
    var chroma_u_values: [chroma_block_count][]const i32 = @splat(empty);
    chroma_u_values[0] = &.{-1};
    chroma_u_values[3] = &.{ 1, 1, 1 };
    var chroma_v_values: [chroma_block_count][]const i32 = @splat(empty);
    chroma_v_values[2] = &.{19};

    try encodeTestMacroblock(
        &writer,
        options,
        &encode_left,
        &encode_above,
        &.{ -2, 1 },
        &luma_values,
        &chroma_u_values,
        &chroma_v_values,
    );
    try writer.writeLiteral(0x6, 4);
    const encoded = try writer.finish();

    var left = NonzeroFlags.zero;
    var above = NonzeroFlags.zero;
    var reader = bool_reader.BoolReader.init(encoded);
    var coefficients: MacroblockCoefficients = undefined;
    const any_nonzero = try decodeMacroblock(&reader, options, &left, &above, &coefficients);

    try std.testing.expect(any_nonzero);
    try std.testing.expect(coefficients.has_y2);

    // Y2 block: -2 * y2_dc at position 0, +1 * y2_ac at position 1.
    try std.testing.expectEqual(@as(i16, -2 * 20), coefficients.y2.coefficients[zigzag[0]]);
    try std.testing.expectEqual(@as(i16, 9), coefficients.y2.coefficients[zigzag[1]]);
    try std.testing.expectEqual(@as(u8, 2), coefficients.y2.last_position);
    try std.testing.expect(left.y2);
    try std.testing.expect(above.y2);

    // Luma block 0 starts at coefficient 1: a zero at position 1, then
    // 2 and -1 at positions 2 and 3, all with the AC factor.
    try std.testing.expectEqual(@as(i16, 0), coefficients.luma[0].coefficients[0]);
    try std.testing.expectEqual(@as(i16, 0), coefficients.luma[0].coefficients[zigzag[1]]);
    try std.testing.expectEqual(@as(i16, 12), coefficients.luma[0].coefficients[zigzag[2]]);
    try std.testing.expectEqual(@as(i16, -6), coefficients.luma[0].coefficients[zigzag[3]]);
    try std.testing.expectEqual(@as(u8, 4), coefficients.luma[0].last_position);

    try std.testing.expectEqual(@as(i16, 7 * 6), coefficients.luma[5].coefficients[zigzag[3]]);
    try std.testing.expectEqual(@as(i16, -35 * 6), coefficients.luma[15].coefficients[zigzag[2]]);

    // Final left/above luma flags hold the rightmost block of each row and
    // the bottom block of each column; only block 15 of those is nonzero.
    try std.testing.expectEqual(
        [4]bool{ false, false, false, true },
        left.luma,
    );
    try std.testing.expectEqual(
        [4]bool{ false, false, false, true },
        above.luma,
    );

    try std.testing.expectEqual(@as(i16, -7), coefficients.chroma_u[0].coefficients[0]);
    try std.testing.expectEqual(@as(i16, 5), coefficients.chroma_u[3].coefficients[zigzag[2]]);
    try std.testing.expectEqual(@as(i16, 19 * 7), coefficients.chroma_v[2].coefficients[0]);
    try std.testing.expectEqual(@as(u8, 0), coefficients.chroma_v[3].last_position);

    try std.testing.expectEqual(@as(u32, 0x6), try reader.readLiteral(4));
}

test "implicit skip is reported when every block decodes empty" {
    var encode_left = NonzeroFlags.zero;
    var encode_above = NonzeroFlags.zero;
    var buffer: [256]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&buffer);

    const options = MacroblockOptions{
        .probabilities = &token_probs.default_probabilities,
        .factors = &test_factors,
        .has_y2 = true,
        .skip = false,
    };

    const empty: []const i32 = &.{};
    const luma_values: [luma_block_count][]const i32 = @splat(empty);
    const chroma_values: [chroma_block_count][]const i32 = @splat(empty);
    try encodeTestMacroblock(
        &writer,
        options,
        &encode_left,
        &encode_above,
        &.{},
        &luma_values,
        &chroma_values,
        &chroma_values,
    );
    const encoded = try writer.finish();

    var left = NonzeroFlags.zero;
    var above = NonzeroFlags.zero;
    var reader = bool_reader.BoolReader.init(encoded);
    var coefficients: MacroblockCoefficients = undefined;
    const any_nonzero = try decodeMacroblock(&reader, options, &left, &above, &coefficients);

    try std.testing.expect(!any_nonzero);
    // Empty first=1 luma blocks end at position 1 (the immediate EOB is
    // read at the first coded position) with no stored coefficients.
    for (coefficients.luma) |block| {
        try std.testing.expectEqual([_]i16{0} ** coefficient_count, block.coefficients);
        try std.testing.expectEqual(@as(u8, 1), block.last_position);
    }
    try std.testing.expectEqual(@as(u8, 0), coefficients.y2.last_position);
    try std.testing.expect(!left.y2);
}

test "skipped macroblocks read no tokens and preserve B_PRED Y2 context" {
    var left = NonzeroFlags.zero;
    left.y2 = true;
    left.luma = @splat(true);
    var above = NonzeroFlags.zero;
    above.y2 = true;
    above.chroma_u = @splat(true);

    // The reader would fail on any read: two bytes only, already drained.
    var reader = bool_reader.BoolReader.init(&.{ 0x00, 0x00 });

    var coefficients: MacroblockCoefficients = undefined;
    const b_pred_options = MacroblockOptions{
        .probabilities = &token_probs.default_probabilities,
        .factors = &test_factors,
        .has_y2 = false,
        .skip = true,
    };
    const any_nonzero = try decodeMacroblock(&reader, b_pred_options, &left, &above, &coefficients);

    try std.testing.expect(!any_nonzero);
    // Y/U/V contexts cleared, Y2 context preserved (no Y2 block exists).
    try std.testing.expectEqual([4]bool{ false, false, false, false }, left.luma);
    try std.testing.expectEqual([2]bool{ false, false }, above.chroma_u);
    try std.testing.expect(left.y2);
    try std.testing.expect(above.y2);

    // A skipped macroblock with a Y2 block clears the Y2 context too.
    const y2_options = MacroblockOptions{
        .probabilities = &token_probs.default_probabilities,
        .factors = &test_factors,
        .has_y2 = true,
        .skip = true,
    };
    _ = try decodeMacroblock(&reader, y2_options, &left, &above, &coefficients);
    try std.testing.expect(!left.y2);
    try std.testing.expect(!above.y2);
}

test "reports truncation on exhausted token partitions" {
    var reader = bool_reader.BoolReader.init(&.{ 0xff, 0xff });
    var left = NonzeroFlags.zero;
    var above = NonzeroFlags.zero;
    var coefficients: MacroblockCoefficients = undefined;
    const options = MacroblockOptions{
        .probabilities = &token_probs.default_probabilities,
        .factors = &test_factors,
        .has_y2 = true,
        .skip = false,
    };
    try std.testing.expectError(
        error.TruncatedBitstream,
        decodeMacroblock(&reader, options, &left, &above, &coefficients),
    );
}

test "fuzz VP8 macroblock token decoding" {
    const testing_fuzz = @import("../testing/fuzz.zig");

    // Seed: a valid macroblock covering Y2, zero runs, every category, and
    // chroma context updates.
    var encode_left = NonzeroFlags.zero;
    var encode_above = NonzeroFlags.zero;
    var buffer: [1024]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&buffer);
    const options = MacroblockOptions{
        .probabilities = &token_probs.default_probabilities,
        .factors = &test_factors,
        .has_y2 = true,
        .skip = false,
    };
    const empty: []const i32 = &.{};
    var luma_values: [luma_block_count][]const i32 = @splat(empty);
    luma_values[0] = &.{ 0, 1, -2, 0, 0, 5 };
    luma_values[7] = &.{ 0, 67, -2114 };
    var chroma_values: [chroma_block_count][]const i32 = @splat(empty);
    chroma_values[1] = &.{ 11, 0, 35 };
    try encodeTestMacroblock(
        &writer,
        options,
        &encode_left,
        &encode_above,
        &.{ -19, 0, 3 },
        &luma_values,
        &chroma_values,
        &chroma_values,
    );
    const encoded = try writer.finish();

    var seed_buffer: [1100]u8 = undefined;
    const seed = testing_fuzz.sliceCorpusEntry(&seed_buffer, encoded);

    try std.testing.fuzz({}, fuzzDecodeOne, .{ .corpus = &.{seed} });
}

fn fuzzDecodeOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [2048]u8 = undefined;
    const input_len = smith.slice(&input_buffer);

    var reader = bool_reader.BoolReader.init(input_buffer[0..input_len]);
    var left = NonzeroFlags.zero;
    var above = NonzeroFlags.zero;
    var coefficients: MacroblockCoefficients = undefined;

    // Alternate Y2 and B_PRED macroblocks until the input drains.
    var has_y2 = true;
    var iterations: u32 = 0;
    while (iterations < 64) : (iterations += 1) {
        const options = MacroblockOptions{
            .probabilities = &token_probs.default_probabilities,
            .factors = &test_factors,
            .has_y2 = has_y2,
            .skip = false,
        };
        _ = decodeMacroblock(&reader, options, &left, &above, &coefficients) catch return;
        has_y2 = !has_y2;
    }
}

// Identity dequant: with every factor 1, decodeBlock stores the transmitted
// level unchanged, so a writeBlock/decodeBlock round-trip recovers the exact
// raster levels and pins the production writer against the decoder.
const unit_factors = quant.Factors{
    .y1_dc = 1,
    .y1_ac = 1,
    .y2_dc = 1,
    .y2_ac = 1,
    .uv_dc = 1,
    .uv_ac = 1,
};

fn testLevelsRoundTrip(
    plane: usize,
    first_context: u2,
    first_position: u8,
    levels: [coefficient_count]i16,
    expected_last: u8,
) !void {
    const probabilities = &token_probs.default_probabilities[plane];

    var buffer: [256]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&buffer);
    const written_last = try writeBlock(&writer, probabilities, first_context, first_position, &levels);
    try writer.writeLiteral(0x9, 4); // Sentinel.
    const encoded = try writer.finish();

    var reader = bool_reader.BoolReader.init(encoded);
    var decoded: [coefficient_count]i16 = @splat(0);
    const decoded_last = try decodeBlock(&reader, probabilities, first_context, first_position, .{ 1, 1 }, &decoded);

    try std.testing.expectEqual(expected_last, written_last);
    try std.testing.expectEqual(expected_last, decoded_last);

    // The DC (raster 0) is never transmitted when first_position == 1.
    var expected = levels;
    if (first_position == 1) expected[0] = 0;
    try std.testing.expectEqual(expected, decoded);
    try std.testing.expectEqual(@as(u32, 0x9), try reader.readLiteral(4));
}

test "writeBlock round-trips raster levels through decodeBlock" {
    // Empty blocks: immediate EOB ends at the first position.
    try testLevelsRoundTrip(plane_y_no_y2, 0, 0, @splat(0), 0);
    try testLevelsRoundTrip(plane_y_after_y2, 2, 1, @splat(0), 1);

    // DC plus a couple of AC coefficients (trailing zeros dropped).
    var small: [coefficient_count]i16 = @splat(0);
    small[zigzag[0]] = 3;
    small[zigzag[1]] = -2;
    small[zigzag[2]] = 1;
    try testLevelsRoundTrip(plane_y_no_y2, 0, 0, small, 3);

    // Interior zeros are coded; only the trailing run is dropped.
    var gapped: [coefficient_count]i16 = @splat(0);
    gapped[zigzag[0]] = 5;
    gapped[zigzag[4]] = -7;
    try testLevelsRoundTrip(plane_y_no_y2, 1, 0, gapped, 5);

    // A nonzero at the final scan position drives last_position to 16 with no
    // terminating EOB.
    var full: [coefficient_count]i16 = @splat(0);
    full[zigzag[15]] = 9;
    try testLevelsRoundTrip(plane_chroma, 0, 0, full, 16);

    // first_position == 1 ignores the DC slot entirely.
    var after_y2: [coefficient_count]i16 = @splat(0);
    after_y2[zigzag[0]] = 99; // dropped (DC lives in Y2)
    after_y2[zigzag[1]] = -4;
    try testLevelsRoundTrip(plane_y_after_y2, 1, 1, after_y2, 2);
}

test "writeMacroblock round-trips raster levels through decodeMacroblock" {
    const options = MacroblockOptions{
        .probabilities = &token_probs.default_probabilities,
        .factors = &unit_factors,
        .has_y2 = true,
        .skip = false,
    };

    var levels = MacroblockLevels{};
    // Y2 DC and one AC.
    levels.y2[zigzag[0]] = -6;
    levels.y2[zigzag[1]] = 2;
    // Luma blocks carry AC only (DC routed through Y2): leave raster slot 0 at 0.
    levels.luma[0][zigzag[1]] = 4;
    levels.luma[0][zigzag[2]] = -1;
    levels.luma[5][zigzag[3]] = 7;
    levels.luma[15][zigzag[2]] = -35;
    levels.chroma_u[0][zigzag[0]] = -1;
    levels.chroma_v[2][zigzag[0]] = 19;

    var buffer: [2048]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&buffer);
    var write_left = NonzeroFlags.zero;
    var write_above = NonzeroFlags.zero;
    const wrote_nonzero = try writeMacroblock(&writer, options, &write_left, &write_above, &levels);
    try writer.writeLiteral(0x6, 4);
    const encoded = try writer.finish();

    var reader = bool_reader.BoolReader.init(encoded);
    var read_left = NonzeroFlags.zero;
    var read_above = NonzeroFlags.zero;
    var decoded: MacroblockCoefficients = undefined;
    const read_nonzero = try decodeMacroblock(&reader, options, &read_left, &read_above, &decoded);

    try std.testing.expect(wrote_nonzero);
    try std.testing.expectEqual(wrote_nonzero, read_nonzero);

    // Identity dequant: decoded coefficients equal the transmitted levels.
    try std.testing.expectEqual(levels.y2, decoded.y2.coefficients);
    for (0..luma_block_count) |k| {
        var expected = levels.luma[k];
        expected[0] = 0; // luma DC never transmitted under Y2
        try std.testing.expectEqual(expected, decoded.luma[k].coefficients);
    }
    try std.testing.expectEqual(levels.chroma_u[0], decoded.chroma_u[0].coefficients);
    try std.testing.expectEqual(levels.chroma_v[2], decoded.chroma_v[2].coefficients);

    // The encode and decode passes must derive identical nonzero contexts.
    try std.testing.expectEqual(read_left, write_left);
    try std.testing.expectEqual(read_above, write_above);
    try std.testing.expectEqual(@as(u32, 0x6), try reader.readLiteral(4));
}

test "blockCost mirrors token structure and grows with coefficient magnitude" {
    const probs = &token_probs.default_probabilities[plane_y_no_y2];

    var empty: [coefficient_count]i16 = @splat(0);
    var one: [coefficient_count]i16 = @splat(0);
    one[0] = 1;
    var big: [coefficient_count]i16 = @splat(0);
    big[0] = 100;
    var many: [coefficient_count]i16 = @splat(3);

    const c_empty = blockCost(probs, 0, 0, &empty);
    const c_one = blockCost(probs, 0, 0, &one);
    const c_big = blockCost(probs, 0, 0, &big);
    const c_many = blockCost(probs, 0, 0, &many);

    // An empty block is exactly one end-of-block boolean at band 0, context 0.
    try std.testing.expectEqual(cost.boolCost(probs[0][0][0], 0), c_empty);
    // Any coefficient costs more; a larger one costs more than a unit one; a
    // full block of coefficients costs most.
    try std.testing.expect(c_empty < c_one);
    try std.testing.expect(c_one < c_big);
    try std.testing.expect(c_big < c_many);

    // first_position 1 (luma after Y2) skips the DC position entirely, so a
    // block whose only nonzero is at raster position 0 costs just an EOB — and
    // that EOB is read at band coefficient_bands[1], not band 0.
    try std.testing.expectEqual(
        cost.boolCost(probs[coefficient_bands[1]][0][0], 0),
        blockCost(probs, 0, 1, &one),
    );
}
