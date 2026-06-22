//! Public static-image encode composition.
//!
//! Slice 1 covers lossless (VP8L) still encode from a caller-supplied pixel
//! buffer: it builds the VP8L bitstream (literals only) and muxes it into a
//! canonical simple `VP8L` WebP file. The result round-trips bit-exactly
//! through this library's decoder.

const std = @import("std");
const assert = std.debug.assert;

const alpha = @import("alpha.zig");
const color = @import("color.zig");
const container = @import("container.zig");
const errors = @import("errors.zig");
const features = @import("features.zig");
const image = @import("image.zig");
const limits = @import("limits.zig");
const metrics = @import("testing/metrics.zig");
const mux = @import("mux.zig");
const options = @import("options.zig");
const vp8_encoder = @import("vp8/encoder.zig");
const vp8_quant = @import("vp8/quant.zig");
const vp8l_encoder = @import("vp8l/encoder.zig");
const vp8l_pixel = @import("vp8l/pixel.zig");

/// Encodes a caller-supplied pixel buffer into a complete lossless (VP8L) WebP
/// file. The buffer's `format` may be any 4-channel layout (`rgba`, `bgra`,
/// `argb`) or `rgb` (treated as fully opaque); pixels are read row-major using
/// the buffer's `stride`. The returned bytes are caller-owned (free with `gpa`).
///
/// `encode_options.format` must be `.lossless`; lossy encode is a later step.
pub fn encodeStaticLossless(
    gpa: std.mem.Allocator,
    buffer: image.Buffer,
    encode_options: options.EncoderOptions,
) errors.Error![]u8 {
    if (encode_options.format != .lossless) return error.UnsupportedImageFormat;
    try buffer.validate();

    const dimensions = buffer.dimensions;
    const pixel_count: usize = @intCast(try dimensions.pixelCount());

    try encode_options.limits.validateCanvas(dimensions.width, dimensions.height, false);
    const argb = try gpa.alloc(vp8l_pixel.Pixel, pixel_count);
    defer gpa.free(argb);
    gatherArgb(buffer, argb);

    const bitstream = try vp8l_encoder.encodeAlloc(gpa, dimensions, argb);
    defer gpa.free(bitstream);

    return mux.encodeStatic(gpa, .{
        .canvas = dimensions,
        .format = .lossless,
        .bitstream = bitstream,
    }, .{ .limits = encode_options.limits });
}

/// Encodes a caller-supplied pixel buffer into a complete lossy (VP8) WebP file
/// with the step 8a baseline encoder: a fixed all-DC mode decision, no loop
/// filter, and default coefficient probabilities. The buffer's `format` may be
/// any supported layout. Color always goes through the VP8 lossy path; when the
/// input carries a meaningful (non-fully-opaque) alpha channel, the alpha plane
/// is encoded losslessly into an `ALPH` chunk and the file is emitted as a
/// `VP8X` + `ALPH` + `VP8 ` container (step 8c). A fully-opaque input still
/// emits a plain `VP8 ` file, byte-identical to the alpha-free path. Lossy WebP
/// carries straight (non-premultiplied) alpha, so the color bytes are unchanged
/// by the alpha channel.
///
/// The color quantizer is selected by exactly one of three knobs:
/// - Neither `target_size` nor `target_psnr` set: `quality` (0..100) maps
///   directly to the quantizer index, a single encode pass (step 8a/8b path).
/// - `target_size` set: the encoder binary-searches the quantizer index for the
///   output whose final muxed size lands within tolerance of the request.
/// - `target_psnr` set: the encoder binary-searches for the coarsest quantizer
///   whose reconstructed BT.601 luma PSNR still meets the requested dB.
///
/// `target_size` and `target_psnr` are mutually exclusive; supplying both is
/// rejected with `error.InvalidEncodeOptions`. Both search modes re-encode the
/// color frame each pass (bounded to a small probe count) and hold `method` and
/// every other option fixed; only the color quantizer index moves. The alpha
/// plane is independent of the color quantizer, so it is encoded once and reused
/// (byte-for-byte) across every probe.
///
/// `encode_options.alpha_quality` (0..100) selects the alpha compression effort
/// (0 = uncompressed ALPH, 1..100 = lossless VP8L, smaller kept). Alpha is
/// always lossless. `encode_options.format` must be `.lossy`. The returned bytes
/// are caller-owned (free with `gpa`).
pub fn encodeStaticLossy(
    gpa: std.mem.Allocator,
    buffer: image.Buffer,
    encode_options: options.EncoderOptions,
) errors.Error![]u8 {
    if (encode_options.format != .lossy) return error.UnsupportedImageFormat;
    if (encode_options.target_size != null and encode_options.target_psnr != null) {
        return error.InvalidEncodeOptions;
    }
    try buffer.validate();

    const dimensions = buffer.dimensions;
    if (dimensions.width > vp8_encoder.dimension_max or
        dimensions.height > vp8_encoder.dimension_max)
    {
        return error.InvalidCanvasSize;
    }
    try encode_options.limits.validateCanvas(dimensions.width, dimensions.height, false);
    const pixel_count_u64 = try dimensions.pixelCount();
    try validateLossyInitialAllocationBudget(
        dimensions,
        pixel_count_u64,
        encode_options.limits,
    );
    const pixel_count: usize = @intCast(pixel_count_u64);

    const argb = try gpa.alloc(vp8l_pixel.Pixel, pixel_count);
    defer gpa.free(argb);
    gatherArgb(buffer, argb);

    // Extract the straight (non-premultiplied) alpha plane. A fully-opaque
    // plane is left as no ALPH chunk so the output matches the color-only path
    // byte-for-byte.
    const alpha_plane = try gpa.alloc(u8, pixel_count);
    defer gpa.free(alpha_plane);
    for (argb, alpha_plane) |value, *sample| sample.* = vp8l_pixel.alpha(value);
    const has_alpha = alpha.planeHasTransparency(alpha_plane);

    var source = if (encode_options.use_sharp_yuv)
        try color.rgbaToYuv420SharpAlloc(gpa, argb, dimensions.width, dimensions.height)
    else
        try color.rgbaToYuv420Alloc(gpa, argb, dimensions.width, dimensions.height);
    defer source.deinit(gpa);

    // Encode the alpha plane into an ALPH payload only when it carries
    // transparency; the VP8L alpha encoder's scratch is bounded by the same
    // per-pixel budget as the color path. Alpha is independent of the color
    // quantizer, so it is encoded exactly once here and reused (borrowed) across
    // every probe of the target-size/PSNR searches as well as the single-pass
    // default. This function owns `alpha_payload`; the pass/search helpers must
    // not free it.
    var alpha_payload: ?[]u8 = null;
    defer if (alpha_payload) |payload| gpa.free(payload);
    if (has_alpha) {
        try validateAlphaAllocationBudget(dimensions, pixel_count_u64, encode_options.limits);
        alpha_payload = try alpha.encodePlaneAlloc(
            gpa,
            alpha_plane,
            dimensions,
            encode_options.alpha_quality,
        );
    }

    if (encode_options.target_size) |target_size| {
        return searchTargetSizeLossy(
            gpa,
            &source,
            encode_options,
            pixel_count_u64,
            target_size,
            alpha_payload,
            has_alpha,
        );
    }
    if (encode_options.target_psnr) |target_psnr| {
        return searchTargetPsnrLossy(
            gpa,
            &source,
            argb,
            encode_options,
            pixel_count_u64,
            target_psnr,
            alpha_payload,
            has_alpha,
        );
    }

    // Default path: the plain quality knob, a single encode pass. This branch
    // must stay byte-identical to the pre-8c-3 encoder (asserted by test).
    const base_quant_index = vp8_quant.baseQuantIndexForQuality(encode_options.quality);
    var pass = try encodeLossyPass(
        gpa,
        &source,
        encode_options,
        pixel_count_u64,
        base_quant_index,
        0,
        null,
        alpha_payload,
        has_alpha,
    );
    defer pass.deinit(gpa);
    return pass.takeFile();
}

/// One muxed lossy encode at a fixed quantizer index, plus the realized
/// reconstruction luma PSNR. The target-size/PSNR searches produce one of these
/// per probe, comparing `file.len` or `luma_psnr` against the request and
/// freeing the loser before the next probe so only the best candidate survives.
const LossyPass = struct {
    /// The complete muxed WebP file; null once `takeFile` has handed it off.
    file: ?[]u8,
    /// BT.601 luma PSNR of the encoder reconstruction vs the source (dB), `inf`
    /// for a bit-exact luma plane.
    luma_psnr: f64,
    /// The quantizer index this pass encoded at (0 finest .. 127 coarsest).
    base_quant_index: u8,

    fn size(self: *const LossyPass) usize {
        return (self.file orelse unreachable).len;
    }

    /// Transfers ownership of the muxed file to the caller; `deinit` is then a
    /// no-op for the bytes. The caller frees the returned slice with `gpa`.
    fn takeFile(self: *LossyPass) []u8 {
        const file = self.file orelse unreachable;
        self.file = null;
        return file;
    }

    fn deinit(self: *LossyPass, gpa: std.mem.Allocator) void {
        if (self.file) |file| gpa.free(file);
        self.* = undefined;
    }
};

/// Bound on the quantizer-search probe count. The index range is 0..127, so a
/// binary search converges in ceil(log2(128)) = 7 probes; the extra one absorbs
/// the inclusive-bracket bookkeeping. Keeps the loop fixed-bound (AGENTS.md).
const search_passes_max = 8;

/// Encodes `source` once at `base_quant_index`, validating the mux allocation
/// budget exactly as the single-pass default path does, and muxes the result.
/// `method` and the resource limits ride along from `encode_options`; the
/// quantizer index is the only moving part.
///
/// `alpha_payload` (when `has_alpha`) is the ALPH chunk `encodeStaticLossy`
/// encoded once and owns; this pass muxes it in but never frees it. Because the
/// payload stays live across every probe's mux peak, its length is charged
/// against the mux allocation budget alongside `extra_reserved_bytes`.
///
/// When `source_rgb` is non-null (the target-PSNR search), the pass also
/// upsamples its reconstruction back to RGB and computes the full-range BT.601
/// luma PSNR against `source_rgb` — the same metric `metrics.psnrLuma` and
/// `cwebp` report, so the requested dB is honest. `source_rgb` is the tightly
/// packed `width*height*3` RGB of the source; the size search passes null and
/// `luma_psnr` stays `inf` (unused).
fn encodeLossyPass(
    gpa: std.mem.Allocator,
    source: *const color.YuvPlanes,
    encode_options: options.EncoderOptions,
    pixel_count: u64,
    base_quant_index: u8,
    extra_reserved_bytes: u64,
    source_rgb: ?[]const u8,
    alpha_payload: ?[]const u8,
    has_alpha: bool,
) errors.Error!LossyPass {
    assert(base_quant_index <= vp8_quant.index_max);
    const dimensions = image.Dimensions{ .width = source.width, .height = source.height };

    var result = try vp8_encoder.encodeAlloc(gpa, source, .{
        .base_quant_index = base_quant_index,
        .method = encode_options.method,
    });
    defer result.deinit(gpa);

    // The reconstruction-RGB scratch the PSNR measurement allocates is live
    // alongside the mux peak, so reserve it too when this pass measures PSNR.
    // The borrowed alpha payload is also live across the mux, so charge it.
    const psnr_scratch_bytes: u64 = if (source_rgb != null) pixel_count * 3 else 0;
    const alpha_bytes: u64 = if (alpha_payload) |payload| payload.len else 0;
    try validateLossyMuxAllocationBudget(
        dimensions,
        pixel_count,
        result.bitstream.len,
        encode_options.limits,
        try addByteCounts(extra_reserved_bytes, try addByteCounts(psnr_scratch_bytes, alpha_bytes)),
    );

    const luma_psnr = if (source_rgb) |rgb|
        try reconstructionLumaPsnr(gpa, &result.reconstruction, rgb)
    else
        std.math.inf(f64);

    const file = try mux.encodeStatic(gpa, .{
        .canvas = dimensions,
        .format = .lossy,
        .bitstream = result.bitstream,
        .alpha = alpha_payload,
        .has_alpha = has_alpha,
    }, .{ .limits = encode_options.limits });

    return .{ .file = file, .luma_psnr = luma_psnr, .base_quant_index = base_quant_index };
}

/// Full-range BT.601 luma PSNR (dB) of `reconstruction` against `source_rgb`,
/// the metric `cwebp` and `metrics.psnrLuma` report. Upsamples the
/// reconstruction back to RGB (libwebp's fancy chroma filter, matching the
/// decode path) into a scratch buffer, then compares luma. `source_rgb` is the
/// tightly packed `width*height*3` source RGB. Caller has reserved the scratch
/// against the allocation budget.
fn reconstructionLumaPsnr(
    gpa: std.mem.Allocator,
    reconstruction: *const color.YuvPlanes,
    source_rgb: []const u8,
) errors.Error!f64 {
    const width: usize = reconstruction.width;
    const height: usize = reconstruction.height;
    const pixel_count: usize = width * height;
    assert(source_rgb.len == pixel_count * 3);

    const recon_rgb = try gpa.alloc(u8, pixel_count * 3);
    defer gpa.free(recon_rgb);
    color.upsampleFancy(.rgb, reconstruction.view(), recon_rgb, width * 3);

    return metrics.psnrLuma(source_rgb, recon_rgb, 3);
}

/// Allocates the tightly packed `width*height*3` RGB of `argb` for the
/// target-PSNR search to measure against. Caller frees with `gpa`.
fn sourceRgbAlloc(gpa: std.mem.Allocator, argb: []const vp8l_pixel.Pixel) errors.Error![]u8 {
    const rgb = try gpa.alloc(u8, argb.len * 3);
    errdefer gpa.free(rgb);
    for (argb, 0..) |pixel, i| {
        rgb[i * 3 + 0] = vp8l_pixel.red(pixel);
        rgb[i * 3 + 1] = vp8l_pixel.green(pixel);
        rgb[i * 3 + 2] = vp8l_pixel.blue(pixel);
    }
    return rgb;
}

/// Binary-searches the quantizer index for the output whose final muxed size
/// lands closest to `target_size` bytes, returning that file (caller-owned).
///
/// Size is effectively monotone in the quantizer index: a coarser index (higher)
/// quantizes more coefficients to zero, so the file shrinks. The search exploits
/// that — when the current size exceeds the target the next probe goes coarser,
/// and when it falls short the next probe goes finer — while still tracking the
/// best (closest-to-target) candidate across every probe, so minor
/// non-monotonicity from segmentation or skip coding never traps it on a worse
/// result. Bounded to `search_passes_max` probes.
///
/// `alpha_payload`/`has_alpha` are the ALPH chunk `encodeStaticLossy` owns; they
/// are forwarded (borrowed) into every probe's mux and never freed here.
fn searchTargetSizeLossy(
    gpa: std.mem.Allocator,
    source: *const color.YuvPlanes,
    encode_options: options.EncoderOptions,
    pixel_count: u64,
    target_size: u32,
    alpha_payload: ?[]const u8,
    has_alpha: bool,
) errors.Error![]u8 {
    var low: u8 = 0; // finest quantizer -> largest file
    var high: u8 = vp8_quant.index_max; // coarsest quantizer -> smallest file

    var best: ?LossyPass = null;
    errdefer if (best) |*pass| pass.deinit(gpa);

    var probe: usize = 0;
    while (probe < search_passes_max) : (probe += 1) {
        const mid: u8 = @intCast((@as(u16, low) + high) / 2);
        // The best candidate from the previous probe stays live while this one
        // encodes and muxes; reserve it against the budget.
        const carried: u64 = if (best) |*pass| pass.size() else 0;
        var pass = try encodeLossyPass(
            gpa,
            source,
            encode_options,
            pixel_count,
            mid,
            carried,
            null,
            alpha_payload,
            has_alpha,
        );
        // Capture this probe's size before the bookkeeping below may free it;
        // the bisection direction is driven by this index's result, not by the
        // best-so-far (which may sit at a different index).
        const pass_size = pass.size();

        // Keep the probe with the smallest absolute distance to the target.
        if (best) |*current_best| {
            if (sizeDistance(pass_size, target_size) < sizeDistance(current_best.size(), target_size)) {
                current_best.deinit(gpa);
                best = pass;
            } else {
                pass.deinit(gpa);
            }
        } else {
            best = pass;
        }

        if (pass_size > target_size) {
            // Too big: go coarser (raise the index) on the next probe.
            if (mid == high) break;
            low = mid + 1;
        } else if (pass_size < target_size) {
            // Too small: go finer (lower the index) on the next probe.
            if (mid == low) break;
            high = mid - 1;
        } else {
            break; // Exact hit.
        }
        if (low > high) break;
    }

    return (best orelse unreachable).takeFile();
}

/// Binary-searches the quantizer index for the coarsest output (smallest file)
/// whose reconstructed BT.601 luma PSNR still meets `target_psnr` dB, returning
/// that file (caller-owned).
///
/// PSNR is monotone-decreasing in the quantizer index (a coarser index loses
/// more detail), so the search drives toward the largest index that still
/// satisfies the target — meeting the request with the fewest bits. The best
/// candidate tracked is the meeting-target probe with the highest index; if no
/// probe meets the target the highest-PSNR probe (finest index reached) is
/// returned, so the result brackets the request within the quantizer
/// granularity. Bounded to `search_passes_max` probes.
///
/// `alpha_payload`/`has_alpha` are the ALPH chunk `encodeStaticLossy` owns; they
/// are forwarded (borrowed) into every probe's mux and never freed here.
fn searchTargetPsnrLossy(
    gpa: std.mem.Allocator,
    source: *const color.YuvPlanes,
    argb: []const vp8l_pixel.Pixel,
    encode_options: options.EncoderOptions,
    pixel_count: u64,
    target_psnr: f32,
    alpha_payload: ?[]const u8,
    has_alpha: bool,
) errors.Error![]u8 {
    var low: u8 = 0; // finest quantizer -> highest PSNR
    var high: u8 = vp8_quant.index_max; // coarsest quantizer -> lowest PSNR
    const target: f64 = target_psnr;

    // The source RGB the per-pass luma PSNR measures the reconstruction against;
    // allocated once and live for the whole search.
    const source_rgb = try sourceRgbAlloc(gpa, argb);
    defer gpa.free(source_rgb);
    const source_rgb_bytes: u64 = source_rgb.len;

    // The best candidate that meets the target (prefer the coarsest such index),
    // and a fallback holding the highest-PSNR probe in case none ever meets it.
    var meeting: ?LossyPass = null;
    errdefer if (meeting) |*pass| pass.deinit(gpa);
    var fallback: ?LossyPass = null;
    errdefer if (fallback) |*pass| pass.deinit(gpa);

    var probe: usize = 0;
    while (probe < search_passes_max) : (probe += 1) {
        const mid: u8 = @intCast((@as(u16, low) + high) / 2);
        // The persistent source RGB plus the meeting-target and fallback
        // candidates from earlier probes can all stay live while this one
        // encodes and muxes; reserve them.
        var carried: u64 = source_rgb_bytes;
        if (meeting) |*pass| carried += pass.size();
        if (fallback) |*pass| carried += pass.size();
        var pass = try encodeLossyPass(
            gpa,
            source,
            encode_options,
            pixel_count,
            mid,
            carried,
            source_rgb,
            alpha_payload,
            has_alpha,
        );

        if (pass.luma_psnr >= target) {
            // Meets the target: keep the coarsest (largest index) such probe,
            // then try coarser still to shave bits.
            if (meeting) |*current| {
                if (pass.base_quant_index >= current.base_quant_index) {
                    current.deinit(gpa);
                    meeting = pass;
                } else {
                    pass.deinit(gpa);
                }
            } else {
                meeting = pass;
            }
            if (mid == high) break;
            low = mid + 1;
        } else {
            // Misses the target: keep the highest-PSNR (smallest index) probe as
            // the fallback, then try finer.
            if (fallback) |*current| {
                if (pass.base_quant_index <= current.base_quant_index) {
                    current.deinit(gpa);
                    fallback = pass;
                } else {
                    pass.deinit(gpa);
                }
            } else {
                fallback = pass;
            }
            if (mid == low) break;
            high = mid - 1;
        }
        if (low > high) break;
    }

    if (meeting) |*pass| {
        if (fallback) |*unused| unused.deinit(gpa);
        return pass.takeFile();
    }
    return (fallback orelse unreachable).takeFile();
}

fn sizeDistance(actual: usize, target: u32) u64 {
    const a: u64 = actual;
    const t: u64 = target;
    return if (a > t) a - t else t - a;
}

/// Encodes a packed-ARGB pixel array (`0xAARRGGBB`, row-major, length
/// `width*height`) into a raw VP8 bitstream — the payload of a `VP8 ` chunk,
/// without the RIFF container. `quality` is 0..100. Most callers want
/// `encodeStaticLossy`; this is for tooling that muxes the bitstream itself.
/// Returns caller-owned bytes (free with `gpa`).
pub fn encodeVP8Bitstream(
    gpa: std.mem.Allocator,
    dimensions: image.Dimensions,
    pixels: []const vp8l_pixel.Pixel,
    quality: u8,
) errors.Error![]u8 {
    if (dimensions.width > vp8_encoder.dimension_max or
        dimensions.height > vp8_encoder.dimension_max)
    {
        return error.InvalidCanvasSize;
    }
    if (pixels.len != @as(usize, @intCast(try dimensions.pixelCount()))) {
        return error.InvalidCanvasSize;
    }

    var source = try color.rgbaToYuv420Alloc(gpa, pixels, dimensions.width, dimensions.height);
    defer source.deinit(gpa);

    var result = try vp8_encoder.encodeAlloc(gpa, &source, .{
        .base_quant_index = vp8_quant.baseQuantIndexForQuality(quality),
    });
    result.reconstruction.deinit(gpa);
    return result.bitstream;
}

const AllocationBudget = struct {
    resource_limits: limits.ResourceLimits,
    bytes: u64 = 0,

    fn init(resource_limits: limits.ResourceLimits) AllocationBudget {
        return .{ .resource_limits = resource_limits };
    }

    fn reserveElements(
        self: *AllocationBudget,
        comptime T: type,
        count: u64,
    ) errors.Error!void {
        try self.reserveBytes(try elementByteCount(T, count));
    }

    fn reserveBytes(self: *AllocationBudget, bytes: u64) errors.Error!void {
        if (bytes > std.math.maxInt(u64) - self.bytes) return error.AllocationLimitExceeded;
        self.bytes += bytes;
        try self.resource_limits.validateAllocationBytes(self.bytes);
    }
};

fn validateLossyInitialAllocationBudget(
    dimensions: image.Dimensions,
    pixel_count: u64,
    resource_limits: limits.ResourceLimits,
) errors.Error!void {
    var budget = AllocationBudget.init(resource_limits);
    try budget.reserveElements(vp8l_pixel.Pixel, pixel_count);
    try budget.reserveBytes(try color.yuv420AllocationBytes(dimensions.width, dimensions.height));
    try budget.reserveBytes(try vp8_encoder.allocationBytesMax(dimensions));
}

/// Reserves the alpha-encode scratch against the allocation limits: the
/// extracted plane and its forward-filtered copy (one byte per pixel each), the
/// VP8L source pixels (4 bytes per pixel), and the VP8L encoder's worst-case
/// output buffer. This runs only when the input actually carries transparency.
fn validateAlphaAllocationBudget(
    dimensions: image.Dimensions,
    pixel_count: u64,
    resource_limits: limits.ResourceLimits,
) errors.Error!void {
    var budget = AllocationBudget.init(resource_limits);
    try budget.reserveElements(u8, pixel_count); // extracted alpha plane
    try budget.reserveElements(u8, pixel_count); // forward-filtered plane
    try budget.reserveElements(vp8l_pixel.Pixel, pixel_count); // VP8L source
    try budget.reserveBytes(@intCast(try vp8l_encoder.maxEncodedSize(dimensions)));
}

fn validateLossyMuxAllocationBudget(
    dimensions: image.Dimensions,
    pixel_count: u64,
    bitstream_len: usize,
    resource_limits: limits.ResourceLimits,
    /// Bytes already live across this pass that the single-pass peak does not
    /// cover. During a target-size/PSNR search the best candidate file from the
    /// previous probe, the PSNR scratch, and the borrowed alpha payload stay
    /// allocated while the next probe encodes and muxes, so the search passes
    /// their combined length here; the single-pass path passes the alpha
    /// payload length (0 when fully opaque).
    extra_reserved_bytes: u64,
) errors.Error!void {
    var budget = AllocationBudget.init(resource_limits);
    try budget.reserveBytes(extra_reserved_bytes);
    try budget.reserveElements(vp8l_pixel.Pixel, pixel_count);

    const yuv_bytes = try color.yuv420AllocationBytes(dimensions.width, dimensions.height);
    try budget.reserveBytes(yuv_bytes);
    try budget.reserveBytes(yuv_bytes);
    try budget.reserveBytes(@intCast(bitstream_len));
    try budget.reserveBytes(try simpleLossyWebPFileBytes(bitstream_len));
}

fn simpleLossyWebPFileBytes(bitstream_len: usize) errors.Error!u64 {
    const payload_size: u64 = @intCast(bitstream_len);
    if (payload_size > std.math.maxInt(u32)) return error.ChunkTooLarge;

    var bytes = @as(u64, container.riff_header_size + container.chunk_header_size);
    bytes = try addByteCounts(bytes, payload_size);
    bytes = try addByteCounts(bytes, payload_size & 1);
    return bytes;
}

fn elementByteCount(comptime T: type, count: u64) errors.Error!u64 {
    if (count > std.math.maxInt(u64) / @sizeOf(T)) return error.AllocationLimitExceeded;
    return count * @sizeOf(T);
}

fn addByteCounts(a: u64, b: u64) errors.Error!u64 {
    return std.math.add(u64, a, b) catch error.AllocationLimitExceeded;
}

/// Reads the caller buffer's pixels (any supported format, honoring stride)
/// into packed ARGB `vp8l_pixel.Pixel` values in row-major order.
fn gatherArgb(buffer: image.Buffer, argb: []vp8l_pixel.Pixel) void {
    const width: usize = buffer.dimensions.width;
    const height: usize = buffer.dimensions.height;
    const stride: usize = buffer.stride;
    const channels: usize = @intCast(buffer.format.channelCount());
    assert(argb.len == width * height);

    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = buffer.pixels[y * stride ..][0 .. width * channels];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const sample = row[x * channels ..][0..channels];
            argb[y * width + x] = pixelFromSample(buffer.format, sample);
        }
    }
}

fn pixelFromSample(format: image.PixelFormat, sample: []const u8) vp8l_pixel.Pixel {
    return switch (format) {
        .rgb => vp8l_pixel.fromChannels(255, sample[0], sample[1], sample[2]),
        .rgba => vp8l_pixel.fromChannels(sample[3], sample[0], sample[1], sample[2]),
        .bgra => vp8l_pixel.fromChannels(sample[3], sample[2], sample[1], sample[0]),
        .argb => vp8l_pixel.fromChannels(sample[0], sample[1], sample[2], sample[3]),
    };
}

/// Allocates a row-major packed-ARGB copy of `buffer` (any supported format,
/// honoring stride) — the input the YUV converter and the VP8/VP8L encoders
/// take. Caller owns the result (free with `gpa`).
pub fn gatherArgbAlloc(
    gpa: std.mem.Allocator,
    buffer: image.Buffer,
) std.mem.Allocator.Error![]vp8l_pixel.Pixel {
    const pixel_count: usize = @as(usize, buffer.dimensions.width) * buffer.dimensions.height;
    const argb = try gpa.alloc(vp8l_pixel.Pixel, pixel_count);
    errdefer gpa.free(argb);
    gatherArgb(buffer, argb);
    return argb;
}

const testing = std.testing;

test "encodeStaticLossless round-trips RGBA through the decoder" {
    const decode = @import("decode.zig");

    const width = 5;
    const height = 4;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const base = (y * width + x) * 4;
            pixels[base + 0] = @intCast((x * 50) % 256);
            pixels[base + 1] = @intCast((y * 60) % 256);
            pixels[base + 2] = @intCast((x + y) * 10);
            pixels[base + 3] = @intCast(200 + x);
        }
    }

    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    const encoded = try encodeStaticLossless(testing.allocator, buffer, .{});
    defer testing.allocator.free(encoded);

    var decoded = try decode.decodeStatic(testing.allocator, encoded, .{ .output_format = .rgba });
    defer decoded.deinit();

    try testing.expectEqual(dims.width, decoded.buffer.dimensions.width);
    try testing.expectEqual(dims.height, decoded.buffer.dimensions.height);
    try testing.expectEqualSlices(u8, &pixels, decoded.buffer.pixels);
}

test "encodeStaticLossless honors stride and bgra input" {
    const decode = @import("decode.zig");

    const width = 3;
    const height = 2;
    const stride = width * 4 + 5; // padded rows
    const dims = try image.Dimensions.init(width, height);
    var pixels: [stride * height]u8 = undefined;
    @memset(&pixels, 0);
    for (0..height) |y| {
        for (0..width) |x| {
            const base = y * stride + x * 4;
            pixels[base + 0] = @intCast(10 + x); // B
            pixels[base + 1] = @intCast(20 + y); // G
            pixels[base + 2] = @intCast(30 + x + y); // R
            pixels[base + 3] = @intCast(100 + x); // A
        }
    }

    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = stride,
        .format = .bgra,
    };

    const encoded = try encodeStaticLossless(testing.allocator, buffer, .{});
    defer testing.allocator.free(encoded);

    var decoded = try decode.decodeStatic(testing.allocator, encoded, .{ .output_format = .bgra });
    defer decoded.deinit();

    // Compare per-pixel (decoded output is tightly packed; source has padding).
    for (0..height) |y| {
        for (0..width) |x| {
            const src = pixels[y * stride + x * 4 ..][0..4];
            const out = decoded.buffer.pixels[(y * width + x) * 4 ..][0..4];
            try testing.expectEqualSlices(u8, src, out);
        }
    }
}

test "encodeStaticLossless rejects lossy format requests" {
    const dims = try image.Dimensions.init(1, 1);
    var pixels = [_]u8{ 1, 2, 3, 4 };
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = 4,
        .format = .rgba,
    };
    try testing.expectError(
        error.UnsupportedImageFormat,
        encodeStaticLossless(testing.allocator, buffer, .{ .format = .lossy }),
    );
}

fn encodeAllocationProbe(gpa: std.mem.Allocator, buffer: image.Buffer) !void {
    const encoded = try encodeStaticLossless(gpa, buffer, .{});
    gpa.free(encoded);
}

test "lossless static encode survives allocation failure at every site" {
    const width = 4;
    const height = 3;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height * 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i % 256);

    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    try testing.checkAllAllocationFailures(testing.allocator, encodeAllocationProbe, .{buffer});
}

test "encodeStaticLossy produces a decodable VP8 WebP at the source size" {
    const decode = @import("decode.zig");

    const width = 18;
    const height = 10;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const base = (y * width + x) * 4;
            pixels[base + 0] = @intCast((x * 14) % 256);
            pixels[base + 1] = @intCast((y * 25) % 256);
            pixels[base + 2] = @intCast(((x + y) * 8) % 256);
            pixels[base + 3] = 255;
        }
    }

    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    const encoded = try encodeStaticLossy(testing.allocator, buffer, .{ .format = .lossy });
    defer testing.allocator.free(encoded);

    // It must decode without error at the right size (lossy, so not bit-exact;
    // fidelity is covered by the encoder self-consistency and corpus PSNR tests).
    var decoded = try decode.decodeStatic(testing.allocator, encoded, .{ .output_format = .rgba });
    defer decoded.deinit();
    try testing.expectEqual(dims.width, decoded.buffer.dimensions.width);
    try testing.expectEqual(dims.height, decoded.buffer.dimensions.height);
}

test "encodeStaticLossy rejects non-lossy format requests" {
    const dims = try image.Dimensions.init(1, 1);
    var pixels = [_]u8{ 1, 2, 3, 4 };
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = 4,
        .format = .rgba,
    };
    try testing.expectError(
        error.UnsupportedImageFormat,
        encodeStaticLossy(testing.allocator, buffer, .{ .format = .lossless }),
    );
}

test "encodeStaticLossy counts VP8 scratch against allocation limits" {
    const width = 32;
    const height = 32;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height * 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i % 256);

    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    var pre_vp8_budget = AllocationBudget.init(.{
        .allocation_bytes_max = std.math.maxInt(u64),
    });
    const pixel_count = try dims.pixelCount();
    try pre_vp8_budget.reserveElements(vp8l_pixel.Pixel, pixel_count);
    try pre_vp8_budget.reserveBytes(try color.yuv420AllocationBytes(width, height));

    try testing.expectError(
        error.AllocationLimitExceeded,
        encodeStaticLossy(testing.allocator, buffer, .{
            .format = .lossy,
            .limits = .{ .allocation_bytes_max = pre_vp8_budget.bytes + 1 },
        }),
    );
}

fn encodeLossyAllocationProbe(gpa: std.mem.Allocator, buffer: image.Buffer) !void {
    const encoded = try encodeStaticLossy(gpa, buffer, .{ .format = .lossy });
    gpa.free(encoded);
}

test "lossy static encode survives allocation failure at every site" {
    const width = 17; // partial macroblock exercises the padding path too
    const height = 9;
    const dims = try image.Dimensions.init(width, height);
    var pixels: [width * height * 4]u8 = undefined;
    // `i % 256` cycles the alpha byte too, so some pixels are transparent: this
    // exercises the alpha-encode allocations under failure, not just color.
    for (&pixels, 0..) |*p, i| p.* = @intCast(i % 256);

    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    try testing.checkAllAllocationFailures(testing.allocator, encodeLossyAllocationProbe, .{buffer});
}

const synth = @import("testing/synth.zig");
const demux = @import("demux.zig");

test "encodeStaticLossy recovers the alpha plane exactly for alpha sources" {
    const decode = @import("decode.zig");

    // The synth set's RGBA alpha cases: a smooth ramp, a hard binary checker,
    // and a fully-transparent plane over non-zero RGB. Lossy alpha must be
    // lossless, so the recovered alpha must match byte-for-byte regardless of
    // the (lossy) color tolerance.
    for (synth.sources) |source| {
        if (source.format != .rgba) continue;
        switch (source.content) {
            .alpha_gradient, .alpha_checker, .alpha_transparent_rgb => {},
            else => continue,
        }

        const rendered = try synth.render(testing.allocator, source);
        defer rendered.deinit();

        const encoded = try encodeStaticLossy(
            testing.allocator,
            rendered.buffer,
            .{ .format = .lossy },
        );
        defer testing.allocator.free(encoded);

        // The container must advertise alpha (VP8X + ALPH + VP8 ).
        var parsed = try demux.parse(testing.allocator, encoded, .{});
        defer parsed.deinit();
        try testing.expect(parsed.features.has_alpha);
        try testing.expect(parsed.features.alpha != null);

        var decoded = try decode.decodeStatic(
            testing.allocator,
            encoded,
            .{ .output_format = .rgba },
        );
        defer decoded.deinit();

        const width: usize = source.width;
        const height: usize = source.height;
        try testing.expectEqual(@as(u32, @intCast(width)), decoded.buffer.dimensions.width);
        try testing.expectEqual(@as(u32, @intCast(height)), decoded.buffer.dimensions.height);

        // Compare the alpha channel only (channel 3); color is lossy.
        const out_stride: usize = decoded.buffer.stride;
        for (0..height) |y| {
            for (0..width) |x| {
                const src_alpha = rendered.pixels[(y * width + x) * 4 + 3];
                const out_alpha = decoded.buffer.pixels[y * out_stride + x * 4 + 3];
                try testing.expectEqual(src_alpha, out_alpha);
            }
        }
    }
}

test "encodeStaticLossy alpha round-trips under the uncompressed ALPH form" {
    const decode = @import("decode.zig");

    const source = synth.Source{
        .name = "alpha_checker_33x33_rgba",
        .width = 33,
        .height = 33,
        .format = .rgba,
        .content = .alpha_checker,
    };
    const rendered = try synth.render(testing.allocator, source);
    defer rendered.deinit();

    // alpha_quality == 0 forces the uncompressed ALPH form; it must still
    // recover the plane exactly.
    const encoded = try encodeStaticLossy(
        testing.allocator,
        rendered.buffer,
        .{ .format = .lossy, .alpha_quality = 0 },
    );
    defer testing.allocator.free(encoded);

    var parsed = try demux.parse(testing.allocator, encoded, .{});
    defer parsed.deinit();
    const alpha_chunk = parsed.features.alpha orelse return error.TestUnexpectedResult;
    // Uncompressed header: compression bits (0..1) are 0.
    try testing.expectEqual(@as(u8, 0), alpha_chunk.payload(encoded)[0] & 0x03);

    var decoded = try decode.decodeStatic(
        testing.allocator,
        encoded,
        .{ .output_format = .rgba },
    );
    defer decoded.deinit();

    const out_stride: usize = decoded.buffer.stride;
    for (0..source.height) |y| {
        for (0..source.width) |x| {
            const src_alpha = rendered.pixels[(y * source.width + x) * 4 + 3];
            const out_alpha = decoded.buffer.pixels[y * out_stride + x * 4 + 3];
            try testing.expectEqual(src_alpha, out_alpha);
        }
    }
}

test "encodeStaticLossy keeps fully-opaque output byte-identical to the color-only path" {
    const width = 18;
    const height = 10;
    const dims = try image.Dimensions.init(width, height);

    // Build the same image as RGB and as fully-opaque RGBA. The RGBA path must
    // detect the opaque plane, skip the ALPH chunk, and produce identical bytes.
    var rgb_pixels: [width * height * 3]u8 = undefined;
    var rgba_pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const r: u8 = @intCast((x * 14) % 256);
            const g: u8 = @intCast((y * 25) % 256);
            const b: u8 = @intCast(((x + y) * 8) % 256);
            const rgb_base = (y * width + x) * 3;
            rgb_pixels[rgb_base + 0] = r;
            rgb_pixels[rgb_base + 1] = g;
            rgb_pixels[rgb_base + 2] = b;
            const rgba_base = (y * width + x) * 4;
            rgba_pixels[rgba_base + 0] = r;
            rgba_pixels[rgba_base + 1] = g;
            rgba_pixels[rgba_base + 2] = b;
            rgba_pixels[rgba_base + 3] = 255;
        }
    }

    const rgb_buffer = image.Buffer{
        .pixels = &rgb_pixels,
        .dimensions = dims,
        .stride = width * 3,
        .format = .rgb,
    };
    const rgba_buffer = image.Buffer{
        .pixels = &rgba_pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    const from_rgb = try encodeStaticLossy(testing.allocator, rgb_buffer, .{ .format = .lossy });
    defer testing.allocator.free(from_rgb);
    const from_rgba = try encodeStaticLossy(testing.allocator, rgba_buffer, .{ .format = .lossy });
    defer testing.allocator.free(from_rgba);

    try testing.expectEqualSlices(u8, from_rgb, from_rgba);

    // And it is a plain simple `VP8 ` file (no VP8X / ALPH).
    var parsed = try demux.parse(testing.allocator, from_rgba, .{});
    defer parsed.deinit();
    try testing.expect(!parsed.features.has_alpha);
    try testing.expectEqual(features.FileKind.simple, parsed.features.file_kind);
}

// --- Target-size and target-PSNR encode modes (step 8c-3) ------------------

/// Renders a detail-rich RGBA test image: a smooth diagonal color gradient with
/// a deterministic high-frequency ripple layered on, so the file size and luma
/// PSNR both span a wide, monotone range across the quantizer. Caller frees with
/// `gpa`.
fn renderTargetModeSource(gpa: std.mem.Allocator, width: u32, height: u32) ![]u8 {
    const pixels = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(pixels);
    for (0..height) |y| {
        for (0..width) |x| {
            const base = (y * width + x) * 4;
            const ripple: i32 = @intCast((x *% 37 +% y *% 53) & 0x3f);
            const r: i32 = @as(i32, @intCast((x * 255) / width)) + ripple - 32;
            const g: i32 = @as(i32, @intCast((y * 255) / height)) + ripple - 32;
            const b: i32 = @as(i32, @intCast(((x + y) * 255) / (width + height))) - ripple + 32;
            pixels[base + 0] = @intCast(std.math.clamp(r, 0, 255));
            pixels[base + 1] = @intCast(std.math.clamp(g, 0, 255));
            pixels[base + 2] = @intCast(std.math.clamp(b, 0, 255));
            pixels[base + 3] = 255;
        }
    }
    return pixels;
}

test "encodeStaticLossy rejects target_size and target_psnr set together" {
    const dims = try image.Dimensions.init(2, 2);
    var pixels = [_]u8{0} ** (2 * 2 * 4);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = dims,
        .stride = 2 * 4,
        .format = .rgba,
    };
    try testing.expectError(error.InvalidEncodeOptions, encodeStaticLossy(testing.allocator, buffer, .{
        .format = .lossy,
        .target_size = 1000,
        .target_psnr = 35.0,
    }));
}

test "encodeStaticLossy default path is byte-identical with target modes inert" {
    const width = 40;
    const height = 24;
    const dims = try image.Dimensions.init(width, height);
    const pixels = try renderTargetModeSource(testing.allocator, width, height);
    defer testing.allocator.free(pixels);
    const buffer = image.Buffer{
        .pixels = pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    // The single-pass quality knob (target_* both null) must match exactly what
    // the pre-8c-3 encoder produced — i.e. one encodeAlloc + mux at the quality
    // quantizer, no search. The source is fully opaque, so there is no ALPH
    // chunk and the reference path muxes color only.
    inline for (.{ 0, 25, 50, 75, 100 }) |quality| {
        const with_default = try encodeStaticLossy(testing.allocator, buffer, .{
            .format = .lossy,
            .quality = quality,
        });
        defer testing.allocator.free(with_default);

        const base_quant_index = vp8_quant.baseQuantIndexForQuality(quality);
        const argb = try gatherArgbAlloc(testing.allocator, buffer);
        defer testing.allocator.free(argb);
        var source = try color.rgbaToYuv420Alloc(testing.allocator, argb, width, height);
        defer source.deinit(testing.allocator);
        var result = try vp8_encoder.encodeAlloc(testing.allocator, &source, .{
            .base_quant_index = base_quant_index,
            .method = (options.EncoderOptions{}).method,
        });
        defer result.deinit(testing.allocator);
        const reference = try mux.encodeStatic(testing.allocator, .{
            .canvas = dims,
            .format = .lossy,
            .bitstream = result.bitstream,
        }, .{});
        defer testing.allocator.free(reference);

        try testing.expectEqualSlices(u8, reference, with_default);
    }
}

test "encodeStaticLossy target-size lands within 5 percent" {
    const width = 96;
    const height = 96;
    const dims = try image.Dimensions.init(width, height);
    const pixels = try renderTargetModeSource(testing.allocator, width, height);
    defer testing.allocator.free(pixels);
    const buffer = image.Buffer{
        .pixels = pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    // Measure the achievable size envelope (finest vs coarsest quantizer), then
    // request a few interior targets the search must reach within tolerance.
    const finest = try encodeStaticLossy(testing.allocator, buffer, .{ .format = .lossy, .quality = 100 });
    defer testing.allocator.free(finest);
    const coarsest = try encodeStaticLossy(testing.allocator, buffer, .{ .format = .lossy, .quality = 0 });
    defer testing.allocator.free(coarsest);
    try testing.expect(coarsest.len < finest.len);

    const span = finest.len - coarsest.len;
    const targets = [_]u32{
        @intCast(coarsest.len + span / 4),
        @intCast(coarsest.len + span / 2),
        @intCast(coarsest.len + (span * 3) / 4),
    };
    for (targets) |target_size| {
        const encoded = try encodeStaticLossy(testing.allocator, buffer, .{
            .format = .lossy,
            .target_size = target_size,
        });
        defer testing.allocator.free(encoded);

        const achieved: f64 = @floatFromInt(encoded.len);
        const requested: f64 = @floatFromInt(target_size);
        const relative_error = @abs(achieved - requested) / requested;
        if (relative_error > 0.05) {
            std.debug.print(
                "target_size {d}: achieved {d} bytes, relative error {d:.4}\n",
                .{ target_size, encoded.len, relative_error },
            );
            return error.TargetSizeOutOfTolerance;
        }
    }
}

test "encodeStaticLossy target-PSNR meets or brackets the request" {
    const decode = @import("decode.zig");

    const width = 96;
    const height = 96;
    const dims = try image.Dimensions.init(width, height);
    const pixels = try renderTargetModeSource(testing.allocator, width, height);
    defer testing.allocator.free(pixels);
    const buffer = image.Buffer{
        .pixels = pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    // Request a spread of luma PSNRs and confirm the decoded result's full-range
    // BT.601 luma PSNR (what a consumer sees) meets each — the same metric the
    // search drives. A small dB slack absorbs the difference between the search
    // measuring its own reconstruction and this end-to-end decode.
    const requests = [_]f32{ 30.0, 36.0, 40.0 };
    for (requests) |target_psnr| {
        const encoded = try encodeStaticLossy(testing.allocator, buffer, .{
            .format = .lossy,
            .target_psnr = target_psnr,
        });
        defer testing.allocator.free(encoded);

        var decoded = try decode.decodeStatic(testing.allocator, encoded, .{ .output_format = .rgba });
        defer decoded.deinit();

        const achieved = metrics.psnrLuma(buffer.pixels, decoded.buffer.pixels, 4);
        if (achieved + 1.0 < target_psnr) {
            std.debug.print(
                "target_psnr {d:.1}: achieved {d:.2} dB ({d} bytes)\n",
                .{ target_psnr, achieved, encoded.len },
            );
            return error.TargetPsnrNotBracketed;
        }
    }
}

test "encodeStaticLossy target-size rides through the alpha search path" {
    const decode = @import("decode.zig");

    // An alpha source proves the once-encoded ALPH payload is reused across the
    // target-size search: the result must still recover its alpha byte-exactly
    // (lossy alpha is lossless) AND land within 5% of the requested size.
    const source = synth.Source{
        .name = "alpha_gradient_64x48_rgba",
        .width = 64,
        .height = 48,
        .format = .rgba,
        .content = .alpha_gradient,
    };
    const rendered = try synth.render(testing.allocator, source);
    defer rendered.deinit();
    const buffer = rendered.buffer;

    // Frame the achievable size envelope, then request an interior target.
    const finest = try encodeStaticLossy(testing.allocator, buffer, .{ .format = .lossy, .quality = 100 });
    defer testing.allocator.free(finest);
    const coarsest = try encodeStaticLossy(testing.allocator, buffer, .{ .format = .lossy, .quality = 0 });
    defer testing.allocator.free(coarsest);
    try testing.expect(coarsest.len < finest.len);

    const target_size: u32 = @intCast(coarsest.len + (finest.len - coarsest.len) / 2);
    const encoded = try encodeStaticLossy(testing.allocator, buffer, .{
        .format = .lossy,
        .target_size = target_size,
    });
    defer testing.allocator.free(encoded);

    // The search output must still advertise and round-trip its alpha.
    var parsed = try demux.parse(testing.allocator, encoded, .{});
    defer parsed.deinit();
    try testing.expect(parsed.features.has_alpha);
    try testing.expect(parsed.features.alpha != null);

    var decoded = try decode.decodeStatic(testing.allocator, encoded, .{ .output_format = .rgba });
    defer decoded.deinit();

    const out_stride: usize = decoded.buffer.stride;
    for (0..source.height) |y| {
        for (0..source.width) |x| {
            const src_alpha = rendered.pixels[(y * source.width + x) * 4 + 3];
            const out_alpha = decoded.buffer.pixels[y * out_stride + x * 4 + 3];
            try testing.expectEqual(src_alpha, out_alpha);
        }
    }

    const achieved: f64 = @floatFromInt(encoded.len);
    const requested: f64 = @floatFromInt(target_size);
    const relative_error = @abs(achieved - requested) / requested;
    if (relative_error > 0.05) {
        std.debug.print(
            "alpha target_size {d}: achieved {d} bytes, relative error {d:.4}\n",
            .{ target_size, encoded.len, relative_error },
        );
        return error.TargetSizeOutOfTolerance;
    }
}

fn encodeTargetSizeAllocationProbe(gpa: std.mem.Allocator, buffer: image.Buffer) !void {
    const encoded = try encodeStaticLossy(gpa, buffer, .{ .format = .lossy, .target_size = 600 });
    gpa.free(encoded);
}

fn encodeTargetPsnrAllocationProbe(gpa: std.mem.Allocator, buffer: image.Buffer) !void {
    const encoded = try encodeStaticLossy(gpa, buffer, .{ .format = .lossy, .target_psnr = 34.0 });
    gpa.free(encoded);
}

test "lossy target-mode searches survive allocation failure at every site" {
    // A small partial-macroblock canvas keeps the bounded search cheap while
    // still exercising every alloc site the multi-pass search adds (the carried
    // candidate file, the source-RGB and reconstruction-RGB PSNR scratch). The
    // `i % 256` fill cycles the alpha byte, so the alpha-encode allocations ride
    // through the search under failure too.
    const width = 20;
    const height = 12;
    const dims = try image.Dimensions.init(width, height);
    const pixels = try renderTargetModeSource(testing.allocator, width, height);
    defer testing.allocator.free(pixels);
    const buffer = image.Buffer{
        .pixels = pixels,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    try testing.checkAllAllocationFailures(testing.allocator, encodeTargetSizeAllocationProbe, .{buffer});
    try testing.checkAllAllocationFailures(testing.allocator, encodeTargetPsnrAllocationProbe, .{buffer});
}
