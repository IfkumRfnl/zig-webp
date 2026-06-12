//! ALPH chunk header parsing and alpha-plane decoding.

const std = @import("std");
const assert = std.debug.assert;

const bit_writer = @import("bit_writer.zig");
const errors = @import("errors.zig");
const image = @import("image.zig");
const vp8l_decoder = @import("vp8l/decoder.zig");
const vp8l_pixel = @import("vp8l/pixel.zig");

pub const header_size = 1;

pub const Compression = enum(u2) {
    none = 0,
    lossless = 1,
};

pub const Filter = enum(u2) {
    none = 0,
    horizontal = 1,
    vertical = 2,
    gradient = 3,
};

pub const Preprocessing = enum(u2) {
    none = 0,
    quantized_levels = 1,
};

pub const Header = struct {
    compression: Compression,
    filter: Filter,
    preprocessing: Preprocessing,
};

pub fn parseHeader(payload: []const u8) errors.Error!Header {
    if (payload.len < header_size) return error.InvalidAlphaChunk;

    const bits = payload[0];
    const compression: u2 = @truncate(bits);
    const filter: u2 = @truncate(bits >> 2);
    const preprocessing: u2 = @truncate(bits >> 4);
    const reserved: u2 = @truncate(bits >> 6);

    if (compression > @intFromEnum(Compression.lossless)) return error.InvalidAlphaChunk;
    if (preprocessing > @intFromEnum(Preprocessing.quantized_levels)) {
        return error.InvalidAlphaChunk;
    }
    if (reserved != 0) return error.InvalidAlphaChunk;

    return .{
        .compression = @enumFromInt(compression),
        .filter = @enumFromInt(filter),
        .preprocessing = @enumFromInt(preprocessing),
    };
}

/// Decodes a full ALPH chunk payload (header byte included) into `output`,
/// which receives one alpha byte per pixel in row-major order. Only
/// uncompressed payloads decode without an allocator; use `decodePlaneAlloc`
/// for VP8L-compressed alpha.
pub fn decodePlane(
    payload: []const u8,
    dimensions: image.Dimensions,
    output: []u8,
) errors.Error!Header {
    const header = try parseHeader(payload);

    switch (header.compression) {
        .none => try decodeRaw(header, payload[header_size..], dimensions, output),
        .lossless => return error.UnsupportedAlphaCompression,
    }

    return header;
}

/// Decodes a full ALPH chunk payload (header byte included) into `output`,
/// covering both uncompressed and VP8L-compressed alpha streams. The
/// allocator only backs scratch buffers for the VP8L path; `output` stays
/// caller-owned.
pub fn decodePlaneAlloc(
    gpa: std.mem.Allocator,
    payload: []const u8,
    dimensions: image.Dimensions,
    output: []u8,
) errors.Error!Header {
    const header = try parseHeader(payload);

    switch (header.compression) {
        .none => try decodeRaw(header, payload[header_size..], dimensions, output),
        .lossless => try decodeLossless(
            gpa,
            header,
            payload[header_size..],
            dimensions,
            output,
        ),
    }

    return header;
}

/// Decodes a VP8L-compressed alpha stream: a headerless VP8L image-data
/// stream whose green channel carries the alpha values, optionally followed
/// by in-place row unfiltering with the ALPH header filter.
fn decodeLossless(
    gpa: std.mem.Allocator,
    header: Header,
    stream: []const u8,
    dimensions: image.Dimensions,
    output: []u8,
) errors.Error!void {
    const pixel_count: usize = @intCast(try dimensions.pixelCount());
    if (output.len < pixel_count) return error.OutputTooLarge;

    const argb_pixels = try gpa.alloc(vp8l_pixel.Pixel, pixel_count);
    defer gpa.free(argb_pixels);

    // Capacity for one color table (256 entries plus rounding) or
    // subsampled predictor/color transform blocks, matching the public
    // static decode composition.
    const transform_pixels = try gpa.alloc(vp8l_pixel.Pixel, pixel_count + 257);
    defer gpa.free(transform_pixels);

    const entropy_image = try gpa.alloc(vp8l_pixel.Pixel, pixel_count);
    defer gpa.free(entropy_image);

    var buffers = vp8l_decoder.WorkBuffers{
        .transform_pixels = transform_pixels,
        .entropy_image = entropy_image,
    };
    _ = try vp8l_decoder.decodeImageStreamAlloc(
        gpa,
        stream,
        dimensions,
        argb_pixels,
        &buffers,
    );

    const plane = output[0..pixel_count];
    for (argb_pixels, plane) |value, *sample| {
        sample.* = vp8l_pixel.green(value);
    }

    unfilterPlaneInPlace(header.filter, plane, dimensions);
}

fn unfilterPlaneInPlace(
    filter: Filter,
    plane: []u8,
    dimensions: image.Dimensions,
) void {
    if (filter == .none) return;

    const width: usize = dimensions.width;
    const height: usize = dimensions.height;
    assert(plane.len == width * height);

    var prev_row: ?[]const u8 = null;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = plane[y * width ..][0..width];
        unfilterRow(filter, prev_row, row, row);
        prev_row = row;
    }
}

/// Decodes an uncompressed alpha stream (the ALPH payload after the header
/// byte). The stream holds one filtered byte per pixel; rows are unfiltered
/// top to bottom. Trailing stream bytes are ignored, matching libwebp.
pub fn decodeRaw(
    header: Header,
    stream: []const u8,
    dimensions: image.Dimensions,
    output: []u8,
) errors.Error!void {
    const pixel_count: usize = @intCast(try dimensions.pixelCount());
    if (output.len < pixel_count) return error.OutputTooLarge;
    if (stream.len < pixel_count) return error.TruncatedBitstream;

    const width: usize = dimensions.width;
    const height: usize = dimensions.height;

    var prev_row: ?[]const u8 = null;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row_start = y * width;
        const in = stream[row_start..][0..width];
        const out = output[row_start..][0..width];
        unfilterRow(header.filter, prev_row, in, out);
        prev_row = out;
    }
}

/// Reconstructs one row of alpha samples from filter residuals. `prev` is the
/// previously reconstructed row, or null for the topmost row.
pub fn unfilterRow(
    filter: Filter,
    prev: ?[]const u8,
    in: []const u8,
    out: []u8,
) void {
    assert(in.len == out.len);
    if (prev) |row| assert(row.len == out.len);

    switch (filter) {
        .none => @memcpy(out, in),
        .horizontal => unfilterRowHorizontal(prev, in, out),
        .vertical => {
            const row = prev orelse return unfilterRowHorizontal(null, in, out);
            for (in, row, out) |delta, above, *sample| sample.* = delta +% above;
        },
        .gradient => {
            const row = prev orelse return unfilterRowHorizontal(null, in, out);
            var left = row[0];
            var top_left = row[0];
            for (in, row, out) |delta, top, *sample| {
                left = delta +% gradientPredictor(left, top, top_left);
                top_left = top;
                sample.* = left;
            }
        },
    }
}

fn unfilterRowHorizontal(prev: ?[]const u8, in: []const u8, out: []u8) void {
    var pred: u8 = if (prev) |row| row[0] else 0;
    for (in, out) |delta, *sample| {
        pred = delta +% pred;
        sample.* = pred;
    }
}

fn gradientPredictor(left: u8, top: u8, top_left: u8) u8 {
    const prediction = @as(i16, left) + @as(i16, top) - @as(i16, top_left);
    return @intCast(std.math.clamp(prediction, 0, 255));
}

test "parses ALPH header fields" {
    const header = try parseHeader(&.{0b00_01_10_01});

    try std.testing.expectEqual(Compression.lossless, header.compression);
    try std.testing.expectEqual(Filter.vertical, header.filter);
    try std.testing.expectEqual(Preprocessing.quantized_levels, header.preprocessing);

    const raw_gradient = try parseHeader(&.{0b00_00_11_00});
    try std.testing.expectEqual(Compression.none, raw_gradient.compression);
    try std.testing.expectEqual(Filter.gradient, raw_gradient.filter);
    try std.testing.expectEqual(Preprocessing.none, raw_gradient.preprocessing);
}

test "rejects invalid ALPH headers" {
    try std.testing.expectError(error.InvalidAlphaChunk, parseHeader(&.{}));

    const invalid_compression: [2]u8 = .{ 2, 3 };
    for (invalid_compression) |byte| {
        try std.testing.expectError(error.InvalidAlphaChunk, parseHeader(&.{byte}));
    }

    const invalid_preprocessing: [2]u8 = .{ 0b10_0000, 0b11_0000 };
    for (invalid_preprocessing) |byte| {
        try std.testing.expectError(error.InvalidAlphaChunk, parseHeader(&.{byte}));
    }

    const reserved_bits: [3]u8 = .{ 0b01_000000, 0b10_000000, 0b11_000000 };
    for (reserved_bits) |byte| {
        try std.testing.expectError(error.InvalidAlphaChunk, parseHeader(&.{byte}));
    }
}

test "decodes raw alpha with no filter" {
    const dimensions = try image.Dimensions.init(3, 2);
    const payload = [_]u8{0} ++ [_]u8{ 10, 20, 30, 40, 50, 60 };
    var output: [6]u8 = undefined;

    const header = try decodePlane(&payload, dimensions, &output);

    try std.testing.expectEqual(Compression.none, header.compression);
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30, 40, 50, 60 }, &output);
}

test "decodes raw alpha with horizontal filter" {
    const dimensions = try image.Dimensions.init(2, 2);
    const payload = [_]u8{0b0100} ++ [_]u8{ 1, 2, 3, 4 };
    var output: [4]u8 = undefined;

    _ = try decodePlane(&payload, dimensions, &output);

    // Row 0 accumulates from 0; row 1 starts from the sample above.
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 4, 8 }, &output);
}

test "decodes raw alpha with vertical filter" {
    const dimensions = try image.Dimensions.init(2, 2);
    const payload = [_]u8{0b1000} ++ [_]u8{ 1, 2, 3, 4 };
    var output: [4]u8 = undefined;

    _ = try decodePlane(&payload, dimensions, &output);

    // Row 0 falls back to horizontal prediction; row 1 adds the row above.
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 4, 7 }, &output);
}

test "decodes raw alpha with gradient filter" {
    const dimensions = try image.Dimensions.init(2, 2);
    const payload = [_]u8{0b1100} ++ [_]u8{ 1, 2, 3, 4 };
    var output: [4]u8 = undefined;

    _ = try decodePlane(&payload, dimensions, &output);

    // Row 0 falls back to horizontal prediction. Row 1: the leftmost sample
    // predicts from above (clip(1 + 1 - 1) = 1), the next from
    // clip(left + top - top_left) = clip(4 + 3 - 1) = 6.
    try std.testing.expectEqualSlices(u8, &.{ 1, 3, 4, 10 }, &output);
}

test "gradient predictor clamps and samples wrap" {
    try std.testing.expectEqual(@as(u8, 0), gradientPredictor(0, 10, 200));
    try std.testing.expectEqual(@as(u8, 255), gradientPredictor(250, 100, 10));

    const dimensions = try image.Dimensions.init(2, 1);
    const payload = [_]u8{0b0100} ++ [_]u8{ 200, 100 };
    var output: [2]u8 = undefined;

    _ = try decodePlane(&payload, dimensions, &output);

    try std.testing.expectEqualSlices(u8, &.{ 200, 44 }, &output);
}

test "raw alpha round-trips through forward filtering" {
    const width = 7;
    const height = 5;
    var plane: [width * height]u8 = undefined;
    for (&plane, 0..) |*sample, index| {
        sample.* = @truncate(index *% 41 +% 13);
    }

    const filters = [_]Filter{ .none, .horizontal, .vertical, .gradient };
    for (filters) |filter| {
        var filtered: [width * height]u8 = undefined;
        forwardFilterPlane(filter, &plane, width, height, &filtered);

        const dimensions = try image.Dimensions.init(width, height);
        var decoded: [width * height]u8 = undefined;
        const header = Header{
            .compression = .none,
            .filter = filter,
            .preprocessing = .none,
        };
        try decodeRaw(header, &filtered, dimensions, &decoded);

        try std.testing.expectEqualSlices(u8, &plane, &decoded);
    }
}

test "rejects truncated and undersized raw alpha buffers" {
    const dimensions = try image.Dimensions.init(2, 2);
    var output: [4]u8 = undefined;

    const truncated = [_]u8{0} ++ [_]u8{ 1, 2, 3 };
    try std.testing.expectError(
        error.TruncatedBitstream,
        decodePlane(&truncated, dimensions, &output),
    );

    const payload = [_]u8{0} ++ [_]u8{ 1, 2, 3, 4 };
    var small_output: [3]u8 = undefined;
    try std.testing.expectError(
        error.OutputTooLarge,
        decodePlane(&payload, dimensions, &small_output),
    );

    // Trailing stream bytes are tolerated, matching libwebp.
    const trailing = [_]u8{0} ++ [_]u8{ 1, 2, 3, 4, 5 };
    _ = try decodePlane(&trailing, dimensions, &output);
}

test "allocator-free decode rejects lossless alpha compression" {
    const dimensions = try image.Dimensions.init(1, 1);
    var output: [1]u8 = undefined;
    const payload = [_]u8{ 0b01, 0x2f };

    try std.testing.expectError(
        error.UnsupportedAlphaCompression,
        decodePlane(&payload, dimensions, &output),
    );
}

test "decodes VP8L-compressed alpha with no filter" {
    const dimensions = try image.Dimensions.init(2, 1);
    var payload: [32]u8 = undefined;
    const encoded = try makeConstantLosslessAlpha(&payload, .none, 77);

    var output: [2]u8 = undefined;
    const header = try decodePlaneAlloc(
        std.testing.allocator,
        encoded,
        dimensions,
        &output,
    );

    try std.testing.expectEqual(Compression.lossless, header.compression);
    try std.testing.expectEqual(Filter.none, header.filter);
    try std.testing.expectEqualSlices(u8, &.{ 77, 77 }, &output);
}

test "decodes VP8L-compressed alpha with horizontal filter" {
    const dimensions = try image.Dimensions.init(2, 2);
    var payload: [32]u8 = undefined;
    const encoded = try makeConstantLosslessAlpha(&payload, .horizontal, 3);

    var output: [4]u8 = undefined;
    _ = try decodePlaneAlloc(std.testing.allocator, encoded, dimensions, &output);

    // The VP8L stream decodes residual 3 everywhere; rows then unfilter in
    // place: row 0 accumulates from 0, row 1 starts from the sample above.
    try std.testing.expectEqualSlices(u8, &.{ 3, 6, 6, 9 }, &output);
}

test "rejects truncated VP8L-compressed alpha streams" {
    const dimensions = try image.Dimensions.init(2, 1);
    const payload = [_]u8{0b01};

    var output: [2]u8 = undefined;
    try std.testing.expectError(
        error.TruncatedBitstream,
        decodePlaneAlloc(std.testing.allocator, &payload, dimensions, &output),
    );
}

/// Test-only writer for a lossless ALPH payload holding a headerless VP8L
/// stream whose green channel is a constant residual value.
fn makeConstantLosslessAlpha(
    out: []u8,
    filter: Filter,
    green: u8,
) errors.Error![]const u8 {
    out[0] = @as(u8, @intFromEnum(Compression.lossless)) |
        (@as(u8, @intFromEnum(filter)) << 2);

    var writer = bit_writer.BitWriter.init(out[header_size..]);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writer.writeBit(0);
    try writeSimplePrefixCode(&writer, green);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 0);
    try writeSimplePrefixCode(&writer, 255);
    try writeSimplePrefixCode(&writer, 0);
    const stream = try writer.finish();

    return out[0 .. header_size + stream.len];
}

fn writeSimplePrefixCode(writer: *bit_writer.BitWriter, symbol: u8) errors.Error!void {
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(if (symbol <= 1) 0 else 1);
    try writer.writeBits(symbol, if (symbol <= 1) 1 else 8);
}

/// Test-only forward filter applying the spec predictors in encode direction.
fn forwardFilterPlane(
    filter: Filter,
    plane: []const u8,
    width: usize,
    height: usize,
    out: []u8,
) void {
    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const index = y * width + x;
            const value = plane[index];
            const left = if (x > 0) plane[index - 1] else null;
            const top = if (y > 0) plane[index - width] else null;
            const top_left = if (x > 0 and y > 0) plane[index - width - 1] else null;

            const prediction: u8 = switch (filter) {
                .none => 0,
                .horizontal => left orelse top orelse 0,
                .vertical => top orelse left orelse 0,
                .gradient => prediction: {
                    if (top == null) break :prediction left orelse 0;
                    if (left == null) break :prediction top.?;
                    break :prediction gradientPredictor(left.?, top.?, top_left.?);
                },
            };

            out[index] = value -% prediction;
        }
    }
}

test "fuzz alpha plane decode" {
    const testing_fuzz = @import("testing/fuzz.zig");

    // A valid seed: uncompressed, unfiltered header byte plus an 8x8 plane.
    const plane_payload = [_]u8{0} ++ [_]u8{0x80} ** 64;
    var seed_buffer: [plane_payload.len + testing_fuzz.slice_length_prefix_size]u8 = undefined;
    const seed = testing_fuzz.sliceCorpusEntry(&seed_buffer, &plane_payload);

    try std.testing.fuzz({}, fuzzDecodePlaneOne, .{ .corpus = &.{seed} });
}

fn fuzzDecodePlaneOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [1024]u8 = undefined;
    const input_len = smith.slice(&input_buffer);

    const dimensions = try image.Dimensions.init(8, 8);
    var output: [64]u8 = undefined;
    _ = decodePlaneAlloc(
        std.testing.allocator,
        input_buffer[0..input_len],
        dimensions,
        &output,
    ) catch return;
}
