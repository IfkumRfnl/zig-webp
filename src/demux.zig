//! Strict RIFF/WebP demuxing without pixel decode.

const std = @import("std");
const assert = std.debug.assert;

const animation = @import("animation.zig");
const container = @import("container.zig");
const errors = @import("errors.zig");
const features = @import("features.zig");
const image = @import("image.zig");
const limits = @import("limits.zig");
const metadata = @import("metadata.zig");

pub const Options = struct {
    limits: limits.ResourceLimits = .{},
    allow_trailing_data: bool = false,
    strict_padding: bool = true,
};

pub const BitstreamInfo = struct {
    format: features.FormatKind,
    dimensions: image.Dimensions,
    has_alpha: bool,
};

pub const Result = struct {
    gpa: std.mem.Allocator,
    header: container.ContainerHeader,
    file_size_bytes: u64,
    features: features.Summary,
    chunks: []container.ChunkLocation,
    unknown_chunks: []container.ChunkLocation,
    metadata: metadata.RawLocations,
    animation_info: ?animation.Info,
    frames: []animation.Frame,

    pub fn deinit(self: *Result) void {
        self.gpa.free(self.frames);
        self.gpa.free(self.unknown_chunks);
        self.gpa.free(self.chunks);
        self.* = undefined;
    }

    pub fn metadataPayloads(self: Result, bytes: []const u8) metadata.RawPayloads {
        return self.metadata.payloads(bytes);
    }
};

const ExtendedFlags = struct {
    color_profile: bool = false,
    alpha: bool = false,
    exif: bool = false,
    xmp: bool = false,
    animation: bool = false,
};

const ParseState = struct {
    file_kind: ?features.FileKind = null,
    flags: ExtendedFlags = .{},
    canvas: ?image.Dimensions = null,
    format: ?features.FormatKind = null,
    has_alpha: bool = false,
    frame_has_alpha: bool = false,
    extended_header: ?container.ChunkLocation = null,
    image_data: ?container.ChunkLocation = null,
    alpha: ?container.ChunkLocation = null,
    animation_control: ?container.ChunkLocation = null,
    first_animation_frame: ?container.ChunkLocation = null,
    animation_info: ?animation.Info = null,
    metadata: metadata.RawLocations = .{},
    reconstruction_started: bool = false,
};

pub fn parse(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    options: Options,
) errors.Error!Result {
    try options.limits.validateInputBytes(bytes.len);

    const header = try container.parseHeader(bytes);
    const file_size = try validateEnvelope(bytes, header, options);
    const file_end: usize = @intCast(file_size);

    var chunks: std.ArrayList(container.ChunkLocation) = .empty;
    defer chunks.deinit(gpa);
    var unknown_chunks: std.ArrayList(container.ChunkLocation) = .empty;
    defer unknown_chunks.deinit(gpa);
    var frames: std.ArrayList(animation.Frame) = .empty;
    defer frames.deinit(gpa);

    var state = ParseState{};
    var chunk_count: u64 = 0;
    var offset: usize = container.riff_header_size;
    while (offset < file_end) {
        chunk_count += 1;
        try options.limits.validateChunkCount(chunk_count);

        const location = try readChunkLocation(bytes, offset, file_end, options);
        try appendLimited(container.ChunkLocation, &chunks, gpa, location, options);
        try processTopLevelChunk(
            gpa,
            &state,
            &frames,
            &unknown_chunks,
            &chunk_count,
            bytes,
            location,
            options,
        );

        offset = @intCast(location.endOffset());
    }

    assert(offset == file_end);
    const summary = try finishFeatures(state, frames.items.len, chunks.items.len, options);

    try validateSliceAllocation(container.ChunkLocation, chunks.items.len, options);
    const chunks_owned = try chunks.toOwnedSlice(gpa);
    errdefer gpa.free(chunks_owned);
    try validateSliceAllocation(container.ChunkLocation, unknown_chunks.items.len, options);
    const unknown_owned = try unknown_chunks.toOwnedSlice(gpa);
    errdefer gpa.free(unknown_owned);
    try validateSliceAllocation(animation.Frame, frames.items.len, options);
    const frames_owned = try frames.toOwnedSlice(gpa);
    errdefer gpa.free(frames_owned);

    return .{
        .gpa = gpa,
        .header = header,
        .file_size_bytes = file_size,
        .features = summary,
        .chunks = chunks_owned,
        .unknown_chunks = unknown_owned,
        .metadata = state.metadata,
        .animation_info = state.animation_info,
        .frames = frames_owned,
    };
}

pub fn parseFeatures(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    options: Options,
) errors.Error!features.Summary {
    var result = try parse(gpa, bytes, options);
    defer result.deinit();

    return result.features;
}

fn appendLimited(
    comptime T: type,
    list: *std.ArrayList(T),
    gpa: std.mem.Allocator,
    item: T,
    options: Options,
) errors.Error!void {
    const new_len = list.items.len + 1;
    if (new_len > list.capacity) {
        const new_capacity = std.ArrayList(T).growCapacity(new_len);
        try validateSliceAllocation(T, new_capacity, options);
        try list.ensureTotalCapacityPrecise(gpa, new_capacity);
    }

    list.appendAssumeCapacity(item);
}

fn validateSliceAllocation(
    comptime T: type,
    count: usize,
    options: Options,
) errors.Error!void {
    const count_u64 = std.math.cast(u64, count) orelse return error.AllocationLimitExceeded;
    const byte_count = std.math.mul(u64, count_u64, @sizeOf(T)) catch {
        return error.AllocationLimitExceeded;
    };

    try options.limits.validateAllocationBytes(byte_count);
}

pub fn parseBitstreamInfo(
    kind: container.ChunkKind,
    payload: []const u8,
) errors.Error!BitstreamInfo {
    return switch (kind) {
        .lossy_bitstream => parseVP8Info(payload),
        .lossless_bitstream => parseVP8LInfo(payload),
        else => error.InvalidMuxChunk,
    };
}

fn validateEnvelope(
    bytes: []const u8,
    header: container.ContainerHeader,
    options: Options,
) errors.Error!u64 {
    const file_size = header.fileSizeBytes();
    if (file_size > container.file_size_max) return error.FileTooLarge;
    if (file_size > bytes.len) return error.TruncatedChunkPayload;
    if (file_size < container.riff_header_size) return error.InvalidRiffSize;
    if (file_size < bytes.len and !options.allow_trailing_data) return error.TrailingData;

    return file_size;
}

fn readChunkLocation(
    bytes: []const u8,
    offset: usize,
    file_end: usize,
    options: Options,
) errors.Error!container.ChunkLocation {
    assert(offset <= file_end);
    if (file_end - offset < container.chunk_header_size) return error.TruncatedChunkHeader;

    const header = try container.parseChunkHeader(bytes[offset..][0..container.chunk_header_size]);
    const payload_offset = offset + container.chunk_header_size;
    const padded_payload_size = header.paddedPayloadSizeBytes();
    const chunk_size = @as(u64, container.chunk_header_size) + padded_payload_size;
    const end = @as(u64, offset) + chunk_size;
    if (end > file_end) return error.TruncatedChunkPayload;

    if (options.strict_padding and (header.payload_size & 1) != 0) {
        const padding_offset = payload_offset + header.payload_size;
        if (bytes[padding_offset] != 0) return error.InvalidChunkPadding;
    }

    return .{
        .tag = header.tag,
        .kind = header.tag.kind(),
        .offset = offset,
        .payload_offset = payload_offset,
        .payload_size = header.payload_size,
    };
}

fn processTopLevelChunk(
    gpa: std.mem.Allocator,
    state: *ParseState,
    frames: *std.ArrayList(animation.Frame),
    unknown_chunks: *std.ArrayList(container.ChunkLocation),
    chunk_count: *u64,
    bytes: []const u8,
    location: container.ChunkLocation,
    options: Options,
) errors.Error!void {
    if (state.file_kind == null) {
        switch (location.kind) {
            .lossy_bitstream,
            .lossless_bitstream,
            => {
                state.file_kind = .simple;
                try setImageData(state, bytes, location, options);
                return;
            },
            .extended_header => {
                state.file_kind = .extended;
                state.extended_header = location;
                const extended = try parseExtendedHeader(location.payload(bytes));
                state.flags = extended.flags;
                state.canvas = extended.canvas;
                try options.limits.validateCanvas(
                    extended.canvas.width,
                    extended.canvas.height,
                    extended.flags.animation,
                );
                return;
            },
            .unknown => {
                try appendLimited(container.ChunkLocation, unknown_chunks, gpa, location, options);
                return;
            },
            else => return error.MissingExtendedHeader,
        }
    }

    switch (state.file_kind.?) {
        .simple => try processSimpleChunk(gpa, unknown_chunks, location, options),
        .extended => try processExtendedChunk(
            gpa,
            state,
            frames,
            unknown_chunks,
            chunk_count,
            bytes,
            location,
            options,
        ),
    }
}

fn processSimpleChunk(
    gpa: std.mem.Allocator,
    unknown_chunks: *std.ArrayList(container.ChunkLocation),
    location: container.ChunkLocation,
    options: Options,
) errors.Error!void {
    switch (location.kind) {
        .unknown => try appendLimited(container.ChunkLocation, unknown_chunks, gpa, location, options),
        else => return error.InvalidSimpleChunk,
    }
}

fn processExtendedChunk(
    gpa: std.mem.Allocator,
    state: *ParseState,
    frames: *std.ArrayList(animation.Frame),
    unknown_chunks: *std.ArrayList(container.ChunkLocation),
    chunk_count: *u64,
    bytes: []const u8,
    location: container.ChunkLocation,
    options: Options,
) errors.Error!void {
    switch (location.kind) {
        .extended_header => return error.DuplicateChunk,

        .color_profile => {
            if (state.metadata.color_profile != null) return error.DuplicateMetadata;
            if (state.reconstruction_started) return error.InvalidChunkOrder;
            state.metadata.color_profile = location;
        },

        .exif_metadata => {
            if (state.metadata.exif != null) return error.DuplicateMetadata;
            state.metadata.exif = location;
        },

        .xmp_metadata => {
            if (state.metadata.xmp != null) return error.DuplicateMetadata;
            state.metadata.xmp = location;
        },

        .alpha => {
            if (state.flags.animation) return error.InvalidChunkOrder;
            if (state.image_data != null) return error.InvalidChunkOrder;
            if (state.alpha != null) return error.DuplicateChunk;

            const canvas = state.canvas orelse return error.MissingExtendedHeader;
            try validateAlphaPayload(location.payload(bytes), canvas);
            state.alpha = location;
            state.has_alpha = true;
            state.reconstruction_started = true;
        },

        .lossy_bitstream,
        .lossless_bitstream,
        => {
            if (state.flags.animation) return error.InvalidChunkOrder;
            try setImageData(state, bytes, location, options);
            state.reconstruction_started = true;
        },

        .animation => {
            // The WebP container spec requires readers to ignore unflagged ANIM chunks.
            if (!state.flags.animation) return;
            if (state.animation_control != null) return error.DuplicateChunk;
            if (state.reconstruction_started) return error.InvalidChunkOrder;

            state.animation_control = location;
            state.animation_info = try parseAnimationInfo(location.payload(bytes));
            state.reconstruction_started = true;
        },

        .animation_frame => {
            if (!state.flags.animation) return error.InvalidChunkOrder;
            if (state.animation_control == null) return error.MissingAnimationControl;

            const frame_count_next: u64 = @intCast(frames.items.len + 1);
            try options.limits.validateFrameCount(frame_count_next);
            const canvas = state.canvas orelse return error.MissingExtendedHeader;
            const frame = try parseAnimationFrame(bytes, location, canvas, chunk_count, options);
            if (state.first_animation_frame == null) state.first_animation_frame = location;
            state.reconstruction_started = true;
            state.frame_has_alpha = state.frame_has_alpha or frame.has_alpha;
            try appendLimited(animation.Frame, frames, gpa, frame, options);
        },

        .unknown => {
            try appendLimited(container.ChunkLocation, unknown_chunks, gpa, location, options);
        },
    }
}

fn setImageData(
    state: *ParseState,
    bytes: []const u8,
    location: container.ChunkLocation,
    options: Options,
) errors.Error!void {
    if (state.image_data != null) return error.DuplicateImageData;

    const bitstream = try parseBitstreamInfo(location.kind, location.payload(bytes));
    if (state.canvas) |canvas| {
        if (bitstream.dimensions.width != canvas.width) return error.InvalidFeatureFlags;
        if (bitstream.dimensions.height != canvas.height) return error.InvalidFeatureFlags;
    } else {
        state.canvas = bitstream.dimensions;
        try options.limits.validateCanvas(
            bitstream.dimensions.width,
            bitstream.dimensions.height,
            false,
        );
    }

    state.format = bitstream.format;
    state.has_alpha = state.has_alpha or bitstream.has_alpha;
    state.image_data = location;
}

fn finishFeatures(
    state: ParseState,
    frame_count: usize,
    chunk_count: usize,
    options: Options,
) errors.Error!features.Summary {
    const file_kind = state.file_kind orelse return error.MissingImageData;
    const canvas = state.canvas orelse return error.MissingImageData;

    switch (file_kind) {
        .simple => {
            if (state.extended_header != null) return error.InvalidSimpleChunk;
            if (state.image_data == null) return error.MissingImageData;
        },
        .extended => try finishExtendedFeatures(state, frame_count, options),
    }

    return .{
        .file_kind = file_kind,
        .format = state.format,
        .canvas = canvas,
        .has_alpha = if (state.flags.animation) state.frame_has_alpha else state.has_alpha,
        .is_animation = state.flags.animation,
        .metadata = state.metadata.presence(),
        .chunk_count = @intCast(chunk_count),
        .extended_header = state.extended_header,
        .image_data = state.image_data,
        .alpha = state.alpha,
        .animation_control = state.animation_control,
        .first_animation_frame = state.first_animation_frame,
    };
}

fn finishExtendedFeatures(
    state: ParseState,
    frame_count: usize,
    options: Options,
) errors.Error!void {
    if (state.extended_header == null) return error.MissingExtendedHeader;

    try requireFlagMatchesChunk(state.flags.color_profile, state.metadata.color_profile != null);
    try requireFlagMatchesChunk(state.flags.exif, state.metadata.exif != null);
    try requireFlagMatchesChunk(state.flags.xmp, state.metadata.xmp != null);

    if (state.flags.animation) {
        if (state.animation_control == null) return error.MissingAnimationControl;
        if (frame_count == 0) return error.MissingImageData;
        if (state.image_data != null) return error.InvalidChunkOrder;
        if (state.alpha != null) return error.InvalidChunkOrder;
        if (state.frame_has_alpha and !state.flags.alpha) return error.InvalidFeatureFlags;
        if (state.flags.alpha and !state.frame_has_alpha) return error.MissingRequiredChunk;
        try options.limits.validateFrameCount(frame_count);
    } else {
        if (state.animation_control != null) return error.InvalidChunkOrder;
        if (frame_count != 0) return error.InvalidChunkOrder;
        if (state.image_data == null) return error.MissingImageData;
        if (state.alpha != null and state.format != .lossy) return error.InvalidChunkOrder;
        if (state.has_alpha and !state.flags.alpha) return error.InvalidFeatureFlags;
        if (state.flags.alpha and !state.has_alpha) return error.MissingRequiredChunk;
    }
}

fn requireFlagMatchesChunk(flag: bool, present: bool) errors.Error!void {
    if (flag and !present) return error.MissingRequiredChunk;
    if (!flag and present) return error.InvalidFeatureFlags;
}

const ExtendedHeader = struct {
    flags: ExtendedFlags,
    canvas: image.Dimensions,
};

fn parseExtendedHeader(payload: []const u8) errors.Error!ExtendedHeader {
    if (payload.len < 10) return error.InvalidExtendedHeaderSize;

    const flags_byte = payload[0];

    const width_minus_one = container.readLittleU24(payload[4..7]);
    const height_minus_one = container.readLittleU24(payload[7..10]);
    const canvas = try image.Dimensions.init(width_minus_one + 1, height_minus_one + 1);

    return .{
        .flags = .{
            .color_profile = (flags_byte & 0x20) != 0,
            .alpha = (flags_byte & 0x10) != 0,
            .exif = (flags_byte & 0x08) != 0,
            .xmp = (flags_byte & 0x04) != 0,
            .animation = (flags_byte & 0x02) != 0,
        },
        .canvas = canvas,
    };
}

fn parseAnimationInfo(payload: []const u8) errors.Error!animation.Info {
    if (payload.len != 6) return error.InvalidAnimationChunk;

    var background_bgra: [4]u8 = undefined;
    @memcpy(background_bgra[0..], payload[0..4]);

    const loop_count_raw = container.readLittleU16(payload[4..6]);
    return .{
        .background_bgra = background_bgra,
        .loop_count = if (loop_count_raw == 0)
            .infinite
        else
            .{ .count = loop_count_raw },
    };
}

fn validateAlphaPayload(
    payload: []const u8,
    dimensions: image.Dimensions,
) errors.Error!void {
    if (payload.len < 2) return error.InvalidAlphaChunk;

    const header = payload[0];

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

fn parseAnimationFrame(
    bytes: []const u8,
    location: container.ChunkLocation,
    canvas: image.Dimensions,
    chunk_count: *u64,
    options: Options,
) errors.Error!animation.Frame {
    const payload = location.payload(bytes);
    if (payload.len < 16) return error.InvalidFrameChunk;

    const x_units = container.readLittleU24(payload[0..3]);
    const y_units = container.readLittleU24(payload[3..6]);
    if (x_units > std.math.maxInt(u32) / 2) return error.InvalidFrameChunk;
    if (y_units > std.math.maxInt(u32) / 2) return error.InvalidFrameChunk;

    const rect = animation.FrameRect{
        .x = x_units * 2,
        .y = y_units * 2,
        .width = container.readLittleU24(payload[6..9]) + 1,
        .height = container.readLittleU24(payload[9..12]) + 1,
    };
    try rect.validateInside(canvas);

    const duration_ms = container.readLittleU24(payload[12..15]);
    const flags_byte = payload[15];

    var frame = animation.Frame{
        .rect = rect,
        .duration_ms = duration_ms,
        .blend_method = @enumFromInt((flags_byte >> 1) & 1),
        .dispose_method = @enumFromInt(flags_byte & 1),
    };

    var saw_image = false;
    var saw_unknown = false;
    var offset: usize = @intCast(location.payload_offset + 16);
    const frame_end: usize = @intCast(location.payload_offset + location.payload_size);
    while (offset < frame_end) {
        chunk_count.* += 1;
        try options.limits.validateChunkCount(chunk_count.*);

        const inner = try readChunkLocation(bytes, offset, frame_end, options);
        switch (inner.kind) {
            .alpha => {
                if (saw_image) return error.InvalidFrameChunk;
                if (saw_unknown) return error.InvalidFrameChunk;
                if (frame.alpha_chunk != null) return error.InvalidFrameChunk;

                const frame_dimensions = try image.Dimensions.init(rect.width, rect.height);
                try validateAlphaPayload(inner.payload(bytes), frame_dimensions);
                frame.alpha_chunk = inner;
                frame.has_alpha = true;
            },

            .lossy_bitstream,
            .lossless_bitstream,
            => {
                if (saw_image) return error.InvalidFrameChunk;
                if (saw_unknown) return error.InvalidFrameChunk;
                if (inner.kind == .lossless_bitstream and frame.alpha_chunk != null) {
                    return error.InvalidFrameChunk;
                }

                const bitstream = try parseBitstreamInfo(inner.kind, inner.payload(bytes));
                if (bitstream.dimensions.width != rect.width) return error.InvalidFrameChunk;
                if (bitstream.dimensions.height != rect.height) return error.InvalidFrameChunk;

                frame.format = bitstream.format;
                frame.has_alpha = frame.has_alpha or bitstream.has_alpha;
                frame.bitstream_chunk = inner;
                saw_image = true;
            },

            .unknown => {
                if (!saw_image) return error.InvalidFrameChunk;
                saw_unknown = true;
            },

            else => return error.InvalidFrameChunk,
        }

        offset = @intCast(inner.endOffset());
    }

    if (!saw_image) return error.MissingImageData;

    return frame;
}

fn parseVP8Info(payload: []const u8) errors.Error!BitstreamInfo {
    if (payload.len < 10) return error.InvalidVP8Header;

    const frame_tag = container.readLittleU24(payload[0..3]);
    const key_frame = (frame_tag & 1) == 0;
    const profile = (frame_tag >> 1) & 7;
    const show_frame = ((frame_tag >> 4) & 1) == 1;
    const first_partition_length: usize = @intCast(frame_tag >> 5);
    if (!key_frame) return error.InvalidVP8Header;
    if (profile > 3) return error.InvalidVP8Header;
    if (!show_frame) return error.InvalidVP8Header;
    if (first_partition_length >= payload.len) return error.InvalidVP8Header;
    if (!std.mem.eql(u8, payload[3..6], &.{ 0x9d, 0x01, 0x2a })) {
        return error.InvalidVP8Header;
    }

    const width = @as(u32, container.readLittleU16(payload[6..8]) & 0x3fff);
    const height = @as(u32, container.readLittleU16(payload[8..10]) & 0x3fff);

    return .{
        .format = .lossy,
        .dimensions = try image.Dimensions.init(width, height),
        .has_alpha = false,
    };
}

fn parseVP8LInfo(payload: []const u8) errors.Error!BitstreamInfo {
    if (payload.len < 5) return error.InvalidVP8LHeader;
    if (payload[0] != 0x2f) return error.InvalidVP8LHeader;

    const bits = container.readLittleU32(payload[1..5]);
    const width = (bits & 0x3fff) + 1;
    const height = ((bits >> 14) & 0x3fff) + 1;
    const has_alpha = ((bits >> 28) & 1) == 1;
    const version = (bits >> 29) & 0x7;
    if (version != 0) return error.InvalidVP8LHeader;

    return .{
        .format = .lossless,
        .dimensions = try image.Dimensions.init(width, height),
        .has_alpha = has_alpha,
    };
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

fn writeChunk(out: []u8, offset: *usize, tag: []const u8, payload: []const u8) void {
    assert(tag.len == container.fourcc_size);
    assert(out.len >= offset.* + container.chunk_header_size + payload.len);

    @memcpy(out[offset.*..][0..container.fourcc_size], tag);
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

test "parses simple lossy WebP dimensions from VP8 header" {
    const vp8 = makeSimpleVP8(4, 3);
    var bytes: [container.riff_header_size + container.chunk_header_size + vp8.len]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], @intCast(bytes.len - 8));
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8 ", &vp8);

    var result = try parse(std.testing.allocator, &bytes, .{});
    defer result.deinit();

    try std.testing.expectEqual(features.FileKind.simple, result.features.file_kind);
    try std.testing.expectEqual(features.FormatKind.lossy, result.features.format.?);
    try std.testing.expectEqual(@as(u32, 4), result.features.canvas.width);
    try std.testing.expectEqual(@as(u32, 3), result.features.canvas.height);
    try std.testing.expect(!result.features.has_alpha);
}

test "rejects malformed VP8 frame tags" {
    var unsupported_profile = makeSimpleVP8(1, 1);
    container.writeLittleU24(unsupported_profile[0..3], 0x10 | (@as(u32, 4) << 1));
    try std.testing.expectError(
        error.InvalidVP8Header,
        parseBitstreamInfo(.lossy_bitstream, &unsupported_profile),
    );

    var oversized_partition = makeSimpleVP8(1, 1);
    const first_partition_length: u32 = @intCast(oversized_partition.len);
    container.writeLittleU24(oversized_partition[0..3], 0x10 | (first_partition_length << 5));
    try std.testing.expectError(
        error.InvalidVP8Header,
        parseBitstreamInfo(.lossy_bitstream, &oversized_partition),
    );

    var bytes: [container.riff_header_size + container.chunk_header_size + oversized_partition.len]u8 =
        undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], @intCast(bytes.len - 8));
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8 ", &oversized_partition);

    try std.testing.expectError(
        error.InvalidVP8Header,
        parse(std.testing.allocator, &bytes, .{}),
    );
}

test "parses simple lossless alpha from VP8L header" {
    const vp8l = makeSimpleVP8L(2, 5, true);
    const payload_size = container.chunk_header_size + vp8l.len + 1;
    var bytes: [container.riff_header_size + payload_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], @intCast(bytes.len - 8));
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8L", &vp8l);

    var result = try parse(std.testing.allocator, &bytes, .{});
    defer result.deinit();

    try std.testing.expectEqual(features.FormatKind.lossless, result.features.format.?);
    try std.testing.expectEqual(@as(u32, 2), result.features.canvas.width);
    try std.testing.expectEqual(@as(u32, 5), result.features.canvas.height);
    try std.testing.expect(result.features.has_alpha);
}

test "parses simple WebP files with ancillary RIFF chunks" {
    const vp8 = makeSimpleVP8(1, 1);
    const comment = "test1x1";
    const riff_size = 4 +
        (container.chunk_header_size + vp8.len) +
        (container.chunk_header_size + comment.len + 1);
    var bytes: [8 + riff_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], riff_size);
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8 ", &vp8);
    writeChunk(&bytes, &offset, "ICMT", comment);

    var result = try parse(std.testing.allocator, &bytes, .{});
    defer result.deinit();

    try std.testing.expectEqual(features.FileKind.simple, result.features.file_kind);
    try std.testing.expectEqual(features.FormatKind.lossy, result.features.format.?);
    try std.testing.expectEqual(@as(u32, 2), result.features.chunk_count);
    try std.testing.expectEqual(@as(usize, 1), result.unknown_chunks.len);
    try std.testing.expectEqualSlices(u8, comment, result.unknown_chunks[0].payload(&bytes));
}

test "rejects trailing data and non-zero RIFF padding in strict mode" {
    const vp8 = makeSimpleVP8(1, 1);
    var good: [container.riff_header_size + container.chunk_header_size + vp8.len]u8 = undefined;
    @memcpy(good[0..4], "RIFF");
    container.writeLittleU32(good[4..8], @intCast(good.len - 8));
    @memcpy(good[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&good, &offset, "VP8 ", &vp8);

    var trailing: [good.len + 1]u8 = undefined;
    @memcpy(trailing[0..good.len], &good);
    trailing[good.len] = 0;
    try std.testing.expectError(
        error.TrailingData,
        parse(std.testing.allocator, &trailing, .{}),
    );

    const vp8l = makeSimpleVP8L(1, 1, false);
    var bad_padding: [container.riff_header_size + container.chunk_header_size + vp8l.len + 1]u8 =
        undefined;
    @memcpy(bad_padding[0..4], "RIFF");
    container.writeLittleU32(bad_padding[4..8], @intCast(bad_padding.len - 8));
    @memcpy(bad_padding[8..12], "WEBP");
    offset = 12;
    writeChunk(&bad_padding, &offset, "VP8L", &vp8l);
    bad_padding[bad_padding.len - 1] = 1;
    try std.testing.expectError(
        error.InvalidChunkPadding,
        parse(std.testing.allocator, &bad_padding, .{}),
    );
}

test "parses extended metadata and rejects duplicate metadata chunks" {
    const vp8 = makeSimpleVP8(3, 2);
    const vp8x = [_]u8{ 0x2c, 0, 0, 0, 2, 0, 0, 1, 0, 0 };
    const iccp = "icc";
    const exif = "exif";
    const xmp = "xmp";
    const riff_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + iccp.len + 1) +
        (container.chunk_header_size + vp8.len) +
        (container.chunk_header_size + exif.len) +
        (container.chunk_header_size + xmp.len + 1);
    var bytes: [8 + riff_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], riff_size);
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8X", &vp8x);
    writeChunk(&bytes, &offset, "ICCP", iccp);
    writeChunk(&bytes, &offset, "VP8 ", &vp8);
    writeChunk(&bytes, &offset, "EXIF", exif);
    writeChunk(&bytes, &offset, "XMP ", xmp);

    var result = try parse(std.testing.allocator, &bytes, .{});
    defer result.deinit();

    const payloads = result.metadataPayloads(&bytes);
    try std.testing.expectEqualSlices(u8, iccp, payloads.color_profile.?);
    try std.testing.expectEqualSlices(u8, exif, payloads.exif.?);
    try std.testing.expectEqualSlices(u8, xmp, payloads.xmp.?);

    const duplicate_size = riff_size + container.chunk_header_size + exif.len;
    var duplicate: [8 + duplicate_size]u8 = undefined;
    @memcpy(duplicate[0..bytes.len], &bytes);
    container.writeLittleU32(duplicate[4..8], duplicate_size);
    offset = bytes.len;
    writeChunk(&duplicate, &offset, "EXIF", exif);
    try std.testing.expectError(
        error.DuplicateMetadata,
        parse(std.testing.allocator, &duplicate, .{}),
    );
}

test "rejects color profile after alpha reconstruction data" {
    const vp8 = makeSimpleVP8(1, 1);
    const vp8x = [_]u8{ 0x30, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const alpha = [_]u8{ 0, 0xff };
    const iccp = "icc";
    const riff_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + alpha.len) +
        (container.chunk_header_size + iccp.len + 1) +
        (container.chunk_header_size + vp8.len);
    var bytes: [8 + riff_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], riff_size);
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8X", &vp8x);
    writeChunk(&bytes, &offset, "ALPH", &alpha);
    writeChunk(&bytes, &offset, "ICCP", iccp);
    writeChunk(&bytes, &offset, "VP8 ", &vp8);

    try std.testing.expectError(
        error.InvalidChunkOrder,
        parse(std.testing.allocator, &bytes, .{}),
    );
}

test "rejects truncated alpha chunk payloads" {
    const vp8 = makeSimpleVP8(1, 1);
    const vp8x = [_]u8{ 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const alpha = "";
    const riff_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + alpha.len) +
        (container.chunk_header_size + vp8.len);
    var bytes: [8 + riff_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], riff_size);
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8X", &vp8x);
    writeChunk(&bytes, &offset, "ALPH", alpha);
    writeChunk(&bytes, &offset, "VP8 ", &vp8);

    try std.testing.expectError(
        error.InvalidAlphaChunk,
        parse(std.testing.allocator, &bytes, .{}),
    );
}

test "ignores reserved alpha header bits" {
    const vp8 = makeSimpleVP8(1, 1);
    const vp8x = [_]u8{ 0x10, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const alpha_reserved = [_]u8{ 0xc0, 0xff };
    const reserved_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + alpha_reserved.len) +
        (container.chunk_header_size + vp8.len);
    var reserved: [8 + reserved_size]u8 = undefined;
    @memcpy(reserved[0..4], "RIFF");
    container.writeLittleU32(reserved[4..8], reserved_size);
    @memcpy(reserved[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&reserved, &offset, "VP8X", &vp8x);
    writeChunk(&reserved, &offset, "ALPH", &alpha_reserved);
    writeChunk(&reserved, &offset, "VP8 ", &vp8);

    var result = try parse(std.testing.allocator, &reserved, .{});
    defer result.deinit();

    try std.testing.expect(result.features.has_alpha);
    try std.testing.expectEqual(features.FormatKind.lossy, result.features.format.?);
}

test "rejects color profile after animation control" {
    const vp8 = makeSimpleVP8(1, 1);
    const vp8x = [_]u8{ 0x22, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const anim = [_]u8{ 0, 0, 0, 0, 0, 0 };
    const iccp = "icc";

    const frame_payload_size = 16 + container.chunk_header_size + vp8.len;
    var frame_payload: [frame_payload_size]u8 = undefined;
    @memset(frame_payload[0..16], 0);
    var frame_offset: usize = 16;
    writeChunk(&frame_payload, &frame_offset, "VP8 ", &vp8);
    assert(frame_offset == frame_payload.len);

    const riff_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + anim.len) +
        (container.chunk_header_size + iccp.len + 1) +
        (container.chunk_header_size + frame_payload.len);
    var bytes: [8 + riff_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], riff_size);
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8X", &vp8x);
    writeChunk(&bytes, &offset, "ANIM", &anim);
    writeChunk(&bytes, &offset, "ICCP", iccp);
    writeChunk(&bytes, &offset, "ANMF", &frame_payload);

    try std.testing.expectError(
        error.InvalidChunkOrder,
        parse(std.testing.allocator, &bytes, .{}),
    );
}

test "ignores animation control when VP8X animation flag is unset" {
    const vp8 = makeSimpleVP8(1, 1);
    const vp8x = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const anim = [_]u8{ 0, 0, 0, 0, 0, 0 };
    const riff_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + anim.len) +
        (container.chunk_header_size + vp8.len);
    var bytes: [8 + riff_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], riff_size);
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8X", &vp8x);
    writeChunk(&bytes, &offset, "ANIM", &anim);
    writeChunk(&bytes, &offset, "VP8 ", &vp8);

    var result = try parse(std.testing.allocator, &bytes, .{});
    defer result.deinit();

    try std.testing.expect(!result.features.is_animation);
    try std.testing.expect(result.animation_info == null);
    try std.testing.expectEqual(features.FormatKind.lossy, result.features.format.?);
}

test "preserves unknown chunks before reconstruction data" {
    const vp8 = makeSimpleVP8(1, 1);
    const vp8x = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const unknown = "u";
    const riff_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + unknown.len + 1) +
        (container.chunk_header_size + vp8.len);
    var bytes: [8 + riff_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], riff_size);
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8X", &vp8x);
    writeChunk(&bytes, &offset, "zzzz", unknown);
    writeChunk(&bytes, &offset, "VP8 ", &vp8);

    var result = try parse(std.testing.allocator, &bytes, .{});
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 1), result.unknown_chunks.len);
    try std.testing.expectEqualSlices(u8, unknown, result.unknown_chunks[0].payload(&bytes));
}

test "ignores reserved and future VP8X fields" {
    const vp8 = makeSimpleVP8(1, 1);
    const vp8x = [_]u8{ 0xc1, 0xde, 0xad, 0xbe, 0, 0, 0, 0, 0, 0, 0xaa, 0xbb };
    const riff_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + vp8.len);
    var bytes: [8 + riff_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], riff_size);
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8X", &vp8x);
    writeChunk(&bytes, &offset, "VP8 ", &vp8);

    var result = try parse(std.testing.allocator, &bytes, .{});
    defer result.deinit();

    try std.testing.expectEqual(features.FileKind.extended, result.features.file_kind);
    try std.testing.expectEqual(@as(u32, 1), result.features.canvas.width);
    try std.testing.expectEqual(@as(u32, 1), result.features.canvas.height);
}

test "ignores reserved animation frame flag bits" {
    const vp8 = makeSimpleVP8(1, 1);
    const vp8x = [_]u8{ 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const anim = [_]u8{ 0, 0, 0, 0, 0, 0 };

    const frame_payload_size = 16 + container.chunk_header_size + vp8.len;
    var frame_payload: [frame_payload_size]u8 = undefined;
    @memset(frame_payload[0..16], 0);
    frame_payload[15] = 0xff;
    var frame_offset: usize = 16;
    writeChunk(&frame_payload, &frame_offset, "VP8 ", &vp8);
    assert(frame_offset == frame_payload.len);

    const riff_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + anim.len) +
        (container.chunk_header_size + frame_payload.len);
    var bytes: [8 + riff_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], riff_size);
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8X", &vp8x);
    writeChunk(&bytes, &offset, "ANIM", &anim);
    writeChunk(&bytes, &offset, "ANMF", &frame_payload);

    var result = try parse(std.testing.allocator, &bytes, .{});
    defer result.deinit();

    try std.testing.expect(result.features.is_animation);
    try std.testing.expectEqual(@as(usize, 1), result.frames.len);
    try std.testing.expectEqual(animation.BlendMethod.replace, result.frames[0].blend_method);
    try std.testing.expectEqual(animation.DisposeMethod.background, result.frames[0].dispose_method);
}

test "rejects missing chunks promised by VP8X flags" {
    const vp8 = makeSimpleVP8(1, 1);
    const vp8x = [_]u8{ 0x04, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const riff_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + vp8.len);
    var bytes: [8 + riff_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], riff_size);
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8X", &vp8x);
    writeChunk(&bytes, &offset, "VP8 ", &vp8);

    try std.testing.expectError(
        error.MissingRequiredChunk,
        parse(std.testing.allocator, &bytes, .{}),
    );
}

test "rejects animation frames that combine ALPH with VP8L" {
    const vp8l = makeSimpleVP8L(1, 1, false);
    const vp8x = [_]u8{ 0x12, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const anim = [_]u8{ 0, 0, 0, 0, 0, 0 };
    const alpha = [_]u8{ 0, 0xff };

    const frame_payload_size = 16 +
        (container.chunk_header_size + alpha.len) +
        (container.chunk_header_size + vp8l.len + 1);
    var frame_payload: [frame_payload_size]u8 = undefined;
    @memset(frame_payload[0..16], 0);
    var frame_offset: usize = 16;
    writeChunk(&frame_payload, &frame_offset, "ALPH", &alpha);
    writeChunk(&frame_payload, &frame_offset, "VP8L", &vp8l);
    assert(frame_offset == frame_payload.len);

    const riff_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + anim.len) +
        (container.chunk_header_size + frame_payload.len);
    var bytes: [8 + riff_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], riff_size);
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8X", &vp8x);
    writeChunk(&bytes, &offset, "ANIM", &anim);
    writeChunk(&bytes, &offset, "ANMF", &frame_payload);

    try std.testing.expectError(
        error.InvalidFrameChunk,
        parse(std.testing.allocator, &bytes, .{}),
    );
}

test "enforces configured frame count limits before parsing frame payload" {
    const vp8x = [_]u8{ 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const anim = [_]u8{ 0, 0, 0, 0, 0, 0 };
    const frame_payload = "";
    const riff_size = 4 +
        (container.chunk_header_size + vp8x.len) +
        (container.chunk_header_size + anim.len) +
        (container.chunk_header_size + frame_payload.len);
    var bytes: [8 + riff_size]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], riff_size);
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8X", &vp8x);
    writeChunk(&bytes, &offset, "ANIM", &anim);
    writeChunk(&bytes, &offset, "ANMF", frame_payload);

    try std.testing.expectError(
        error.FrameCountTooLarge,
        parse(std.testing.allocator, &bytes, .{
            .limits = .{ .frame_count_max = 0 },
        }),
    );
}

test "enforces configured chunk count limits" {
    const vp8 = makeSimpleVP8(1, 1);
    var bytes: [container.riff_header_size + container.chunk_header_size + vp8.len]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], @intCast(bytes.len - 8));
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8 ", &vp8);

    try std.testing.expectError(
        error.TooManyChunks,
        parse(std.testing.allocator, &bytes, .{
            .limits = .{ .chunk_count_max = 0 },
        }),
    );
}

test "enforces configured allocation limits" {
    const vp8 = makeSimpleVP8(1, 1);
    var bytes: [container.riff_header_size + container.chunk_header_size + vp8.len]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], @intCast(bytes.len - 8));
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = 12;
    writeChunk(&bytes, &offset, "VP8 ", &vp8);

    try std.testing.expectError(
        error.AllocationLimitExceeded,
        parse(std.testing.allocator, &bytes, .{
            .limits = .{ .allocation_bytes_max = 0 },
        }),
    );
}
