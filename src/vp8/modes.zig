//! VP8 key-frame macroblock prediction records (RFC 6386 sections 10 and 11).
//!
//! Decodes the per-macroblock segment ids, coefficient-skip flags, and intra
//! prediction modes that follow the compressed frame header in the first
//! partition, picking up exactly where the frame header parser leaves the
//! boolean reader. The mode trees and fixed key-frame probability tables are
//! transcribed from the normative RFC 6386 tables and were cross-checked
//! value-for-value against `references/libwebp` and `references/ffmpeg`
//! (both store the same values under permuted mode enumerations).

const std = @import("std");
const assert = std.debug.assert;

const bool_reader = @import("bool_reader.zig");
const errors = @import("../errors.zig");
const frame_header = @import("frame_header.zig");
const image = @import("../image.zig");

pub const Error = errors.Error;

pub const macroblock_size_pixels = 16;
pub const subblocks_per_edge = 4;
pub const subblock_count = subblocks_per_edge * subblocks_per_edge;
pub const luma_mode_count = 5;
pub const chroma_mode_count = 4;
pub const subblock_mode_count = 10;
pub const grid_columns_max =
    (frame_header.dimension_limit + macroblock_size_pixels - 1) / macroblock_size_pixels;

comptime {
    assert(subblock_count == 16);
    assert(grid_columns_max == 1024);
    // The picture header cannot describe a frame whose macroblock count
    // overflows the u32 arithmetic in MacroblockGrid.macroblockCount.
    assert(@as(u64, grid_columns_max) * grid_columns_max <= std.math.maxInt(u32));
}

/// RFC 6386 intra_mbmode, in normative enumeration order.
pub const LumaMode = enum(u8) {
    dc = 0,
    vertical = 1,
    horizontal = 2,
    true_motion = 3,
    /// B_PRED: every luma subblock carries its own SubblockMode.
    subblocks = 4,
};

/// RFC 6386 intra_mbmode restricted to the four chroma-capable modes.
pub const ChromaMode = enum(u8) {
    dc = 0,
    vertical = 1,
    horizontal = 2,
    true_motion = 3,
};

/// RFC 6386 intra_bmode, in normative enumeration order. The probability
/// tables below are indexed by these values, so the order is load-bearing.
pub const SubblockMode = enum(u8) {
    dc = 0,
    true_motion = 1,
    vertical = 2,
    horizontal = 3,
    left_down = 4,
    right_down = 5,
    vertical_right = 6,
    vertical_left = 7,
    horizontal_down = 8,
    horizontal_up = 9,
};

comptime {
    assert(@typeInfo(LumaMode).@"enum".fields.len == luma_mode_count);
    assert(@typeInfo(ChromaMode).@"enum".fields.len == chroma_mode_count);
    assert(@typeInfo(SubblockMode).@"enum".fields.len == subblock_mode_count);
}

// Tree leaves are negated enum values; the explicit `= N` enum declarations
// above pin the correspondence, and the implied codings are commented.

// RFC 6386 section 10: mb_segment_tree.
pub const segment_id_tree = [6]i8{
    2, 4, // root: "0x" and "1x" subtrees
    0, -1, // "00" = id 0, "01" = id 1
    -2, -3, // "10" = id 2, "11" = id 3
};

// RFC 6386 section 11.2: kf_ymode_tree and kf_ymode_prob.
pub const kf_luma_mode_tree = [2 * (luma_mode_count - 1)]i8{
    -4, 2, // "0" = subblocks (B_PRED)
    4, 6, // "10x" and "11x" subtrees
    0, -1, // "100" = dc, "101" = vertical
    -2, -3, // "110" = horizontal, "111" = true_motion
};
pub const kf_luma_mode_probabilities = [luma_mode_count - 1]u8{ 145, 156, 163, 128 };

// RFC 6386 section 11.4: uv_mode_tree and kf_uv_mode_prob.
pub const chroma_mode_tree = [2 * (chroma_mode_count - 1)]i8{
    0, 2, // "0" = dc
    -1, 4, // "10" = vertical
    -2, -3, // "110" = horizontal, "111" = true_motion
};
pub const kf_chroma_mode_probabilities = [chroma_mode_count - 1]u8{ 142, 114, 183 };

// RFC 6386 section 11.2: bmode_tree.
pub const subblock_mode_tree = [2 * (subblock_mode_count - 1)]i8{
    0, 2, // "0" = dc
    -1, 4, // "10" = true_motion
    -2, 6, // "110" = vertical
    8, 12, // "1110x" and "1111x" subtrees
    -3, 10, // "11100" = horizontal
    -5, -6, // "111010" = right_down, "111011" = vertical_right
    -4, 14, // "11110" = left_down
    -7, 16, // "111110" = vertical_left
    -8, -9, // "1111110" = horizontal_down, "1111111" = horizontal_up
};

// RFC 6386 section 11.5: kf_bmode_prob, indexed [above][left] by SubblockMode
// values, then by tree probability position.
pub const kf_subblock_mode_probabilities =
    [subblock_mode_count][subblock_mode_count][subblock_mode_count - 1]u8{
        .{
            .{ 231, 120, 48, 89, 115, 113, 120, 152, 112 },
            .{ 152, 179, 64, 126, 170, 118, 46, 70, 95 },
            .{ 175, 69, 143, 80, 85, 82, 72, 155, 103 },
            .{ 56, 58, 10, 171, 218, 189, 17, 13, 152 },
            .{ 144, 71, 10, 38, 171, 213, 144, 34, 26 },
            .{ 114, 26, 17, 163, 44, 195, 21, 10, 173 },
            .{ 121, 24, 80, 195, 26, 62, 44, 64, 85 },
            .{ 170, 46, 55, 19, 136, 160, 33, 206, 71 },
            .{ 63, 20, 8, 114, 114, 208, 12, 9, 226 },
            .{ 81, 40, 11, 96, 182, 84, 29, 16, 36 },
        },
        .{
            .{ 134, 183, 89, 137, 98, 101, 106, 165, 148 },
            .{ 72, 187, 100, 130, 157, 111, 32, 75, 80 },
            .{ 66, 102, 167, 99, 74, 62, 40, 234, 128 },
            .{ 41, 53, 9, 178, 241, 141, 26, 8, 107 },
            .{ 104, 79, 12, 27, 217, 255, 87, 17, 7 },
            .{ 74, 43, 26, 146, 73, 166, 49, 23, 157 },
            .{ 65, 38, 105, 160, 51, 52, 31, 115, 128 },
            .{ 87, 68, 71, 44, 114, 51, 15, 186, 23 },
            .{ 47, 41, 14, 110, 182, 183, 21, 17, 194 },
            .{ 66, 45, 25, 102, 197, 189, 23, 18, 22 },
        },
        .{
            .{ 88, 88, 147, 150, 42, 46, 45, 196, 205 },
            .{ 43, 97, 183, 117, 85, 38, 35, 179, 61 },
            .{ 39, 53, 200, 87, 26, 21, 43, 232, 171 },
            .{ 56, 34, 51, 104, 114, 102, 29, 93, 77 },
            .{ 107, 54, 32, 26, 51, 1, 81, 43, 31 },
            .{ 39, 28, 85, 171, 58, 165, 90, 98, 64 },
            .{ 34, 22, 116, 206, 23, 34, 43, 166, 73 },
            .{ 68, 25, 106, 22, 64, 171, 36, 225, 114 },
            .{ 34, 19, 21, 102, 132, 188, 16, 76, 124 },
            .{ 62, 18, 78, 95, 85, 57, 50, 48, 51 },
        },
        .{
            .{ 193, 101, 35, 159, 215, 111, 89, 46, 111 },
            .{ 60, 148, 31, 172, 219, 228, 21, 18, 111 },
            .{ 112, 113, 77, 85, 179, 255, 38, 120, 114 },
            .{ 40, 42, 1, 196, 245, 209, 10, 25, 109 },
            .{ 100, 80, 8, 43, 154, 1, 51, 26, 71 },
            .{ 88, 43, 29, 140, 166, 213, 37, 43, 154 },
            .{ 61, 63, 30, 155, 67, 45, 68, 1, 209 },
            .{ 142, 78, 78, 16, 255, 128, 34, 197, 171 },
            .{ 41, 40, 5, 102, 211, 183, 4, 1, 221 },
            .{ 51, 50, 17, 168, 209, 192, 23, 25, 82 },
        },
        .{
            .{ 125, 98, 42, 88, 104, 85, 117, 175, 82 },
            .{ 95, 84, 53, 89, 128, 100, 113, 101, 45 },
            .{ 75, 79, 123, 47, 51, 128, 81, 171, 1 },
            .{ 57, 17, 5, 71, 102, 57, 53, 41, 49 },
            .{ 115, 21, 2, 10, 102, 255, 166, 23, 6 },
            .{ 38, 33, 13, 121, 57, 73, 26, 1, 85 },
            .{ 41, 10, 67, 138, 77, 110, 90, 47, 114 },
            .{ 101, 29, 16, 10, 85, 128, 101, 196, 26 },
            .{ 57, 18, 10, 102, 102, 213, 34, 20, 43 },
            .{ 117, 20, 15, 36, 163, 128, 68, 1, 26 },
        },
        .{
            .{ 138, 31, 36, 171, 27, 166, 38, 44, 229 },
            .{ 67, 87, 58, 169, 82, 115, 26, 59, 179 },
            .{ 63, 59, 90, 180, 59, 166, 93, 73, 154 },
            .{ 40, 40, 21, 116, 143, 209, 34, 39, 175 },
            .{ 57, 46, 22, 24, 128, 1, 54, 17, 37 },
            .{ 47, 15, 16, 183, 34, 223, 49, 45, 183 },
            .{ 46, 17, 33, 183, 6, 98, 15, 32, 183 },
            .{ 65, 32, 73, 115, 28, 128, 23, 128, 205 },
            .{ 40, 3, 9, 115, 51, 192, 18, 6, 223 },
            .{ 87, 37, 9, 115, 59, 77, 64, 21, 47 },
        },
        .{
            .{ 104, 55, 44, 218, 9, 54, 53, 130, 226 },
            .{ 64, 90, 70, 205, 40, 41, 23, 26, 57 },
            .{ 54, 57, 112, 184, 5, 41, 38, 166, 213 },
            .{ 30, 34, 26, 133, 152, 116, 10, 32, 134 },
            .{ 75, 32, 12, 51, 192, 255, 160, 43, 51 },
            .{ 39, 19, 53, 221, 26, 114, 32, 73, 255 },
            .{ 31, 9, 65, 234, 2, 15, 1, 118, 73 },
            .{ 88, 31, 35, 67, 102, 85, 55, 186, 85 },
            .{ 56, 21, 23, 111, 59, 205, 45, 37, 192 },
            .{ 55, 38, 70, 124, 73, 102, 1, 34, 98 },
        },
        .{
            .{ 102, 61, 71, 37, 34, 53, 31, 243, 192 },
            .{ 69, 60, 71, 38, 73, 119, 28, 222, 37 },
            .{ 68, 45, 128, 34, 1, 47, 11, 245, 171 },
            .{ 62, 17, 19, 70, 146, 85, 55, 62, 70 },
            .{ 75, 15, 9, 9, 64, 255, 184, 119, 16 },
            .{ 37, 43, 37, 154, 100, 163, 85, 160, 1 },
            .{ 63, 9, 92, 136, 28, 64, 32, 201, 85 },
            .{ 86, 6, 28, 5, 64, 255, 25, 248, 1 },
            .{ 56, 8, 17, 132, 137, 255, 55, 116, 128 },
            .{ 58, 15, 20, 82, 135, 57, 26, 121, 40 },
        },
        .{
            .{ 164, 50, 31, 137, 154, 133, 25, 35, 218 },
            .{ 51, 103, 44, 131, 131, 123, 31, 6, 158 },
            .{ 86, 40, 64, 135, 148, 224, 45, 183, 128 },
            .{ 22, 26, 17, 131, 240, 154, 14, 1, 209 },
            .{ 83, 12, 13, 54, 192, 255, 68, 47, 28 },
            .{ 45, 16, 21, 91, 64, 222, 7, 1, 197 },
            .{ 56, 21, 39, 155, 60, 138, 23, 102, 213 },
            .{ 85, 26, 85, 85, 128, 128, 32, 146, 171 },
            .{ 18, 11, 7, 63, 144, 171, 4, 4, 246 },
            .{ 35, 27, 10, 146, 174, 171, 12, 26, 128 },
        },
        .{
            .{ 190, 80, 35, 99, 180, 80, 126, 54, 45 },
            .{ 85, 126, 47, 87, 176, 51, 41, 20, 32 },
            .{ 101, 75, 128, 139, 118, 146, 116, 128, 85 },
            .{ 56, 41, 15, 176, 236, 85, 37, 9, 62 },
            .{ 146, 36, 19, 30, 171, 255, 97, 27, 20 },
            .{ 71, 30, 17, 119, 118, 255, 17, 18, 138 },
            .{ 101, 38, 60, 138, 55, 70, 43, 26, 142 },
            .{ 138, 45, 61, 62, 219, 1, 81, 188, 64 },
            .{ 32, 41, 20, 117, 151, 142, 20, 21, 163 },
            .{ 112, 19, 12, 61, 195, 128, 48, 4, 24 },
        },
    };

comptime {
    // Spot anchors for the transcribed table: first and last probability rows
    // as printed in RFC 6386 section 11.5.
    assert(kf_subblock_mode_probabilities[0][0][0] == 231);
    assert(kf_subblock_mode_probabilities[0][0][8] == 112);
    assert(kf_subblock_mode_probabilities[9][9][0] == 112);
    assert(kf_subblock_mode_probabilities[9][9][8] == 24);
}

/// One decoded macroblock prediction record. For 16x16 luma modes the
/// subblock modes hold the derived context mode (RFC 6386 section 11.3,
/// caveat 4) replicated across all sixteen positions.
pub const Macroblock = struct {
    segment_id: u2,
    /// RFC 6386 mb_skip_coeff: true when the macroblock codes no residue.
    skip: bool,
    luma_mode: LumaMode,
    chroma_mode: ChromaMode,
    /// Luma subblock modes in raster order.
    subblock_modes: [subblock_count]SubblockMode,
};

pub const MacroblockGrid = struct {
    columns: u32,
    rows: u32,

    pub fn init(dimensions: image.Dimensions) MacroblockGrid {
        assert(dimensions.width >= 1);
        assert(dimensions.width <= frame_header.dimension_limit);
        assert(dimensions.height >= 1);
        assert(dimensions.height <= frame_header.dimension_limit);

        return .{
            .columns = divCeilPixels(dimensions.width),
            .rows = divCeilPixels(dimensions.height),
        };
    }

    pub fn macroblockCount(self: MacroblockGrid) u32 {
        assert(self.columns >= 1);
        assert(self.columns <= grid_columns_max);
        assert(self.rows >= 1);
        assert(self.rows <= grid_columns_max);

        return self.columns * self.rows;
    }
};

fn divCeilPixels(pixels: u32) u32 {
    assert(pixels >= 1);
    assert(pixels <= frame_header.dimension_limit);

    return (pixels + macroblock_size_pixels - 1) / macroblock_size_pixels;
}

/// Parses every macroblock prediction record of a key frame from `reader`,
/// which must be positioned at the start of the records (where
/// `frame_header.parse` leaves it). `macroblocks` must hold exactly one
/// entry per macroblock of the frame, in raster order.
pub fn parseKeyFrameModes(
    reader: *bool_reader.BoolReader,
    header: *const frame_header.Header,
    macroblocks: []Macroblock,
) Error!void {
    const grid = MacroblockGrid.init(header.picture.dimensions);
    assert(macroblocks.len == grid.macroblockCount());

    // Subblock mode contexts for the row above; out-of-frame predictors act
    // as B_DC_PRED (RFC 6386 section 11.3, caveat 3).
    var above_modes_storage: [subblocks_per_edge * grid_columns_max]SubblockMode = undefined;
    const above_modes = above_modes_storage[0 .. subblocks_per_edge * grid.columns];
    @memset(above_modes, .dc);

    var row: u32 = 0;
    while (row < grid.rows) : (row += 1) {
        var left_modes: [subblocks_per_edge]SubblockMode = @splat(.dc);

        var column: u32 = 0;
        while (column < grid.columns) : (column += 1) {
            const macroblock = &macroblocks[row * grid.columns + column];
            const above = above_modes[subblocks_per_edge * column ..][0..subblocks_per_edge];
            try parseMacroblock(reader, header, above, &left_modes, macroblock);
        }
    }
}

fn parseMacroblock(
    reader: *bool_reader.BoolReader,
    header: *const frame_header.Header,
    above_modes: *[subblocks_per_edge]SubblockMode,
    left_modes: *[subblocks_per_edge]SubblockMode,
    macroblock: *Macroblock,
) Error!void {
    macroblock.segment_id = if (header.segmentation.update_map)
        @intCast(try reader.readTree(&segment_id_tree, &header.segmentation.tree_probabilities))
    else
        0;

    macroblock.skip = if (header.skip_enabled)
        (try reader.readBool(header.skip_probability)) == 1
    else
        false;

    macroblock.luma_mode = @enumFromInt(
        try reader.readTree(&kf_luma_mode_tree, &kf_luma_mode_probabilities),
    );
    if (macroblock.luma_mode == .subblocks) {
        try parseSubblockModes(reader, above_modes, left_modes, &macroblock.subblock_modes);
    } else {
        const derived = derivedSubblockMode(macroblock.luma_mode);
        macroblock.subblock_modes = @splat(derived);
        above_modes.* = @splat(derived);
        left_modes.* = @splat(derived);
    }

    macroblock.chroma_mode = @enumFromInt(
        try reader.readTree(&chroma_mode_tree, &kf_chroma_mode_probabilities),
    );
}

fn parseSubblockModes(
    reader: *bool_reader.BoolReader,
    above_modes: *[subblocks_per_edge]SubblockMode,
    left_modes: *[subblocks_per_edge]SubblockMode,
    subblock_modes: *[subblock_count]SubblockMode,
) Error!void {
    for (0..subblocks_per_edge) |sub_y| {
        var left = left_modes[sub_y];
        for (0..subblocks_per_edge) |sub_x| {
            const above = above_modes[sub_x];
            const probabilities =
                &kf_subblock_mode_probabilities[@intFromEnum(above)][@intFromEnum(left)];
            const mode: SubblockMode = @enumFromInt(
                try reader.readTree(&subblock_mode_tree, probabilities),
            );

            subblock_modes[sub_y * subblocks_per_edge + sub_x] = mode;
            // This entry is the above-context for the subblock one row down,
            // which lands in the next macroblock row once sub_y reaches 3.
            above_modes[sub_x] = mode;
            left = mode;
        }
        left_modes[sub_y] = left;
    }
}

/// RFC 6386 section 11.3, caveat 4: the constant subblock context mode a
/// 16x16 luma mode contributes to its neighbours.
pub fn derivedSubblockMode(mode: LumaMode) SubblockMode {
    return switch (mode) {
        .dc => .dc,
        .vertical => .vertical,
        .horizontal => .horizontal,
        .true_motion => .true_motion,
        .subblocks => unreachable,
    };
}

// --- Test helpers -----------------------------------------------------------

const bool_writer = @import("bool_writer.zig");
const token_probs = @import("token_probs.zig");

const TestHeaderOptions = struct {
    width: u32 = 48,
    height: u32 = 32,
    segmentation: frame_header.Segmentation = .disabled,
    skip_enabled: bool = false,
    skip_probability: u8 = 0,
};

fn testHeader(options: TestHeaderOptions) frame_header.Header {
    return .{
        .tag = .{ .version = 0, .first_partition_size = 0 },
        .picture = .{
            .dimensions = image.Dimensions.init(options.width, options.height) catch
                unreachable,
            .width_scale = 0,
            .height_scale = 0,
        },
        .color_space = 0,
        .clamping_type = 0,
        .segmentation = options.segmentation,
        .loop_filter = .{
            .simple = false,
            .level = 0,
            .sharpness = 0,
            .delta_enabled = false,
            .ref_frame_deltas = @splat(0),
            .mode_deltas = @splat(0),
        },
        .quant_indices = .{
            .y_ac_index = 0,
            .y_dc_delta = 0,
            .y2_dc_delta = 0,
            .y2_ac_delta = 0,
            .uv_dc_delta = 0,
            .uv_ac_delta = 0,
        },
        .refresh_entropy_probs = true,
        .coefficient_probabilities = token_probs.default_probabilities,
        .skip_enabled = options.skip_enabled,
        .skip_probability = options.skip_probability,
    };
}

const tree_depth_max = 9;

const TreePath = struct {
    probability_indices: [tree_depth_max]u8,
    bits: [tree_depth_max]u1,
    len: u4,
};

// Depth-first search for the root-to-leaf path of `value`; recursion is
// bounded by the depth of the constant coding trees (at most nine).
fn findTreePath(tree: []const i8, value: u8, node_index: usize, depth: u4, path: *TreePath) bool {
    assert(depth < tree_depth_max);

    for (0..2) |bit| {
        path.probability_indices[depth] = @intCast(node_index / 2);
        path.bits[depth] = @intCast(bit);

        const entry = tree[node_index + bit];
        if (entry <= 0) {
            const leaf: u8 = @intCast(-entry);
            if (leaf == value) {
                path.len = depth + 1;
                return true;
            }
        } else if (findTreePath(tree, value, @intCast(entry), depth + 1, path)) {
            return true;
        }
    }
    return false;
}

fn writeTreeValue(
    writer: *bool_writer.BoolWriter,
    tree: []const i8,
    probabilities: []const u8,
    value: u8,
) !void {
    var path: TreePath = undefined;
    const found = findTreePath(tree, value, 0, 0, &path);
    assert(found);

    for (0..path.len) |step| {
        try writer.writeBool(probabilities[path.probability_indices[step]], path.bits[step]);
    }
}

// Mirror of parseKeyFrameModes for round-trip tests, tracking the same
// subblock contexts on the encoding side.
fn encodeKeyFrameModes(
    writer: *bool_writer.BoolWriter,
    header: *const frame_header.Header,
    macroblocks: []const Macroblock,
) !void {
    const grid = MacroblockGrid.init(header.picture.dimensions);
    assert(macroblocks.len == grid.macroblockCount());

    var above_modes_storage: [subblocks_per_edge * grid_columns_max]SubblockMode = undefined;
    const above_modes = above_modes_storage[0 .. subblocks_per_edge * grid.columns];
    @memset(above_modes, .dc);

    var row: u32 = 0;
    while (row < grid.rows) : (row += 1) {
        var left_modes: [subblocks_per_edge]SubblockMode = @splat(.dc);

        var column: u32 = 0;
        while (column < grid.columns) : (column += 1) {
            const macroblock = macroblocks[row * grid.columns + column];
            const above = above_modes[subblocks_per_edge * column ..][0..subblocks_per_edge];

            if (header.segmentation.update_map) {
                try writeTreeValue(
                    writer,
                    &segment_id_tree,
                    &header.segmentation.tree_probabilities,
                    macroblock.segment_id,
                );
            }
            if (header.skip_enabled) {
                try writer.writeBool(header.skip_probability, @intFromBool(macroblock.skip));
            }

            try writeTreeValue(
                writer,
                &kf_luma_mode_tree,
                &kf_luma_mode_probabilities,
                @intFromEnum(macroblock.luma_mode),
            );
            if (macroblock.luma_mode == .subblocks) {
                for (0..subblocks_per_edge) |sub_y| {
                    var left = left_modes[sub_y];
                    for (0..subblocks_per_edge) |sub_x| {
                        const mode = macroblock.subblock_modes[sub_y * subblocks_per_edge + sub_x];
                        const above_index = @intFromEnum(above[sub_x]);
                        const left_index = @intFromEnum(left);
                        const probabilities =
                            &kf_subblock_mode_probabilities[above_index][left_index];
                        try writeTreeValue(
                            writer,
                            &subblock_mode_tree,
                            probabilities,
                            @intFromEnum(mode),
                        );
                        above[sub_x] = mode;
                        left = mode;
                    }
                    left_modes[sub_y] = left;
                }
            } else {
                const derived = derivedSubblockMode(macroblock.luma_mode);
                @memset(above, derived);
                left_modes = @splat(derived);
            }

            try writeTreeValue(
                writer,
                &chroma_mode_tree,
                &kf_chroma_mode_probabilities,
                @intFromEnum(macroblock.chroma_mode),
            );
        }
    }
}

test "derives subblock contexts from 16x16 luma modes" {
    // Goal: pin the exact probability tables the parser must select. A 2x1
    // grid codes MB0 as 16x16 vertical, then MB1 as B_PRED whose sixteen
    // submodes are all horizontal_up. The encoder below picks each context
    // table explicitly (no shared helper with the parser), so a swapped
    // [above][left] lookup or a wrong derived context decodes differently.
    const header = testHeader(.{ .width = 32, .height = 16 });

    var buffer: [128]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&buffer);

    // MB0: luma vertical, chroma dc. No segment or skip bits are coded.
    try writeTreeValue(
        &writer,
        &kf_luma_mode_tree,
        &kf_luma_mode_probabilities,
        @intFromEnum(LumaMode.vertical),
    );
    try writeTreeValue(
        &writer,
        &chroma_mode_tree,
        &kf_chroma_mode_probabilities,
        @intFromEnum(ChromaMode.dc),
    );

    // MB1: B_PRED. Off-frame above contexts are dc; the left contexts start
    // as vertical, derived from MB0's 16x16 mode.
    try writeTreeValue(
        &writer,
        &kf_luma_mode_tree,
        &kf_luma_mode_probabilities,
        @intFromEnum(LumaMode.subblocks),
    );
    const dc = @intFromEnum(SubblockMode.dc);
    const vertical = @intFromEnum(SubblockMode.vertical);
    const horizontal_up = @intFromEnum(SubblockMode.horizontal_up);
    for (0..subblocks_per_edge) |sub_y| {
        for (0..subblocks_per_edge) |sub_x| {
            const above = if (sub_y == 0) dc else horizontal_up;
            // The left context at sub_x 0 stays vertical for every row:
            // left_modes was filled by MB0's derived 16x16 mode, and each
            // row only consumes its own entry.
            const left = if (sub_x == 0) vertical else horizontal_up;
            try writeTreeValue(
                &writer,
                &subblock_mode_tree,
                &kf_subblock_mode_probabilities[above][left],
                horizontal_up,
            );
        }
    }
    try writeTreeValue(
        &writer,
        &chroma_mode_tree,
        &kf_chroma_mode_probabilities,
        @intFromEnum(ChromaMode.true_motion),
    );

    const encoded = try writer.finish();
    var reader = try bool_reader.BoolReader.init(encoded);

    var macroblocks: [2]Macroblock = undefined;
    try parseKeyFrameModes(&reader, &header, &macroblocks);

    try std.testing.expectEqual(@as(u2, 0), macroblocks[0].segment_id);
    try std.testing.expectEqual(false, macroblocks[0].skip);
    try std.testing.expectEqual(LumaMode.vertical, macroblocks[0].luma_mode);
    try std.testing.expectEqual(ChromaMode.dc, macroblocks[0].chroma_mode);
    try std.testing.expectEqual(
        [subblock_count]SubblockMode{
            .vertical, .vertical, .vertical, .vertical,
            .vertical, .vertical, .vertical, .vertical,
            .vertical, .vertical, .vertical, .vertical,
            .vertical, .vertical, .vertical, .vertical,
        },
        macroblocks[0].subblock_modes,
    );

    try std.testing.expectEqual(LumaMode.subblocks, macroblocks[1].luma_mode);
    try std.testing.expectEqual(ChromaMode.true_motion, macroblocks[1].chroma_mode);
    for (macroblocks[1].subblock_modes) |mode| {
        try std.testing.expectEqual(SubblockMode.horizontal_up, mode);
    }
}

test "round-trips prediction records across a mixed grid" {
    var segmentation = frame_header.Segmentation.disabled;
    segmentation.enabled = true;
    segmentation.update_map = true;
    segmentation.tree_probabilities = .{ 30, 100, 200 };
    const header = testHeader(.{
        .width = 48,
        .height = 32,
        .segmentation = segmentation,
        .skip_enabled = true,
        .skip_probability = 170,
    });

    const all_modes_pattern = [subblock_count]SubblockMode{
        .dc,              .true_motion,   .vertical,       .horizontal,
        .left_down,       .right_down,    .vertical_right, .vertical_left,
        .horizontal_down, .horizontal_up, .dc,             .left_down,
        .vertical,        .horizontal_up, .right_down,     .true_motion,
    };
    const second_pattern = [subblock_count]SubblockMode{
        .horizontal_up, .horizontal_down, .vertical_left,  .vertical_right,
        .right_down,    .left_down,       .horizontal,     .vertical,
        .true_motion,   .dc,              .vertical_right, .horizontal_up,
        .left_down,     .dc,              .true_motion,    .vertical,
    };
    const expected = [6]Macroblock{
        .{
            .segment_id = 0,
            .skip = false,
            .luma_mode = .dc,
            .chroma_mode = .dc,
            .subblock_modes = @splat(.dc),
        },
        .{
            .segment_id = 1,
            .skip = true,
            .luma_mode = .subblocks,
            .chroma_mode = .vertical,
            .subblock_modes = all_modes_pattern,
        },
        .{
            .segment_id = 2,
            .skip = false,
            .luma_mode = .true_motion,
            .chroma_mode = .horizontal,
            .subblock_modes = @splat(.true_motion),
        },
        .{
            .segment_id = 3,
            .skip = true,
            .luma_mode = .subblocks,
            .chroma_mode = .true_motion,
            .subblock_modes = second_pattern,
        },
        .{
            .segment_id = 1,
            .skip = true,
            .luma_mode = .horizontal,
            .chroma_mode = .dc,
            .subblock_modes = @splat(.horizontal),
        },
        .{
            .segment_id = 0,
            .skip = false,
            .luma_mode = .vertical,
            .chroma_mode = .vertical,
            .subblock_modes = @splat(.vertical),
        },
    };

    var buffer: [512]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&buffer);
    try encodeKeyFrameModes(&writer, &header, &expected);
    // Sentinel for verifying the parser leaves the reader exactly past the
    // last record.
    try writer.writeLiteral(0x5, 4);
    const encoded = try writer.finish();

    var reader = try bool_reader.BoolReader.init(encoded);
    var macroblocks: [6]Macroblock = undefined;
    try parseKeyFrameModes(&reader, &header, &macroblocks);

    try std.testing.expectEqual(expected, macroblocks);
    try std.testing.expectEqual(@as(u32, 0x5), try reader.readLiteral(4));
}

test "rejects truncated prediction records" {
    var segmentation = frame_header.Segmentation.disabled;
    segmentation.enabled = true;
    segmentation.update_map = true;
    segmentation.tree_probabilities = .{ 30, 100, 200 };
    const header = testHeader(.{
        .width = 32,
        .height = 16,
        .segmentation = segmentation,
        .skip_enabled = true,
        .skip_probability = 170,
    });

    // An all-ones value drains range fast (every read takes the low-
    // probability branch), so two bytes cannot carry even one record.
    var reader = try bool_reader.BoolReader.init(&.{ 0xff, 0xff });
    var macroblocks: [2]Macroblock = undefined;
    try std.testing.expectError(
        error.TruncatedBitstream,
        parseKeyFrameModes(&reader, &header, &macroblocks),
    );
}

test "fuzz VP8 macroblock prediction record parsing" {
    const testing_fuzz = @import("../testing/fuzz.zig");

    // Seed: valid records covering every luma mode for the fixed fuzz
    // header, so coverage starts from the deepest happy path.
    var seed_macroblocks: [fuzz_macroblock_count]Macroblock = undefined;
    for (&seed_macroblocks, 0..) |*macroblock, index| {
        const luma_mode: LumaMode = @enumFromInt(index % luma_mode_count);
        macroblock.* = .{
            .segment_id = @intCast(index % segment_count),
            .skip = index % 2 == 0,
            .luma_mode = luma_mode,
            .chroma_mode = @enumFromInt(index % chroma_mode_count),
            .subblock_modes = undefined,
        };
        if (luma_mode == .subblocks) {
            for (&macroblock.subblock_modes, 0..) |*mode, sub_index| {
                mode.* = @enumFromInt((index + sub_index) % subblock_mode_count);
            }
        } else {
            macroblock.subblock_modes = @splat(derivedSubblockMode(luma_mode));
        }
    }

    const header = fuzzHeader();
    var encode_buffer: [512]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&encode_buffer);
    try encodeKeyFrameModes(&writer, &header, &seed_macroblocks);
    const encoded = try writer.finish();

    var seed_buffer: [600]u8 = undefined;
    const seed = testing_fuzz.sliceCorpusEntry(&seed_buffer, encoded);

    try std.testing.fuzz({}, fuzzParseOne, .{ .corpus = &.{seed} });
}

const segment_count = frame_header.segment_count;
const fuzz_macroblock_count = 16;

fn fuzzHeader() frame_header.Header {
    var segmentation = frame_header.Segmentation.disabled;
    segmentation.enabled = true;
    segmentation.update_map = true;
    segmentation.tree_probabilities = .{ 30, 100, 200 };
    return testHeader(.{
        .width = 64,
        .height = 64,
        .segmentation = segmentation,
        .skip_enabled = true,
        .skip_probability = 170,
    });
}

fn fuzzParseOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [1024]u8 = undefined;
    const input_len = smith.slice(&input_buffer);

    const header = fuzzHeader();
    var reader = bool_reader.BoolReader.init(input_buffer[0..input_len]) catch return;
    var macroblocks: [fuzz_macroblock_count]Macroblock = undefined;
    parseKeyFrameModes(&reader, &header, &macroblocks) catch return;
}
