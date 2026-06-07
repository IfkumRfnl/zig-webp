//! RIFF container helpers shared by WebP decoders and encoders.

const std = @import("std");
const assert = std.debug.assert;

const errors = @import("errors.zig");

pub const fourcc_size = 4;
pub const chunk_header_size = 8;
pub const riff_header_size = 12;
pub const riff_payload_size_max = std.math.maxInt(u32) - 9;
pub const file_size_max = @as(u64, riff_payload_size_max) + 8;

comptime {
    assert(chunk_header_size == 2 * fourcc_size);
    assert(riff_header_size == 3 * fourcc_size);
    assert(riff_payload_size_max == 0xfffffff6);
    assert(file_size_max == 0xfffffffe);
}

pub const Error = errors.Error;

pub const ChunkKind = enum {
    lossy_bitstream,
    lossless_bitstream,
    extended_header,
    alpha,
    animation,
    animation_frame,
    color_profile,
    exif_metadata,
    xmp_metadata,
    unknown,
};

pub const FourCC = struct {
    bytes: [fourcc_size]u8,

    pub fn fromString(comptime bytes: []const u8) FourCC {
        comptime assert(bytes.len == fourcc_size);

        return .{
            .bytes = .{
                bytes[0],
                bytes[1],
                bytes[2],
                bytes[3],
            },
        };
    }

    pub fn fromBytes(bytes: []const u8) FourCC {
        assert(bytes.len == fourcc_size);

        return .{
            .bytes = .{
                bytes[0],
                bytes[1],
                bytes[2],
                bytes[3],
            },
        };
    }

    pub fn eql(self: FourCC, bytes: []const u8) bool {
        assert(bytes.len == fourcc_size);

        return std.mem.eql(u8, self.bytes[0..], bytes);
    }

    pub fn kind(self: FourCC) ChunkKind {
        if (self.eql("VP8 ")) return .lossy_bitstream;
        if (self.eql("VP8L")) return .lossless_bitstream;
        if (self.eql("VP8X")) return .extended_header;
        if (self.eql("ALPH")) return .alpha;
        if (self.eql("ANIM")) return .animation;
        if (self.eql("ANMF")) return .animation_frame;
        if (self.eql("ICCP")) return .color_profile;
        if (self.eql("EXIF")) return .exif_metadata;
        if (self.eql("XMP ")) return .xmp_metadata;

        return .unknown;
    }
};

pub const ContainerHeader = struct {
    riff_payload_size: u32,

    pub fn fileSizeBytes(self: ContainerHeader) u64 {
        return @as(u64, self.riff_payload_size) + 8;
    }
};

pub const ChunkHeader = struct {
    tag: FourCC,
    payload_size: u32,

    pub fn paddedPayloadSizeBytes(self: ChunkHeader) u64 {
        const payload_size: u64 = self.payload_size;

        return payload_size + (payload_size & 1);
    }

    pub fn chunkSizeBytes(self: ChunkHeader) u64 {
        return chunk_header_size + self.paddedPayloadSizeBytes();
    }
};

pub const ChunkLocation = struct {
    tag: FourCC,
    kind: ChunkKind,
    offset: u64,
    payload_offset: u64,
    payload_size: u32,

    pub fn paddedPayloadSizeBytes(self: ChunkLocation) u64 {
        const payload_size: u64 = self.payload_size;

        return payload_size + (payload_size & 1);
    }

    pub fn chunkSizeBytes(self: ChunkLocation) u64 {
        return chunk_header_size + self.paddedPayloadSizeBytes();
    }

    pub fn endOffset(self: ChunkLocation) u64 {
        return self.offset + self.chunkSizeBytes();
    }

    pub fn payload(self: ChunkLocation, bytes: []const u8) []const u8 {
        const start: usize = @intCast(self.payload_offset);
        const end: usize = @intCast(self.payload_offset + self.payload_size);
        assert(start <= end);
        assert(end <= bytes.len);

        return bytes[start..end];
    }
};

pub fn isWebP(bytes: []const u8) bool {
    if (bytes.len < riff_header_size) return false;
    if (!std.mem.eql(u8, bytes[0..fourcc_size], "RIFF")) return false;
    if (!std.mem.eql(u8, bytes[8..riff_header_size], "WEBP")) return false;

    return true;
}

pub fn parseHeader(bytes: []const u8) Error!ContainerHeader {
    if (bytes.len < riff_header_size) return error.InputTooSmall;
    if (!std.mem.eql(u8, bytes[0..fourcc_size], "RIFF")) {
        return error.InvalidRiffSignature;
    }
    if (!std.mem.eql(u8, bytes[8..riff_header_size], "WEBP")) {
        return error.InvalidWebPSignature;
    }

    const riff_payload_size = readLittleU32(bytes[4..8]);
    if (riff_payload_size > riff_payload_size_max) return error.FileTooLarge;
    if (riff_payload_size < fourcc_size) return error.InvalidRiffSize;
    if ((riff_payload_size & 1) != 0) return error.InvalidRiffSize;

    return .{
        .riff_payload_size = riff_payload_size,
    };
}

pub fn parseChunkHeader(bytes: []const u8) Error!ChunkHeader {
    if (bytes.len < chunk_header_size) return error.TruncatedChunkHeader;

    return .{
        .tag = FourCC.fromBytes(bytes[0..fourcc_size]),
        .payload_size = readLittleU32(bytes[4..chunk_header_size]),
    };
}

pub fn readLittleU16(bytes: []const u8) u16 {
    assert(bytes.len == 2);

    return @as(u16, bytes[0]) |
        (@as(u16, bytes[1]) << 8);
}

pub fn readLittleU24(bytes: []const u8) u32 {
    assert(bytes.len == 3);

    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16);
}

pub fn readLittleU32(bytes: []const u8) u32 {
    assert(bytes.len == 4);

    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

pub fn writeLittleU16(out: []u8, value: u16) void {
    assert(out.len == 2);

    out[0] = @truncate(value);
    out[1] = @truncate(value >> 8);
}

pub fn writeLittleU24(out: []u8, value: u32) void {
    assert(out.len == 3);
    assert(value <= 0x00ff_ffff);

    out[0] = @truncate(value);
    out[1] = @truncate(value >> 8);
    out[2] = @truncate(value >> 16);
}

pub fn writeLittleU32(out: []u8, value: u32) void {
    assert(out.len == 4);

    out[0] = @truncate(value);
    out[1] = @truncate(value >> 8);
    out[2] = @truncate(value >> 16);
    out[3] = @truncate(value >> 24);
}

test "detects RIFF WebP headers" {
    const valid = "RIFF\x12\x00\x00\x00WEBPVP8 ";

    try std.testing.expect(isWebP(valid));
    try std.testing.expect(!isWebP("RIFF\x00\x00\x00\x00NOPE"));
    try std.testing.expect(!isWebP("short"));
}

test "parses RIFF payload size" {
    const header = try parseHeader("RIFF\x12\x00\x00\x00WEBP");

    try std.testing.expectEqual(@as(u32, 18), header.riff_payload_size);
    try std.testing.expectEqual(@as(u64, 26), header.fileSizeBytes());
}

test "rejects invalid RIFF and WebP signatures" {
    try std.testing.expectError(
        error.InvalidRiffSignature,
        parseHeader("NOPE\x00\x00\x00\x00WEBP"),
    );
    try std.testing.expectError(
        error.InvalidWebPSignature,
        parseHeader("RIFF\x00\x00\x00\x00NOPE"),
    );
}

test "rejects invalid RIFF size fields" {
    try std.testing.expectError(
        error.InvalidRiffSize,
        parseHeader("RIFF\x05\x00\x00\x00WEBP"),
    );
    try std.testing.expectError(
        error.FileTooLarge,
        parseHeader("RIFF\xf8\xff\xff\xffWEBP"),
    );
}

test "parses chunk header and padded chunk size" {
    const bytes = [_]u8{ 'V', 'P', '8', ' ', 5, 0, 0, 0 };
    const header = try parseChunkHeader(&bytes);

    try std.testing.expectEqualSlices(u8, "VP8 ", header.tag.bytes[0..]);
    try std.testing.expectEqual(ChunkKind.lossy_bitstream, header.tag.kind());
    try std.testing.expectEqual(@as(u32, 5), header.payload_size);
    try std.testing.expectEqual(@as(u64, 6), header.paddedPayloadSizeBytes());
    try std.testing.expectEqual(@as(u64, 14), header.chunkSizeBytes());
}
