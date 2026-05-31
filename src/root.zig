//! Public module surface for zig-webp.

const std = @import("std");

pub const container = @import("container.zig");

pub const ChunkHeader = container.ChunkHeader;
pub const ChunkKind = container.ChunkKind;
pub const ContainerHeader = container.ContainerHeader;
pub const Error = container.Error;
pub const FourCC = container.FourCC;

pub const chunk_header_size = container.chunk_header_size;
pub const riff_header_size = container.riff_header_size;

pub fn isWebP(bytes: []const u8) bool {
    return container.isWebP(bytes);
}

pub fn parseHeader(bytes: []const u8) Error!ContainerHeader {
    return container.parseHeader(bytes);
}

pub fn parseChunkHeader(bytes: []const u8) Error!ChunkHeader {
    return container.parseChunkHeader(bytes);
}

test "root exposes WebP container helpers" {
    const bytes = "RIFF\x12\x00\x00\x00WEBPVP8 ";

    try std.testing.expect(isWebP(bytes));

    const header = try parseHeader(bytes);
    try std.testing.expectEqual(@as(u32, 18), header.riff_payload_size);
    try std.testing.expectEqual(@as(u64, 26), header.fileSizeBytes());
}
