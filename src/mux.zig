//! RIFF/WebP muxing for valid static-image containers.

const std = @import("std");
const assert = std.debug.assert;

const container = @import("container.zig");
const demux = @import("demux.zig");
const errors = @import("errors.zig");
const features = @import("features.zig");
const image = @import("image.zig");
const limits = @import("limits.zig");
const metadata = @import("metadata.zig");

pub const Options = struct {
    limits: limits.ResourceLimits = .{},
    force_extended: bool = false,
};

pub const RawChunk = struct {
    tag: container.FourCC,
    payload: []const u8,
};

pub const StaticImage = struct {
    canvas: image.Dimensions,
    format: features.FormatKind,
    bitstream: []const u8,
    alpha: ?[]const u8 = null,
    has_alpha: bool = false,
    metadata: metadata.RawPayloads = .{},
    unknown_chunks: []const RawChunk = &.{},
    force_extended: bool = false,
};

pub fn encodeStatic(
    gpa: std.mem.Allocator,
    static_image: StaticImage,
    options: Options,
) errors.Error![]u8 {
    try options.limits.validateCanvas(
        static_image.canvas.width,
        static_image.canvas.height,
        false,
    );
    try validateVP8XCanvas(static_image.canvas);

    const metadata_presence = static_image.metadata.presence();
    const use_extended = options.force_extended or
        static_image.force_extended or
        metadata_presence.any() or
        static_image.alpha != null or
        static_image.unknown_chunks.len != 0;

    const chunk_count = try encodedChunkCount(
        static_image.metadata,
        static_image.alpha != null,
        static_image.unknown_chunks.len,
        use_extended,
    );
    try options.limits.validateChunkCount(chunk_count);

    try validateUnknownChunks(static_image.unknown_chunks);

    const bitstream = try demux.parseBitstreamInfo(
        static_image.format.chunkKind(),
        static_image.bitstream,
    );
    if (bitstream.format != static_image.format) return error.InvalidMuxChunk;
    if (bitstream.dimensions.width != static_image.canvas.width) return error.InvalidMuxChunk;
    if (bitstream.dimensions.height != static_image.canvas.height) return error.InvalidMuxChunk;
    if (static_image.alpha != null and static_image.format != .lossy) {
        return error.InvalidMuxChunk;
    }
    if (static_image.alpha) |payload| {
        try validateAlphaPayload(payload, static_image.canvas);
    }

    if (static_image.format == .lossless and static_image.has_alpha and !bitstream.has_alpha) {
        return error.InvalidMuxChunk;
    }

    const has_alpha = switch (static_image.format) {
        .lossy => static_image.has_alpha or
            (static_image.alpha != null) or
            bitstream.has_alpha,
        .lossless => bitstream.has_alpha,
    };
    if (static_image.format == .lossy and has_alpha and static_image.alpha == null) {
        return error.MissingRequiredChunk;
    }

    const riff_payload_size = try encodedPayloadSize(static_image, use_extended, has_alpha);
    if (riff_payload_size > container.riff_payload_size_max) return error.FileTooLarge;

    const file_size = riff_payload_size + 8;
    try options.limits.validateAllocationBytes(file_size);

    const out = try gpa.alloc(u8, @intCast(file_size));
    errdefer gpa.free(out);

    @memcpy(out[0..4], "RIFF");
    container.writeLittleU32(out[4..8], @intCast(riff_payload_size));
    @memcpy(out[8..12], "WEBP");

    var offset: usize = container.riff_header_size;
    if (use_extended) {
        var vp8x_payload: [10]u8 = undefined;
        writeVP8X(&vp8x_payload, static_image.canvas, static_image.metadata, has_alpha);
        writeChunk(out, &offset, container.FourCC.fromString("VP8X"), &vp8x_payload);
    }

    if (static_image.metadata.color_profile) |payload| {
        writeChunk(out, &offset, container.FourCC.fromString("ICCP"), payload);
    }
    if (static_image.alpha) |payload| {
        writeChunk(out, &offset, container.FourCC.fromString("ALPH"), payload);
    }

    const bitstream_tag = switch (static_image.format) {
        .lossy => container.FourCC.fromString("VP8 "),
        .lossless => container.FourCC.fromString("VP8L"),
    };
    writeChunk(out, &offset, bitstream_tag, static_image.bitstream);

    if (static_image.metadata.exif) |payload| {
        writeChunk(out, &offset, container.FourCC.fromString("EXIF"), payload);
    }
    if (static_image.metadata.xmp) |payload| {
        writeChunk(out, &offset, container.FourCC.fromString("XMP "), payload);
    }
    for (static_image.unknown_chunks) |chunk| {
        writeChunk(out, &offset, chunk.tag, chunk.payload);
    }

    assert(offset == out.len);
    return out;
}

pub fn encodeStaticFromDemux(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    parsed: demux.Result,
    options: Options,
) errors.Error![]u8 {
    if (parsed.features.is_animation) return error.UnsupportedAnimationMux;

    const image_chunk = parsed.features.image_data orelse return error.MissingImageData;
    const format = parsed.features.format orelse return error.MissingImageData;
    const alpha_raw = if (parsed.features.alpha) |chunk| chunk.payload(bytes) else null;
    const raw_metadata = parsed.metadataPayloads(bytes);
    const force_extended = parsed.features.file_kind == .extended;

    const metadata_presence = raw_metadata.presence();
    const use_extended = options.force_extended or
        force_extended or
        metadata_presence.any() or
        alpha_raw != null or
        parsed.unknown_chunks.len != 0;
    const chunk_count = try encodedChunkCount(
        raw_metadata,
        alpha_raw != null,
        parsed.unknown_chunks.len,
        use_extended,
    );
    try options.limits.validateChunkCount(chunk_count);

    var alpha_canonical: []u8 = &.{};
    defer gpa.free(alpha_canonical);
    const alpha = if (alpha_raw) |payload| alpha: {
        if (payload.len < 2) break :alpha payload;
        if ((payload[0] & 0xc0) == 0) break :alpha payload;

        const allocation_size: u64 = @intCast(payload.len);
        try options.limits.validateAllocationBytes(allocation_size);
        alpha_canonical = try gpa.dupe(u8, payload);
        alpha_canonical[0] &= 0x3f;
        break :alpha alpha_canonical;
    } else null;

    var unknown_chunks: []RawChunk = &.{};
    if (parsed.unknown_chunks.len != 0) {
        const allocation_size = @as(u64, parsed.unknown_chunks.len) * @sizeOf(RawChunk);
        try options.limits.validateAllocationBytes(allocation_size);
        unknown_chunks = try gpa.alloc(RawChunk, parsed.unknown_chunks.len);
    }
    defer gpa.free(unknown_chunks);

    for (parsed.unknown_chunks, 0..) |chunk, index| {
        unknown_chunks[index] = .{
            .tag = chunk.tag,
            .payload = chunk.payload(bytes),
        };
    }

    return encodeStatic(gpa, .{
        .canvas = parsed.features.canvas,
        .format = format,
        .bitstream = image_chunk.payload(bytes),
        .alpha = alpha,
        .has_alpha = parsed.features.has_alpha,
        .metadata = raw_metadata,
        .unknown_chunks = unknown_chunks,
        .force_extended = force_extended,
    }, .{
        .limits = options.limits,
        .force_extended = options.force_extended,
    });
}

fn encodedChunkCount(
    raw_metadata: metadata.RawPayloads,
    has_alpha_chunk: bool,
    unknown_chunks_len: usize,
    use_extended: bool,
) errors.Error!u64 {
    var count: u64 = 1;

    if (use_extended) count = try addEncodedChunkCount(count, 1);
    if (raw_metadata.color_profile != null) count = try addEncodedChunkCount(count, 1);
    if (has_alpha_chunk) count = try addEncodedChunkCount(count, 1);
    if (raw_metadata.exif != null) count = try addEncodedChunkCount(count, 1);
    if (raw_metadata.xmp != null) count = try addEncodedChunkCount(count, 1);

    const unknown_chunk_count = std.math.cast(u64, unknown_chunks_len) orelse {
        return error.TooManyChunks;
    };
    count = try addEncodedChunkCount(count, unknown_chunk_count);

    return count;
}

fn addEncodedChunkCount(count: u64, increment: u64) errors.Error!u64 {
    return std.math.add(u64, count, increment) catch return error.TooManyChunks;
}

fn encodedPayloadSize(
    static_image: StaticImage,
    use_extended: bool,
    has_alpha: bool,
) errors.Error!u64 {
    var size: u64 = container.fourcc_size;

    if (use_extended) {
        _ = has_alpha;
        size += try encodedChunkSize(10);
    }
    if (static_image.metadata.color_profile) |payload| {
        size += try encodedChunkSize(payload.len);
    }
    if (static_image.alpha) |payload| {
        size += try encodedChunkSize(payload.len);
    }
    size += try encodedChunkSize(static_image.bitstream.len);
    if (static_image.metadata.exif) |payload| {
        size += try encodedChunkSize(payload.len);
    }
    if (static_image.metadata.xmp) |payload| {
        size += try encodedChunkSize(payload.len);
    }
    for (static_image.unknown_chunks) |chunk| {
        size += try encodedChunkSize(chunk.payload.len);
    }

    return size;
}

fn encodedChunkSize(payload_len: usize) errors.Error!u64 {
    if (payload_len > std.math.maxInt(u32)) return error.ChunkTooLarge;

    const payload_size: u64 = payload_len;
    return container.chunk_header_size + payload_size + (payload_size & 1);
}

fn writeVP8X(
    payload: *[10]u8,
    canvas: image.Dimensions,
    raw_metadata: metadata.RawPayloads,
    has_alpha: bool,
) void {
    payload.* = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    if (raw_metadata.color_profile != null) payload[0] |= 0x20;
    if (has_alpha) payload[0] |= 0x10;
    if (raw_metadata.exif != null) payload[0] |= 0x08;
    if (raw_metadata.xmp != null) payload[0] |= 0x04;

    container.writeLittleU24(payload[4..7], canvas.width - 1);
    container.writeLittleU24(payload[7..10], canvas.height - 1);
}

fn writeChunk(
    out: []u8,
    offset: *usize,
    tag: container.FourCC,
    payload: []const u8,
) void {
    assert(payload.len <= std.math.maxInt(u32));
    assert(out.len >= offset.* + container.chunk_header_size + payload.len);

    @memcpy(out[offset.*..][0..container.fourcc_size], tag.bytes[0..]);
    offset.* += container.fourcc_size;
    container.writeLittleU32(out[offset.*..][0..4], @intCast(payload.len));
    offset.* += 4;
    @memcpy(out[offset.*..][0..payload.len], payload);
    offset.* += payload.len;
    if ((payload.len & 1) != 0) {
        out[offset.*] = 0;
        offset.* += 1;
    }
}

fn validateVP8XCanvas(canvas: image.Dimensions) errors.Error!void {
    if (canvas.width > 0x0100_0000) return error.InvalidCanvasSize;
    if (canvas.height > 0x0100_0000) return error.InvalidCanvasSize;
}

fn validateUnknownChunks(chunks: []const RawChunk) errors.Error!void {
    for (chunks) |chunk| {
        if (chunk.tag.kind() != .unknown) return error.InvalidMuxChunk;
    }
}

fn validateAlphaPayload(
    payload: []const u8,
    dimensions: image.Dimensions,
) errors.Error!void {
    if (payload.len < 2) return error.InvalidAlphaChunk;

    const header = payload[0];
    if ((header & 0xc0) != 0) return error.InvalidAlphaChunk;

    const compression = header & 0x03;
    if (compression > 1) return error.InvalidAlphaChunk;

    const preprocessing = (header >> 4) & 0x03;
    if (preprocessing > 1) return error.InvalidAlphaChunk;

    if (compression == 0) {
        const pixel_count = try dimensions.pixelCount();
        const expected_len = pixel_count + 1;
        const payload_len: u64 = @intCast(payload.len);
        if (payload_len != expected_len) return error.InvalidAlphaChunk;
    }
}

fn makeSimpleVP8(width: u16, height: u16) [10]u8 {
    var payload = [_]u8{ 0x10, 0, 0, 0x9d, 0x01, 0x2a, 0, 0, 0, 0 };
    container.writeLittleU16(payload[6..8], width);
    container.writeLittleU16(payload[8..10], height);

    return payload;
}

fn makeSimpleVP8L(width: u32, height: u32, has_alpha: bool) [5]u8 {
    assert(width > 0);
    assert(height > 0);
    assert(width <= 16_384);
    assert(height <= 16_384);

    var payload: [5]u8 = .{ 0x2f, 0, 0, 0, 0 };
    const bits = (width - 1) |
        ((height - 1) << 14) |
        (@as(u32, @intFromBool(has_alpha)) << 28);
    container.writeLittleU32(payload[1..5], bits);

    return payload;
}

test "muxes a simple lossless-free lossy file" {
    const vp8 = makeSimpleVP8(8, 6);
    const encoded = try encodeStatic(std.testing.allocator, .{
        .canvas = try image.Dimensions.init(8, 6),
        .format = .lossy,
        .bitstream = &vp8,
    }, .{});
    defer std.testing.allocator.free(encoded);

    var parsed = try demux.parse(std.testing.allocator, encoded, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(features.FileKind.simple, parsed.features.file_kind);
    try std.testing.expectEqual(features.FormatKind.lossy, parsed.features.format.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.chunks.len);
}

test "enforces configured chunk count limits while muxing" {
    const vp8 = makeSimpleVP8(1, 1);

    try std.testing.expectError(
        error.TooManyChunks,
        encodeStatic(std.testing.allocator, .{
            .canvas = try image.Dimensions.init(1, 1),
            .format = .lossy,
            .bitstream = &vp8,
        }, .{
            .limits = .{ .chunk_count_max = 0 },
        }),
    );

    const unknown = [_]RawChunk{
        .{
            .tag = container.FourCC.fromString("zzzz"),
            .payload = "",
        },
    };
    try std.testing.expectError(
        error.TooManyChunks,
        encodeStatic(std.testing.allocator, .{
            .canvas = try image.Dimensions.init(1, 1),
            .format = .lossy,
            .bitstream = &vp8,
            .unknown_chunks = &unknown,
        }, .{
            .limits = .{ .chunk_count_max = 2 },
        }),
    );
}

test "rejects malformed lossy frame tags" {
    const canvas = try image.Dimensions.init(1, 1);

    var unsupported_profile = makeSimpleVP8(1, 1);
    container.writeLittleU24(unsupported_profile[0..3], 0x10 | (@as(u32, 4) << 1));
    try std.testing.expectError(
        error.InvalidVP8Header,
        encodeStatic(std.testing.allocator, .{
            .canvas = canvas,
            .format = .lossy,
            .bitstream = &unsupported_profile,
        }, .{}),
    );

    var oversized_partition = makeSimpleVP8(1, 1);
    const first_partition_length: u32 = @intCast(oversized_partition.len);
    container.writeLittleU24(oversized_partition[0..3], 0x10 | (first_partition_length << 5));
    try std.testing.expectError(
        error.InvalidVP8Header,
        encodeStatic(std.testing.allocator, .{
            .canvas = canvas,
            .format = .lossy,
            .bitstream = &oversized_partition,
        }, .{}),
    );
}

test "preserves static metadata and unknown chunks through demux and mux" {
    const vp8 = makeSimpleVP8(4, 4);
    const unknown = [_]RawChunk{
        .{
            .tag = container.FourCC.fromString("zzzz"),
            .payload = "future",
        },
    };
    const encoded = try encodeStatic(std.testing.allocator, .{
        .canvas = try image.Dimensions.init(4, 4),
        .format = .lossy,
        .bitstream = &vp8,
        .metadata = .{
            .color_profile = "icc",
            .exif = "exif",
            .xmp = "xmp",
        },
        .unknown_chunks = &unknown,
        .force_extended = true,
    }, .{});
    defer std.testing.allocator.free(encoded);

    var parsed = try demux.parse(std.testing.allocator, encoded, .{});
    defer parsed.deinit();

    const payloads = parsed.metadataPayloads(encoded);
    try std.testing.expectEqualSlices(u8, "icc", payloads.color_profile.?);
    try std.testing.expectEqualSlices(u8, "exif", payloads.exif.?);
    try std.testing.expectEqualSlices(u8, "xmp", payloads.xmp.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.unknown_chunks.len);

    const remuxed = try encodeStaticFromDemux(std.testing.allocator, encoded, parsed, .{});
    defer std.testing.allocator.free(remuxed);

    try std.testing.expectEqualSlices(u8, encoded, remuxed);
}

test "canonicalizes demuxed alpha reserved bits while remuxing" {
    const vp8 = makeSimpleVP8(1, 1);
    const vp8x = [_]u8{ 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const alpha_reserved = [_]u8{ 0xc0, 0xff };
    const riff_payload_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + alpha_reserved.len) +
        (container.chunk_header_size + vp8.len);
    var encoded: [8 + riff_payload_size]u8 = undefined;
    @memcpy(encoded[0..4], "RIFF");
    container.writeLittleU32(encoded[4..8], riff_payload_size);
    @memcpy(encoded[8..12], "WEBP");
    var offset: usize = container.riff_header_size;
    writeChunk(&encoded, &offset, container.FourCC.fromString("VP8X"), &vp8x);
    writeChunk(&encoded, &offset, container.FourCC.fromString("ALPH"), &alpha_reserved);
    writeChunk(&encoded, &offset, container.FourCC.fromString("VP8 "), &vp8);
    assert(offset == encoded.len);

    var parsed = try demux.parse(std.testing.allocator, &encoded, .{});
    defer parsed.deinit();

    const remuxed = try encodeStaticFromDemux(std.testing.allocator, &encoded, parsed, .{});
    defer std.testing.allocator.free(remuxed);

    const alpha_canonical = [_]u8{ 0, 0xff };
    const expected = try encodeStatic(std.testing.allocator, .{
        .canvas = try image.Dimensions.init(1, 1),
        .format = .lossy,
        .bitstream = &vp8,
        .alpha = &alpha_canonical,
        .has_alpha = true,
    }, .{});
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualSlices(u8, expected, remuxed);
}

test "validates remux chunk count before allocating unknown chunks" {
    const vp8 = makeSimpleVP8(1, 1);
    const unknown = [_]RawChunk{
        .{
            .tag = container.FourCC.fromString("zzzz"),
            .payload = "",
        },
    };
    const encoded = try encodeStatic(std.testing.allocator, .{
        .canvas = try image.Dimensions.init(1, 1),
        .format = .lossy,
        .bitstream = &vp8,
        .unknown_chunks = &unknown,
    }, .{});
    defer std.testing.allocator.free(encoded);

    var parsed = try demux.parse(std.testing.allocator, encoded, .{});
    defer parsed.deinit();

    try std.testing.expectError(
        error.TooManyChunks,
        encodeStaticFromDemux(std.testing.allocator, encoded, parsed, .{
            .limits = .{
                .allocation_bytes_max = 0,
                .chunk_count_max = 2,
            },
        }),
    );
}

test "rejects stale caller alpha flag for lossless bitstreams" {
    const vp8l = makeSimpleVP8L(2, 2, false);

    try std.testing.expectError(
        error.InvalidMuxChunk,
        encodeStatic(std.testing.allocator, .{
            .canvas = try image.Dimensions.init(2, 2),
            .format = .lossless,
            .bitstream = &vp8l,
            .has_alpha = true,
            .force_extended = true,
        }, .{}),
    );
}

test "rejects invalid alpha payloads" {
    const vp8 = makeSimpleVP8(1, 1);
    const alpha_reserved = [_]u8{ 0xc0, 0xff };

    try std.testing.expectError(
        error.InvalidAlphaChunk,
        encodeStatic(std.testing.allocator, .{
            .canvas = try image.Dimensions.init(1, 1),
            .format = .lossy,
            .bitstream = &vp8,
            .alpha = "",
        }, .{}),
    );
    try std.testing.expectError(
        error.InvalidAlphaChunk,
        encodeStatic(std.testing.allocator, .{
            .canvas = try image.Dimensions.init(1, 1),
            .format = .lossy,
            .bitstream = &vp8,
            .alpha = &alpha_reserved,
        }, .{}),
    );
}
