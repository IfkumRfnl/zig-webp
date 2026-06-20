//! VP8 lossy encoder — step 8b-1 intra mode decision.
//!
//! Produces a valid `VP8 ` key-frame bitstream from source YUV 4:2:0 planes.
//! Each macroblock now picks its 16x16 luma mode (DC/V/H/TM) and its shared 8x8
//! chroma mode (DC/V/H/TM) by a rate-distortion score — reconstruction SSE plus
//! a quantizer-scaled penalty on coded coefficients — instead of the step 8a
//! all-DC default. B_PRED (per-subblock 4x4 luma intra) stays out until step
//! 8b-2; segmentation, skip decisions, and the loop filter are off; coefficient
//! probabilities stay at the RFC defaults; and there is a single token
//! partition.
//!
//! Correctness rests on one invariant (see PLAN.MD step 8a): the encoder
//! reconstructs each macroblock by feeding its own quantized levels back through
//! the *same* inverse routines the decoder uses (`quant.dequantize`,
//! `transform.inverseWalshHadamard`, `transform.addInverseDct`) over neighbors
//! it has already reconstructed, then emits exactly those levels. A conforming
//! decoder therefore reproduces the stored reconstruction bit-for-bit, because
//! both sides run identical math on identical inputs. The forward transform,
//! quantizer, and mode decision only affect quality, never this
//! self-consistency — which is why the encoder gathers prediction neighbors the
//! way the decoder does, including the synthetic above-left corner.

const std = @import("std");
const assert = std.debug.assert;

const bool_writer = @import("bool_writer.zig");
const color = @import("../color.zig");
const errors = @import("../errors.zig");
const forward_transform = @import("forward_transform.zig");
const frame_header = @import("frame_header.zig");
const image = @import("../image.zig");
const modes = @import("modes.zig");
const prediction = @import("prediction.zig");
const quant = @import("quant.zig");
const token_probs = @import("token_probs.zig");
const tokens = @import("tokens.zig");
const transform = @import("transform.zig");

pub const Error = errors.Error;

const luma_block = color.luma_block; // 16
const chroma_block = color.chroma_block; // 8
const coeff_count = transform.coefficient_count; // 16
const luma_pixels = luma_block * luma_block; // 256
const chroma_pixels = chroma_block * chroma_block; // 64

/// Largest width or height a VP8 frame can encode (14-bit dimension field).
pub const dimension_max = frame_header.dimension_limit;

/// The output of one encode: the muxable raw `VP8 ` bitstream plus the encoder's
/// reconstructed planes — what a conforming decoder reproduces. The public
/// encode path discards the reconstruction; the round-trip tests compare it
/// against the decoder's output to enforce the step 8a self-consistency gate.
pub const Result = struct {
    bitstream: []u8,
    reconstruction: color.YuvPlanes,

    pub fn deinit(self: *Result, gpa: std.mem.Allocator) void {
        gpa.free(self.bitstream);
        self.reconstruction.deinit(gpa);
        self.* = undefined;
    }
};

/// Maximum bytes this encoder can have live at once while producing a frame for
/// `dimensions`, excluding the caller-owned source planes.
///
/// Real mode decision (step 8b) decides each macroblock's modes during the
/// reconstruction pass and writes partition 0 afterward, so the per-macroblock
/// mode records, the reconstruction planes, the token scratch, the above-edge
/// flags, partition 0, and the final bitstream are all reachable at once (each
/// is held by a `defer` until the function returns). The peak is their sum.
pub fn allocationBytesMax(dimensions: image.Dimensions) Error!u64 {
    const grid = modes.MacroblockGrid.init(dimensions);
    const mb_count = grid.macroblockCount();

    const partition0_bytes: u64 = @intCast(partition0Capacity(mb_count));
    const token_bytes: u64 = @intCast(tokenCapacity(mb_count));
    const bitstream_bytes = try bitstreamCapacity(mb_count);
    const macroblock_bytes = try elementByteCount(modes.Macroblock, mb_count);
    const reconstruction_bytes = try color.yuv420AllocationBytes(
        dimensions.width,
        dimensions.height,
    );
    const above_flags_bytes = try elementByteCount(tokens.NonzeroFlags, grid.columns);

    var peak = macroblock_bytes;
    peak = try addByteCounts(peak, reconstruction_bytes);
    peak = try addByteCounts(peak, token_bytes);
    peak = try addByteCounts(peak, above_flags_bytes);
    peak = try addByteCounts(peak, partition0_bytes);
    peak = try addByteCounts(peak, bitstream_bytes);
    return peak;
}

/// Encodes macroblock-padded source YUV planes into a raw VP8 key-frame
/// bitstream. `base_quant_index` is the frame-wide AC quantizer index (0..127);
/// derive it from a quality knob with `quant.baseQuantIndexForQuality`.
pub fn encodeAlloc(
    gpa: std.mem.Allocator,
    source: *const color.YuvPlanes,
    base_quant_index: u8,
) Error!Result {
    assert(base_quant_index <= quant.index_max);

    const dimensions = image.Dimensions{ .width = source.width, .height = source.height };
    const grid = modes.MacroblockGrid.init(dimensions);
    const mb_count = grid.macroblockCount();

    const header = baselineHeader(dimensions, base_quant_index);
    // Segmentation is disabled, so every segment shares the frame-level factors.
    const factors = quant.segmentFactors(&header)[0];

    // --- Per-macroblock mode records, filled by the reconstruction pass below
    //     and written into partition 0 once every mode is decided.
    const macroblocks = try gpa.alloc(modes.Macroblock, mb_count);
    defer gpa.free(macroblocks);

    // --- Reconstruction planes (the encoder's running prediction context and
    //     the artifact the self-consistency gate checks).
    var reconstruction = try color.YuvPlanes.initAlloc(gpa, dimensions.width, dimensions.height);
    errdefer reconstruction.deinit(gpa);
    assert(source.luma_stride == reconstruction.luma_stride);
    assert(source.chroma_stride == reconstruction.chroma_stride);

    // --- Token partition: choose modes, reconstruct, and emit residual tokens
    //     per macroblock in raster order.
    const token_buffer = try gpa.alloc(u8, tokenCapacity(mb_count));
    defer gpa.free(token_buffer);
    var token_writer = bool_writer.BoolWriter.init(token_buffer);

    const above_flags = try gpa.alloc(tokens.NonzeroFlags, grid.columns);
    defer gpa.free(above_flags);
    @memset(above_flags, tokens.NonzeroFlags.zero);

    const token_options = tokens.MacroblockOptions{
        .probabilities = &header.coefficient_probabilities,
        .factors = &factors, // unused by writeMacroblock; levels are already quantized
        .has_y2 = true, // every 16x16 luma mode routes its DC through the Y2 block
        .skip = false,
    };

    var row: u32 = 0;
    while (row < grid.rows) : (row += 1) {
        var left_flags = tokens.NonzeroFlags.zero;
        var column: u32 = 0;
        while (column < grid.columns) : (column += 1) {
            var levels = tokens.MacroblockLevels{};
            const macroblock = &macroblocks[row * grid.columns + column];
            encodeMacroblock(source, &reconstruction, &factors, column, row, &levels, macroblock);
            _ = try tokens.writeMacroblock(
                &token_writer,
                token_options,
                &left_flags,
                &above_flags[column],
                &levels,
            );
        }
    }
    const token_bytes = try token_writer.finish();

    // --- Partition 0: compressed header followed by the per-macroblock modes
    //     decided above.
    const partition0 = try encodePartition0(gpa, &header, macroblocks, base_quant_index);
    defer gpa.free(partition0.buffer);
    if (partition0.bytes.len > frame_header.first_partition_size_max) {
        return error.FileTooLarge;
    }

    // --- Assemble: uncompressed 10-byte header, partition 0, token partition.
    const total = frame_header.header_byte_count + partition0.bytes.len + token_bytes.len;
    const bitstream = try gpa.alloc(u8, total);
    errdefer gpa.free(bitstream);

    frame_header.writeFrameTag(
        bitstream[0..frame_header.frame_tag_byte_count],
        @intCast(partition0.bytes.len),
    );
    frame_header.writePictureHeader(
        bitstream[frame_header.frame_tag_byte_count..frame_header.header_byte_count],
        @intCast(dimensions.width),
        @intCast(dimensions.height),
    );
    var offset: usize = frame_header.header_byte_count;
    @memcpy(bitstream[offset..][0..partition0.bytes.len], partition0.bytes);
    offset += partition0.bytes.len;
    @memcpy(bitstream[offset..][0..token_bytes.len], token_bytes);

    return .{ .bitstream = bitstream, .reconstruction = reconstruction };
}

const Partition0 = struct {
    buffer: []u8,
    bytes: []const u8,
};

fn encodePartition0(
    gpa: std.mem.Allocator,
    header: *const frame_header.Header,
    macroblocks: []const modes.Macroblock,
    base_quant_index: u8,
) Error!Partition0 {
    const buffer = try gpa.alloc(u8, partition0Capacity(@intCast(macroblocks.len)));
    errdefer gpa.free(buffer);
    var writer = bool_writer.BoolWriter.init(buffer);
    try frame_header.writeCompressedHeader(&writer, .{ .y_ac_quant_index = base_quant_index });
    try modes.encodeKeyFrameModes(&writer, header, macroblocks);
    return .{ .buffer = buffer, .bytes = try writer.finish() };
}

/// The fixed step 8a key-frame header: one segment, no loop filter, default
/// coefficient probabilities, skip disabled. Used for both the dequant factors
/// and the mode-record contexts, and kept consistent with the bits
/// `frame_header.writeCompressedHeader` emits.
fn baselineHeader(dimensions: image.Dimensions, base_quant_index: u8) frame_header.Header {
    return .{
        .tag = .{ .version = 0, .first_partition_size = 0 },
        .picture = .{ .dimensions = dimensions, .width_scale = 0, .height_scale = 0 },
        .color_space = 0,
        .clamping_type = 0,
        .segmentation = .disabled,
        .loop_filter = .{
            .simple = false,
            .level = 0,
            .sharpness = 0,
            .delta_enabled = false,
            .ref_frame_deltas = @splat(0),
            .mode_deltas = @splat(0),
        },
        .quant_indices = .{
            .y_ac_index = base_quant_index,
            .y_dc_delta = 0,
            .y2_dc_delta = 0,
            .y2_ac_delta = 0,
            .uv_dc_delta = 0,
            .uv_ac_delta = 0,
        },
        .refresh_entropy_probs = false,
        .coefficient_probabilities = token_probs.default_probabilities,
        .skip_enabled = false,
        .skip_probability = 0,
    };
}

// The intra modes the mode decision ranks. B_PRED (per-subblock 4x4 luma) is
// excluded until step 8b-2; the four 16x16/8x8 modes share the same RFC
// enumeration values for luma and chroma.
const luma_mode_candidates = [_]modes.LumaMode{ .dc, .vertical, .horizontal, .true_motion };
const chroma_mode_candidates = [_]modes.ChromaMode{ .dc, .vertical, .horizontal, .true_motion };

// Lagrange weight tying the coded-coefficient penalty to the quantizer: a
// coarser step (larger AC factor) makes each saved coefficient worth more
// distortion, so the decision drops marginal coefficients at low quality and
// keeps them at high quality. The multiplier was chosen by measuring size and
// luma PSNR over the encode corpus (see the step 8b-1 PROGRESS row).
const rd_rate_weight = 1;

fn lambdaFor(ac_factor: u16) u32 {
    return @as(u32, ac_factor) * rd_rate_weight;
}

/// Rate-distortion terms for one candidate reconstruction. `distortion` is the
/// sum of squared reconstruction errors over the block; `rate` is the count of
/// nonzero quantized coefficients, a cheap monotone proxy for coded token bits
/// (precise token costing is a later refinement).
const Rd = struct {
    distortion: u64,
    rate: u32,

    fn cost(self: Rd, lambda: u32) u64 {
        return self.distortion + @as(u64, lambda) * self.rate;
    }
};

/// Chooses each plane's intra mode, reconstructs the macroblock (into `recon`),
/// records the quantized levels, and writes the decided modes into `macroblock`.
/// Luma is committed before chroma, but the planes are independent.
fn encodeMacroblock(
    source: *const color.YuvPlanes,
    recon: *color.YuvPlanes,
    factors: *const quant.Factors,
    mb_column: u32,
    mb_row: u32,
    levels: *tokens.MacroblockLevels,
    macroblock: *modes.Macroblock,
) void {
    const luma_mode = selectLuma(source, recon, factors, mb_column, mb_row, levels);
    const chroma_mode = selectChroma(source, recon, factors, mb_column, mb_row, levels);
    macroblock.* = .{
        .segment_id = 0,
        .skip = false,
        .luma_mode = luma_mode,
        .chroma_mode = chroma_mode,
        // Non-B_PRED macroblocks contribute a single derived context mode to
        // their neighbors; `encodeKeyFrameModes` reads this for the B_PRED
        // probability contexts of later macroblocks.
        .subblock_modes = @splat(modes.derivedSubblockMode(luma_mode)),
    };
}

/// Gathers the above row, left column, and above-left corner for full-block
/// prediction, mirroring the decoder's bordered scratch (`decoder.Scratch`):
/// the synthetic 127 above the frame, 129 left of it, and — crucially — a
/// corner of 127 on the top macroblock row but 129 down the left edge below it.
/// Only TrueMotion reads the corner, which is why step 8a (DC-only) never
/// needed this distinction.
fn gatherFullBlockNeighbors(
    comptime size: u32,
    plane: []const u8,
    stride: usize,
    mb_x: usize,
    mb_y: usize,
    has_above: bool,
    has_left: bool,
    above: *[size]u8,
    left: *[size]u8,
    above_left: *u8,
) void {
    above.* = @splat(prediction.border_above);
    left.* = @splat(prediction.border_left);
    if (has_above) above.* = plane[(mb_y - 1) * stride + mb_x ..][0..size].*;
    if (has_left) {
        for (0..size) |r| left[r] = plane[(mb_y + r) * stride + mb_x - 1];
    }
    above_left.* = if (has_above and has_left)
        plane[(mb_y - 1) * stride + mb_x - 1]
    else if (!has_above)
        prediction.border_above
    else
        prediction.border_left;
}

fn lumaToChromaMode(mode: modes.LumaMode) modes.ChromaMode {
    assert(mode != .subblocks);
    return @enumFromInt(@intFromEnum(mode));
}

fn selectLuma(
    source: *const color.YuvPlanes,
    recon: *color.YuvPlanes,
    factors: *const quant.Factors,
    mb_column: u32,
    mb_row: u32,
    levels: *tokens.MacroblockLevels,
) modes.LumaMode {
    const stride = recon.luma_stride;
    const mb_x: usize = @as(usize, mb_column) * luma_block;
    const mb_y: usize = @as(usize, mb_row) * luma_block;
    const has_above = mb_row > 0;
    const has_left = mb_column > 0;
    const edges = prediction.EdgePresence{ .has_above = has_above, .has_left = has_left };

    var above: [luma_block]u8 = undefined;
    var left: [luma_block]u8 = undefined;
    var above_left: u8 = undefined;
    gatherFullBlockNeighbors(luma_block, recon.luma, stride, mb_x, mb_y, has_above, has_left, &above, &left, &above_left);

    // Tight copy of the source macroblock for residual and SSE; the planes are
    // macroblock-padded, so a full 16x16 always exists.
    var src: [luma_pixels]u8 = undefined;
    for (0..luma_block) |r| {
        src[r * luma_block ..][0..luma_block].* = source.luma[(mb_y + r) * stride + mb_x ..][0..luma_block].*;
    }

    const lambda = lambdaFor(factors.y1_ac);
    var best_cost: u64 = std.math.maxInt(u64);
    var best_mode: modes.LumaMode = .dc;
    var best_block: [luma_pixels]u8 = undefined;
    var best_luma: [luma_block][coeff_count]i16 = undefined;
    var best_y2: [coeff_count]i16 = undefined;

    for (luma_mode_candidates) |mode| {
        var block: [luma_pixels]u8 = undefined;
        var luma_levels: [luma_block][coeff_count]i16 = undefined;
        var y2_levels: [coeff_count]i16 = undefined;
        const rd = reconstructLuma16(
            lumaToChromaMode(mode),
            &src,
            &above,
            &left,
            above_left,
            edges,
            factors,
            &block,
            &luma_levels,
            &y2_levels,
        );
        const cost = rd.cost(lambda);
        if (cost < best_cost) {
            best_cost = cost;
            best_mode = mode;
            best_block = block;
            best_luma = luma_levels;
            best_y2 = y2_levels;
        }
    }

    for (0..luma_block) |r| {
        recon.luma[(mb_y + r) * stride + mb_x ..][0..luma_block].* = best_block[r * luma_block ..][0..luma_block].*;
    }
    levels.luma = best_luma;
    levels.y2 = best_y2;
    return best_mode;
}

/// Reconstructs one 16x16 luma macroblock for the given mode into the tight
/// `out_block` (stride `luma_block`) and returns its rate-distortion terms.
/// Mirrors the decoder: predict, forward-DCT each subblock, route the DCs
/// through the Y2 WHT, then dequantize and inverse-transform exactly the levels
/// it records, so a conforming decoder reproduces `out_block` bit-for-bit.
fn reconstructLuma16(
    mode: modes.ChromaMode,
    src: *const [luma_pixels]u8,
    above: *const [luma_block]u8,
    left: *const [luma_block]u8,
    above_left: u8,
    edges: prediction.EdgePresence,
    factors: *const quant.Factors,
    out_block: *[luma_pixels]u8,
    out_luma: *[luma_block][coeff_count]i16,
    out_y2: *[coeff_count]i16,
) Rd {
    prediction.predictFullBlock(luma_block, mode, above, left, above_left, edges, out_block, luma_block);

    var subblock_coeffs: [luma_block][coeff_count]i16 = undefined;
    var dcs: [coeff_count]i16 = undefined;
    for (0..luma_block) |sub| {
        const sub_x = (sub % 4) * 4;
        const sub_y = (sub / 4) * 4;
        var residual: [coeff_count]i16 = undefined;
        for (0..4) |r| {
            for (0..4) |c| {
                const idx = (sub_y + r) * luma_block + sub_x + c;
                residual[r * 4 + c] = @as(i16, src[idx]) - @as(i16, out_block[idx]);
            }
        }
        forward_transform.forwardDct(&residual, &subblock_coeffs[sub]);
        dcs[sub] = subblock_coeffs[sub][0];
    }

    // Y2: forward WHT, quantize, then dequant + inverse WHT back to the DCs the
    // decoder scatters into each luma block (NOT level*factor).
    var y2_coeffs: [coeff_count]i16 = undefined;
    forward_transform.forwardWalshHadamard(&dcs, &y2_coeffs);
    out_y2[0] = quant.quantizeCoefficient(y2_coeffs[0], factors.y2_dc);
    for (1..coeff_count) |p| out_y2[p] = quant.quantizeCoefficient(y2_coeffs[p], factors.y2_ac);

    var y2_dequant: [coeff_count]i16 = undefined;
    y2_dequant[0] = quant.dequantize(out_y2[0], factors.y2_dc);
    for (1..coeff_count) |p| y2_dequant[p] = quant.dequantize(out_y2[p], factors.y2_ac);
    var reconstructed_dcs: [coeff_count]i16 = undefined;
    transform.inverseWalshHadamard(&y2_dequant, &reconstructed_dcs);

    var rate: u32 = 0;
    for (out_y2) |level| {
        if (level != 0) rate += 1;
    }

    for (0..luma_block) |sub| {
        const sub_x = (sub % 4) * 4;
        const sub_y = (sub / 4) * 4;
        var level: [coeff_count]i16 = @splat(0); // position 0 is carried by Y2
        var dequant: [coeff_count]i16 = @splat(0);
        dequant[0] = reconstructed_dcs[sub];
        for (1..coeff_count) |p| {
            level[p] = quant.quantizeCoefficient(subblock_coeffs[sub][p], factors.y1_ac);
            dequant[p] = quant.dequantize(level[p], factors.y1_ac);
            if (level[p] != 0) rate += 1;
        }
        out_luma[sub] = level;
        // Skip the inverse DCT of an all-zero block exactly as the decoder does;
        // dequant[0] already carries the Y2-scattered DC.
        if (blockHasNonzero(&dequant)) {
            transform.addInverseDct(&dequant, out_block[sub_y * luma_block + sub_x ..], luma_block);
        }
    }

    return .{ .distortion = sumSquaredError(src, out_block), .rate = rate };
}

/// Chooses the single chroma mode shared by the U and V planes (RFC 11.4) by
/// scoring their combined rate-distortion, then commits both reconstructions.
fn selectChroma(
    source: *const color.YuvPlanes,
    recon: *color.YuvPlanes,
    factors: *const quant.Factors,
    mb_column: u32,
    mb_row: u32,
    levels: *tokens.MacroblockLevels,
) modes.ChromaMode {
    const stride = recon.chroma_stride;
    const mb_x: usize = @as(usize, mb_column) * chroma_block;
    const mb_y: usize = @as(usize, mb_row) * chroma_block;
    const has_above = mb_row > 0;
    const has_left = mb_column > 0;
    const edges = prediction.EdgePresence{ .has_above = has_above, .has_left = has_left };

    var u_above: [chroma_block]u8 = undefined;
    var u_left: [chroma_block]u8 = undefined;
    var u_corner: u8 = undefined;
    gatherFullBlockNeighbors(chroma_block, recon.chroma_u, stride, mb_x, mb_y, has_above, has_left, &u_above, &u_left, &u_corner);
    var v_above: [chroma_block]u8 = undefined;
    var v_left: [chroma_block]u8 = undefined;
    var v_corner: u8 = undefined;
    gatherFullBlockNeighbors(chroma_block, recon.chroma_v, stride, mb_x, mb_y, has_above, has_left, &v_above, &v_left, &v_corner);

    var u_src: [chroma_pixels]u8 = undefined;
    var v_src: [chroma_pixels]u8 = undefined;
    for (0..chroma_block) |r| {
        u_src[r * chroma_block ..][0..chroma_block].* = source.chroma_u[(mb_y + r) * stride + mb_x ..][0..chroma_block].*;
        v_src[r * chroma_block ..][0..chroma_block].* = source.chroma_v[(mb_y + r) * stride + mb_x ..][0..chroma_block].*;
    }

    const lambda = lambdaFor(factors.uv_ac);
    var best_cost: u64 = std.math.maxInt(u64);
    var best_mode: modes.ChromaMode = .dc;
    var best_u_block: [chroma_pixels]u8 = undefined;
    var best_v_block: [chroma_pixels]u8 = undefined;
    var best_u_levels: [tokens.chroma_block_count][coeff_count]i16 = undefined;
    var best_v_levels: [tokens.chroma_block_count][coeff_count]i16 = undefined;

    for (chroma_mode_candidates) |mode| {
        var u_block: [chroma_pixels]u8 = undefined;
        var v_block: [chroma_pixels]u8 = undefined;
        var u_levels: [tokens.chroma_block_count][coeff_count]i16 = undefined;
        var v_levels: [tokens.chroma_block_count][coeff_count]i16 = undefined;
        const rd_u = reconstructChroma8(mode, &u_src, &u_above, &u_left, u_corner, edges, factors.uv_dc, factors.uv_ac, &u_block, &u_levels);
        const rd_v = reconstructChroma8(mode, &v_src, &v_above, &v_left, v_corner, edges, factors.uv_dc, factors.uv_ac, &v_block, &v_levels);
        const combined = Rd{ .distortion = rd_u.distortion + rd_v.distortion, .rate = rd_u.rate + rd_v.rate };
        const cost = combined.cost(lambda);
        if (cost < best_cost) {
            best_cost = cost;
            best_mode = mode;
            best_u_block = u_block;
            best_v_block = v_block;
            best_u_levels = u_levels;
            best_v_levels = v_levels;
        }
    }

    for (0..chroma_block) |r| {
        recon.chroma_u[(mb_y + r) * stride + mb_x ..][0..chroma_block].* = best_u_block[r * chroma_block ..][0..chroma_block].*;
        recon.chroma_v[(mb_y + r) * stride + mb_x ..][0..chroma_block].* = best_v_block[r * chroma_block ..][0..chroma_block].*;
    }
    levels.chroma_u = best_u_levels;
    levels.chroma_v = best_v_levels;
    return best_mode;
}

/// Reconstructs one 8x8 chroma plane for the given mode into the tight
/// `out_block` (stride `chroma_block`) and returns its rate-distortion terms.
fn reconstructChroma8(
    mode: modes.ChromaMode,
    src: *const [chroma_pixels]u8,
    above: *const [chroma_block]u8,
    left: *const [chroma_block]u8,
    above_left: u8,
    edges: prediction.EdgePresence,
    dc_factor: u16,
    ac_factor: u16,
    out_block: *[chroma_pixels]u8,
    out_levels: *[tokens.chroma_block_count][coeff_count]i16,
) Rd {
    prediction.predictFullBlock(chroma_block, mode, above, left, above_left, edges, out_block, chroma_block);

    var rate: u32 = 0;
    for (0..tokens.chroma_block_count) |sub| {
        const sub_x = (sub % 2) * 4;
        const sub_y = (sub / 2) * 4;
        var residual: [coeff_count]i16 = undefined;
        for (0..4) |r| {
            for (0..4) |c| {
                const idx = (sub_y + r) * chroma_block + sub_x + c;
                residual[r * 4 + c] = @as(i16, src[idx]) - @as(i16, out_block[idx]);
            }
        }
        var coeffs: [coeff_count]i16 = undefined;
        forward_transform.forwardDct(&residual, &coeffs);

        var level: [coeff_count]i16 = @splat(0);
        var dequant: [coeff_count]i16 = @splat(0);
        level[0] = quant.quantizeCoefficient(coeffs[0], dc_factor);
        dequant[0] = quant.dequantize(level[0], dc_factor);
        for (1..coeff_count) |p| {
            level[p] = quant.quantizeCoefficient(coeffs[p], ac_factor);
            dequant[p] = quant.dequantize(level[p], ac_factor);
        }
        out_levels[sub] = level;
        for (level) |coded| {
            if (coded != 0) rate += 1;
        }
        // Same all-zero-block skip as the luma path and the decoder.
        if (blockHasNonzero(&dequant)) {
            transform.addInverseDct(&dequant, out_block[sub_y * chroma_block + sub_x ..], chroma_block);
        }
    }

    return .{ .distortion = sumSquaredError(src, out_block), .rate = rate };
}

/// Sum of squared per-pixel differences between two equal-length blocks.
fn sumSquaredError(source: []const u8, reconstruction: []const u8) u64 {
    assert(source.len == reconstruction.len);
    var sse: u64 = 0;
    for (source, reconstruction) |s, r| {
        const diff = @as(i32, s) - @as(i32, r);
        sse += @intCast(diff * diff);
    }
    return sse;
}

/// Whether any dequantized coefficient is nonzero. Mirrors the decoder's
/// `blockHasNonzero`: the inverse DCT of an all-zero block adds nothing, so
/// skipping it on both sides leaves the prediction untouched and keeps the
/// encoder's reconstruction bit-identical to the decoder's.
fn blockHasNonzero(coefficients: *const [coeff_count]i16) bool {
    for (coefficients) |coefficient| {
        if (coefficient != 0) return true;
    }
    return false;
}

fn bitstreamCapacity(mb_count: u32) Error!u64 {
    var bytes: u64 = frame_header.header_byte_count;
    bytes = try addByteCounts(bytes, @intCast(partition0Capacity(mb_count)));
    bytes = try addByteCounts(bytes, @intCast(tokenCapacity(mb_count)));
    return bytes;
}

fn elementByteCount(comptime T: type, count: u64) Error!u64 {
    if (count > std.math.maxInt(u64) / @sizeOf(T)) return error.AllocationLimitExceeded;
    return count * @sizeOf(T);
}

fn addByteCounts(a: u64, b: u64) Error!u64 {
    return std.math.add(u64, a, b) catch error.AllocationLimitExceeded;
}

// Worst-case scratch capacities for the boolean writers. These are temporary
// allocations, freed once the partition is finalized; tightening them (or
// streaming the output) is deferred to the step 10 performance work.
fn partition0Capacity(mb_count: u32) usize {
    // Fixed header is ~132 bytes; all-DC modes are well under a byte per MB.
    return 4096 + @as(usize, mb_count) * 2;
}

fn tokenCapacity(mb_count: u32) usize {
    // A macroblock has at most 25 coded blocks; this leaves generous slack over
    // the densest realistic per-macroblock token cost.
    return 4096 + @as(usize, mb_count) * 4096;
}

// --- Tests ------------------------------------------------------------------

const decoder = @import("decoder.zig");

// The step 8a self-consistency gate in miniature: the decoder must reproduce
// the encoder's own reconstruction byte-for-byte at the YUV layer, across clean
// and partial-macroblock geometries.
fn expectSelfConsistent(width: u32, height: u32) !void {
    const gpa = std.testing.allocator;

    const argb = try gpa.alloc(u32, @as(usize, width) * height);
    defer gpa.free(argb);
    for (0..height) |y| {
        for (0..width) |x| {
            const r: u32 = @intCast((x * 13 + y * 7) & 0xff);
            const g: u32 = @intCast((x * 5 + 30) & 0xff);
            const b: u32 = @intCast((y * 11 + 60) & 0xff);
            argb[y * width + x] = 0xff00_0000 | (r << 16) | (g << 8) | b;
        }
    }

    var source = try color.rgbaToYuv420Alloc(gpa, argb, width, height);
    defer source.deinit(gpa);

    var result = try encodeAlloc(gpa, &source, quant.baseQuantIndexForQuality(75));
    defer result.deinit(gpa);

    var frame = try decoder.decodeFrame(gpa, result.bitstream, .{ .apply_loop_filter = true });
    defer frame.deinit();

    try std.testing.expectEqual(width, frame.width);
    try std.testing.expectEqual(height, frame.height);
    try std.testing.expectEqualSlices(u8, result.reconstruction.luma, frame.luma);
    try std.testing.expectEqualSlices(u8, result.reconstruction.chroma_u, frame.chroma_u);
    try std.testing.expectEqualSlices(u8, result.reconstruction.chroma_v, frame.chroma_v);
}

test "encoder reconstruction matches the decoder byte-for-byte" {
    try expectSelfConsistent(16, 16); // one whole macroblock
    try expectSelfConsistent(17, 17); // 2x2 grid with partial macroblocks
    try expectSelfConsistent(1, 1); // single pixel, all edges synthetic
    try expectSelfConsistent(33, 18); // wide, asymmetric partials
    try expectSelfConsistent(64, 48); // multi-macroblock interior
    // One macroblock column: every macroblock below the top row is a
    // column-0/row>0 case, the only place the above-left corner is the
    // synthetic 129. A TrueMotion choice there would diverge if the encoder
    // gathered the wrong corner, so this pins the decoder-mirroring fix.
    try expectSelfConsistent(16, 64);
}

test "full-block neighbor gather mirrors the decoder's synthetic corner" {
    const stride = 48;
    var plane: [stride * 48]u8 = undefined;
    for (0..48) |y| {
        for (0..48) |x| plane[y * stride + x] = @intCast((x * 3 + y) & 0xff);
    }

    var above: [luma_block]u8 = undefined;
    var left: [luma_block]u8 = undefined;
    var corner: u8 = undefined;

    // Top-left macroblock: no real neighbors, so the corner is the synthetic
    // above border (127).
    gatherFullBlockNeighbors(luma_block, &plane, stride, 0, 0, false, false, &above, &left, &corner);
    try std.testing.expectEqual(@as(u8, prediction.border_above), corner);

    // Left edge below the top row: the corner is the synthetic left border
    // (129), not the above border the step 8a code used here.
    gatherFullBlockNeighbors(luma_block, &plane, stride, 0, luma_block, true, false, &above, &left, &corner);
    try std.testing.expectEqual(@as(u8, prediction.border_left), corner);

    // Interior: the corner is the real reconstructed pixel above and to the left.
    gatherFullBlockNeighbors(luma_block, &plane, stride, luma_block, luma_block, true, true, &above, &left, &corner);
    try std.testing.expectEqual(plane[(luma_block - 1) * stride + (luma_block - 1)], corner);
}

test "encoded baseline frame is a valid muxable VP8 bitstream" {
    const gpa = std.testing.allocator;
    const width = 20;
    const height = 12;

    const argb = try gpa.alloc(u32, width * height);
    defer gpa.free(argb);
    for (argb, 0..) |*p, i| p.* = 0xff00_0000 | @as(u32, @intCast(i * 7 % 256));

    var source = try color.rgbaToYuv420Alloc(gpa, argb, width, height);
    defer source.deinit(gpa);
    var result = try encodeAlloc(gpa, &source, quant.baseQuantIndexForQuality(50));
    defer result.deinit(gpa);

    // The header must parse and report the source dimensions.
    var parsed: frame_header.Parsed = undefined;
    try frame_header.parse(result.bitstream, &parsed);
    try std.testing.expectEqual(width, parsed.header.picture.dimensions.width);
    try std.testing.expectEqual(height, parsed.header.picture.dimensions.height);
    try std.testing.expectEqual(@as(u8, 1), parsed.token_partitions.count);
}
