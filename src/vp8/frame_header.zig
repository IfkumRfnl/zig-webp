//! VP8 key-frame header parsing (RFC 6386 section 9).
//!
//! WebP stores exactly one displayable VP8 key frame per `VP8 ` chunk, so
//! this parser rejects the interframe and hidden-frame states WebP forbids.
//! Parsing covers the uncompressed frame tag and picture header plus the
//! boolean-coded first-partition header through the DCT token probability
//! updates, leaving the returned reader positioned at macroblock data.

const std = @import("std");
const assert = std.debug.assert;

const bool_reader = @import("bool_reader.zig");
const errors = @import("../errors.zig");
const image = @import("../image.zig");
const token_probs = @import("token_probs.zig");

pub const Error = errors.Error;

pub const frame_tag_byte_count = 3;
pub const picture_header_byte_count = 7;
pub const header_byte_count = frame_tag_byte_count + picture_header_byte_count;
pub const start_code = [frame_tag_byte_count]u8{ 0x9d, 0x01, 0x2a };
pub const version_max = 3;
pub const dimension_limit = (1 << 14) - 1;
pub const first_partition_size_max = (1 << 19) - 1;
pub const segment_count = 4;
pub const segment_tree_probability_count = 3;
pub const loop_filter_delta_count = 4;
pub const token_partition_count_max = 8;

comptime {
    assert(header_byte_count == 10);
    assert(dimension_limit == 16_383);
    assert(first_partition_size_max == 524_287);
    assert(token_partition_count_max == 1 << 3);
}

pub const FrameTag = struct {
    version: u3,
    first_partition_size: u32,
};

pub const PictureHeader = struct {
    dimensions: image.Dimensions,
    width_scale: u2,
    height_scale: u2,
};

pub const Segmentation = struct {
    enabled: bool,
    update_map: bool,
    absolute_values: bool,
    quantizer_deltas: [segment_count]i8,
    filter_strength_deltas: [segment_count]i8,
    tree_probabilities: [segment_tree_probability_count]u8,

    pub const disabled: Segmentation = .{
        .enabled = false,
        .update_map = false,
        .absolute_values = true,
        .quantizer_deltas = @splat(0),
        .filter_strength_deltas = @splat(0),
        .tree_probabilities = @splat(255),
    };
};

pub const LoopFilter = struct {
    simple: bool,
    level: u8,
    sharpness: u8,
    delta_enabled: bool,
    ref_frame_deltas: [loop_filter_delta_count]i8,
    mode_deltas: [loop_filter_delta_count]i8,
};

pub const QuantIndices = struct {
    y_ac_index: u8,
    y_dc_delta: i8,
    y2_dc_delta: i8,
    y2_ac_delta: i8,
    uv_dc_delta: i8,
    uv_ac_delta: i8,
};

pub const TokenPartitions = struct {
    count: u8,
    slices: [token_partition_count_max][]const u8,
};

pub const Header = struct {
    tag: FrameTag,
    picture: PictureHeader,
    color_space: u1,
    clamping_type: u1,
    segmentation: Segmentation,
    loop_filter: LoopFilter,
    quant_indices: QuantIndices,
    refresh_entropy_probs: bool,
    coefficient_probabilities: token_probs.Table,
    skip_enabled: bool,
    skip_probability: u8,
};

pub const Parsed = struct {
    header: Header,
    token_partitions: TokenPartitions,
    // Positioned at the start of the macroblock prediction records inside
    // the first partition once `parse` returns.
    macroblock_reader: bool_reader.BoolReader,
};

pub fn parse(payload: []const u8, parsed: *Parsed) Error!void {
    parsed.header.tag = try parseFrameTag(payload);
    parsed.header.picture = try parsePictureHeader(payload[frame_tag_byte_count..]);

    const bytes_after_header = payload.len - header_byte_count;
    if (parsed.header.tag.first_partition_size > bytes_after_header) {
        return error.InvalidVP8Header;
    }

    const first_partition_end = header_byte_count + parsed.header.tag.first_partition_size;
    var reader = bool_reader.BoolReader.init(payload[header_byte_count..first_partition_end]);

    parsed.header.color_space = try reader.readBit();
    parsed.header.clamping_type = try reader.readBit();
    parsed.header.segmentation = try parseSegmentation(&reader);
    parsed.header.loop_filter = try parseLoopFilter(&reader);
    parsed.token_partitions = try parseTokenPartitions(&reader, payload[first_partition_end..]);
    parsed.header.quant_indices = try parseQuantIndices(&reader);
    parsed.header.refresh_entropy_probs = (try reader.readBit()) == 1;
    try parseCoefficientProbabilities(&reader, &parsed.header.coefficient_probabilities);
    parsed.header.skip_enabled = (try reader.readBit()) == 1;
    parsed.header.skip_probability = if (parsed.header.skip_enabled)
        @intCast(try reader.readLiteral(8))
    else
        0;

    parsed.macroblock_reader = reader;

    assert(parsed.token_partitions.count >= 1);
    assert(parsed.token_partitions.count <= token_partition_count_max);
}

pub fn parseFrameTag(payload: []const u8) Error!FrameTag {
    if (payload.len < frame_tag_byte_count) return error.InvalidVP8Header;

    const bits = @as(u32, payload[0]) |
        (@as(u32, payload[1]) << 8) |
        (@as(u32, payload[2]) << 16);
    const is_key_frame = (bits & 1) == 0;
    const version: u3 = @intCast((bits >> 1) & 0x7);
    const show_frame = ((bits >> 4) & 1) == 1;
    const first_partition_size = bits >> 5;

    if (!is_key_frame) return error.InvalidVP8Header;
    if (version > version_max) return error.InvalidVP8Header;
    if (!show_frame) return error.InvalidVP8Header;

    assert(first_partition_size <= first_partition_size_max);
    return .{
        .version = version,
        .first_partition_size = first_partition_size,
    };
}

pub fn parsePictureHeader(bytes: []const u8) Error!PictureHeader {
    if (bytes.len < picture_header_byte_count) return error.InvalidVP8Header;
    if (!std.mem.eql(u8, bytes[0..start_code.len], &start_code)) {
        return error.InvalidVP8Header;
    }

    const width_bits = (@as(u16, bytes[4]) << 8) | bytes[3];
    const height_bits = (@as(u16, bytes[6]) << 8) | bytes[5];
    const width: u32 = width_bits & dimension_limit;
    const height: u32 = height_bits & dimension_limit;

    return .{
        .dimensions = try image.Dimensions.init(width, height),
        .width_scale = @intCast(width_bits >> 14),
        .height_scale = @intCast(height_bits >> 14),
    };
}

pub fn parseSegmentation(reader: *bool_reader.BoolReader) Error!Segmentation {
    var segmentation = Segmentation.disabled;
    segmentation.enabled = (try reader.readBit()) == 1;
    if (!segmentation.enabled) return segmentation;

    segmentation.update_map = (try reader.readBit()) == 1;
    const update_feature_data = (try reader.readBit()) == 1;
    if (update_feature_data) {
        segmentation.absolute_values = (try reader.readBit()) == 1;
        for (&segmentation.quantizer_deltas) |*delta| {
            delta.* = try readFlaggedSignedValue(reader, 7);
        }
        for (&segmentation.filter_strength_deltas) |*delta| {
            delta.* = try readFlaggedSignedValue(reader, 6);
        }
    }
    if (segmentation.update_map) {
        for (&segmentation.tree_probabilities) |*probability| {
            probability.* = if ((try reader.readBit()) == 1)
                @intCast(try reader.readLiteral(8))
            else
                255;
        }
    }

    return segmentation;
}

pub fn parseLoopFilter(reader: *bool_reader.BoolReader) Error!LoopFilter {
    var loop_filter = LoopFilter{
        .simple = (try reader.readBit()) == 1,
        .level = @intCast(try reader.readLiteral(6)),
        .sharpness = @intCast(try reader.readLiteral(3)),
        .delta_enabled = false,
        .ref_frame_deltas = @splat(0),
        .mode_deltas = @splat(0),
    };

    loop_filter.delta_enabled = (try reader.readBit()) == 1;
    if (loop_filter.delta_enabled) {
        const update_deltas = (try reader.readBit()) == 1;
        if (update_deltas) {
            for (&loop_filter.ref_frame_deltas) |*delta| {
                if ((try reader.readBit()) == 1) {
                    delta.* = @intCast(try reader.readSignedLiteral(6));
                }
            }
            for (&loop_filter.mode_deltas) |*delta| {
                if ((try reader.readBit()) == 1) {
                    delta.* = @intCast(try reader.readSignedLiteral(6));
                }
            }
        }
    }

    return loop_filter;
}

pub fn parseTokenPartitions(
    reader: *bool_reader.BoolReader,
    bytes: []const u8,
) Error!TokenPartitions {
    const count_log2: u3 = @intCast(try reader.readLiteral(2));
    const count = @as(u8, 1) << count_log2;
    assert(count >= 1);
    assert(count <= token_partition_count_max);

    const size_entry_count: usize = count - 1;
    const size_table_bytes = size_entry_count * 3;
    if (bytes.len < size_table_bytes) return error.InvalidVP8Header;

    var partitions = TokenPartitions{
        .count = count,
        .slices = @splat(&.{}),
    };

    var remaining = bytes[size_table_bytes..];
    var entry_index: usize = 0;
    while (entry_index < size_entry_count) : (entry_index += 1) {
        const size_bytes = bytes[entry_index * 3 ..][0..3];
        const partition_size: usize = @as(usize, size_bytes[0]) |
            (@as(usize, size_bytes[1]) << 8) |
            (@as(usize, size_bytes[2]) << 16);
        // libwebp clamps an oversized declared size and then fails its final
        // bounds check, so rejecting here accepts exactly the same inputs.
        if (partition_size > remaining.len) return error.InvalidVP8Header;

        partitions.slices[entry_index] = remaining[0..partition_size];
        remaining = remaining[partition_size..];
    }

    // The final partition takes every remaining byte and must not be empty,
    // matching libwebp's bounds check.
    if (remaining.len == 0) return error.InvalidVP8Header;
    partitions.slices[size_entry_count] = remaining;

    return partitions;
}

pub fn parseQuantIndices(reader: *bool_reader.BoolReader) Error!QuantIndices {
    return .{
        .y_ac_index = @intCast(try reader.readLiteral(7)),
        .y_dc_delta = try readFlaggedSignedValue(reader, 4),
        .y2_dc_delta = try readFlaggedSignedValue(reader, 4),
        .y2_ac_delta = try readFlaggedSignedValue(reader, 4),
        .uv_dc_delta = try readFlaggedSignedValue(reader, 4),
        .uv_ac_delta = try readFlaggedSignedValue(reader, 4),
    };
}

pub fn parseCoefficientProbabilities(
    reader: *bool_reader.BoolReader,
    probabilities: *token_probs.Table,
) Error!void {
    for (probabilities, 0..) |*plane, plane_index| {
        for (plane, 0..) |*band, band_index| {
            for (band, 0..) |*context, context_index| {
                for (context, 0..) |*probability, probability_index| {
                    const update_probability = token_probs
                        .update_probabilities[plane_index][band_index][context_index][probability_index];
                    probability.* = if ((try reader.readBool(update_probability)) == 1)
                        @intCast(try reader.readLiteral(8))
                    else
                        token_probs
                            .default_probabilities[plane_index][band_index][context_index][probability_index];
                }
            }
        }
    }
}

fn readFlaggedSignedValue(reader: *bool_reader.BoolReader, bit_count: u6) Error!i8 {
    assert(bit_count >= 4);
    assert(bit_count <= 7);

    if ((try reader.readBit()) == 1) {
        return @intCast(try reader.readSignedLiteral(bit_count));
    }
    return 0;
}

// --- Test helpers -----------------------------------------------------------

const bool_writer = @import("bool_writer.zig");

fn writeFrameTag(out: *[frame_tag_byte_count]u8, first_partition_size: u32) void {
    assert(first_partition_size <= first_partition_size_max);

    // Key frame (bit 0 clear), version 0, show_frame set.
    const bits = (@as(u32, 1) << 4) | (first_partition_size << 5);
    out[0] = @truncate(bits);
    out[1] = @truncate(bits >> 8);
    out[2] = @truncate(bits >> 16);
}

fn writePictureHeader(out: *[picture_header_byte_count]u8, width: u16, height: u16) void {
    assert(width <= dimension_limit);
    assert(height <= dimension_limit);

    out[0..start_code.len].* = start_code;
    out[3] = @truncate(width);
    out[4] = @truncate(width >> 8);
    out[5] = @truncate(height);
    out[6] = @truncate(height >> 8);
}

fn writeDefaultCoefficientProbabilities(writer: *bool_writer.BoolWriter) Error!void {
    for (token_probs.update_probabilities) |plane| {
        for (plane) |band| {
            for (band) |context| {
                for (context) |update_probability| {
                    try writer.writeBool(update_probability, 0);
                }
            }
        }
    }
}

fn writeMinimalCompressedHeader(writer: *bool_writer.BoolWriter) Error!void {
    try writer.writeBit(0); // Color space: YUV as specified.
    try writer.writeBit(0); // Clamping: spec-required pixel clamping.
    try writer.writeBit(0); // Segmentation disabled.
    try writer.writeBit(1); // Simple loop filter.
    try writer.writeLiteral(26, 6); // Loop filter level.
    try writer.writeLiteral(3, 3); // Sharpness.
    try writer.writeBit(0); // Loop filter deltas disabled.
    try writer.writeLiteral(0, 2); // One token partition.
    try writer.writeLiteral(64, 7); // y_ac quantizer index.
    try writer.writeBit(0); // No y_dc delta.
    try writer.writeBit(0); // No y2_dc delta.
    try writer.writeBit(0); // No y2_ac delta.
    try writer.writeBit(0); // No uv_dc delta.
    try writer.writeBit(0); // No uv_ac delta.
    try writer.writeBit(1); // refresh_entropy_probs.
    try writeDefaultCoefficientProbabilities(writer);
    try writer.writeBit(0); // mb_no_coeff_skip disabled.
}

fn assemblePayload(
    out: []u8,
    compressed: []const u8,
    token_partition_bytes: []const u8,
) []const u8 {
    const total = header_byte_count + compressed.len + token_partition_bytes.len;
    assert(out.len >= total);

    writeFrameTag(out[0..frame_tag_byte_count], @intCast(compressed.len));
    writePictureHeader(out[frame_tag_byte_count..header_byte_count], 320, 240);
    @memcpy(out[header_byte_count..][0..compressed.len], compressed);
    @memcpy(out[header_byte_count + compressed.len ..][0..token_partition_bytes.len], token_partition_bytes);

    return out[0..total];
}

test "parses a minimal key-frame header" {
    var compressed_buffer: [128]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&compressed_buffer);
    try writeMinimalCompressedHeader(&writer);
    const compressed = try writer.finish();

    var payload_buffer: [192]u8 = undefined;
    const payload = assemblePayload(&payload_buffer, compressed, &.{0xee});

    var parsed: Parsed = undefined;
    try parse(payload, &parsed);

    try std.testing.expectEqual(@as(u3, 0), parsed.header.tag.version);
    try std.testing.expectEqual(
        @as(u32, @intCast(compressed.len)),
        parsed.header.tag.first_partition_size,
    );
    try std.testing.expectEqual(@as(u32, 320), parsed.header.picture.dimensions.width);
    try std.testing.expectEqual(@as(u32, 240), parsed.header.picture.dimensions.height);
    try std.testing.expectEqual(@as(u2, 0), parsed.header.picture.width_scale);
    try std.testing.expectEqual(@as(u2, 0), parsed.header.picture.height_scale);
    try std.testing.expectEqual(@as(u1, 0), parsed.header.color_space);
    try std.testing.expectEqual(@as(u1, 0), parsed.header.clamping_type);
    try std.testing.expect(!parsed.header.segmentation.enabled);
    try std.testing.expect(parsed.header.loop_filter.simple);
    try std.testing.expectEqual(@as(u8, 26), parsed.header.loop_filter.level);
    try std.testing.expectEqual(@as(u8, 3), parsed.header.loop_filter.sharpness);
    try std.testing.expect(!parsed.header.loop_filter.delta_enabled);
    try std.testing.expectEqual(@as(u8, 64), parsed.header.quant_indices.y_ac_index);
    try std.testing.expectEqual(@as(i8, 0), parsed.header.quant_indices.uv_ac_delta);
    try std.testing.expect(parsed.header.refresh_entropy_probs);
    try std.testing.expect(!parsed.header.skip_enabled);
    try std.testing.expectEqual(@as(u8, 0), parsed.header.skip_probability);
    try std.testing.expectEqual(@as(u8, 1), parsed.token_partitions.count);
    try std.testing.expectEqualSlices(u8, &.{0xee}, parsed.token_partitions.slices[0]);

    // No updates were coded, so the frame starts from the spec defaults.
    try std.testing.expectEqual(
        token_probs.default_probabilities,
        parsed.header.coefficient_probabilities,
    );
}

test "parses segmentation, filter deltas, quantizer deltas, and probability updates" {
    var compressed_buffer: [192]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&compressed_buffer);

    try writer.writeBit(0); // Color space.
    try writer.writeBit(1); // Clamping: no clamping required.

    try writer.writeBit(1); // Segmentation enabled.
    try writer.writeBit(1); // Update segment map.
    try writer.writeBit(1); // Update segment feature data.
    try writer.writeBit(1); // Absolute values.
    const quantizer_deltas = [segment_count]i8{ 17, -23, 0, 96 };
    for (quantizer_deltas) |delta| {
        if (delta == 0) {
            try writer.writeBit(0);
        } else {
            try writer.writeBit(1);
            try writer.writeSignedLiteral(delta, 7);
        }
    }
    const filter_strength_deltas = [segment_count]i8{ -1, 0, 0, 63 };
    for (filter_strength_deltas) |delta| {
        if (delta == 0) {
            try writer.writeBit(0);
        } else {
            try writer.writeBit(1);
            try writer.writeSignedLiteral(delta, 6);
        }
    }
    try writer.writeBit(1); // First tree probability coded.
    try writer.writeLiteral(12, 8);
    try writer.writeBit(0); // Second tree probability defaults to 255.
    try writer.writeBit(1); // Third tree probability coded.
    try writer.writeLiteral(200, 8);

    try writer.writeBit(0); // Normal loop filter.
    try writer.writeLiteral(63, 6); // Level.
    try writer.writeLiteral(7, 3); // Sharpness.
    try writer.writeBit(1); // Loop filter deltas enabled.
    try writer.writeBit(1); // Update deltas.
    const ref_frame_deltas = [loop_filter_delta_count]i8{ 2, 0, -2, 0 };
    for (ref_frame_deltas) |delta| {
        if (delta == 0) {
            try writer.writeBit(0);
        } else {
            try writer.writeBit(1);
            try writer.writeSignedLiteral(delta, 6);
        }
    }
    const mode_deltas = [loop_filter_delta_count]i8{ 0, 4, 0, -4 };
    for (mode_deltas) |delta| {
        if (delta == 0) {
            try writer.writeBit(0);
        } else {
            try writer.writeBit(1);
            try writer.writeSignedLiteral(delta, 6);
        }
    }

    try writer.writeLiteral(2, 2); // Four token partitions.

    try writer.writeLiteral(99, 7); // y_ac quantizer index.
    try writer.writeBit(1); // y_dc delta.
    try writer.writeSignedLiteral(-7, 4);
    try writer.writeBit(0); // No y2_dc delta.
    try writer.writeBit(0); // No y2_ac delta.
    try writer.writeBit(1); // uv_dc delta.
    try writer.writeSignedLiteral(15, 4);
    try writer.writeBit(0); // No uv_ac delta.

    try writer.writeBit(0); // refresh_entropy_probs clear.

    // Update exactly the first coefficient probability, default the rest.
    var first = true;
    for (token_probs.update_probabilities) |plane| {
        for (plane) |band| {
            for (band) |context| {
                for (context) |update_probability| {
                    if (first) {
                        try writer.writeBool(update_probability, 1);
                        try writer.writeLiteral(77, 8);
                        first = false;
                    } else {
                        try writer.writeBool(update_probability, 0);
                    }
                }
            }
        }
    }

    try writer.writeBit(1); // mb_no_coeff_skip enabled.
    try writer.writeLiteral(0xaa, 8);

    // Macroblock data following the header inside the first partition.
    try writer.writeLiteral(0xa, 4);

    const compressed = try writer.finish();

    // Three explicit partition sizes (5, 6, 7 bytes) and a final remainder.
    var token_bytes_buffer: [3 * 3 + 5 + 6 + 7 + 2]u8 = undefined;
    token_bytes_buffer[0..9].* = .{ 5, 0, 0, 6, 0, 0, 7, 0, 0 };
    for (token_bytes_buffer[9..], 0..) |*byte, index| byte.* = @intCast(index);

    var payload_buffer: [256]u8 = undefined;
    const payload = assemblePayload(&payload_buffer, compressed, &token_bytes_buffer);

    var parsed: Parsed = undefined;
    try parse(payload, &parsed);

    try std.testing.expectEqual(@as(u1, 0), parsed.header.color_space);
    try std.testing.expectEqual(@as(u1, 1), parsed.header.clamping_type);

    try std.testing.expect(parsed.header.segmentation.enabled);
    try std.testing.expect(parsed.header.segmentation.update_map);
    try std.testing.expect(parsed.header.segmentation.absolute_values);
    try std.testing.expectEqual(quantizer_deltas, parsed.header.segmentation.quantizer_deltas);
    try std.testing.expectEqual(
        filter_strength_deltas,
        parsed.header.segmentation.filter_strength_deltas,
    );
    try std.testing.expectEqual(
        [segment_tree_probability_count]u8{ 12, 255, 200 },
        parsed.header.segmentation.tree_probabilities,
    );

    try std.testing.expect(!parsed.header.loop_filter.simple);
    try std.testing.expectEqual(@as(u8, 63), parsed.header.loop_filter.level);
    try std.testing.expectEqual(@as(u8, 7), parsed.header.loop_filter.sharpness);
    try std.testing.expect(parsed.header.loop_filter.delta_enabled);
    try std.testing.expectEqual(ref_frame_deltas, parsed.header.loop_filter.ref_frame_deltas);
    try std.testing.expectEqual(mode_deltas, parsed.header.loop_filter.mode_deltas);

    try std.testing.expectEqual(@as(u8, 99), parsed.header.quant_indices.y_ac_index);
    try std.testing.expectEqual(@as(i8, -7), parsed.header.quant_indices.y_dc_delta);
    try std.testing.expectEqual(@as(i8, 0), parsed.header.quant_indices.y2_dc_delta);
    try std.testing.expectEqual(@as(i8, 0), parsed.header.quant_indices.y2_ac_delta);
    try std.testing.expectEqual(@as(i8, 15), parsed.header.quant_indices.uv_dc_delta);
    try std.testing.expectEqual(@as(i8, 0), parsed.header.quant_indices.uv_ac_delta);

    try std.testing.expect(!parsed.header.refresh_entropy_probs);
    try std.testing.expectEqual(@as(u8, 77), parsed.header.coefficient_probabilities[0][0][0][0]);
    try std.testing.expectEqual(
        token_probs.default_probabilities[0][0][0][1],
        parsed.header.coefficient_probabilities[0][0][0][1],
    );
    try std.testing.expectEqual(
        token_probs.default_probabilities[3][7][2],
        parsed.header.coefficient_probabilities[3][7][2],
    );

    try std.testing.expect(parsed.header.skip_enabled);
    try std.testing.expectEqual(@as(u8, 0xaa), parsed.header.skip_probability);

    try std.testing.expectEqual(@as(u8, 4), parsed.token_partitions.count);
    try std.testing.expectEqual(@as(usize, 5), parsed.token_partitions.slices[0].len);
    try std.testing.expectEqual(@as(usize, 6), parsed.token_partitions.slices[1].len);
    try std.testing.expectEqual(@as(usize, 7), parsed.token_partitions.slices[2].len);
    try std.testing.expectEqual(@as(usize, 2), parsed.token_partitions.slices[3].len);
    try std.testing.expectEqualSlices(
        u8,
        token_bytes_buffer[9..][0..5],
        parsed.token_partitions.slices[0],
    );

    // The returned reader continues with the bits written after the header.
    var macroblock_reader = parsed.macroblock_reader;
    try std.testing.expectEqual(@as(u32, 0xa), try macroblock_reader.readLiteral(4));
}

test "rejects frame tags WebP forbids" {
    try std.testing.expectError(error.InvalidVP8Header, parseFrameTag(&.{}));
    try std.testing.expectError(error.InvalidVP8Header, parseFrameTag(&.{ 0x10, 0x00 }));

    // Interframe bit set.
    try std.testing.expectError(error.InvalidVP8Header, parseFrameTag(&.{ 0x11, 0x00, 0x00 }));

    // Version 4 exceeds the defined profiles.
    try std.testing.expectError(error.InvalidVP8Header, parseFrameTag(&.{ 0x18, 0x00, 0x00 }));

    // show_frame clear is a hidden frame.
    try std.testing.expectError(error.InvalidVP8Header, parseFrameTag(&.{ 0x00, 0x00, 0x00 }));
}

test "rejects invalid picture headers" {
    try std.testing.expectError(error.InvalidVP8Header, parsePictureHeader(&.{}));
    try std.testing.expectError(
        error.InvalidVP8Header,
        parsePictureHeader(&.{ 0x9d, 0x01, 0x2b, 1, 0, 1, 0 }),
    );
    try std.testing.expectError(
        error.InvalidCanvasSize,
        parsePictureHeader(&.{ 0x9d, 0x01, 0x2a, 0, 0, 1, 0 }),
    );
    try std.testing.expectError(
        error.InvalidCanvasSize,
        parsePictureHeader(&.{ 0x9d, 0x01, 0x2a, 1, 0, 0, 0 }),
    );

    const scaled = try parsePictureHeader(&.{ 0x9d, 0x01, 0x2a, 0x01, 0x40, 0x01, 0x80 });
    try std.testing.expectEqual(@as(u32, 1), scaled.dimensions.width);
    try std.testing.expectEqual(@as(u2, 1), scaled.width_scale);
    try std.testing.expectEqual(@as(u2, 2), scaled.height_scale);
}

test "rejects first partitions that overrun or underrun the payload" {
    var payload_buffer: [64]u8 = undefined;

    // Declared first partition larger than the remaining payload.
    writeFrameTag(payload_buffer[0..frame_tag_byte_count], 32);
    writePictureHeader(payload_buffer[frame_tag_byte_count..header_byte_count], 16, 16);
    var parsed: Parsed = undefined;
    try std.testing.expectError(
        error.InvalidVP8Header,
        parse(payload_buffer[0..header_byte_count], &parsed),
    );

    // A first partition too small for the compressed header truncates.
    writeFrameTag(payload_buffer[0..frame_tag_byte_count], 2);
    @memset(payload_buffer[header_byte_count..][0..3], 0);
    try std.testing.expectError(
        error.TruncatedBitstream,
        parse(payload_buffer[0 .. header_byte_count + 3], &parsed),
    );
}

test "rejects token partition layouts that exceed the payload" {
    var compressed_buffer: [128]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&compressed_buffer);
    try writer.writeBit(0); // Color space.
    try writer.writeBit(0); // Clamping.
    try writer.writeBit(0); // Segmentation disabled.
    try writer.writeBit(0); // Normal filter.
    try writer.writeLiteral(0, 6);
    try writer.writeLiteral(0, 3);
    try writer.writeBit(0); // No filter deltas.
    try writer.writeLiteral(3, 2); // Eight token partitions.
    const compressed = try writer.finish();

    // Seven size entries need 21 bytes; provide fewer.
    var payload_buffer: [192]u8 = undefined;
    const payload = assemblePayload(&payload_buffer, compressed, &.{ 0, 0, 0 });

    var parsed: Parsed = undefined;
    try std.testing.expectError(error.InvalidVP8Header, parse(payload, &parsed));
}

test "rejects an empty final token partition" {
    var compressed_buffer: [128]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&compressed_buffer);
    try writeMinimalCompressedHeader(&writer);
    const compressed = try writer.finish();

    var payload_buffer: [192]u8 = undefined;
    const payload = assemblePayload(&payload_buffer, compressed, &.{});

    var parsed: Parsed = undefined;
    try std.testing.expectError(error.InvalidVP8Header, parse(payload, &parsed));
}

test "rejects declared token partition sizes that overrun the payload" {
    var compressed_buffer: [128]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&compressed_buffer);
    try writer.writeBit(0); // Color space.
    try writer.writeBit(0); // Clamping.
    try writer.writeBit(0); // Segmentation disabled.
    try writer.writeBit(0); // Normal filter.
    try writer.writeLiteral(0, 6);
    try writer.writeLiteral(0, 3);
    try writer.writeBit(0); // No filter deltas.
    try writer.writeLiteral(1, 2); // Two token partitions.
    const partial = try writer.finish();

    var reader = bool_reader.BoolReader.init(partial);
    _ = try reader.readBit(); // Color space.
    _ = try reader.readBit(); // Clamping.
    _ = try parseSegmentation(&reader);
    _ = try parseLoopFilter(&reader);

    // The declared first size (200 bytes) exceeds the three bytes that
    // follow the size table.
    const oversized = [_]u8{ 200, 0, 0, 1, 2, 3 };
    try std.testing.expectError(
        error.InvalidVP8Header,
        parseTokenPartitions(&reader, &oversized),
    );
}

test "fuzz VP8 key-frame header parsing" {
    const testing_fuzz = @import("../testing/fuzz.zig");

    var compressed_buffer: [128]u8 = undefined;
    var writer = bool_writer.BoolWriter.init(&compressed_buffer);
    try writeMinimalCompressedHeader(&writer);
    const compressed = try writer.finish();

    var payload_buffer: [192]u8 = undefined;
    const seed_payload = assemblePayload(&payload_buffer, compressed, &.{0xee});

    var seed_buffer: [256]u8 = undefined;
    const seed = testing_fuzz.sliceCorpusEntry(&seed_buffer, seed_payload);

    try std.testing.fuzz({}, fuzzParseOne, .{ .corpus = &.{seed} });
}

fn fuzzParseOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [1024]u8 = undefined;
    const input_len = smith.slice(&input_buffer);

    var parsed: Parsed = undefined;
    parse(input_buffer[0..input_len], &parsed) catch return;
}
