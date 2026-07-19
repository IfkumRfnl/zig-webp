//! ALPH chunk header parsing and alpha-plane decoding.

const std = @import("std");
const assert = std.debug.assert;

const bit_writer = @import("bit_writer.zig");
const errors = @import("errors.zig");
const image = @import("image.zig");
const limits = @import("limits.zig");
const vp8l_decoder = @import("vp8l/decoder.zig");
const vp8l_encoder = @import("vp8l/encoder.zig");
const vp8l_pixel = @import("vp8l/pixel.zig");
const vp8l_meta_prefix = @import("vp8l/meta_prefix.zig");
const vp8l_transform = @import("vp8l/transform.zig");

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

pub const DecodeAllocOptions = struct {
    allocation_bytes_max: u64 = (limits.ResourceLimits{}).allocation_bytes_max,
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
    return decodePlaneAllocWithOptions(gpa, payload, dimensions, output, .{});
}

pub fn decodePlaneAllocWithOptions(
    gpa: std.mem.Allocator,
    payload: []const u8,
    dimensions: image.Dimensions,
    output: []u8,
    decode_options: DecodeAllocOptions,
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
            decode_options,
        ),
    }

    return header;
}
/// Decodes a VP8L-compressed alpha stream: a headerless VP8L image-data
/// stream whose green channel carries the alpha values, optionally followed
/// by in-place row unfiltering with the ALPH header filter.
const lossless_stack_pixel_count = 10_000;

fn decodeLossless(
    gpa: std.mem.Allocator,
    header: Header,
    stream: []const u8,
    dimensions: image.Dimensions,
    output: []u8,
    decode_options: DecodeAllocOptions,
) errors.Error!void {
    const pixel_count = try dimensions.pixelCount();
    if (pixel_count <= lossless_stack_pixel_count) {
        return decodeLosslessStack(
            gpa,
            header,
            stream,
            dimensions,
            output,
            decode_options,
        );
    }
    return decodeLosslessWithScratch(
        gpa,
        header,
        stream,
        dimensions,
        output,
        decode_options,
        &.{},
    );
}

noinline fn decodeLosslessStack(
    gpa: std.mem.Allocator,
    header: Header,
    stream: []const u8,
    dimensions: image.Dimensions,
    output: []u8,
    decode_options: DecodeAllocOptions,
) errors.Error!void {
    var pixel_scratch: [lossless_stack_pixel_count]vp8l_pixel.Pixel = undefined;
    return decodeLosslessWithScratch(
        gpa,
        header,
        stream,
        dimensions,
        output,
        decode_options,
        &pixel_scratch,
    );
}

fn decodeLosslessWithScratch(
    gpa: std.mem.Allocator,
    header: Header,
    stream: []const u8,
    dimensions: image.Dimensions,
    output: []u8,
    decode_options: DecodeAllocOptions,
    pixel_scratch: []vp8l_pixel.Pixel,
) errors.Error!void {
    const pixel_count_u64 = try dimensions.pixelCount();
    const pixel_count: usize = @intCast(pixel_count_u64);
    if (output.len < pixel_count) return error.OutputTooLarge;

    var allocation_bytes: u64 = 0;
    const argb_count = try reserveElements(
        vp8l_pixel.Pixel,
        pixel_count_u64,
        &allocation_bytes,
        decode_options,
    );
    const transform_count = try reserveElements(
        vp8l_pixel.Pixel,
        try transformPixelCapacityForStream(dimensions, stream),
        &allocation_bytes,
        decode_options,
    );
    const entropy_count = try reserveElements(
        vp8l_pixel.Pixel,
        if (pixel_count_u64 < 16384) 0 else try entropyPixelCapacity(dimensions),
        &allocation_bytes,
        decode_options,
    );

    var pixel_storage_count = argb_count;
    if (transform_count > std.math.maxInt(usize) - pixel_storage_count) {
        return error.AllocationLimitExceeded;
    }
    pixel_storage_count += transform_count;
    if (entropy_count > std.math.maxInt(usize) - pixel_storage_count) {
        return error.AllocationLimitExceeded;
    }
    pixel_storage_count += entropy_count;

    const pixel_storage_owned = pixel_storage_count > pixel_scratch.len;
    const pixel_storage = if (pixel_storage_count <= pixel_scratch.len)
        pixel_scratch[0..pixel_storage_count]
    else
        try gpa.alloc(vp8l_pixel.Pixel, pixel_storage_count);
    defer if (pixel_storage_owned) gpa.free(pixel_storage);

    const argb_pixels = pixel_storage[0..argb_count];
    // Capacity for one color table (256 entries plus rounding) or subsampled
    // predictor/color transform blocks, matching static decode composition.
    const transform_start = argb_count;
    const transform_pixels = pixel_storage[transform_start..][0..transform_count];
    const entropy_start = transform_start + transform_count;
    const entropy_image = pixel_storage[entropy_start..][0..entropy_count];

    var buffers = vp8l_decoder.WorkBuffers{
        .transform_pixels = transform_pixels,
        .entropy_image = entropy_image,
        .prefix_group_options = .{
            .allocation_bytes_max = decode_options.allocation_bytes_max - allocation_bytes,
        },
    };
    const plane = output[0..pixel_count];
    try vp8l_decoder.decodeImageStreamAlphaAllocDiscardSummary(
        gpa,
        stream,
        dimensions,
        argb_pixels,
        plane,
        &buffers,
    );

    unfilterPlaneInPlace(header.filter, plane, dimensions);
}

fn reserveElements(
    comptime T: type,
    count: u64,
    allocation_bytes: *u64,
    decode_options: DecodeAllocOptions,
) errors.Error!usize {
    if (count > std.math.maxInt(usize)) return error.AllocationLimitExceeded;
    if (count > std.math.maxInt(u64) / @sizeOf(T)) return error.AllocationLimitExceeded;

    const bytes = count * @sizeOf(T);
    if (bytes > std.math.maxInt(u64) - allocation_bytes.*) {
        return error.AllocationLimitExceeded;
    }

    const total_bytes = allocation_bytes.* + bytes;
    if (total_bytes > decode_options.allocation_bytes_max) {
        return error.AllocationLimitExceeded;
    }
    allocation_bytes.* = total_bytes;

    return @intCast(count);
}

fn blockImagePixelCapacity(
    dimensions: image.Dimensions,
    block_bits: u4,
) errors.Error!u64 {
    const block_size = @as(u64, 1) << @intCast(block_bits);
    const width: u64 = dimensions.width;
    const height: u64 = dimensions.height;
    const block_width = @divFloor(width, block_size) + @intFromBool(width % block_size != 0);
    const block_height = @divFloor(height, block_size) + @intFromBool(height % block_size != 0);
    return std.math.mul(u64, block_width, block_height) catch
        error.AllocationLimitExceeded;
}

// Predictor and color are the only block transforms and each kind may occur
// once. Their minimum block size is 4x4. A color-indexing transform contributes
// at most 256 pixels and can only shrink the width seen by later transforms, so
// two block images at the original dimensions plus one table covers every order.
fn transformPixelCapacity(dimensions: image.Dimensions) errors.Error!u64 {
    const block_count = try blockImagePixelCapacity(
        dimensions,
        vp8l_transform.block_bits_min,
    );
    const two_block_images = std.math.mul(u64, block_count, 2) catch
        return error.AllocationLimitExceeded;
    return std.math.add(
        u64,
        two_block_images,
        vp8l_transform.color_table_size_max,
    ) catch error.AllocationLimitExceeded;
}

// The main image can only be narrower after color indexing. The minimum
// meta-prefix block size is 4x4, so original dimensions are conservative.
fn entropyPixelCapacity(dimensions: image.Dimensions) errors.Error!u64 {
    return blockImagePixelCapacity(dimensions, vp8l_meta_prefix.prefix_bits_min);
}

fn transformPixelCapacityForStream(
    dimensions: image.Dimensions,
    stream: []const u8,
) errors.Error!u64 {
    if (stream.len > 0 and (stream[0] & 1) == 0) return 0;
    return transformPixelCapacity(dimensions);
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

// ---------------------------------------------------------------------------
// Alpha-plane encoding (the inverse of the decode paths above).
//
// An ALPH chunk is a 1-byte header (compression, filter, preprocessing,
// reserved) followed by the alpha stream. We always preprocess = none (lossless
// alpha; the levels-quantization preprocessing is a lossy optimization we leave
// for later). Two compressions are produced and the smaller is kept:
//   - none: the forward-filtered plane verbatim (one byte per pixel);
//   - lossless: the forward-filtered plane carried in the green channel of a
//     headerless VP8L image stream, exactly what `decodeLossless` reads back.
// Either way the decode side reconstructs the plane bit-exactly, so lossy+alpha
// WebP round-trips its alpha losslessly.
// ---------------------------------------------------------------------------

/// The four candidate row filters, tried in turn so the cheapest encoded plane
/// wins. `none` is always valid; the others reduce residual entropy on smooth
/// or structured alpha.
const filter_candidates = [_]Filter{ .none, .horizontal, .vertical, .gradient };

/// Encodes an alpha plane (one byte per pixel, `dimensions.width *
/// dimensions.height` long, row-major) into a complete ALPH chunk payload
/// (header byte included). The result is caller-owned (free with `gpa`).
///
/// `alpha_quality` selects the compression effort: 0 forces the uncompressed
/// form (fastest, largest); 1..100 enables the lossless VP8L form and keeps
/// whichever of {uncompressed, VP8L} is smaller. Alpha is always lossless here
/// regardless of the value — the quality knob only trades encode work for size,
/// it never degrades the recovered alpha. The chosen filter is the one with the
/// smallest encoded stream.
pub fn encodePlaneAlloc(
    gpa: std.mem.Allocator,
    plane: []const u8,
    dimensions: image.Dimensions,
    alpha_quality: u8,
) errors.Error![]u8 {
    const pixel_count: usize = @intCast(try dimensions.pixelCount());
    assert(plane.len == pixel_count);

    const filtered = try gpa.alloc(u8, pixel_count);
    defer gpa.free(filtered);

    // alpha_quality 0 forces the uncompressed form; any positive value also
    // tries the lossless VP8L form and keeps whichever is smaller.
    const try_lossless = alpha_quality > 0;

    var best: ?[]u8 = null;
    errdefer if (best) |payload| gpa.free(payload);
    var best_stream_len: usize = std.math.maxInt(usize);

    for (filter_candidates) |filter| {
        forwardFilterPlane(filter, plane, dimensions, filtered);

        // Uncompressed candidate: header byte + filtered plane.
        const raw_stream_len = pixel_count;
        if (raw_stream_len < best_stream_len) {
            const payload = try gpa.alloc(u8, header_size + raw_stream_len);
            payload[0] = encodeHeaderByte(.none, filter, .none);
            @memcpy(payload[header_size..], filtered);
            if (best) |old| gpa.free(old);
            best = payload;
            best_stream_len = raw_stream_len;
        }

        if (!try_lossless) continue;

        // Lossless candidate: the filtered bytes in the green channel of a
        // headerless VP8L image stream.
        const stream = try encodeLosslessStream(gpa, filtered, dimensions);
        defer gpa.free(stream);
        if (stream.len < best_stream_len) {
            const payload = try gpa.alloc(u8, header_size + stream.len);
            payload[0] = encodeHeaderByte(.lossless, filter, .none);
            @memcpy(payload[header_size..], stream);
            if (best) |old| gpa.free(old);
            best = payload;
            best_stream_len = stream.len;
        }
    }

    // A non-empty plane always produces at least the uncompressed candidate.
    assert(best != null);
    return best.?;
}

/// Returns true when the plane carries meaningful (non-fully-opaque) alpha. A
/// fully-opaque plane needs no ALPH chunk, so callers skip alpha encoding and
/// emit a plain `VP8 ` file.
pub fn planeHasTransparency(plane: []const u8) bool {
    for (plane) |sample| {
        if (sample != 255) return true;
    }
    return false;
}

/// Packs the ALPH header byte: compression in bits 0..1, filter in bits 2..3,
/// preprocessing in bits 4..5, reserved bits 6..7 left zero — exactly the
/// layout `parseHeader` decodes.
fn encodeHeaderByte(
    compression: Compression,
    filter: Filter,
    preprocessing: Preprocessing,
) u8 {
    return @as(u8, @intFromEnum(compression)) |
        (@as(u8, @intFromEnum(filter)) << 2) |
        (@as(u8, @intFromEnum(preprocessing)) << 4);
}

/// Compresses a filtered alpha plane as a headerless VP8L image stream whose
/// green channel carries each filtered byte (red/blue 0, alpha 255 = opaque so
/// the stream itself stays alpha-free). This is the exact inverse of
/// `decodeLossless`, which reads the green channel back out. Caller owns the
/// returned bytes (free with `gpa`).
fn encodeLosslessStream(
    gpa: std.mem.Allocator,
    filtered: []const u8,
    dimensions: image.Dimensions,
) errors.Error![]u8 {
    const pixel_count = filtered.len;
    const pixels = try gpa.alloc(vp8l_pixel.Pixel, pixel_count);
    defer gpa.free(pixels);
    for (filtered, pixels) |sample, *value| {
        value.* = vp8l_pixel.fromChannels(255, 0, sample, 0);
    }
    return vp8l_encoder.encodeImageStreamAlloc(gpa, dimensions, pixels);
}

/// Forward row-filters the plane in encode direction: `residual = value -
/// prediction`, where the prediction is the spec predictor over the original
/// (= reconstructed, since lossless) neighbors. This mirrors `unfilterRow`'s
/// per-filter edge fallbacks (vertical/gradient fall back to horizontal on the
/// top row; horizontal predicts from the pixel above at x == 0).
pub fn forwardFilterPlane(
    filter: Filter,
    plane: []const u8,
    dimensions: image.Dimensions,
    out: []u8,
) void {
    const width: usize = dimensions.width;
    const height: usize = dimensions.height;
    assert(plane.len == width * height);
    assert(out.len == plane.len);

    if (filter == .none) {
        @memcpy(out, plane);
        return;
    }

    var y: usize = 0;
    while (y < height) : (y += 1) {
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const index = y * width + x;
            const value = plane[index];
            const left = if (x > 0) plane[index - 1] else null;
            const top = if (y > 0) plane[index - width] else null;
            const top_left = if (x > 0 and y > 0) plane[index - width - 1] else null;

            const prediction = forwardPrediction(filter, left, top, top_left);
            out[index] = value -% prediction;
        }
    }
}

fn forwardPrediction(filter: Filter, left: ?u8, top: ?u8, top_left: ?u8) u8 {
    return switch (filter) {
        .none => 0,
        .horizontal => left orelse top orelse 0,
        .vertical => top orelse left orelse 0,
        .gradient => prediction: {
            if (top == null) break :prediction left orelse 0;
            if (left == null) break :prediction top.?;
            break :prediction gradientPredictor(left.?, top.?, top_left.?);
        },
    };
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

test "compressed alpha allocation options use the resource default" {
    try std.testing.expectEqual(
        (limits.ResourceLimits{}).allocation_bytes_max,
        (DecodeAllocOptions{}).allocation_bytes_max,
    );
}

test "compressed alpha scratch capacities use rounded format bounds" {
    const rounded = try image.Dimensions.init(5, 9);
    try std.testing.expectEqual(@as(u64, 6), try entropyPixelCapacity(rounded));
    try std.testing.expectEqual(@as(u64, 268), try transformPixelCapacity(rounded));

    const maximum = try image.Dimensions.init(
        vp8l_encoder.dimension_max,
        vp8l_encoder.dimension_max,
    );
    try std.testing.expectEqual(
        @as(u64, 16_777_216),
        try entropyPixelCapacity(maximum),
    );
    try std.testing.expectEqual(
        @as(u64, 33_554_688),
        try transformPixelCapacity(maximum),
    );
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

    const dimensions = try image.Dimensions.init(width, height);
    for (filter_candidates) |filter| {
        var filtered: [width * height]u8 = undefined;
        forwardFilterPlane(filter, &plane, dimensions, &filtered);

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

test "compressed alpha decode enforces the exact reconstruction budget" {
    const dimensions = try image.Dimensions.init(2, 1);
    var payload: [32]u8 = undefined;
    const encoded = try makeConstantLosslessAlpha(&payload, .none, 77);
    var output: [2]u8 = undefined;

    _ = try decodePlaneAllocWithOptions(
        std.testing.allocator,
        encoded,
        dimensions,
        &output,
        .{ .allocation_bytes_max = 8 },
    );
    try std.testing.expectError(
        error.AllocationLimitExceeded,
        decodePlaneAllocWithOptions(
            std.testing.allocator,
            encoded,
            dimensions,
            &output,
            .{ .allocation_bytes_max = 7 },
        ),
    );
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

test "fuzz alpha plane decode" {
    const testing_fuzz = @import("testing/fuzz.zig");

    // A valid seed: uncompressed, unfiltered header byte plus an 8x8 plane.
    const plane_payload = [_]u8{0} ++ [_]u8{0x80} ** 64;
    var seed_buffer: [plane_payload.len + testing_fuzz.slice_length_prefix_size]u8 = undefined;
    const seed = testing_fuzz.sliceCorpusEntry(&seed_buffer, &plane_payload);

    try std.testing.fuzz({}, fuzzDecodePlaneOne, .{ .corpus = &.{seed} });
}

test "bounded mutation exploration of alpha plane decode" {
    const testing_fuzz = @import("testing/fuzz.zig");

    // A valid seed: uncompressed, unfiltered header byte plus an 8x8 plane.
    const plane_payload = [_]u8{0} ++ [_]u8{0x80} ** 64;

    try testing_fuzz.runMutations(fuzzDecodePlaneOne, &plane_payload, .{ .prng_seed = 0x11d_0003 });
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

fn decodePlaneAllocationProbe(gpa: std.mem.Allocator, payload: []const u8) !void {
    const dimensions = try image.Dimensions.init(2, 1);
    var output: [2]u8 = undefined;
    _ = try decodePlaneAlloc(gpa, payload, dimensions, &output);
}

test "compressed alpha decode survives allocation failure at every site" {
    // Exercise the VP8L-compressed branch (decodeLossless), which makes the
    // allocations; the uncompressed branch allocates nothing. The probe's
    // 2x1 dimensions match this single-color stream.
    var payload: [32]u8 = undefined;
    const encoded = try makeConstantLosslessAlpha(&payload, .none, 77);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        decodePlaneAllocationProbe,
        .{encoded},
    );
}
