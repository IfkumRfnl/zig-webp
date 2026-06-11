//! Limited VP8L lossless payload decoder.

const std = @import("std");
const assert = std.debug.assert;

const bit_reader = @import("../bit_reader.zig");
const bit_writer = @import("../bit_writer.zig");
const container = @import("../container.zig");
const entropy = @import("entropy.zig");
const errors = @import("../errors.zig");
const header = @import("header.zig");
const image_data = @import("image_data.zig");
const pixel = @import("pixel.zig");
const transform = @import("transform.zig");

pub const WorkBuffers = struct {
    prefix_code_group: image_data.PrefixCodeGroupBuffers = .{},
};

pub const Result = struct {
    header: header.Header,
    entropy_summary: entropy.DecodeSummary,
};

pub fn decodeARGB(
    payload: []const u8,
    output: []pixel.Pixel,
    buffers: *WorkBuffers,
) errors.Error!Result {
    const parsed_header = try header.parse(payload);

    var reader = bit_reader.BitReader.init(payload[header.byte_count..]);
    var transform_reader = transform.ListReader.init(parsed_header.dimensions);
    if (try transform_reader.readNext(&reader)) |_| {
        return error.UnsupportedVP8LImageData;
    }

    const entropy_summary = try entropy.decodeSingleGroup(
        &reader,
        transform_reader.currentDimensions(),
        .argb,
        output,
        &buffers.prefix_code_group,
    );

    return .{
        .header = parsed_header,
        .entropy_summary = entropy_summary,
    };
}

fn writeHeader(
    payload: *[header.byte_count]u8,
    width: u32,
    height: u32,
    has_alpha: bool,
) void {
    assert(width > 0);
    assert(width <= header.dimension_limit);
    assert(height > 0);
    assert(height <= header.dimension_limit);

    payload[0] = header.signature;
    const bits = (width - 1) |
        ((height - 1) << 14) |
        (@as(u32, @intFromBool(has_alpha)) << 28);
    container.writeLittleU32(payload[1..header.byte_count], bits);
}

fn writeSimplePrefixCode(writer: *bit_writer.BitWriter, symbol: u8) errors.Error!void {
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(if (symbol <= 1) 0 else 1);
    try writer.writeBits(symbol, if (symbol <= 1) 1 else 8);
}

fn writeLiteralOnlyPrefixCodeGroup(writer: *bit_writer.BitWriter) errors.Error!void {
    var code_index: usize = 0;
    while (code_index < image_data.prefix_code_count) : (code_index += 1) {
        try writeSimplePrefixCode(writer, @intFromBool(code_index == 0));
    }
}

test "VP8L decoder materializes a no-transform single-group payload" {
    var payload: [header.byte_count + 16]u8 = undefined;
    writeHeader(payload[0..header.byte_count], 2, 1, false);

    var writer = bit_writer.BitWriter.init(payload[header.byte_count..]);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeLiteralOnlyPrefixCodeGroup(&writer);
    const image_data_bytes = try writer.finish();
    const payload_len = header.byte_count + image_data_bytes.len;

    var buffers: WorkBuffers = .{};
    var output: [2]pixel.Pixel = undefined;
    const result = try decodeARGB(payload[0..payload_len], &output, &buffers);

    try std.testing.expectEqual(@as(u32, 2), result.header.dimensions.width);
    try std.testing.expectEqual(@as(u32, 1), result.header.dimensions.height);
    try std.testing.expectEqual(@as(u64, 2), result.entropy_summary.pixel_count);
    try std.testing.expectEqual(pixel.fromChannels(0, 0, 1, 0), output[0]);
    try std.testing.expectEqual(pixel.fromChannels(0, 0, 1, 0), output[1]);
}

test "VP8L decoder reports transforms as unsupported in the limited slice" {
    var payload: [header.byte_count + 1]u8 = undefined;
    writeHeader(payload[0..header.byte_count], 1, 1, false);

    var writer = bit_writer.BitWriter.init(payload[header.byte_count..]);
    try writer.writeBit(1);
    try writer.writeBits(@intFromEnum(transform.Kind.subtract_green), 2);
    const image_data_bytes = try writer.finish();
    const payload_len = header.byte_count + image_data_bytes.len;

    var buffers: WorkBuffers = .{};
    var output: [1]pixel.Pixel = undefined;
    try std.testing.expectError(
        error.UnsupportedVP8LImageData,
        decodeARGB(payload[0..payload_len], &output, &buffers),
    );
}
