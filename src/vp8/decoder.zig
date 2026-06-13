//! VP8 key-frame reconstruction (RFC 6386 sections 12 through 15).
//!
//! Orchestrates the already-implemented stages — frame header, prediction
//! records, per-segment dequantization, token decode, intra prediction, and
//! inverse transforms — into full-frame YUV reconstruction, then applies the
//! in-loop deblocking filter as a final pass (`loop_filter.zig`). Running the
//! filter strictly after whole-frame reconstruction is bit-identical to
//! libwebp's row pipeline because intra prediction only ever reads unfiltered
//! pixels (the above row is snapshotted before any filtering touches it).
//! Filtering can be disabled via `DecodeOptions` to match `dwebp -nofilter`.

const std = @import("std");
const assert = std.debug.assert;

const bool_reader = @import("bool_reader.zig");
const errors = @import("../errors.zig");
const frame_header = @import("frame_header.zig");
const loop_filter = @import("loop_filter.zig");
const modes = @import("modes.zig");
const prediction = @import("prediction.zig");
const quant = @import("quant.zig");
const tokens = @import("tokens.zig");
const transform = @import("transform.zig");

pub const Error = errors.Error;

/// Decode-time options for the VP8 reconstruction path.
pub const DecodeOptions = struct {
    /// Apply the RFC 6386 section 15 in-loop deblocking filter as a final
    /// pass. Set false for `dwebp -nofilter`-equivalent output.
    apply_loop_filter: bool,
};

pub const macroblock_size = 16;
pub const chroma_block_size = 8;

/// Reconstructed YUV 4:2:0 planes, padded to whole macroblocks. The
/// visible image is the top-left `width` x `height` region of `luma` and
/// the `chromaWidth()` x `chromaHeight()` regions of the chroma planes.
pub const Frame = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    luma_stride: u32,
    chroma_stride: u32,
    luma: []u8,
    chroma_u: []u8,
    chroma_v: []u8,

    pub fn deinit(self: *Frame) void {
        self.gpa.free(self.luma);
        self.gpa.free(self.chroma_u);
        self.gpa.free(self.chroma_v);
        self.* = undefined;
    }

    /// Chroma planes cover ceil(width/2) columns (RFC half-sample rule);
    /// floor would drop the edge column of odd-width images.
    pub fn chromaWidth(self: *const Frame) u32 {
        return (self.width + 1) / 2;
    }

    pub fn chromaHeight(self: *const Frame) u32 {
        return (self.height + 1) / 2;
    }
};

/// Decodes a complete `VP8 ` chunk payload (frame header through pixels).
pub fn decodeFrame(
    gpa: std.mem.Allocator,
    payload: []const u8,
    options: DecodeOptions,
) Error!Frame {
    var parsed: frame_header.Parsed = undefined;
    try frame_header.parse(payload, &parsed);
    return decodeFrameParsed(gpa, &parsed, options);
}

pub fn decodeFrameParsed(
    gpa: std.mem.Allocator,
    parsed: *frame_header.Parsed,
    options: DecodeOptions,
) Error!Frame {
    const header = &parsed.header;
    const grid = modes.MacroblockGrid.init(header.picture.dimensions);

    const macroblocks = try gpa.alloc(modes.Macroblock, grid.macroblockCount());
    defer gpa.free(macroblocks);
    try modes.parseKeyFrameModes(&parsed.macroblock_reader, header, macroblocks);

    const filter_type = if (options.apply_loop_filter)
        loop_filter.filterType(header)
    else
        loop_filter.Type.none;
    const will_filter = filter_type != .none;

    // Residual presence per macroblock feeds the loop filter's interior-edge
    // decision; only allocated when a filter pass will actually run.
    const has_nonzero: []bool = if (will_filter)
        try gpa.alloc(bool, grid.macroblockCount())
    else
        &.{};
    defer if (will_filter) gpa.free(has_nonzero);

    const factors = quant.segmentFactors(header);

    var partition_readers: [frame_header.token_partition_count_max]bool_reader.BoolReader =
        undefined;
    for (0..parsed.token_partitions.count) |index| {
        partition_readers[index] =
            bool_reader.BoolReader.init(parsed.token_partitions.slices[index]);
    }

    const above_flags = try gpa.alloc(tokens.NonzeroFlags, grid.columns);
    defer gpa.free(above_flags);
    @memset(above_flags, tokens.NonzeroFlags.zero);

    // Unfiltered bottom rows of the previous macroblock row, per column;
    // never read while reconstructing row 0.
    const top_samples = try gpa.alloc(TopSamples, grid.columns);
    defer gpa.free(top_samples);

    const luma_stride = grid.columns * macroblock_size;
    const chroma_stride = grid.columns * chroma_block_size;
    const luma = try gpa.alloc(u8, @as(usize, luma_stride) * grid.rows * macroblock_size);
    errdefer gpa.free(luma);
    const chroma_u = try gpa.alloc(u8, @as(usize, chroma_stride) * grid.rows * chroma_block_size);
    errdefer gpa.free(chroma_u);
    const chroma_v = try gpa.alloc(u8, @as(usize, chroma_stride) * grid.rows * chroma_block_size);
    errdefer gpa.free(chroma_v);

    var frame = Frame{
        .gpa = gpa,
        .width = header.picture.dimensions.width,
        .height = header.picture.dimensions.height,
        .luma_stride = luma_stride,
        .chroma_stride = chroma_stride,
        .luma = luma,
        .chroma_u = chroma_u,
        .chroma_v = chroma_v,
    };

    var scratch: Scratch = undefined;
    scratch.initFrameTopBorder();

    var coefficients: tokens.MacroblockCoefficients = undefined;
    var row: u32 = 0;
    while (row < grid.rows) : (row += 1) {
        const reader = &partition_readers[row % parsed.token_partitions.count];
        var left_flags = tokens.NonzeroFlags.zero;

        var column: u32 = 0;
        while (column < grid.columns) : (column += 1) {
            const macroblock = &macroblocks[row * grid.columns + column];
            const has_y2 = macroblock.luma_mode != .subblocks;
            const token_options = tokens.MacroblockOptions{
                .probabilities = &header.coefficient_probabilities,
                .factors = &factors[macroblock.segment_id],
                .has_y2 = has_y2,
                .skip = header.skip_enabled and macroblock.skip,
            };
            const any_nonzero = try tokens.decodeMacroblock(
                reader,
                token_options,
                &left_flags,
                &above_flags[column],
                &coefficients,
            );
            if (will_filter) {
                has_nonzero[row * grid.columns + column] = any_nonzero;
            }

            if (has_y2) {
                // Scatter the inverse WHT of the Y2 block into the DC slot
                // of every luma block before any luma IDCT (RFC 14.2).
                var second_order: [16]i16 = undefined;
                transform.inverseWalshHadamard(&coefficients.y2.coefficients, &second_order);
                for (0..tokens.luma_block_count) |index| {
                    coefficients.luma[index].coefficients[0] = second_order[index];
                }
            }

            reconstructMacroblock(&scratch, .{
                .macroblock = macroblock,
                .coefficients = &coefficients,
                .column = column,
                .row = row,
                .columns = grid.columns,
                .top_samples = top_samples,
            });

            scratch.copyOut(&frame, column, row);
            scratch.stashTopSamples(&top_samples[column]);
        }
    }

    // The deblocking filter runs only after the whole frame is reconstructed
    // and every above-row snapshot has been taken from unfiltered pixels.
    if (will_filter) {
        const strengths = loop_filter.computeStrengths(header);
        loop_filter.applyFrame(.{
            .luma = frame.luma,
            .chroma_u = frame.chroma_u,
            .chroma_v = frame.chroma_v,
            .luma_stride = frame.luma_stride,
            .chroma_stride = frame.chroma_stride,
        }, grid, macroblocks, has_nonzero, &strengths, filter_type);
    }

    return frame;
}

const TopSamples = struct {
    luma: [macroblock_size]u8,
    chroma_u: [chroma_block_size]u8,
    chroma_v: [chroma_block_size]u8,
};

/// Bordered scratch macroblock: row -1 carries the above samples (or the
/// synthetic 127 border on the top row), column -1 the left samples (129
/// at the frame edge), and luma columns 16..19 of row -1 the fixed
/// top-right pixels for right-edge subblocks.
const Scratch = struct {
    const luma_stride = 32;
    const luma_margin = 8;
    const luma_rows = 1 + macroblock_size;
    const chroma_stride = 16;
    const chroma_margin = 4;
    const chroma_rows = 1 + chroma_block_size;

    luma: [luma_rows * luma_stride]u8,
    chroma_u: [chroma_rows * chroma_stride]u8,
    chroma_v: [chroma_rows * chroma_stride]u8,

    fn lumaIndex(block_row: i32, block_column: i32) usize {
        assert(block_row >= -1);
        assert(block_row < macroblock_size);
        assert(block_column >= -1);
        assert(block_column < luma_stride - luma_margin);
        return @intCast((block_row + 1) * luma_stride + block_column + luma_margin);
    }

    fn chromaIndex(block_row: i32, block_column: i32) usize {
        assert(block_row >= -1);
        assert(block_row < chroma_block_size);
        assert(block_column >= -1);
        assert(block_column < chroma_stride - chroma_margin);
        return @intCast((block_row + 1) * chroma_stride + block_column + chroma_margin);
    }

    /// Before the top macroblock row: every above sample (including the
    /// corner and the top-right extension) is the synthetic 127. Row -1 is
    /// never overwritten while reconstructing row 0, so this survives.
    fn initFrameTopBorder(self: *Scratch) void {
        @memset(self.luma[0..luma_stride], prediction.border_above);
        @memset(self.chroma_u[0..chroma_stride], prediction.border_above);
        @memset(self.chroma_v[0..chroma_stride], prediction.border_above);
    }

    /// At the start of each macroblock row: the left samples are the
    /// synthetic 129 and the above-left corner is 127 on the top row,
    /// 129 below it.
    fn initLeftBorder(self: *Scratch, row: u32) void {
        const corner: u8 = if (row == 0) prediction.border_above else prediction.border_left;
        self.luma[lumaIndex(-1, -1)] = corner;
        self.chroma_u[chromaIndex(-1, -1)] = corner;
        self.chroma_v[chromaIndex(-1, -1)] = corner;
        for (0..macroblock_size) |pixel_row| {
            self.luma[lumaIndex(@intCast(pixel_row), -1)] = prediction.border_left;
        }
        for (0..chroma_block_size) |pixel_row| {
            self.chroma_u[chromaIndex(@intCast(pixel_row), -1)] = prediction.border_left;
            self.chroma_v[chromaIndex(@intCast(pixel_row), -1)] = prediction.border_left;
        }
    }

    /// Between horizontally adjacent macroblocks: the new left samples are
    /// the previous macroblock's rightmost column, including row -1, which
    /// becomes the next macroblock's above-left corner.
    fn rotateLeft(self: *Scratch) void {
        var luma_row: i32 = -1;
        while (luma_row < macroblock_size) : (luma_row += 1) {
            self.luma[lumaIndex(luma_row, -1)] =
                self.luma[lumaIndex(luma_row, macroblock_size - 1)];
        }
        var chroma_row: i32 = -1;
        while (chroma_row < chroma_block_size) : (chroma_row += 1) {
            self.chroma_u[chromaIndex(chroma_row, -1)] =
                self.chroma_u[chromaIndex(chroma_row, chroma_block_size - 1)];
            self.chroma_v[chromaIndex(chroma_row, -1)] =
                self.chroma_v[chromaIndex(chroma_row, chroma_block_size - 1)];
        }
    }

    fn loadTopRow(self: *Scratch, samples: *const TopSamples) void {
        self.luma[lumaIndex(-1, 0)..][0..macroblock_size].* = samples.luma;
        self.chroma_u[chromaIndex(-1, 0)..][0..chroma_block_size].* = samples.chroma_u;
        self.chroma_v[chromaIndex(-1, 0)..][0..chroma_block_size].* = samples.chroma_v;
    }

    fn setTopRight(self: *Scratch, pixels: [4]u8) void {
        self.luma[lumaIndex(-1, macroblock_size)..][0..4].* = pixels;
    }

    fn copyOut(self: *const Scratch, frame: *Frame, column: u32, row: u32) void {
        for (0..macroblock_size) |pixel_row| {
            const source = self.luma[lumaIndex(@intCast(pixel_row), 0)..][0..macroblock_size];
            const offset = (@as(usize, row) * macroblock_size + pixel_row) * frame.luma_stride +
                @as(usize, column) * macroblock_size;
            frame.luma[offset..][0..macroblock_size].* = source.*;
        }
        for (0..chroma_block_size) |pixel_row| {
            const offset = (@as(usize, row) * chroma_block_size + pixel_row) *
                frame.chroma_stride + @as(usize, column) * chroma_block_size;
            frame.chroma_u[offset..][0..chroma_block_size].* =
                self.chroma_u[chromaIndex(@intCast(pixel_row), 0)..][0..chroma_block_size].*;
            frame.chroma_v[offset..][0..chroma_block_size].* =
                self.chroma_v[chromaIndex(@intCast(pixel_row), 0)..][0..chroma_block_size].*;
        }
    }

    /// Snapshot the unfiltered bottom rows for the next macroblock row;
    /// must run before any loop filtering ever touches these pixels.
    fn stashTopSamples(self: *const Scratch, samples: *TopSamples) void {
        samples.luma = self.luma[lumaIndex(macroblock_size - 1, 0)..][0..macroblock_size].*;
        samples.chroma_u =
            self.chroma_u[chromaIndex(chroma_block_size - 1, 0)..][0..chroma_block_size].*;
        samples.chroma_v =
            self.chroma_v[chromaIndex(chroma_block_size - 1, 0)..][0..chroma_block_size].*;
    }
};

const ReconstructContext = struct {
    macroblock: *const modes.Macroblock,
    coefficients: *const tokens.MacroblockCoefficients,
    column: u32,
    row: u32,
    columns: u32,
    top_samples: []const TopSamples,
};

fn reconstructMacroblock(scratch: *Scratch, context: ReconstructContext) void {
    // 1. Left samples: synthetic border at the frame edge, otherwise the
    // previous macroblock's right column (rotation precedes the top-row
    // load so the corner carries the old above-row pixel).
    if (context.column == 0) {
        scratch.initLeftBorder(context.row);
    } else {
        scratch.rotateLeft();
    }

    // 2. Above samples from the previous row's unfiltered snapshot; on the
    // top row the 127 border persists from frame start.
    if (context.row > 0) {
        scratch.loadTopRow(&context.top_samples[context.column]);
        scratch.setTopRight(topRightPixels(context));
    }

    // 3. Luma.
    if (context.macroblock.luma_mode == .subblocks) {
        reconstructSubblockLuma(scratch, context);
    } else {
        reconstructFullLuma(scratch, context);
    }

    // 4. Chroma: the same mode predicts both planes, then each plane adds
    // its four residual blocks.
    const edges = prediction.EdgePresence{
        .has_above = context.row > 0,
        .has_left = context.column > 0,
    };
    inline for (.{ "chroma_u", "chroma_v" }) |field| {
        const plane = &@field(scratch, field);
        var above: [chroma_block_size]u8 = undefined;
        var left: [chroma_block_size]u8 = undefined;
        for (0..chroma_block_size) |index| {
            above[index] = plane[Scratch.chromaIndex(-1, @intCast(index))];
            left[index] = plane[Scratch.chromaIndex(@intCast(index), -1)];
        }
        prediction.predictFullBlock(
            chroma_block_size,
            context.macroblock.chroma_mode,
            &above,
            &left,
            plane[Scratch.chromaIndex(-1, -1)],
            edges,
            plane[Scratch.chromaIndex(0, 0)..],
            Scratch.chroma_stride,
        );
        for (0..tokens.chroma_block_count) |index| {
            const block = &@field(context.coefficients, field)[index];
            if (!blockHasNonzero(&block.coefficients)) continue;
            const block_row: i32 = @intCast(4 * (index / 2));
            const block_column: i32 = @intCast(4 * (index % 2));
            transform.addInverseDct(
                &block.coefficients,
                plane[Scratch.chromaIndex(block_row, block_column)..],
                Scratch.chroma_stride,
            );
        }
    }
}

/// The four pixels above and to the right of the macroblock (luma row -1,
/// columns 16..19), read by right-edge subblocks: real above-right
/// neighbors when one exists, replicated corner pixel on the rightmost
/// column (RFC 12.3).
fn topRightPixels(context: ReconstructContext) [4]u8 {
    assert(context.row > 0);
    if (context.column == context.columns - 1) {
        return @splat(context.top_samples[context.column].luma[macroblock_size - 1]);
    }
    return context.top_samples[context.column + 1].luma[0..4].*;
}

fn reconstructFullLuma(scratch: *Scratch, context: ReconstructContext) void {
    assert(context.macroblock.luma_mode != .subblocks);
    // The 16x16 modes coincide with the chroma mode values (RFC order).
    const mode: modes.ChromaMode = @enumFromInt(@intFromEnum(context.macroblock.luma_mode));

    var above: [macroblock_size]u8 = undefined;
    var left: [macroblock_size]u8 = undefined;
    for (0..macroblock_size) |index| {
        above[index] = scratch.luma[Scratch.lumaIndex(-1, @intCast(index))];
        left[index] = scratch.luma[Scratch.lumaIndex(@intCast(index), -1)];
    }
    prediction.predictFullBlock(
        macroblock_size,
        mode,
        &above,
        &left,
        scratch.luma[Scratch.lumaIndex(-1, -1)],
        .{ .has_above = context.row > 0, .has_left = context.column > 0 },
        scratch.luma[Scratch.lumaIndex(0, 0)..],
        Scratch.luma_stride,
    );

    // Prediction strictly precedes every residual add; the nonzero test
    // runs after the Y2 scatter so DC-only blocks are not dropped.
    for (0..tokens.luma_block_count) |index| {
        const block = &context.coefficients.luma[index];
        if (!blockHasNonzero(&block.coefficients)) continue;
        addLumaResidual(scratch, index, block);
    }
}

fn reconstructSubblockLuma(scratch: *Scratch, context: ReconstructContext) void {
    for (0..tokens.luma_block_count) |index| {
        const sub_x: i32 = @intCast(index % 4);
        const sub_y: i32 = @intCast(index / 4);
        const above_row = 4 * sub_y - 1;

        var neighbors: prediction.SubblockNeighbors = undefined;
        neighbors.above_left = scratch.luma[Scratch.lumaIndex(above_row, 4 * sub_x - 1)];
        neighbors.above =
            scratch.luma[Scratch.lumaIndex(above_row, 4 * sub_x)..][0..4].*;
        neighbors.above_right = if (sub_x == 3)
            // Right-edge subblocks always read the fixed top-right of the
            // macroblock row, never in-macroblock pixels.
            scratch.luma[Scratch.lumaIndex(-1, macroblock_size)..][0..4].*
        else
            scratch.luma[Scratch.lumaIndex(above_row, 4 * sub_x + 4)..][0..4].*;
        for (0..4) |pixel_row| {
            neighbors.left[pixel_row] =
                scratch.luma[Scratch.lumaIndex(4 * sub_y + @as(i32, @intCast(pixel_row)), 4 * sub_x - 1)];
        }

        prediction.predictSubblock(
            context.macroblock.subblock_modes[index],
            &neighbors,
            scratch.luma[Scratch.lumaIndex(4 * sub_y, 4 * sub_x)..],
            Scratch.luma_stride,
        );

        // The residual must land before the next subblock predicts from
        // these pixels.
        const block = &context.coefficients.luma[index];
        if (blockHasNonzero(&block.coefficients)) {
            addLumaResidual(scratch, index, block);
        }
    }
}

fn addLumaResidual(scratch: *Scratch, index: usize, block: *const tokens.Block) void {
    const block_row: i32 = @intCast(4 * (index / 4));
    const block_column: i32 = @intCast(4 * (index % 4));
    transform.addInverseDct(
        &block.coefficients,
        scratch.luma[Scratch.lumaIndex(block_row, block_column)..],
        Scratch.luma_stride,
    );
}

fn blockHasNonzero(coefficients: *const [tokens.coefficient_count]i16) bool {
    for (coefficients) |coefficient| {
        if (coefficient != 0) return true;
    }
    return false;
}

// --- Tests -------------------------------------------------------------

const bool_writer = @import("bool_writer.zig");
const token_probs = @import("token_probs.zig");

// Assembles a minimal valid key-frame payload whose macroblocks are all
// skipped (no residuals), so the reconstruction is pure prediction and the
// expected pixels are computable by hand.
fn assembleSkippedFramePayload(
    buffer: []u8,
    width: u16,
    height: u16,
    macroblock_count: u32,
    luma_mode_bits: []const u1,
) ![]const u8 {
    var compressed_buffer: [512]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&compressed_buffer);

    try writer.writeBit(0); // Color space.
    try writer.writeBit(0); // Clamping.
    try writer.writeBit(0); // Segmentation disabled.
    try writer.writeBit(0); // Normal loop filter.
    try writer.writeLiteral(0, 6); // Filter level 0.
    try writer.writeLiteral(0, 3); // Sharpness.
    try writer.writeBit(0); // No filter deltas.
    try writer.writeLiteral(0, 2); // One token partition.
    try writer.writeLiteral(0, 7); // y_ac quantizer index.
    try writer.writeBit(0); // No y_dc delta.
    try writer.writeBit(0); // No y2_dc delta.
    try writer.writeBit(0); // No y2_ac delta.
    try writer.writeBit(0); // No uv_dc delta.
    try writer.writeBit(0); // No uv_ac delta.
    try writer.writeBit(1); // refresh_entropy_probs.
    for (token_probs.update_probabilities) |plane| {
        for (plane) |band| {
            for (band) |context_probabilities| {
                for (context_probabilities) |update_probability| {
                    try writer.writeBool(update_probability, 0);
                }
            }
        }
    }
    try writer.writeBit(1); // mb_no_coeff_skip enabled.
    try writer.writeLiteral(128, 8); // Skip probability.

    // Per-macroblock records: skip flag = 1, a 16x16 luma mode, chroma dc.
    var mode_index: usize = 0;
    for (0..macroblock_count) |_| {
        try writer.writeBool(128, 1); // Skipped.
        // kf_ymode_tree: "10x" selects dc ("100") or vertical ("101").
        try writer.writeBool(145, 1);
        try writer.writeBool(156, 0);
        try writer.writeBool(163, luma_mode_bits[mode_index]);
        mode_index += 1;
        try writer.writeBool(142, 0); // Chroma dc.
    }
    const compressed = try writer.finish();

    const header_bytes = frame_header.header_byte_count;
    const total = header_bytes + compressed.len + 1;
    assert(buffer.len >= total);

    // Frame tag: key frame, version 0, show_frame, first partition size.
    const tag_bits = (@as(u32, 1) << 4) | (@as(u32, @intCast(compressed.len)) << 5);
    buffer[0] = @truncate(tag_bits);
    buffer[1] = @truncate(tag_bits >> 8);
    buffer[2] = @truncate(tag_bits >> 16);
    buffer[3..6].* = frame_header.start_code;
    buffer[6] = @truncate(width);
    buffer[7] = @truncate(width >> 8);
    buffer[8] = @truncate(height);
    buffer[9] = @truncate(height >> 8);
    @memcpy(buffer[header_bytes..][0..compressed.len], compressed);
    buffer[header_bytes + compressed.len] = 0; // One-byte token partition.

    return buffer[0..total];
}

test "reconstructs a skipped DC-mode frame as flat 128" {
    var payload_buffer: [600]u8 = undefined;
    const payload = try assembleSkippedFramePayload(&payload_buffer, 16, 16, 1, &.{0});

    var frame = try decodeFrame(std.testing.allocator, payload, .{ .apply_loop_filter = true });
    defer frame.deinit();

    try std.testing.expectEqual(@as(u32, 16), frame.width);
    try std.testing.expectEqual(@as(u32, 16), frame.height);
    // DC with no neighbors predicts 128 for luma and both chroma planes.
    for (frame.luma) |pixel| try std.testing.expectEqual(@as(u8, 128), pixel);
    for (frame.chroma_u) |pixel| try std.testing.expectEqual(@as(u8, 128), pixel);
    for (frame.chroma_v) |pixel| try std.testing.expectEqual(@as(u8, 128), pixel);
}

test "reconstructs neighbor-fed prediction across macroblocks" {
    // 32x16: MB0 is dc (flat 128), MB1 is vertical. MB1's above row is the
    // synthetic 127 border, so its luma is flat 127 while its chroma (dc
    // with a left neighbor only) averages MB0's 128 column.
    var payload_buffer: [600]u8 = undefined;
    const payload = try assembleSkippedFramePayload(&payload_buffer, 32, 16, 2, &.{ 0, 1 });

    var frame = try decodeFrame(std.testing.allocator, payload, .{ .apply_loop_filter = true });
    defer frame.deinit();

    for (0..16) |row| {
        for (0..16) |column| {
            try std.testing.expectEqual(
                @as(u8, 128),
                frame.luma[row * frame.luma_stride + column],
            );
            try std.testing.expectEqual(
                @as(u8, 127),
                frame.luma[row * frame.luma_stride + 16 + column],
            );
        }
    }
    // MB1 chroma: dc-no-above variant averages the left column (all 128).
    for (0..8) |row| {
        try std.testing.expectEqual(
            @as(u8, 128),
            frame.chroma_u[row * frame.chroma_stride + 8],
        );
    }
}

test "fuzz VP8 frame reconstruction" {
    const testing_fuzz = @import("../testing/fuzz.zig");

    var payload_buffer: [600]u8 = undefined;
    const seed_payload = try assembleSkippedFramePayload(&payload_buffer, 32, 32, 4, &.{ 0, 1, 1, 0 });

    var seed_buffer: [700]u8 = undefined;
    const seed = testing_fuzz.sliceCorpusEntry(&seed_buffer, seed_payload);

    try std.testing.fuzz({}, fuzzDecodeOne, .{ .corpus = &.{seed} });
}

fn fuzzDecodeOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [4096]u8 = undefined;
    const input_len = smith.slice(&input_buffer);

    var parsed: frame_header.Parsed = undefined;
    frame_header.parse(input_buffer[0..input_len], &parsed) catch return;
    // Keep hostile dimensions from ballooning the fuzz iteration.
    const grid = modes.MacroblockGrid.init(parsed.header.picture.dimensions);
    if (grid.macroblockCount() > 64) return;

    var frame = decodeFrameParsed(std.testing.allocator, &parsed, .{
        .apply_loop_filter = true,
    }) catch return;
    frame.deinit();
}
