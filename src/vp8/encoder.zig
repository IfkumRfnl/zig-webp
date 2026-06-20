//! VP8 lossy encoder — step 8a valid-bitstream baseline.
//!
//! Produces a valid `VP8 ` key-frame bitstream from source YUV 4:2:0 planes
//! with a deliberately fixed mode decision: every macroblock uses 16x16 DC luma
//! prediction and 8x8 DC chroma prediction, segmentation and the loop filter
//! are off, coefficient probabilities stay at the RFC defaults, and there is a
//! single token partition. Real mode decision, rate-distortion, and the loop
//! filter are step 8b; alpha and presets are step 8c.
//!
//! Correctness rests on one invariant (see PLAN.MD step 8a): the encoder
//! reconstructs each macroblock by feeding its own quantized levels back through
//! the *same* inverse routines the decoder uses (`quant.dequantize`,
//! `transform.inverseWalshHadamard`, `transform.addInverseDct`) over neighbors
//! it has already reconstructed, then emits exactly those levels. A conforming
//! decoder therefore reproduces the stored reconstruction bit-for-bit, because
//! both sides run identical math on identical inputs. The forward transform and
//! quantizer only affect quality, never this self-consistency.

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

    const partition0_peak = try addByteCounts(macroblock_bytes, partition0_bytes);

    var encode_peak = partition0_bytes;
    encode_peak = try addByteCounts(encode_peak, reconstruction_bytes);
    encode_peak = try addByteCounts(encode_peak, token_bytes);
    encode_peak = try addByteCounts(encode_peak, above_flags_bytes);
    encode_peak = try addByteCounts(encode_peak, bitstream_bytes);

    if (encode_peak > partition0_peak) return encode_peak;
    return partition0_peak;
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

    // --- Partition 0: compressed header followed by the per-macroblock modes.
    const partition0 = try encodePartition0(gpa, &header, mb_count, base_quant_index);
    defer gpa.free(partition0.buffer);
    if (partition0.bytes.len > frame_header.first_partition_size_max) {
        return error.FileTooLarge;
    }

    // --- Reconstruction planes (the encoder's running prediction context and
    //     the artifact the self-consistency gate checks).
    var reconstruction = try color.YuvPlanes.initAlloc(gpa, dimensions.width, dimensions.height);
    errdefer reconstruction.deinit(gpa);
    assert(source.luma_stride == reconstruction.luma_stride);
    assert(source.chroma_stride == reconstruction.chroma_stride);

    // --- Token partition: reconstruct and emit residual tokens per macroblock.
    const token_buffer = try gpa.alloc(u8, tokenCapacity(mb_count));
    defer gpa.free(token_buffer);
    var token_writer = bool_writer.BoolWriter.init(token_buffer);

    const above_flags = try gpa.alloc(tokens.NonzeroFlags, grid.columns);
    defer gpa.free(above_flags);
    @memset(above_flags, tokens.NonzeroFlags.zero);

    const token_options = tokens.MacroblockOptions{
        .probabilities = &header.coefficient_probabilities,
        .factors = &factors, // unused by writeMacroblock; levels are already quantized
        .has_y2 = true, // 16x16 luma routes its DC through the Y2 block
        .skip = false,
    };

    var row: u32 = 0;
    while (row < grid.rows) : (row += 1) {
        var left_flags = tokens.NonzeroFlags.zero;
        var column: u32 = 0;
        while (column < grid.columns) : (column += 1) {
            var levels = tokens.MacroblockLevels{};
            encodeMacroblock(source, &reconstruction, &factors, column, row, &levels);
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
    mb_count: u32,
    base_quant_index: u8,
) Error!Partition0 {
    const macroblocks = try gpa.alloc(modes.Macroblock, mb_count);
    defer gpa.free(macroblocks);
    for (macroblocks) |*macroblock| macroblock.* = .{
        .segment_id = 0,
        .skip = false,
        .luma_mode = .dc,
        .chroma_mode = .dc,
        .subblock_modes = @splat(.dc),
    };

    const buffer = try gpa.alloc(u8, partition0Capacity(mb_count));
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

/// Predicts, transforms, quantizes, reconstructs (into `recon`), and records the
/// quantized levels for one macroblock at grid position (`mb_column`, `mb_row`).
fn encodeMacroblock(
    source: *const color.YuvPlanes,
    recon: *color.YuvPlanes,
    factors: *const quant.Factors,
    mb_column: u32,
    mb_row: u32,
    levels: *tokens.MacroblockLevels,
) void {
    encodeLuma(source, recon, factors, mb_column, mb_row, levels);
    encodeChromaPlane(
        source.chroma_u,
        recon.chroma_u,
        recon.chroma_stride,
        factors.uv_dc,
        factors.uv_ac,
        mb_column,
        mb_row,
        &levels.chroma_u,
    );
    encodeChromaPlane(
        source.chroma_v,
        recon.chroma_v,
        recon.chroma_stride,
        factors.uv_dc,
        factors.uv_ac,
        mb_column,
        mb_row,
        &levels.chroma_v,
    );
}

fn encodeLuma(
    source: *const color.YuvPlanes,
    recon: *color.YuvPlanes,
    factors: *const quant.Factors,
    mb_column: u32,
    mb_row: u32,
    levels: *tokens.MacroblockLevels,
) void {
    const stride = recon.luma_stride;
    const mb_x: usize = @as(usize, mb_column) * luma_block;
    const mb_y: usize = @as(usize, mb_row) * luma_block;
    const origin = mb_y * stride + mb_x;
    const has_above = mb_row > 0;
    const has_left = mb_column > 0;

    // 1. DC-predict the whole 16x16 block from already-reconstructed neighbors.
    //    DC ignores absent edges via EdgePresence, so the dummy fill is unread.
    var above: [luma_block]u8 = @splat(127);
    var left: [luma_block]u8 = @splat(129);
    var above_left: u8 = 127;
    if (has_above) above = recon.luma[(mb_y - 1) * stride + mb_x ..][0..luma_block].*;
    if (has_left) {
        for (0..luma_block) |r| left[r] = recon.luma[(mb_y + r) * stride + mb_x - 1];
    }
    if (has_above and has_left) above_left = recon.luma[(mb_y - 1) * stride + mb_x - 1];
    prediction.predictFullBlock(
        luma_block,
        .dc,
        &above,
        &left,
        above_left,
        .{ .has_above = has_above, .has_left = has_left },
        recon.luma[origin..],
        @intCast(stride),
    );

    // 2. Forward-DCT each subblock residual; collect the 16 DC coefficients.
    var subblock_coeffs: [luma_block][coeff_count]i16 = undefined;
    var dcs: [coeff_count]i16 = undefined;
    for (0..luma_block) |sub| {
        const sub_x = (sub % 4) * 4;
        const sub_y = (sub / 4) * 4;
        var residual: [coeff_count]i16 = undefined;
        for (0..4) |r| {
            for (0..4) |c| {
                const idx = (mb_y + sub_y + r) * stride + mb_x + sub_x + c;
                residual[r * 4 + c] = @as(i16, source.luma[idx]) - @as(i16, recon.luma[idx]);
            }
        }
        forward_transform.forwardDct(&residual, &subblock_coeffs[sub]);
        dcs[sub] = subblock_coeffs[sub][0];
    }

    // 3. Y2: forward WHT, quantize, then dequant + inverse WHT back to the DCs
    //    the decoder will scatter into each luma block (NOT level*factor).
    var y2_coeffs: [coeff_count]i16 = undefined;
    forward_transform.forwardWalshHadamard(&dcs, &y2_coeffs);
    levels.y2[0] = quant.quantizeCoefficient(y2_coeffs[0], factors.y2_dc);
    for (1..coeff_count) |p| levels.y2[p] = quant.quantizeCoefficient(y2_coeffs[p], factors.y2_ac);

    var y2_dequant: [coeff_count]i16 = undefined;
    y2_dequant[0] = quant.dequantize(levels.y2[0], factors.y2_dc);
    for (1..coeff_count) |p| y2_dequant[p] = quant.dequantize(levels.y2[p], factors.y2_ac);
    var reconstructed_dcs: [coeff_count]i16 = undefined;
    transform.inverseWalshHadamard(&y2_dequant, &reconstructed_dcs);

    // 4. Quantize each block's AC, rebuild the dequantized block with the
    //    scattered DC at position 0, and add the inverse DCT to the prediction.
    for (0..luma_block) |sub| {
        const sub_x = (sub % 4) * 4;
        const sub_y = (sub / 4) * 4;
        var level: [coeff_count]i16 = @splat(0); // position 0 is carried by Y2
        var dequant: [coeff_count]i16 = @splat(0);
        dequant[0] = reconstructed_dcs[sub];
        for (1..coeff_count) |p| {
            level[p] = quant.quantizeCoefficient(subblock_coeffs[sub][p], factors.y1_ac);
            dequant[p] = quant.dequantize(level[p], factors.y1_ac);
        }
        levels.luma[sub] = level;
        // Skip the inverse DCT of an all-zero block exactly as the decoder does
        // (its residual is identically zero, leaving the prediction untouched);
        // dequant[0] already carries the Y2-scattered DC, so the test matches.
        if (blockHasNonzero(&dequant)) {
            const sub_origin = (mb_y + sub_y) * stride + mb_x + sub_x;
            transform.addInverseDct(&dequant, recon.luma[sub_origin..], @intCast(stride));
        }
    }
}

fn encodeChromaPlane(
    source: []const u8,
    recon: []u8,
    stride: usize,
    dc_factor: u16,
    ac_factor: u16,
    mb_column: u32,
    mb_row: u32,
    plane_levels: *[tokens.chroma_block_count][coeff_count]i16,
) void {
    const mb_x: usize = @as(usize, mb_column) * chroma_block;
    const mb_y: usize = @as(usize, mb_row) * chroma_block;
    const origin = mb_y * stride + mb_x;
    const has_above = mb_row > 0;
    const has_left = mb_column > 0;

    // 1. DC-predict the 8x8 block from reconstructed chroma neighbors.
    var above: [chroma_block]u8 = @splat(127);
    var left: [chroma_block]u8 = @splat(129);
    var above_left: u8 = 127;
    if (has_above) above = recon[(mb_y - 1) * stride + mb_x ..][0..chroma_block].*;
    if (has_left) {
        for (0..chroma_block) |r| left[r] = recon[(mb_y + r) * stride + mb_x - 1];
    }
    if (has_above and has_left) above_left = recon[(mb_y - 1) * stride + mb_x - 1];
    prediction.predictFullBlock(
        chroma_block,
        .dc,
        &above,
        &left,
        above_left,
        .{ .has_above = has_above, .has_left = has_left },
        recon[origin..],
        @intCast(stride),
    );

    // 2. Per 4x4 subblock: residual, forward DCT, quantize (DC + AC), then
    //    dequant + inverse DCT back onto the prediction.
    for (0..tokens.chroma_block_count) |sub| {
        const sub_x = (sub % 2) * 4;
        const sub_y = (sub / 2) * 4;
        var residual: [coeff_count]i16 = undefined;
        for (0..4) |r| {
            for (0..4) |c| {
                const idx = (mb_y + sub_y + r) * stride + mb_x + sub_x + c;
                residual[r * 4 + c] = @as(i16, source[idx]) - @as(i16, recon[idx]);
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
        plane_levels[sub] = level;
        // Same all-zero-block skip as the luma path and the decoder.
        if (blockHasNonzero(&dequant)) {
            const sub_origin = (mb_y + sub_y) * stride + mb_x + sub_x;
            transform.addInverseDct(&dequant, recon[sub_origin..], @intCast(stride));
        }
    }
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
