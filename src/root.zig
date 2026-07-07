//! Public module surface for zig-webp, a zero-dependency WebP codec.
//!
//! Most callers need only a handful of names:
//! - `decodeStatic` — decode a complete WebP still to pixels (lossless,
//!   lossy, and lossy+alpha).
//! - `decodeStaticInto` — the same decode into a caller-owned pixel buffer,
//!   honoring its stride and format.
//! - `decodeAnimation` — decode a complete animated WebP to composited frames.
//! - `encodeLossless` — encode pixels into a lossless (VP8L) WebP file.
//! - `encodeLossy` — encode pixels into a lossy (VP8) WebP file.
//! - `parseFeatures` — probe dimensions/format/alpha/animation/metadata
//!   without decoding pixels.
//! - `parseWebP` — strict RIFF demux to chunk locations.
//! - `encodeStatic` — mux an existing VP8/VP8L bitstream into a WebP file.
//! - `ResourceLimits` / `DecoderOptions` — bound untrusted-input handling.
//!
//! ## API stability tiers
//!
//! - **Tier 1 (stable at 1.0, semver-governed)**: the entry points
//!   `decodeStatic`, `decodeStaticInto`, `decodeAnimation`,
//!   `AnimationDecoder`, `encodeLossless`, `encodeLossy`, `encodeStatic`,
//!   `encodeAnimation`, `encodeAnimationFromBuffers`,
//!   `encodeAnimationMinimized`, `parseFeatures`, `parseWebP`, `isWebP`,
//!   `parseHeader`, `parseChunkHeader`, and `errorCategory`, plus their
//!   parameter and result types: `DecoderOptions`, `EncoderOptions`,
//!   `ResourceLimits`, `ImageBuffer`, `Dimensions`, `PixelFormat` (via
//!   `image`), `Error`/`ErrorCategory`, `FeatureSummary`, `DemuxResult`,
//!   the animation option/frame types (`AnimationImage`,
//!   `AnimationFrameImage`, `AnimationInfo`, `CompositedFrame`,
//!   `DecodedAnimation`, `DecodedAnimationFrame`, `AnimationFrameSource`,
//!   `AnimationEncodeOptions`, `AnimationFrameInput`,
//!   `AnimationMinimizeOptions`), and `MetadataPayloads`.
//! - **Tier 2 (internals, no stability promise)**: the `vp8_*` and `vp8l_*`
//!   module exports and their aliased `VP8*`/`VP8L*` types, plus
//!   `bit_reader`/`bit_writer`, `testing`, and the other module re-exports —
//!   exported for tooling, tests, and advanced callers; they may change in
//!   any release.
//!
//! The breaking-change rule: additions to `errors.Error` are not breaking;
//! removals or renames of Tier 1 names are.

const std = @import("std");
const corpus_tests = @import("testing/corpus.zig");
const encode_corpus_tests = @import("testing/encode_corpus.zig");
const hardening_tests = @import("testing/hardening.zig");
const metrics_tests = @import("testing/metrics.zig");
const synth_tests = @import("testing/synth.zig");
const encode = @import("encode.zig");

pub const alpha = @import("alpha.zig");
pub const animation = @import("animation.zig");
pub const animation_decode = @import("animation_decode.zig");
pub const animation_encode = @import("animation_encode.zig");
pub const animation_optimize = @import("animation_optimize.zig");
pub const bit_reader = @import("bit_reader.zig");
pub const bit_writer = @import("bit_writer.zig");
pub const color = @import("color.zig");
pub const container = @import("container.zig");
pub const decode = @import("decode.zig");
pub const demux = @import("demux.zig");
pub const encode_module = @import("encode.zig");
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
pub const vp8_cost = @import("vp8/cost.zig");
pub const vp8_decoder = @import("vp8/decoder.zig");
pub const vp8_frame_header = @import("vp8/frame_header.zig");
pub const vp8_header = @import("vp8/header.zig");
pub const vp8_modes = @import("vp8/modes.zig");
pub const vp8_prediction = @import("vp8/prediction.zig");
pub const vp8_quant = @import("vp8/quant.zig");
pub const vp8_token_probs = @import("vp8/token_probs.zig");
pub const vp8_tokens = @import("vp8/tokens.zig");
pub const vp8_transform = @import("vp8/transform.zig");
pub const vp8l_header = @import("vp8l/header.zig");
pub const vp8l_color_cache = @import("vp8l/color_cache.zig");
pub const vp8l_decoder = @import("vp8l/decoder.zig");
pub const vp8l_encoder = @import("vp8l/encoder.zig");
pub const vp8l_huffman_writer = @import("vp8l/huffman_writer.zig");
pub const vp8l_entropy = @import("vp8l/entropy.zig");
pub const vp8l_huffman = @import("vp8l/huffman.zig");
pub const vp8l_image_data = @import("vp8l/image_data.zig");
pub const vp8l_inverse_transform = @import("vp8l/inverse_transform.zig");
pub const vp8l_forward_transform = @import("vp8l/forward_transform.zig");
pub const vp8l_lz77 = @import("vp8l/lz77.zig");
pub const vp8l_meta_prefix = @import("vp8l/meta_prefix.zig");
pub const vp8l_pixel = @import("vp8l/pixel.zig");
pub const vp8l_prefix_groups = @import("vp8l/prefix_groups.zig");
pub const vp8l_transform = @import("vp8l/transform.zig");

pub const AlphaCompression = alpha.Compression;
pub const AlphaFilter = alpha.Filter;
pub const AlphaHeader = alpha.Header;
pub const AlphaPreprocessing = alpha.Preprocessing;
pub const AnimationFrame = animation.Frame;
/// Inputs to `encodeAnimation`: global canvas/loop/background plus an ordered
/// list of pre-encoded `AnimationFrameImage` frames and optional metadata.
pub const AnimationImage = mux.AnimationImage;
/// One pre-encoded frame for `encodeAnimation`: placement, timing, blend/dispose
/// methods, and the already-encoded VP8/VP8L bitstream (plus optional lossy
/// `ALPH`). Distinct from `AnimationFrame`, which is a decoded/parsed frame.
pub const AnimationFrameImage = mux.FrameImage;
/// Streaming animated-WebP decoder: composites one frame at a time onto a
/// reused canvas (bounded memory). The caller owns it and must `deinit`.
pub const AnimationDecoder = animation_decode.Decoder;
/// Global animation properties (canvas, frame count, loop count, background).
pub const AnimationInfo = animation_decode.Info;
/// One composited animation frame; from `AnimationDecoder.next` its pixels
/// borrow the decoder's canvas, from `decodeAnimation` they are owned.
pub const CompositedFrame = animation_decode.Frame;
/// Result of `decodeAnimation`: every composited frame as its own buffer.
pub const DecodedAnimation = animation_decode.OwnedAnimation;
pub const DecodedAnimationFrame = animation_decode.OwnedFrame;
/// One source frame for `encodeAnimationFromBuffers`: a pixel buffer plus its
/// canvas offset, duration, blend/dispose methods, and per-frame codec. Distinct
/// from `AnimationFrameImage` (a pre-encoded bitstream for the mux-level
/// `encodeAnimation`) — this carries pixels for the encoder to compress.
pub const AnimationFrameSource = animation_encode.FrameSource;
/// Options for `encodeAnimationFromBuffers`: canvas, loop count, background,
/// metadata, resource limits, and the shared per-frame quality/method/alpha
/// knobs.
pub const AnimationEncodeOptions = animation_encode.Options;
/// One full-canvas source frame for `encodeAnimationMinimized`: the desired
/// canvas at this timestamp plus duration and codec. The optimizer derives the
/// rectangle/blend/dispose, so (unlike `AnimationFrameSource`) the caller does
/// not supply them.
pub const AnimationFrameInput = animation_optimize.FrameInput;
/// Options for `encodeAnimationMinimized`: the `AnimationEncodeOptions` knobs
/// plus the keyframe interval. The per-frame compositing is derived.
pub const AnimationMinimizeOptions = animation_optimize.Options;
pub const BitReader = bit_reader.BitReader;
pub const BitWriter = bit_writer.BitWriter;
pub const ByteReader = bit_reader.ByteReader;
pub const ByteWriter = bit_writer.ByteWriter;
pub const ChunkHeader = container.ChunkHeader;
pub const ChunkKind = container.ChunkKind;
pub const ChunkLocation = container.ChunkLocation;
/// Borrowed VP8 YUV 4:2:0 planes accepted by `color.upsampleFancy`.
pub const ColorPlanes = color.Planes;
pub const ContainerHeader = container.ContainerHeader;
/// Decode-time options: resource limits and output pixel format.
pub const DecoderOptions = options.DecoderOptions;
pub const DemuxOptions = demux.Options;
/// Result of `parseWebP`: chunk locations, features, and metadata; the
/// caller owns it and must call `deinit`.
pub const DemuxResult = demux.Result;
/// Validated image width and height in pixels.
pub const Dimensions = image.Dimensions;
/// Options bag for the still pixel encoders (`encodeLossless`/`encodeLossy`);
/// see `options.EncoderOptions` for the per-field documentation.
pub const EncoderOptions = options.EncoderOptions;
/// The error set returned by every fallible entry point.
pub const Error = errors.Error;
/// Coarse failure class for an `Error`, for callers that branch on it.
pub const ErrorCategory = errors.Category;
/// By-value feature probe: dimensions, format, alpha, animation, metadata.
pub const FeatureSummary = features.Summary;
pub const FourCC = container.FourCC;
/// A decoded pixel plane with its dimensions, stride, and format.
pub const ImageBuffer = image.Buffer;
/// Borrowed metadata chunk payloads (ICCP/EXIF/XMP) carried by a file.
pub const MetadataPayloads = metadata.RawPayloads;
pub const MuxOptions = mux.Options;
/// Bounds on input size and allocation for handling untrusted input.
pub const ResourceLimits = limits.ResourceLimits;
/// Inputs to `encodeStatic`: a canvas plus an already-encoded bitstream.
pub const StaticImage = mux.StaticImage;
pub const VP8BoolReader = vp8_bool_reader.BoolReader;
pub const VP8BoolWriter = vp8_bool_writer.BoolWriter;
pub const VP8ChromaMode = vp8_modes.ChromaMode;
pub const VP8Frame = vp8_decoder.Frame;
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
pub const VP8LHuffmanWriterCode = vp8l_huffman_writer.Code;

pub const chunk_header_size = container.chunk_header_size;
pub const riff_header_size = container.riff_header_size;

/// Maps any `Error` to its coarse `ErrorCategory` failure class.
pub fn errorCategory(err: Error) ErrorCategory {
    return errors.category(err);
}

/// Cheap, allocation-free check that `bytes` begins with the RIFF/WEBP
/// signature; performs no validation beyond the magic.
pub fn isWebP(bytes: []const u8) bool {
    return container.isWebP(bytes);
}

/// Bounded parse of the RIFF/WebP container header from a complete buffer.
pub fn parseHeader(bytes: []const u8) Error!ContainerHeader {
    return container.parseHeader(bytes);
}

/// Bounded parse of a single chunk header from a complete buffer slice.
pub fn parseChunkHeader(bytes: []const u8) Error!ChunkHeader {
    return container.parseChunkHeader(bytes);
}

/// Probes a complete WebP buffer for its features (dimensions, format,
/// alpha, animation, metadata presence) without decoding any pixels.
/// Strictly validates the container; allocation is bounded by
/// `DemuxOptions.limits`. Returns the summary by value (nothing to free).
pub fn parseFeatures(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    parse_options: DemuxOptions,
) Error!FeatureSummary {
    return demux.parseFeatures(gpa, bytes, parse_options);
}

/// Strict RIFF/WebP demux of a complete buffer into chunk locations and
/// features; rejects malformed chunk ordering and duplicate chunks. Does
/// not decode pixels. The caller owns the result and must call
/// `DemuxResult.deinit`.
pub fn parseWebP(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    parse_options: DemuxOptions,
) Error!DemuxResult {
    return demux.parse(gpa, bytes, parse_options);
}

/// Muxes an already-encoded VP8/VP8L bitstream (`StaticImage`) into a
/// canonical WebP file. It does not encode pixels — use
/// `encodeLossless`/`encodeLossy` for that. Returns caller-owned bytes
/// (free with the same allocator).
pub fn encodeStatic(
    gpa: std.mem.Allocator,
    static_image: StaticImage,
    encode_options: MuxOptions,
) Error![]u8 {
    return mux.encodeStatic(gpa, static_image, encode_options);
}

/// Muxes already-encoded animation frames (`AnimationImage`) into a complete
/// animated WebP file: `VP8X` + `ANIM` + one `ANMF` per frame (with optional
/// per-frame `ALPH`), plus optional `ICCP`/`EXIF`/`XMP ` metadata. It does not
/// encode pixels — each frame supplies its own VP8/VP8L bitstream — and is the
/// animated analogue of `encodeStatic`. Every frame's rectangle, even-offset,
/// codec, dimensions, and alpha are validated against the canvas and the
/// container rules, so the output round-trips through `parseWebP` and is
/// accepted by `webpinfo`/`webpmux`. Returns caller-owned bytes (free with the
/// same allocator).
pub fn encodeAnimation(
    gpa: std.mem.Allocator,
    anim: AnimationImage,
    encode_options: MuxOptions,
) Error![]u8 {
    return mux.encodeAnimation(gpa, anim, encode_options);
}

/// Encodes an ordered list of pixel-buffer frames (`AnimationFrameSource`) into
/// a complete animated WebP file. Each frame's pixels are compressed to a
/// `VP8 `/`VP8L` bitstream — lossless via the VP8L encoder, lossy via the VP8
/// encoder plus an optional lossless `ALPH` plane — and the frames are muxed via
/// `encodeAnimation`. This is the pixel-level animated analogue of
/// `encodeLossy`/`encodeLossless`; the caller dictates each frame's rectangle,
/// blend, and dispose (automatic sub-rectangle/differencing optimization is a
/// later step). The output round-trips through `decodeAnimation` and is accepted
/// by `webpinfo`/`webpmux`/`anim_dump`. Returns caller-owned bytes (free with
/// the same allocator).
pub fn encodeAnimationFromBuffers(
    gpa: std.mem.Allocator,
    frame_sources: []const AnimationFrameSource,
    encode_options: AnimationEncodeOptions,
) Error![]u8 {
    return animation_encode.encodeAnimationFromBuffers(gpa, frame_sources, encode_options);
}

/// Encodes a sequence of full-canvas frames (`AnimationFrameInput`) into a
/// minimized animated WebP. The optimizer automatically derives a minimal
/// `ANMF` layout — sub-rectangles, blend/dispose methods, and keyframes — that
/// composites back to exactly the input canvases, then reuses the per-frame
/// encoder behind `encodeAnimationFromBuffers` and `encodeAnimation`. For
/// all-lossless input the round-trip through `decodeAnimation` is byte-exact
/// after transparent-RGB canonicalization: fully-transparent pixels are
/// normalized to `0,0,0,0` (matching libwebp `anim_dump` composition), so RGB
/// hidden behind alpha=0 is not preserved. Lossy frames are tracked against the
/// decoder's reconstructed canvas so error never accumulates. The output is
/// accepted by `webpinfo`/`webpmux`/`anim_dump`.
/// Unlike `encodeAnimationFromBuffers` (the explicit-rect API), the caller does
/// not pick per-frame rectangles or compositing. Returns caller-owned bytes.
pub fn encodeAnimationMinimized(
    gpa: std.mem.Allocator,
    frames: []const AnimationFrameInput,
    encode_options: AnimationMinimizeOptions,
) Error![]u8 {
    return animation_optimize.encodeAnimationMinimized(gpa, frames, encode_options);
}

/// Encodes a caller-supplied pixel buffer into a complete lossless (VP8L)
/// WebP file. The buffer may be `rgba`/`bgra`/`argb` (4-channel) or `rgb`
/// (treated as opaque), read row-major honoring its stride. The current VP8L
/// encoder applies LZ77 back-references plus decision-gated subtract-green,
/// color, predictor, and palette/color-indexing transforms, with an optional
/// color cache and optional meta-prefix (multiple prefix-code groups), each
/// chosen by measured encoded size, so the output is valid and round-trips
/// bit-exactly. `encode_options.format` must be `.lossless`.
///
/// Set `encode_options.metadata` (raw ICCP/EXIF/XMP payloads) to attach metadata
/// (step 9d); the file is then an extended (`VP8X`) container with those chunks
/// in spec-canonical order, round-tripping byte-exactly through `parseWebP`.
/// With the default empty metadata the output is the canonical simple `VP8L`
/// file, byte-identical to the no-metadata path.
/// Returns caller-owned bytes (free with the same allocator).
pub fn encodeLossless(
    gpa: std.mem.Allocator,
    buffer: ImageBuffer,
    encode_options: EncoderOptions,
) Error![]u8 {
    return encode.encodeStaticLossless(gpa, buffer, encode_options);
}

/// Encodes a `width`x`height` ARGB pixel array (packed `0xAARRGGBB`,
/// row-major) into a raw VP8L bitstream — the payload of a `VP8L` chunk,
/// without the RIFF container. Most callers want `encodeLossless`; this is for
/// tooling that muxes the bitstream itself. Returns caller-owned bytes.
pub fn encodeVP8LBitstream(
    gpa: std.mem.Allocator,
    dimensions: Dimensions,
    pixels: []const VP8LARGBPixel,
) Error![]u8 {
    return vp8l_encoder.encodeAlloc(gpa, dimensions, pixels);
}

/// Encodes a caller-supplied pixel buffer into a complete lossy (VP8) WebP file.
/// The encoder does rate-distortion intra mode decision (16x16/8x8 and 4x4
/// B_PRED), skip coding, quantizer-derived in-loop deblocking, and per-segment
/// quantization, with effort scaled by `encode_options.method` (0..6). The
/// buffer may be `rgba`/`bgra`/`argb` or `rgb`, read row-major honoring stride.
/// A meaningful (non-fully-opaque) alpha channel is encoded losslessly into an
/// `ALPH` chunk and emitted as a `VP8X` + `ALPH` + `VP8 ` container; fully-opaque
/// input emits a plain `VP8 ` file. `encode_options.quality` (0..100) selects the
/// color quantizer (or set `target_size`/`target_psnr` for a size/PSNR search),
/// `encode_options.alpha_quality` (0..100) the alpha compression effort, and
/// `encode_options.format` must be `.lossy`.
///
/// Set `encode_options.metadata` (raw ICCP/EXIF/XMP payloads) to attach metadata
/// (step 9d); the chunks are written in spec-canonical order and coexist with a
/// lossy `ALPH` chunk, round-tripping byte-exactly through `parseWebP`. With the
/// default empty metadata (and no alpha) the output is byte-identical to the
/// no-metadata path. Returns caller-owned bytes.
pub fn encodeLossy(
    gpa: std.mem.Allocator,
    buffer: ImageBuffer,
    encode_options: EncoderOptions,
) Error![]u8 {
    return encode.encodeStaticLossy(gpa, buffer, encode_options);
}

/// Encodes a `width`x`height` ARGB pixel array (packed `0xAARRGGBB`, row-major)
/// into a raw VP8 bitstream — the payload of a `VP8 ` chunk, without the RIFF
/// container. `quality` is 0..100. Most callers want `encodeLossy`; this is for
/// tooling that muxes the bitstream itself. Returns caller-owned bytes.
pub fn encodeVP8Bitstream(
    gpa: std.mem.Allocator,
    dimensions: Dimensions,
    pixels: []const VP8LARGBPixel,
    quality: u8,
) Error![]u8 {
    return encode.encodeVP8Bitstream(gpa, dimensions, pixels, quality);
}

/// Decodes a complete still WebP file into an owned pixel buffer: lossless
/// (VP8L), lossy (VP8), and lossy+alpha (the `ALPH` plane composed over color),
/// to packed `rgba`/`bgra`/`argb`/`rgb` per `DecoderOptions.output_format`.
/// Animated inputs fail with `error.UnsupportedAnimationDecode` — decode those
/// via `decodeAnimation` / `AnimationDecoder`. Allocation is budgeted against
/// `DecoderOptions.limits.allocation_bytes_max`. The caller frees the
/// result via `OwnedBuffer.deinit`.
pub fn decodeStatic(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    decode_options: DecoderOptions,
) Error!image.OwnedBuffer {
    return decode.decodeStatic(gpa, bytes, decode_options);
}

/// Decodes a complete still WebP file into the caller-owned `dest` buffer,
/// row-major, honoring `dest.stride`. `dest.format` is authoritative and
/// `DecoderOptions.output_format` is ignored on this path. `dest` must pass
/// `ImageBuffer.validate()` and its dimensions must exactly equal the file's
/// canvas dimensions; any mismatch fails with `error.InvalidCanvasSize`
/// before any pixel is decoded. Internal scratch (including one packed
/// output-sized buffer) is still allocated from `gpa` and budgeted against
/// `DecoderOptions.limits.allocation_bytes_max`. Bytes in `dest.pixels`
/// outside the written rows (stride padding, tail slack) are left untouched.
/// Animated inputs fail with `error.UnsupportedAnimationDecode`.
pub fn decodeStaticInto(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    dest: ImageBuffer,
    decode_options: DecoderOptions,
) Error!void {
    return decode.decodeStaticInto(gpa, bytes, dest, decode_options);
}

/// Decodes an animated WebP into composited per-frame buffers, matching
/// libwebp's `WebPAnimDecoder`/`anim_dump`: a transparent canvas with spec
/// keyframe, blend, and dispose rules. Each frame is reconstructed through the
/// static VP8/VP8L/alpha decoders. Requires a 4-channel `output_format`; still
/// images fail with `error.NotAnimated`. For bounded per-frame memory, drive
/// `AnimationDecoder` directly. The caller frees the result via
/// `DecodedAnimation.deinit`.
pub fn decodeAnimation(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    decode_options: DecoderOptions,
) Error!DecodedAnimation {
    return animation_decode.decodeAnimationAlloc(gpa, bytes, decode_options);
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
    _ = encode_corpus_tests;
    _ = hardening_tests;
    _ = metrics_tests;
    _ = synth_tests;
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
