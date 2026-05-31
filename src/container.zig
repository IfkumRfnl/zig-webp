//! RIFF container helpers shared by WebP decoders and encoders.

const std = @import("std");
const assert = std.debug.assert;

pub const fourcc_size = 4;
pub const chunk_header_size = 8;
pub const riff_header_size = 12;

comptime {
    assert(chunk_header_size == 2 * fourcc_size);
    assert(riff_header_size == 3 * fourcc_size);
}

pub const Error = error{
    InputTooSmall,
    InvalidRiffSignature,
    InvalidWebPSignature,
    TruncatedChunkHeader,
};

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

    return .{
        .riff_payload_size = readLittleU32(bytes[4..8]),
    };
}

pub fn parseChunkHeader(bytes: []const u8) Error!ChunkHeader {
    if (bytes.len < chunk_header_size) return error.TruncatedChunkHeader;

    return .{
        .tag = FourCC.fromBytes(bytes[0..fourcc_size]),
        .payload_size = readLittleU32(bytes[4..chunk_header_size]),
    };
}

fn readLittleU32(bytes: []const u8) u32 {
    assert(bytes.len == 4);

    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
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

test "parses chunk header and padded chunk size" {
    const bytes = [_]u8{ 'V', 'P', '8', ' ', 5, 0, 0, 0 };
    const header = try parseChunkHeader(&bytes);

    try std.testing.expectEqualSlices(u8, "VP8 ", header.tag.bytes[0..]);
    try std.testing.expectEqual(ChunkKind.lossy_bitstream, header.tag.kind());
    try std.testing.expectEqual(@as(u32, 5), header.payload_size);
    try std.testing.expectEqual(@as(u64, 6), header.paddedPayloadSizeBytes());
    try std.testing.expectEqual(@as(u64, 14), header.chunkSizeBytes());
}
