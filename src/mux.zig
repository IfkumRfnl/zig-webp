//! RIFF/WebP muxing for valid static-image containers.

const std = @import("std");
const assert = std.debug.assert;

const animation = @import("animation.zig");
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

/// One pre-encoded animation frame for `encodeAnimation`: its placement and
/// timing on the canvas, its blend/dispose methods, and the already-encoded
/// VP8/VP8L bitstream (with an optional lossy `ALPH` payload). This muxer does
/// not encode pixels — it assembles these into `ANMF` chunks.
pub const FrameImage = struct {
    /// Frame rectangle on the canvas. `x`/`y` must be even (the container
    /// stores them in 2-pixel units) and the rectangle must lie inside the
    /// canvas. `width`/`height` must equal the bitstream's own dimensions.
    rect: animation.FrameRect,
    /// Display duration in milliseconds; stored as a 24-bit field.
    duration_ms: u32 = 0,
    blend_method: animation.BlendMethod = .alpha_blend,
    dispose_method: animation.DisposeMethod = .none,
    /// `.lossy` (`VP8 `) or `.lossless` (`VP8L`) frame codec.
    format: features.FormatKind,
    /// The raw `VP8 `/`VP8L` chunk payload for this frame.
    bitstream: []const u8,
    /// Optional `ALPH` payload. Valid only on `.lossy` frames (VP8L carries its
    /// own alpha); validated against the frame rectangle.
    alpha: ?[]const u8 = null,
};

/// Inputs to `encodeAnimation`: the global canvas, loop count, background color,
/// the ordered list of pre-encoded frames, and optional metadata. This is the
/// animated analogue of `StaticImage` — both carry already-encoded bitstreams.
pub const AnimationImage = struct {
    canvas: image.Dimensions,
    loop_count: animation.LoopCount = .infinite,
    /// Background color (B, G, R, A) stored in the `ANIM` chunk. Informational:
    /// libwebp's animation decoder composites over a transparent canvas.
    background_bgra: [4]u8 = .{ 0, 0, 0, 0 },
    frames: []const FrameImage,
    metadata: metadata.RawPayloads = .{},
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

/// Muxes a sequence of already-encoded animation frames into a complete animated
/// WebP file: `VP8X` (animation flag + canvas) → optional `ICCP` → `ANIM`
/// (background + loop count) → one `ANMF` per frame (frame header + optional
/// `ALPH` + `VP8 `/`VP8L`) → optional `EXIF`/`XMP `. It does not encode pixels;
/// each frame supplies its own bitstream. Every frame's rectangle, even-offset,
/// codec, dimensions, and alpha are validated, and the `VP8X` alpha flag is set
/// iff any frame carries alpha — so the output round-trips through this
/// library's demux and is accepted by `webpinfo`/`webpmux`.
///
/// Returns caller-owned bytes (free with the same allocator).
pub fn encodeAnimation(
    gpa: std.mem.Allocator,
    anim: AnimationImage,
    options: Options,
) errors.Error![]u8 {
    if (anim.frames.len == 0) return error.MissingImageData;

    try options.limits.validateCanvas(anim.canvas.width, anim.canvas.height, true);
    try validateVP8XCanvas(anim.canvas);

    const frame_count = std.math.cast(u32, anim.frames.len) orelse {
        return error.FrameCountTooLarge;
    };
    try options.limits.validateFrameCount(frame_count);

    // Validate every frame up front and learn whether any carries alpha, which
    // drives the VP8X alpha flag (demux requires the flag to match the frames).
    var any_alpha = false;
    for (anim.frames) |frame| {
        if (try validateAnimationFrame(frame, anim.canvas)) any_alpha = true;
    }

    const chunk_count = try animationChunkCount(anim);
    try options.limits.validateChunkCount(chunk_count);

    const riff_payload_size = try animationPayloadSize(anim);
    if (riff_payload_size > container.riff_payload_size_max) return error.FileTooLarge;

    const file_size = riff_payload_size + 8;
    try options.limits.validateAllocationBytes(file_size);

    const out = try gpa.alloc(u8, @intCast(file_size));
    errdefer gpa.free(out);

    @memcpy(out[0..4], "RIFF");
    container.writeLittleU32(out[4..8], @intCast(riff_payload_size));
    @memcpy(out[8..12], "WEBP");

    var offset: usize = container.riff_header_size;

    // VP8X first: animation is an extended-format feature, so it is mandatory.
    var vp8x_payload: [10]u8 = undefined;
    writeAnimationVP8X(&vp8x_payload, anim.canvas, anim.metadata, any_alpha);
    writeChunk(out, &offset, container.FourCC.fromString("VP8X"), &vp8x_payload);

    // ICCP must precede the first reconstruction chunk (here, ANIM).
    if (anim.metadata.color_profile) |payload| {
        writeChunk(out, &offset, container.FourCC.fromString("ICCP"), payload);
    }

    var anim_payload: [6]u8 = undefined;
    writeAnimControl(&anim_payload, anim.background_bgra, anim.loop_count);
    writeChunk(out, &offset, container.FourCC.fromString("ANIM"), &anim_payload);

    for (anim.frames) |frame| {
        writeAnimationFrameChunk(out, &offset, frame);
    }

    // EXIF/XMP carry no ordering constraint beyond following the image data.
    if (anim.metadata.exif) |payload| {
        writeChunk(out, &offset, container.FourCC.fromString("EXIF"), payload);
    }
    if (anim.metadata.xmp) |payload| {
        writeChunk(out, &offset, container.FourCC.fromString("XMP "), payload);
    }

    assert(offset == out.len);
    return out;
}

/// Validates one animation frame against the canvas and the container's frame
/// rules, returning whether the frame carries alpha (an `ALPH` chunk or a
/// bitstream alpha bit). Mirrors the constraints `demux.parseAnimationFrame`
/// enforces on read, so a validated frame always round-trips.
fn validateAnimationFrame(frame: FrameImage, canvas: image.Dimensions) errors.Error!bool {
    try frame.rect.validateInside(canvas);
    // The container stores frame offsets in 2-pixel units, so they must be even.
    if (frame.rect.x % 2 != 0) return error.InvalidFrameChunk;
    if (frame.rect.y % 2 != 0) return error.InvalidFrameChunk;
    if (frame.duration_ms > 0x00ff_ffff) return error.InvalidFrameChunk;

    // Alpha is a lossy-only side chunk; a VP8L frame carries its own alpha.
    if (frame.alpha != null and frame.format != .lossy) return error.InvalidMuxChunk;

    const bitstream = try demux.parseBitstreamInfo(frame.format.chunkKind(), frame.bitstream);
    if (bitstream.format != frame.format) return error.InvalidMuxChunk;
    if (bitstream.dimensions.width != frame.rect.width) return error.InvalidMuxChunk;
    if (bitstream.dimensions.height != frame.rect.height) return error.InvalidMuxChunk;

    if (frame.alpha) |payload| {
        try validateAlphaPayload(payload, try frame.rect.dimensions());
    }

    return (frame.alpha != null) or bitstream.has_alpha;
}

/// Top-level plus per-frame inner chunk count, matching how `demux` accounts for
/// an animation: VP8X, optional ICCP, ANIM, then per frame the ANMF wrapper, its
/// image sub-chunk, and an optional ALPH sub-chunk, then optional EXIF/XMP.
fn animationChunkCount(anim: AnimationImage) errors.Error!u64 {
    var count: u64 = 1; // VP8X
    if (anim.metadata.color_profile != null) count = try addEncodedChunkCount(count, 1);
    count = try addEncodedChunkCount(count, 1); // ANIM

    for (anim.frames) |frame| {
        count = try addEncodedChunkCount(count, 1); // ANMF wrapper
        count = try addEncodedChunkCount(count, 1); // image sub-chunk
        if (frame.alpha != null) count = try addEncodedChunkCount(count, 1); // ALPH sub-chunk
    }

    if (anim.metadata.exif != null) count = try addEncodedChunkCount(count, 1);
    if (anim.metadata.xmp != null) count = try addEncodedChunkCount(count, 1);
    return count;
}

/// RIFF payload byte count of the muxed animation (everything after the 8-byte
/// RIFF header), used to size the single output allocation.
fn animationPayloadSize(anim: AnimationImage) errors.Error!u64 {
    var size: u64 = container.fourcc_size; // the leading "WEBP" tag
    size += try encodedChunkSize(10); // VP8X
    if (anim.metadata.color_profile) |payload| size += try encodedChunkSize(payload.len);
    size += try encodedChunkSize(6); // ANIM

    for (anim.frames) |frame| {
        size += try encodedChunkSize(try anmfPayloadSize(frame));
    }

    if (anim.metadata.exif) |payload| size += try encodedChunkSize(payload.len);
    if (anim.metadata.xmp) |payload| size += try encodedChunkSize(payload.len);
    return size;
}

/// Byte length of an `ANMF` chunk's payload: the 16-byte frame header plus the
/// optional `ALPH` and the image sub-chunks. Each sub-chunk is even-padded, so
/// the total is always even and the `ANMF` wrapper itself needs no padding.
fn anmfPayloadSize(frame: FrameImage) errors.Error!u64 {
    var size: u64 = animation_frame_header_size;
    if (frame.alpha) |payload| size += try encodedChunkSize(payload.len);
    size += try encodedChunkSize(frame.bitstream.len);
    return size;
}

const animation_frame_header_size = 16;

fn writeAnimationVP8X(
    payload: *[10]u8,
    canvas: image.Dimensions,
    raw_metadata: metadata.RawPayloads,
    has_alpha: bool,
) void {
    payload.* = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    payload[0] |= 0x02; // animation
    if (raw_metadata.color_profile != null) payload[0] |= 0x20;
    if (has_alpha) payload[0] |= 0x10;
    if (raw_metadata.exif != null) payload[0] |= 0x08;
    if (raw_metadata.xmp != null) payload[0] |= 0x04;

    container.writeLittleU24(payload[4..7], canvas.width - 1);
    container.writeLittleU24(payload[7..10], canvas.height - 1);
}

fn writeAnimControl(
    payload: *[6]u8,
    background_bgra: [4]u8,
    loop_count: animation.LoopCount,
) void {
    @memcpy(payload[0..4], background_bgra[0..]);
    const loops: u16 = switch (loop_count) {
        .infinite => 0,
        .count => |count| count,
    };
    container.writeLittleU16(payload[4..6], loops);
}

/// Writes one complete `ANMF` chunk (header + 16-byte frame header + inner
/// `ALPH`/image sub-chunks). The payload size was validated by
/// `animationPayloadSize` before allocation, so the size recompute cannot fail.
fn writeAnimationFrameChunk(out: []u8, offset: *usize, frame: FrameImage) void {
    const anmf_payload = anmfPayloadSize(frame) catch unreachable;

    @memcpy(out[offset.*..][0..container.fourcc_size], "ANMF");
    offset.* += container.fourcc_size;
    container.writeLittleU32(out[offset.*..][0..4], @intCast(anmf_payload));
    offset.* += 4;

    const payload_start = offset.*;

    container.writeLittleU24(out[offset.* + 0 ..][0..3], frame.rect.x / 2);
    container.writeLittleU24(out[offset.* + 3 ..][0..3], frame.rect.y / 2);
    container.writeLittleU24(out[offset.* + 6 ..][0..3], frame.rect.width - 1);
    container.writeLittleU24(out[offset.* + 9 ..][0..3], frame.rect.height - 1);
    container.writeLittleU24(out[offset.* + 12 ..][0..3], frame.duration_ms);
    out[offset.* + 15] = (@as(u8, @intFromEnum(frame.blend_method)) << 1) |
        @intFromEnum(frame.dispose_method);
    offset.* += animation_frame_header_size;

    // ALPH precedes the image bitstream within the frame (lossy frames only).
    if (frame.alpha) |payload| {
        writeChunk(out, offset, container.FourCC.fromString("ALPH"), payload);
    }
    const image_tag = switch (frame.format) {
        .lossy => container.FourCC.fromString("VP8 "),
        .lossless => container.FourCC.fromString("VP8L"),
    };
    writeChunk(out, offset, image_tag, frame.bitstream);

    assert(offset.* - payload_start == anmf_payload);
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

fn encodedChunkSize(payload_len: u64) errors.Error!u64 {
    if (payload_len > std.math.maxInt(u32)) return error.ChunkTooLarge;

    return container.chunk_header_size + payload_len + (payload_len & 1);
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

fn encodeStaticAllocationProbe(gpa: std.mem.Allocator, static_image: StaticImage) !void {
    const encoded = try encodeStatic(gpa, static_image, .{});
    gpa.free(encoded);
}

test "static encode survives allocation failure at every site" {
    const vp8 = makeSimpleVP8(8, 6);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        encodeStaticAllocationProbe,
        .{StaticImage{
            .canvas = try image.Dimensions.init(8, 6),
            .format = .lossy,
            .bitstream = &vp8,
        }},
    );
}

// --- Animation mux (step 9a) -------------------------------------------------

/// Fills `out` with an uncompressed `ALPH` payload for a `width`x`height` frame:
/// the 1-byte header (compression 0, no filter, no preprocessing) plus one
/// fully-opaque alpha byte per pixel. Returns the populated slice.
fn makeUncompressedAlpha(out: []u8, width: u32, height: u32) []const u8 {
    const pixel_count: usize = @intCast(width * height);
    out[0] = 0;
    @memset(out[1 .. 1 + pixel_count], 0xff);
    return out[0 .. 1 + pixel_count];
}

test "muxes a multi-frame animation that round-trips through demux" {
    const gpa = std.testing.allocator;
    const vp8l_a = makeSimpleVP8L(4, 4, false);
    const vp8_b = makeSimpleVP8(2, 2);
    const frames = [_]FrameImage{
        .{
            .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
            .duration_ms = 100,
            .blend_method = .replace,
            .dispose_method = .none,
            .format = .lossless,
            .bitstream = &vp8l_a,
        },
        .{
            .rect = .{ .x = 2, .y = 2, .width = 2, .height = 2 },
            .duration_ms = 50,
            .blend_method = .alpha_blend,
            .dispose_method = .background,
            .format = .lossy,
            .bitstream = &vp8_b,
        },
    };

    const encoded = try encodeAnimation(gpa, .{
        .canvas = try image.Dimensions.init(4, 4),
        .loop_count = .{ .count = 3 },
        .background_bgra = .{ 1, 2, 3, 4 },
        .frames = &frames,
    }, .{});
    defer gpa.free(encoded);

    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.features.is_animation);
    try std.testing.expectEqual(features.FileKind.extended, parsed.features.file_kind);
    try std.testing.expectEqual(@as(u32, 4), parsed.features.canvas.width);
    try std.testing.expectEqual(@as(u32, 4), parsed.features.canvas.height);
    try std.testing.expect(!parsed.features.has_alpha);
    try std.testing.expectEqual(@as(usize, 2), parsed.frames.len);

    const info = parsed.animation_info.?;
    try std.testing.expectEqual(@as(u16, 3), info.loop_count.count);
    try std.testing.expectEqual([4]u8{ 1, 2, 3, 4 }, info.background_bgra);

    const f0 = parsed.frames[0];
    try std.testing.expectEqual(@as(u32, 0), f0.rect.x);
    try std.testing.expectEqual(@as(u32, 0), f0.rect.y);
    try std.testing.expectEqual(@as(u32, 4), f0.rect.width);
    try std.testing.expectEqual(@as(u32, 4), f0.rect.height);
    try std.testing.expectEqual(@as(u32, 100), f0.duration_ms);
    try std.testing.expectEqual(animation.BlendMethod.replace, f0.blend_method);
    try std.testing.expectEqual(animation.DisposeMethod.none, f0.dispose_method);
    try std.testing.expectEqual(features.FormatKind.lossless, f0.format.?);

    const f1 = parsed.frames[1];
    try std.testing.expectEqual(@as(u32, 2), f1.rect.x);
    try std.testing.expectEqual(@as(u32, 2), f1.rect.y);
    try std.testing.expectEqual(@as(u32, 2), f1.rect.width);
    try std.testing.expectEqual(@as(u32, 50), f1.duration_ms);
    try std.testing.expectEqual(animation.BlendMethod.alpha_blend, f1.blend_method);
    try std.testing.expectEqual(animation.DisposeMethod.background, f1.dispose_method);
    try std.testing.expectEqual(features.FormatKind.lossy, f1.format.?);
}

test "infinite loop encodes a zero loop count" {
    const gpa = std.testing.allocator;
    const vp8l = makeSimpleVP8L(2, 2, false);
    const frames = [_]FrameImage{.{
        .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .format = .lossless,
        .bitstream = &vp8l,
    }};

    const encoded = try encodeAnimation(gpa, .{
        .canvas = try image.Dimensions.init(2, 2),
        .loop_count = .infinite,
        .frames = &frames,
    }, .{});
    defer gpa.free(encoded);

    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(animation.LoopCount.infinite, parsed.animation_info.?.loop_count);
}

test "a lossy frame with ALPH sets the VP8X alpha flag and round-trips" {
    const gpa = std.testing.allocator;
    const vp8 = makeSimpleVP8(2, 2);
    var alpha_buffer: [8]u8 = undefined;
    const alpha = makeUncompressedAlpha(&alpha_buffer, 2, 2);
    const frames = [_]FrameImage{.{
        .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .format = .lossy,
        .bitstream = &vp8,
        .alpha = alpha,
    }};

    const encoded = try encodeAnimation(gpa, .{
        .canvas = try image.Dimensions.init(2, 2),
        .frames = &frames,
    }, .{});
    defer gpa.free(encoded);

    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.features.has_alpha);
    try std.testing.expect(parsed.frames[0].alpha_chunk != null);
    try std.testing.expect(parsed.frames[0].has_alpha);
}

test "a lossless frame's own alpha bit sets the VP8X alpha flag" {
    const gpa = std.testing.allocator;
    const vp8l = makeSimpleVP8L(2, 2, true); // alpha bit set in the bitstream
    const frames = [_]FrameImage{.{
        .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .format = .lossless,
        .bitstream = &vp8l,
    }};

    const encoded = try encodeAnimation(gpa, .{
        .canvas = try image.Dimensions.init(2, 2),
        .frames = &frames,
    }, .{});
    defer gpa.free(encoded);

    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.features.has_alpha);
}

test "preserves animation metadata through demux" {
    const gpa = std.testing.allocator;
    const vp8l = makeSimpleVP8L(2, 2, false);
    const frames = [_]FrameImage{.{
        .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .format = .lossless,
        .bitstream = &vp8l,
    }};

    const encoded = try encodeAnimation(gpa, .{
        .canvas = try image.Dimensions.init(2, 2),
        .frames = &frames,
        .metadata = .{ .color_profile = "icc", .exif = "exif", .xmp = "xmp" },
    }, .{});
    defer gpa.free(encoded);

    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();

    const payloads = parsed.metadataPayloads(encoded);
    try std.testing.expectEqualSlices(u8, "icc", payloads.color_profile.?);
    try std.testing.expectEqualSlices(u8, "exif", payloads.exif.?);
    try std.testing.expectEqualSlices(u8, "xmp", payloads.xmp.?);
}

test "rejects empty frame lists" {
    try std.testing.expectError(error.MissingImageData, encodeAnimation(std.testing.allocator, .{
        .canvas = try image.Dimensions.init(2, 2),
        .frames = &.{},
    }, .{}));
}

test "rejects odd frame offsets" {
    const vp8l = makeSimpleVP8L(2, 2, false);
    const frames = [_]FrameImage{.{
        .rect = .{ .x = 1, .y = 0, .width = 2, .height = 2 },
        .format = .lossless,
        .bitstream = &vp8l,
    }};
    try std.testing.expectError(error.InvalidFrameChunk, encodeAnimation(std.testing.allocator, .{
        .canvas = try image.Dimensions.init(4, 4),
        .frames = &frames,
    }, .{}));
}

test "rejects frame rectangles outside the canvas" {
    const vp8l = makeSimpleVP8L(4, 4, false);
    const frames = [_]FrameImage{.{
        .rect = .{ .x = 2, .y = 2, .width = 4, .height = 4 }, // 2+4 > 4
        .format = .lossless,
        .bitstream = &vp8l,
    }};
    try std.testing.expectError(error.InvalidFrameChunk, encodeAnimation(std.testing.allocator, .{
        .canvas = try image.Dimensions.init(4, 4),
        .frames = &frames,
    }, .{}));
}

test "rejects alpha on a lossless frame" {
    const vp8l = makeSimpleVP8L(2, 2, false);
    var alpha_buffer: [8]u8 = undefined;
    const alpha = makeUncompressedAlpha(&alpha_buffer, 2, 2);
    const frames = [_]FrameImage{.{
        .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .format = .lossless,
        .bitstream = &vp8l,
        .alpha = alpha,
    }};
    try std.testing.expectError(error.InvalidMuxChunk, encodeAnimation(std.testing.allocator, .{
        .canvas = try image.Dimensions.init(2, 2),
        .frames = &frames,
    }, .{}));
}

test "rejects a bitstream whose dimensions disagree with the frame rect" {
    const vp8l = makeSimpleVP8L(2, 2, false);
    const frames = [_]FrameImage{.{
        .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 }, // bitstream says 2x2
        .format = .lossless,
        .bitstream = &vp8l,
    }};
    try std.testing.expectError(error.InvalidMuxChunk, encodeAnimation(std.testing.allocator, .{
        .canvas = try image.Dimensions.init(4, 4),
        .frames = &frames,
    }, .{}));
}

test "enforces the configured frame count limit" {
    const gpa = std.testing.allocator;
    const vp8l = makeSimpleVP8L(2, 2, false);
    const frames = [_]FrameImage{
        .{ .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 }, .format = .lossless, .bitstream = &vp8l },
        .{ .rect = .{ .x = 0, .y = 0, .width = 2, .height = 2 }, .format = .lossless, .bitstream = &vp8l },
    };
    try std.testing.expectError(error.FrameCountTooLarge, encodeAnimation(gpa, .{
        .canvas = try image.Dimensions.init(2, 2),
        .frames = &frames,
    }, .{ .limits = .{ .frame_count_max = 1 } }));
}

fn encodeAnimationAllocationProbe(gpa: std.mem.Allocator, anim: AnimationImage) !void {
    const encoded = try encodeAnimation(gpa, anim, .{});
    gpa.free(encoded);
}

test "animation mux survives allocation failure at every site" {
    const vp8l = makeSimpleVP8L(4, 4, false);
    const vp8 = makeSimpleVP8(2, 2);
    var alpha_buffer: [8]u8 = undefined;
    const alpha = makeUncompressedAlpha(&alpha_buffer, 2, 2);
    const frames = [_]FrameImage{
        .{
            .rect = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
            .format = .lossless,
            .bitstream = &vp8l,
        },
        .{
            .rect = .{ .x = 2, .y = 2, .width = 2, .height = 2 },
            .format = .lossy,
            .bitstream = &vp8,
            .alpha = alpha,
        },
    };
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        encodeAnimationAllocationProbe,
        .{AnimationImage{
            .canvas = try image.Dimensions.init(4, 4),
            .frames = &frames,
            .metadata = .{ .exif = "exif" },
        }},
    );
}
