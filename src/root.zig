//! Public module surface for zig-webp.

const std = @import("std");
const corpus_tests = @import("testing/corpus.zig");

pub const alpha = @import("alpha.zig");
pub const animation = @import("animation.zig");
pub const bit_reader = @import("bit_reader.zig");
pub const bit_writer = @import("bit_writer.zig");
pub const container = @import("container.zig");
pub const decode = @import("decode.zig");
pub const demux = @import("demux.zig");
pub const errors = @import("errors.zig");
pub const features = @import("features.zig");
pub const image = @import("image.zig");
pub const limits = @import("limits.zig");
pub const metadata = @import("metadata.zig");
pub const mux = @import("mux.zig");
pub const options = @import("options.zig");
pub const testing = @import("testing.zig");
pub const vp8_bool_reader = @import("vp8/bool_reader.zig");
pub const vp8_bool_writer = @import("vp8/bool_writer.zig");
pub const vp8_frame_header = @import("vp8/frame_header.zig");
pub const vp8_modes = @import("vp8/modes.zig");
pub const vp8_prediction = @import("vp8/prediction.zig");
pub const vp8_quant = @import("vp8/quant.zig");
pub const vp8_token_probs = @import("vp8/token_probs.zig");
pub const vp8_tokens = @import("vp8/tokens.zig");
pub const vp8_transform = @import("vp8/transform.zig");
pub const vp8l_header = @import("vp8l/header.zig");
pub const vp8l_color_cache = @import("vp8l/color_cache.zig");
pub const vp8l_decoder = @import("vp8l/decoder.zig");
pub const vp8l_entropy = @import("vp8l/entropy.zig");
pub const vp8l_huffman = @import("vp8l/huffman.zig");
pub const vp8l_image_data = @import("vp8l/image_data.zig");
pub const vp8l_inverse_transform = @import("vp8l/inverse_transform.zig");
pub const vp8l_meta_prefix = @import("vp8l/meta_prefix.zig");
pub const vp8l_pixel = @import("vp8l/pixel.zig");
pub const vp8l_prefix_groups = @import("vp8l/prefix_groups.zig");
pub const vp8l_transform = @import("vp8l/transform.zig");

pub const AlphaCompression = alpha.Compression;
pub const AlphaFilter = alpha.Filter;
pub const AlphaHeader = alpha.Header;
pub const AlphaPreprocessing = alpha.Preprocessing;
pub const AnimationFrame = animation.Frame;
pub const BitReader = bit_reader.BitReader;
pub const BitWriter = bit_writer.BitWriter;
pub const ByteReader = bit_reader.ByteReader;
pub const ByteWriter = bit_writer.ByteWriter;
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
pub const VP8BoolReader = vp8_bool_reader.BoolReader;
pub const VP8BoolWriter = vp8_bool_writer.BoolWriter;
pub const VP8ChromaMode = vp8_modes.ChromaMode;
pub const VP8FrameHeader = vp8_frame_header.Header;
pub const VP8FrameTag = vp8_frame_header.FrameTag;
pub const VP8LumaMode = vp8_modes.LumaMode;
pub const VP8Macroblock = vp8_modes.Macroblock;
pub const VP8MacroblockGrid = vp8_modes.MacroblockGrid;
pub const VP8ParsedFrameHeader = vp8_frame_header.Parsed;
pub const VP8QuantFactors = vp8_quant.Factors;
pub const VP8PictureHeader = vp8_frame_header.PictureHeader;
pub const VP8SubblockMode = vp8_modes.SubblockMode;
pub const VP8TokenPartitions = vp8_frame_header.TokenPartitions;
pub const VP8TokenProbabilityTable = vp8_token_probs.Table;
pub const VP8MacroblockCoefficients = vp8_tokens.MacroblockCoefficients;
pub const VP8NonzeroFlags = vp8_tokens.NonzeroFlags;
pub const VP8LARGBPixel = vp8l_pixel.Pixel;
pub const VP8LColorCache = vp8l_color_cache.Cache;
pub const VP8LDecodeResult = vp8l_decoder.Result;
pub const VP8LDecodeWorkBuffers = vp8l_decoder.WorkBuffers;
pub const VP8LEntropyDecodeSummary = vp8l_entropy.DecodeSummary;
pub const VP8LHeader = vp8l_header.Header;
pub const VP8LCodeLengthHuffmanTable = vp8l_huffman.CodeLengthTable;
pub const VP8LHuffmanSymbolTable = vp8l_huffman.SymbolTable;
pub const VP8LImageData = vp8l_image_data.ImageData;
pub const VP8LImageDataPrefixCodeGroupBuffers = vp8l_image_data.PrefixCodeGroupBuffers;
pub const VP8LInverseTransform = vp8l_inverse_transform;
pub const VP8LMetaPrefixInfo = vp8l_meta_prefix.Info;
pub const VP8LPrefixCodeGroupStore = vp8l_prefix_groups.Store;
pub const VP8LPrefixCodeGroupWorkBuffers = vp8l_prefix_groups.WorkBuffers;
pub const VP8LTransform = vp8l_transform.Transform;
pub const VP8LTransformListReader = vp8l_transform.ListReader;

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

pub fn decodeStatic(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    decode_options: DecoderOptions,
) Error!image.OwnedBuffer {
    return decode.decodeStatic(gpa, bytes, decode_options);
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

test "root exposes composable Step 2 bitstream infrastructure" {
    var lsb_out: [2]u8 = undefined;
    var bit_writer_instance = BitWriter.init(&lsb_out);
    try bit_writer_instance.writeBits(0b101, 3);
    try bit_writer_instance.writeBits(0x1f, 5);

    var bit_reader_instance = BitReader.init(try bit_writer_instance.finish());
    try std.testing.expectEqual(@as(u32, 0b101), try bit_reader_instance.readBits(3));
    try std.testing.expectEqual(@as(u32, 0x1f), try bit_reader_instance.readBits(5));

    var bool_out: [8]u8 = undefined;
    var bool_writer_instance = VP8BoolWriter.init(&bool_out);
    try bool_writer_instance.writeBool(40, 1);
    try bool_writer_instance.writeBool(200, 0);

    var bool_reader_instance = VP8BoolReader.init(try bool_writer_instance.finish());
    try std.testing.expectEqual(@as(u1, 1), try bool_reader_instance.readBool(40));
    try std.testing.expectEqual(@as(u1, 0), try bool_reader_instance.readBool(200));

    var entries: [VP8LHuffmanSymbolTable.entry_count_limit]vp8l_huffman.Entry = undefined;
    const huffman_table = try VP8LHuffmanSymbolTable.build(&entries, &.{ 1, 1 });
    var huffman_reader = BitReader.init(&.{0});

    try std.testing.expectEqual(@as(u16, 0), try huffman_table.decode(&huffman_reader));
}
