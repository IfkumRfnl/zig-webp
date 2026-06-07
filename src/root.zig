//! Public module surface for zig-webp.

const std = @import("std");
const corpus_tests = @import("testing/corpus.zig");

pub const animation = @import("animation.zig");
pub const container = @import("container.zig");
pub const demux = @import("demux.zig");
pub const errors = @import("errors.zig");
pub const features = @import("features.zig");
pub const image = @import("image.zig");
pub const limits = @import("limits.zig");
pub const metadata = @import("metadata.zig");
pub const mux = @import("mux.zig");
pub const options = @import("options.zig");
pub const testing = @import("testing.zig");

pub const AnimationFrame = animation.Frame;
pub const ChunkHeader = container.ChunkHeader;
pub const ChunkKind = container.ChunkKind;
pub const ChunkLocation = container.ChunkLocation;
pub const ContainerHeader = container.ContainerHeader;
pub const DecoderOptions = options.DecoderOptions;
pub const DemuxOptions = demux.Options;
pub const DemuxResult = demux.Result;
pub const Dimensions = image.Dimensions;
pub const EncoderOptions = options.EncoderOptions;
pub const Error = errors.Error;
pub const ErrorCategory = errors.Category;
pub const FeatureSummary = features.Summary;
pub const FourCC = container.FourCC;
pub const ImageBuffer = image.Buffer;
pub const MetadataPayloads = metadata.RawPayloads;
pub const MuxOptions = mux.Options;
pub const ResourceLimits = limits.ResourceLimits;
pub const StaticImage = mux.StaticImage;

pub const chunk_header_size = container.chunk_header_size;
pub const riff_header_size = container.riff_header_size;

pub fn errorCategory(err: Error) ErrorCategory {
    return errors.category(err);
}

pub fn isWebP(bytes: []const u8) bool {
    return container.isWebP(bytes);
}

pub fn parseHeader(bytes: []const u8) Error!ContainerHeader {
    return container.parseHeader(bytes);
}

pub fn parseChunkHeader(bytes: []const u8) Error!ChunkHeader {
    return container.parseChunkHeader(bytes);
}

pub fn parseFeatures(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    parse_options: DemuxOptions,
) Error!FeatureSummary {
    return demux.parseFeatures(gpa, bytes, parse_options);
}

pub fn parseWebP(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    parse_options: DemuxOptions,
) Error!DemuxResult {
    return demux.parse(gpa, bytes, parse_options);
}

pub fn encodeStatic(
    gpa: std.mem.Allocator,
    static_image: StaticImage,
    encode_options: MuxOptions,
) Error![]u8 {
    return mux.encodeStatic(gpa, static_image, encode_options);
}

test "root exposes WebP container helpers" {
    const bytes = "RIFF\x12\x00\x00\x00WEBPVP8 ";

    try std.testing.expect(isWebP(bytes));

    const header = try parseHeader(bytes);
    try std.testing.expectEqual(@as(u32, 18), header.riff_payload_size);
    try std.testing.expectEqual(@as(u64, 26), header.fileSizeBytes());
}

test "root public declarations compile" {
    _ = corpus_tests;
    std.testing.refAllDecls(@This());
}
