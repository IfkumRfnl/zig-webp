//! Public pixel-level animation encode composition (step 9 slice 9b).
//!
//! `encodeAnimationFromBuffers` is the animated analogue of the still
//! `encodeLossy`/`encodeLossless`: it takes a caller-supplied ordered list of
//! pixel-buffer frames — each with its canvas offset, duration, blend/dispose
//! methods, and per-frame codec choice — encodes every frame's pixels to a raw
//! `VP8`/`VP8L` bitstream (plus an optional lossy `ALPH` plane), and muxes them
//! into a complete animated WebP via the slice-9a container muxer
//! (`mux.encodeAnimation`).
//!
//! Per-frame encode reuses the existing still machinery rather than
//! reimplementing codecs: `encode.gatherArgbAlloc` gathers the frame's ARGB, a
//! lossless frame runs `vp8l_encoder.encodeAlloc`, and a lossy frame runs
//! `color.rgbaToYuv420Alloc` + `vp8_encoder.encodeAlloc` plus
//! `alpha.encodePlaneAlloc` when the plane carries transparency. The caller
//! dictates each frame's rectangle, blend, and dispose; automatic
//! sub-rectangle detection / inter-frame differencing is slice 9c.
//!
//! Because the mux re-validates every frame (rectangle inside the canvas, even
//! offsets, bitstream dimensions, alpha placement), this layer leans on
//! `mux.encodeAnimation` for the container rules and adds only the input
//! checks the mux cannot make (each buffer's declared dimensions must match its
//! own `image.Buffer`, and the lossy/lossless codec choice is honored).

const std = @import("std");

const alpha = @import("alpha.zig");
const animation = @import("animation.zig");
const color = @import("color.zig");
const encode = @import("encode.zig");
const errors = @import("errors.zig");
const features = @import("features.zig");
const image = @import("image.zig");
const limits = @import("limits.zig");
const metadata = @import("metadata.zig");
const mux = @import("mux.zig");
const options = @import("options.zig");
const vp8_encoder = @import("vp8/encoder.zig");
const vp8_quant = @import("vp8/quant.zig");
const vp8l_encoder = @import("vp8l/encoder.zig");
const vp8l_pixel = @import("vp8l/pixel.zig");

/// One source frame for `encodeAnimationFromBuffers`: a pixel buffer plus its
/// placement, timing, compositing methods, and codec. The buffer's own
/// dimensions are the frame rectangle's width/height; `x`/`y` place that
/// rectangle on the canvas (must be even — the container stores offsets in
/// 2-pixel units — and the rectangle must lie inside the canvas).
pub const FrameSource = struct {
    /// The frame's pixels. Any supported `image.PixelFormat`; read row-major
    /// honoring `buffer.stride`. `buffer.dimensions` is the frame rectangle's
    /// size.
    buffer: image.Buffer,
    /// Top-left offset of the frame rectangle on the canvas (even values only).
    x: u32 = 0,
    y: u32 = 0,
    /// Display duration in milliseconds; stored as a 24-bit field.
    duration_ms: u32 = 0,
    blend_method: animation.BlendMethod = .alpha_blend,
    dispose_method: animation.DisposeMethod = .none,
    /// Per-frame codec: `.lossy` (`VP8 ` + optional `ALPH`) or `.lossless`
    /// (`VP8L`, which carries its own alpha).
    format: features.FormatKind,
};

/// Inputs to `encodeAnimationFromBuffers`: the global canvas, loop count,
/// background color, optional animation-level metadata, resource limits, and
/// the shared per-frame encode knobs (quality/method/alpha_quality). The
/// per-frame compositing and codec live on each `FrameSource`.
pub const Options = struct {
    /// The animation canvas. Every frame rectangle must lie inside it.
    canvas: image.Dimensions,
    loop_count: animation.LoopCount = .infinite,
    /// Background color (B, G, R, A) stored in the `ANIM` chunk. Informational:
    /// the animation decoder composites over a transparent canvas.
    background_bgra: [4]u8 = .{ 0, 0, 0, 0 },
    /// Animation-level metadata (`ICCP`/`EXIF`/`XMP `) passed through to the
    /// mux. Metadata-from-pixels for the still encoders is slice 9d; this only
    /// forwards already-formed payloads.
    metadata: metadata.RawPayloads = .{},
    limits: limits.ResourceLimits = .{},
    /// Color quantizer for `.lossy` frames (0..100), the same knob
    /// `encodeLossy` takes. Shared across all lossy frames.
    quality: u8 = 75,
    /// Rate-distortion search effort for `.lossy` frames (0..6, `cwebp -m`).
    method: u8 = 4,
    /// Alpha-plane compression effort for `.lossy` frames carrying transparency
    /// (0 = uncompressed `ALPH`, 1..100 = lossless VP8L, smaller kept).
    alpha_quality: u8 = 100,
};

/// Encodes an ordered list of pixel-buffer frames into a complete animated
/// WebP file. Each frame's pixels are encoded to a raw `VP8`/`VP8L` bitstream
/// (plus an optional lossy `ALPH` plane), then all frames are muxed via
/// `mux.encodeAnimation`. The caller dictates each frame's rectangle, blend,
/// and dispose; this slice does not optimize them (that is slice 9c).
///
/// Returns caller-owned bytes (free with `gpa`).
pub fn encodeAnimationFromBuffers(
    gpa: std.mem.Allocator,
    frame_sources: []const FrameSource,
    encode_options: Options,
) errors.Error![]u8 {
    if (frame_sources.len == 0) return error.MissingImageData;

    // Validate the canvas and the frame count up front (the mux re-validates,
    // but failing fast here avoids encoding pixels we would only reject).
    try encode_options.limits.validateCanvas(
        encode_options.canvas.width,
        encode_options.canvas.height,
        true,
    );
    const frame_count = std.math.cast(u32, frame_sources.len) orelse {
        return error.FrameCountTooLarge;
    };
    try encode_options.limits.validateFrameCount(frame_count);

    // One muxer `FrameImage` per source frame, each owning its encoded
    // bitstream (and optional ALPH). Built incrementally so a mid-list failure
    // frees every bitstream encoded so far via the errdefer below.
    const frame_images = try gpa.alloc(mux.FrameImage, frame_sources.len);
    var encoded_count: usize = 0;
    defer gpa.free(frame_images);
    errdefer freeEncodedFrames(gpa, frame_images[0..encoded_count]);

    for (frame_sources, 0..) |source, index| {
        frame_images[index] = try encodeFrame(gpa, source, encode_options);
        encoded_count += 1;
    }

    const file = try mux.encodeAnimation(gpa, .{
        .canvas = encode_options.canvas,
        .loop_count = encode_options.loop_count,
        .background_bgra = encode_options.background_bgra,
        .frames = frame_images,
        .metadata = encode_options.metadata,
    }, .{ .limits = encode_options.limits });

    // The mux copied every frame payload into `file`; the per-frame scratch is
    // no longer referenced. (errdefer above only fires before this point.)
    freeEncodedFrames(gpa, frame_images[0..encoded_count]);
    return file;
}

/// Encodes one derived frame for the slice-9c optimizer
/// (`animation_optimize.encodeAnimationMinimized`). The optimizer derives each
/// frame's rectangle, blend, and dispose; this reuses the exact same per-frame
/// pixel→bitstream path as `encodeAnimationFromBuffers` so the two encode APIs
/// share one codec. The returned image owns its `bitstream` (and `alpha`, when
/// present); the caller frees them. Kept narrow on purpose — it is the only
/// hook the optimizer needs into this module.
pub fn encodeFrameForOptimizer(
    gpa: std.mem.Allocator,
    source: FrameSource,
    encode_options: Options,
) errors.Error!mux.FrameImage {
    return encodeFrame(gpa, source, encode_options);
}

/// Frees the encoded bitstream and optional ALPH payload of every frame image
/// in `frames`. Used on the error path and after a successful mux (the mux
/// copies each payload into the output file, so the scratch is no longer
/// needed).
fn freeEncodedFrames(gpa: std.mem.Allocator, frames: []mux.FrameImage) void {
    for (frames) |frame| {
        gpa.free(frame.bitstream);
        if (frame.alpha) |payload| gpa.free(payload);
    }
}

/// Encodes one source frame's pixels into a `mux.FrameImage`: gathers the
/// frame's ARGB, then either a `VP8L` bitstream (lossless) or a `VP8 `
/// bitstream plus an optional `ALPH` payload (lossy). The returned image owns
/// its `bitstream` (and `alpha`, when present); the caller frees them.
fn encodeFrame(
    gpa: std.mem.Allocator,
    source: FrameSource,
    encode_options: Options,
) errors.Error!mux.FrameImage {
    try source.buffer.validate();
    const dimensions = source.buffer.dimensions;

    return switch (source.format) {
        .lossless => try encodeLosslessFrame(gpa, source, dimensions, encode_options),
        .lossy => try encodeLossyFrame(gpa, source, dimensions, encode_options),
    };
}

/// Encodes one frame losslessly (`VP8L`), mirroring the inner half of
/// `encode.encodeStaticLossless`. VP8L carries its own alpha, so no `ALPH`
/// chunk is produced.
fn encodeLosslessFrame(
    gpa: std.mem.Allocator,
    source: FrameSource,
    dimensions: image.Dimensions,
    encode_options: Options,
) errors.Error!mux.FrameImage {
    const pixel_count = try dimensions.pixelCount();
    try validateLosslessFrameBudget(pixel_count, dimensions, encode_options.limits);

    const argb = try encode.gatherArgbAlloc(gpa, source.buffer);
    defer gpa.free(argb);

    const bitstream = try vp8l_encoder.encodeAlloc(gpa, dimensions, argb);
    return frameImage(source, dimensions, .lossless, bitstream, null);
}

/// Encodes one frame lossily (`VP8 ` + optional `ALPH`), mirroring the inner
/// half of `encode.encodeStaticLossy`'s single-pass path: the color frame goes
/// through the VP8 encoder at the shared quality quantizer, and a
/// non-fully-opaque alpha plane is encoded losslessly into an `ALPH` payload.
fn encodeLossyFrame(
    gpa: std.mem.Allocator,
    source: FrameSource,
    dimensions: image.Dimensions,
    encode_options: Options,
) errors.Error!mux.FrameImage {
    if (dimensions.width > vp8_encoder.dimension_max or
        dimensions.height > vp8_encoder.dimension_max)
    {
        return error.InvalidCanvasSize;
    }
    const pixel_count = try dimensions.pixelCount();
    try validateLossyInitialFrameBudget(pixel_count, dimensions, encode_options.limits);

    const argb = try encode.gatherArgbAlloc(gpa, source.buffer);
    defer gpa.free(argb);

    // Extract the straight (non-premultiplied) alpha plane; a fully-opaque
    // plane needs no ALPH chunk (the frame is a plain `VP8 `).
    const alpha_plane = try gpa.alloc(u8, @intCast(pixel_count));
    defer gpa.free(alpha_plane);
    for (argb, alpha_plane) |value, *sample| sample.* = vp8l_pixel.alpha(value);
    const has_alpha = alpha.planeHasTransparency(alpha_plane);

    var alpha_payload: ?[]u8 = null;
    errdefer if (alpha_payload) |payload| gpa.free(payload);
    if (has_alpha) {
        try validateAlphaFrameBudget(pixel_count, dimensions, encode_options.limits);
        alpha_payload = try alpha.encodePlaneAlloc(
            gpa,
            alpha_plane,
            dimensions,
            encode_options.alpha_quality,
        );
    }

    var planes = try color.rgbaToYuv420Alloc(gpa, argb, dimensions.width, dimensions.height);
    defer planes.deinit(gpa);

    var result = try vp8_encoder.encodeAlloc(gpa, &planes, .{
        .base_quant_index = vp8_quant.baseQuantIndexForQuality(encode_options.quality),
        .method = encode_options.method,
    });
    // The reconstruction is only needed for the PSNR/target-size searches the
    // still encoder runs; an animation frame uses the plain quality knob, so we
    // keep only the bitstream.
    result.reconstruction.deinit(gpa);
    return frameImage(source, dimensions, .lossy, result.bitstream, alpha_payload);
}

/// Assembles a `mux.FrameImage` from a source frame's placement/timing and its
/// freshly encoded bitstream (+ optional ALPH). The bitstream and alpha are
/// caller-owned by the returned image.
fn frameImage(
    source: FrameSource,
    dimensions: image.Dimensions,
    format: features.FormatKind,
    bitstream: []u8,
    alpha_payload: ?[]u8,
) mux.FrameImage {
    return .{
        .rect = .{
            .x = source.x,
            .y = source.y,
            .width = dimensions.width,
            .height = dimensions.height,
        },
        .duration_ms = source.duration_ms,
        .blend_method = source.blend_method,
        .dispose_method = source.dispose_method,
        .format = format,
        .bitstream = bitstream,
        .alpha = alpha_payload,
    };
}

// --- Per-frame allocation budgets -------------------------------------------
//
// Each frame is encoded and freed before the next begins, so the peak across
// the list is one frame's encode scratch (plus the accumulated bitstreams,
// which the mux charges separately). These mirror `encode.zig`'s lossy/lossless
// budget checks so a frame fails before allocating rather than during.

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
        if (count > std.math.maxInt(u64) / @sizeOf(T)) return error.AllocationLimitExceeded;
        try self.reserveBytes(count * @sizeOf(T));
    }

    fn reserveBytes(self: *AllocationBudget, bytes: u64) errors.Error!void {
        if (bytes > std.math.maxInt(u64) - self.bytes) return error.AllocationLimitExceeded;
        self.bytes += bytes;
        try self.resource_limits.validateAllocationBytes(self.bytes);
    }
};

fn validateLosslessFrameBudget(
    pixel_count: u64,
    dimensions: image.Dimensions,
    resource_limits: limits.ResourceLimits,
) errors.Error!void {
    var budget = AllocationBudget.init(resource_limits);
    try budget.reserveElements(vp8l_pixel.Pixel, pixel_count);
    try budget.reserveBytes(@intCast(try vp8l_encoder.maxEncodedSize(dimensions)));
}

fn validateLossyInitialFrameBudget(
    pixel_count: u64,
    dimensions: image.Dimensions,
    resource_limits: limits.ResourceLimits,
) errors.Error!void {
    var budget = AllocationBudget.init(resource_limits);
    try budget.reserveElements(vp8l_pixel.Pixel, pixel_count); // gathered ARGB
    try budget.reserveElements(u8, pixel_count); // alpha plane
    try budget.reserveBytes(try color.yuv420AllocationBytes(dimensions.width, dimensions.height));
    try budget.reserveBytes(try vp8_encoder.allocationBytesMax(dimensions));
}

fn validateAlphaFrameBudget(
    pixel_count: u64,
    dimensions: image.Dimensions,
    resource_limits: limits.ResourceLimits,
) errors.Error!void {
    var budget = AllocationBudget.init(resource_limits);
    try budget.reserveElements(u8, pixel_count); // forward-filtered plane
    try budget.reserveElements(vp8l_pixel.Pixel, pixel_count); // VP8L source
    try budget.reserveBytes(@intCast(try vp8l_encoder.maxEncodedSize(dimensions)));
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const animation_decode = @import("animation_decode.zig");

/// Builds an RGBA `image.Buffer` over `pixels` (caller owns the slice).
fn rgbaBuffer(pixels: []u8, width: u32, height: u32) errors.Error!image.Buffer {
    return .{
        .pixels = pixels,
        .dimensions = try image.Dimensions.init(width, height),
        .stride = width * 4,
        .format = .rgba,
    };
}

/// Fills `pixels` (RGBA, tightly packed) with a constant color.
fn fillConstant(pixels: []u8, color_rgba: [4]u8) void {
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        pixels[i + 0] = color_rgba[0];
        pixels[i + 1] = color_rgba[1];
        pixels[i + 2] = color_rgba[2];
        pixels[i + 3] = color_rgba[3];
    }
}

test "all-lossless full-canvas keyframes round-trip byte-for-byte" {
    const gpa = testing.allocator;
    const width = 8;
    const height = 6;

    // Two full-canvas opaque-replace lossless frames are both keyframes, so the
    // composited output must equal each source frame exactly.
    var frame0: [width * height * 4]u8 = undefined;
    var frame1: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const base = (y * width + x) * 4;
            frame0[base + 0] = @intCast((x * 30) % 256);
            frame0[base + 1] = @intCast((y * 40) % 256);
            frame0[base + 2] = @intCast(((x + y) * 11) % 256);
            frame0[base + 3] = 255;
            frame1[base + 0] = @intCast((x * 7 + 100) % 256);
            frame1[base + 1] = @intCast((y * 9 + 50) % 256);
            frame1[base + 2] = @intCast((x * y) % 256);
            frame1[base + 3] = 255;
        }
    }

    const sources = [_]FrameSource{
        .{
            .buffer = try rgbaBuffer(&frame0, width, height),
            .duration_ms = 100,
            .blend_method = .replace,
            .format = .lossless,
        },
        .{
            .buffer = try rgbaBuffer(&frame1, width, height),
            .duration_ms = 80,
            .blend_method = .replace,
            .format = .lossless,
        },
    };

    const encoded = try encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(width, height),
    });
    defer gpa.free(encoded);

    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();

    try testing.expectEqual(@as(usize, 2), animated.frames.len);
    try testing.expectEqual(@as(u32, 100), animated.frames[0].duration_ms);
    try testing.expectEqual(@as(u32, 80), animated.frames[1].duration_ms);
    try testing.expectEqualSlices(u8, &frame0, animated.frames[0].buffer.pixels);
    try testing.expectEqualSlices(u8, &frame1, animated.frames[1].buffer.pixels);
}

test "a lossy frame decodes at the right dimensions" {
    const gpa = testing.allocator;
    const width = 16;
    const height = 16;

    var pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const base = (y * width + x) * 4;
            pixels[base + 0] = @intCast((x * 16) % 256);
            pixels[base + 1] = @intCast((y * 16) % 256);
            pixels[base + 2] = @intCast(((x + y) * 8) % 256);
            pixels[base + 3] = 255;
        }
    }

    const sources = [_]FrameSource{.{
        .buffer = try rgbaBuffer(&pixels, width, height),
        .blend_method = .replace,
        .format = .lossy,
    }};

    const encoded = try encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(width, height),
    });
    defer gpa.free(encoded);

    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();

    try testing.expectEqual(@as(usize, 1), animated.frames.len);
    try testing.expectEqual(@as(u32, width), animated.frames[0].buffer.dimensions.width);
    try testing.expectEqual(@as(u32, height), animated.frames[0].buffer.dimensions.height);
}

test "a sub-rect frame composites over a full-canvas keyframe" {
    const gpa = testing.allocator;
    const canvas_w = 8;
    const canvas_h = 8;

    // Frame 0 fills the canvas opaque red (full-frame replace keyframe). Frame 1
    // paints an opaque-green 4x4 lossless sub-rect at (2,2); the rest of the red
    // canvas must survive.
    var bg: [canvas_w * canvas_h * 4]u8 = undefined;
    fillConstant(&bg, .{ 255, 0, 0, 255 });
    var square: [4 * 4 * 4]u8 = undefined;
    fillConstant(&square, .{ 0, 255, 0, 255 });

    const sources = [_]FrameSource{
        .{
            .buffer = try rgbaBuffer(&bg, canvas_w, canvas_h),
            .blend_method = .replace,
            .format = .lossless,
        },
        .{
            .buffer = try rgbaBuffer(&square, 4, 4),
            .x = 2,
            .y = 2,
            .blend_method = .replace,
            .format = .lossless,
        },
    };

    const encoded = try encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(canvas_w, canvas_h),
    });
    defer gpa.free(encoded);

    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();

    const frame1 = animated.frames[1].buffer;
    const stride = frame1.stride;
    // Inside the square: green.
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, frame1.pixels[2 * stride + 2 * 4 ..][0..4]);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 255 }, frame1.pixels[5 * stride + 5 * 4 ..][0..4]);
    // Outside the square: the red background survives.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, frame1.pixels[0..4]);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, frame1.pixels[7 * stride + 7 * 4 ..][0..4]);
}

test "a lossless alpha frame recovers its alpha exactly" {
    const gpa = testing.allocator;
    const width = 4;
    const height = 4;

    // A single full-canvas lossless frame with a per-pixel alpha gradient: VP8L
    // is lossless, so the composited frame must equal the source byte-for-byte
    // (transparent pixels included — the source already has zeroed RGB where
    // alpha is 0, matching the decoder's transparent-RGB zeroing).
    var pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const base = (y * width + x) * 4;
            const a: u8 = @intCast((x + y) * 32);
            pixels[base + 0] = if (a == 0) 0 else @as(u8, @intCast(x * 60));
            pixels[base + 1] = if (a == 0) 0 else @as(u8, @intCast(y * 60));
            pixels[base + 2] = if (a == 0) 0 else 128;
            pixels[base + 3] = a;
        }
    }

    const sources = [_]FrameSource{.{
        .buffer = try rgbaBuffer(&pixels, width, height),
        .blend_method = .replace,
        .format = .lossless,
    }};

    const encoded = try encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(width, height),
    });
    defer gpa.free(encoded);

    // The container must advertise alpha.
    const demux = @import("demux.zig");
    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    try testing.expect(parsed.features.has_alpha);

    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();
    try testing.expectEqualSlices(u8, &pixels, animated.frames[0].buffer.pixels);
}

test "a lossy alpha frame recovers its alpha exactly" {
    const gpa = testing.allocator;
    const width = 16;
    const height = 16;

    // Lossy color, but lossy+alpha alpha is lossless: the recovered alpha
    // channel must match the source byte-for-byte regardless of color tolerance.
    var pixels: [width * height * 4]u8 = undefined;
    for (0..height) |y| {
        for (0..width) |x| {
            const base = (y * width + x) * 4;
            pixels[base + 0] = @intCast((x * 16) % 256);
            pixels[base + 1] = @intCast((y * 16) % 256);
            pixels[base + 2] = 100;
            pixels[base + 3] = @intCast((x * 17) % 256); // varied alpha
        }
    }

    const sources = [_]FrameSource{.{
        .buffer = try rgbaBuffer(&pixels, width, height),
        .blend_method = .replace,
        .format = .lossy,
    }};

    const encoded = try encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(width, height),
    });
    defer gpa.free(encoded);

    const demux = @import("demux.zig");
    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    try testing.expect(parsed.features.has_alpha);
    try testing.expect(parsed.frames[0].alpha_chunk != null);

    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();

    const out = animated.frames[0].buffer;
    const stride = out.stride;
    for (0..height) |y| {
        for (0..width) |x| {
            const src_alpha = pixels[(y * width + x) * 4 + 3];
            const out_alpha = out.pixels[y * stride + x * 4 + 3];
            try testing.expectEqual(src_alpha, out_alpha);
        }
    }
}

test "per-frame blend and dispose round-trip through the mux" {
    const gpa = testing.allocator;
    // Frame 0 opaque red full-canvas (replace keyframe). Frame 1 paints a green
    // 2x2 sub-rect at (2,2) and disposes it to background. Frame 2 paints a blue
    // 2x2 at (0,0); the green square must have been cleared to transparent.
    var red: [4 * 4 * 4]u8 = undefined;
    fillConstant(&red, .{ 255, 0, 0, 255 });
    var green: [2 * 2 * 4]u8 = undefined;
    fillConstant(&green, .{ 0, 255, 0, 255 });
    var blue: [2 * 2 * 4]u8 = undefined;
    fillConstant(&blue, .{ 0, 0, 255, 255 });

    const sources = [_]FrameSource{
        .{ .buffer = try rgbaBuffer(&red, 4, 4), .blend_method = .replace, .format = .lossless },
        .{
            .buffer = try rgbaBuffer(&green, 2, 2),
            .x = 2,
            .y = 2,
            .dispose_method = .background,
            .format = .lossless,
        },
        .{ .buffer = try rgbaBuffer(&blue, 2, 2), .format = .lossless },
    };

    const encoded = try encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(4, 4),
    });
    defer gpa.free(encoded);

    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();
    try testing.expectEqual(@as(usize, 3), animated.frames.len);

    const frame2 = animated.frames[2].buffer;
    const stride = frame2.stride;
    // New blue square at (0,0).
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 255 }, frame2.pixels[0..4]);
    // The green square was disposed to background (transparent) before frame 2.
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0 }, frame2.pixels[2 * stride + 2 * 4 ..][0..4]);
    // The rest of frame 0's red survives.
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, frame2.pixels[3 * 4 ..][0..4]);
}

test "loop count and background color round-trip" {
    const gpa = testing.allocator;
    var pixels: [4 * 4 * 4]u8 = undefined;
    fillConstant(&pixels, .{ 10, 20, 30, 255 });

    const sources = [_]FrameSource{.{
        .buffer = try rgbaBuffer(&pixels, 4, 4),
        .blend_method = .replace,
        .format = .lossless,
    }};

    const encoded = try encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(4, 4),
        .loop_count = .{ .count = 7 },
        .background_bgra = .{ 1, 2, 3, 4 },
    });
    defer gpa.free(encoded);

    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();
    try testing.expectEqual(@as(u16, 7), animated.info.loop_count.count);
    try testing.expectEqual([4]u8{ 1, 2, 3, 4 }, animated.info.background_bgra);
}

test "animation metadata passes through to the output" {
    const gpa = testing.allocator;
    var pixels: [2 * 2 * 4]u8 = undefined;
    fillConstant(&pixels, .{ 9, 9, 9, 255 });

    const sources = [_]FrameSource{.{
        .buffer = try rgbaBuffer(&pixels, 2, 2),
        .blend_method = .replace,
        .format = .lossless,
    }};

    const encoded = try encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(2, 2),
        .metadata = .{ .color_profile = "icc", .exif = "exif", .xmp = "xmp" },
    });
    defer gpa.free(encoded);

    const demux = @import("demux.zig");
    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    const payloads = parsed.metadataPayloads(encoded);
    try testing.expectEqualSlices(u8, "icc", payloads.color_profile.?);
    try testing.expectEqualSlices(u8, "exif", payloads.exif.?);
    try testing.expectEqualSlices(u8, "xmp", payloads.xmp.?);
}

test "rejects an empty frame list" {
    try testing.expectError(error.MissingImageData, encodeAnimationFromBuffers(
        testing.allocator,
        &.{},
        .{ .canvas = try image.Dimensions.init(2, 2) },
    ));
}

test "rejects an odd frame offset via the mux" {
    const gpa = testing.allocator;
    var pixels: [2 * 2 * 4]u8 = undefined;
    fillConstant(&pixels, .{ 1, 2, 3, 255 });
    const sources = [_]FrameSource{.{
        .buffer = try rgbaBuffer(&pixels, 2, 2),
        .x = 1, // odd offset: the container stores offsets in 2-pixel units.
        .blend_method = .replace,
        .format = .lossless,
    }};
    try testing.expectError(error.InvalidFrameChunk, encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(4, 4),
    }));
}

test "rejects a frame rectangle outside the canvas via the mux" {
    const gpa = testing.allocator;
    var pixels: [4 * 4 * 4]u8 = undefined;
    fillConstant(&pixels, .{ 1, 2, 3, 255 });
    const sources = [_]FrameSource{.{
        .buffer = try rgbaBuffer(&pixels, 4, 4),
        .x = 2, // 2 + 4 > 4
        .y = 2,
        .blend_method = .replace,
        .format = .lossless,
    }};
    try testing.expectError(error.InvalidFrameChunk, encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(4, 4),
    }));
}

test "enforces the configured frame-count limit" {
    const gpa = testing.allocator;
    var pixels: [2 * 2 * 4]u8 = undefined;
    fillConstant(&pixels, .{ 1, 2, 3, 255 });
    const sources = [_]FrameSource{
        .{ .buffer = try rgbaBuffer(&pixels, 2, 2), .blend_method = .replace, .format = .lossless },
        .{ .buffer = try rgbaBuffer(&pixels, 2, 2), .blend_method = .replace, .format = .lossless },
    };
    try testing.expectError(error.FrameCountTooLarge, encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(2, 2),
        .limits = .{ .frame_count_max = 1 },
    }));
}

fn encodeAnimationAllocationProbe(gpa: std.mem.Allocator, sources: []const FrameSource) !void {
    const encoded = try encodeAnimationFromBuffers(gpa, sources, .{
        .canvas = image.Dimensions.init(8, 8) catch unreachable,
    });
    gpa.free(encoded);
}

test "pixel animation encode survives allocation failure at every site" {
    const gpa = testing.allocator;
    // A mixed lossless + lossy(+alpha) two-frame animation exercises every
    // per-frame allocation site (ARGB gather, VP8L output, YUV planes, VP8
    // scratch, alpha plane + ALPH encode) plus the frame-image list and the mux.
    var bg: [8 * 8 * 4]u8 = undefined;
    fillConstant(&bg, .{ 30, 60, 90, 255 });
    var overlay: [4 * 4 * 4]u8 = undefined;
    for (0..4) |y| {
        for (0..4) |x| {
            const base = (y * 4 + x) * 4;
            overlay[base + 0] = @intCast(x * 60);
            overlay[base + 1] = @intCast(y * 60);
            overlay[base + 2] = 120;
            overlay[base + 3] = @intCast((x + y) * 40); // varied alpha
        }
    }

    const sources = [_]FrameSource{
        .{ .buffer = try rgbaBuffer(&bg, 8, 8), .blend_method = .replace, .format = .lossless },
        .{
            .buffer = try rgbaBuffer(&overlay, 4, 4),
            .x = 2,
            .y = 2,
            .dispose_method = .background,
            .format = .lossy,
        },
    };

    try testing.checkAllAllocationFailures(gpa, encodeAnimationAllocationProbe, .{@as([]const FrameSource, &sources)});
}

fn fuzzAnimationEncodeOne(_: void, smith: *std.testing.Smith) anyerror!void {
    var input_buffer: [2048]u8 = undefined;
    const input_len = smith.slice(&input_buffer);
    if (input_len < 2) return;

    const dim_byte = input_buffer[0];
    const width: u32 = 1 + (dim_byte % 16);
    const height: u32 = 1 + ((dim_byte >> 4) % 16);
    const format: features.FormatKind = if (input_buffer[1] & 1 != 0) .lossy else .lossless;

    const dims = try image.Dimensions.init(width, height);
    const pixel_count = @as(usize, width) * height * 4;
    var pixel_buffer: [16 * 16 * 4]u8 = undefined;
    @memset(&pixel_buffer, 0);
    const available = input_len - 2;
    const copy_len = @min(available, pixel_count);
    @memcpy(pixel_buffer[0..copy_len], input_buffer[2..][0..copy_len]);

    const buffer = image.Buffer{
        .pixels = &pixel_buffer,
        .dimensions = dims,
        .stride = width * 4,
        .format = .rgba,
    };

    const frames = [_]FrameSource{.{
        .buffer = buffer,
        .blend_method = .replace,
        .format = format,
    }};

    const encoded = try encodeAnimationFromBuffers(std.testing.allocator, &frames, .{
        .canvas = dims,
    });
    defer std.testing.allocator.free(encoded);

    var decoded = try animation_decode.decodeAnimationAlloc(std.testing.allocator, encoded, .{});
    defer decoded.deinit();
}

test "fuzz animation encode from pixel buffers" {
    const testing_fuzz = @import("testing/fuzz.zig");

    const seed_payload = [_]u8{ 7 | (7 << 4), 0 } ++ .{
        0xff, 0x00, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff,
        0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x00, 0xff,
        0xff, 0x00, 0xff, 0x80, 0x00, 0xff, 0xff, 0x80,
        0x80, 0x80, 0x80, 0xff, 0x10, 0x20, 0x30, 0x40,
        0x50, 0x60, 0x70, 0x80, 0x90, 0xa0, 0xb0, 0xc0,
        0xd0, 0xe0, 0xf0, 0x00, 0x11, 0x22, 0x33, 0x44,
        0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc,
        0xdd, 0xee, 0xff, 0x12, 0x34, 0x56, 0x78, 0x9a,
    };
    var seed_buffer: [128]u8 = undefined;
    const seed = testing_fuzz.sliceCorpusEntry(&seed_buffer, &seed_payload);

    try std.testing.fuzz({}, fuzzAnimationEncodeOne, .{ .corpus = &.{seed} });
}

test "bounded mutation exploration of animation encode" {
    const testing_fuzz = @import("testing/fuzz.zig");

    const seed_payload = [_]u8{ 7 | (7 << 4), 0 } ++ .{
        0xff, 0x00, 0x00, 0xff, 0x00, 0xff, 0x00, 0xff,
        0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0x00, 0xff,
        0xff, 0x00, 0xff, 0x80, 0x00, 0xff, 0xff, 0x80,
        0x80, 0x80, 0x80, 0xff, 0x10, 0x20, 0x30, 0x40,
        0x50, 0x60, 0x70, 0x80, 0x90, 0xa0, 0xb0, 0xc0,
        0xd0, 0xe0, 0xf0, 0x00, 0x11, 0x22, 0x33, 0x44,
        0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc,
        0xdd, 0xee, 0xff, 0x12, 0x34, 0x56, 0x78, 0x9a,
    };

    try testing_fuzz.runMutations(fuzzAnimationEncodeOne, &seed_payload, .{ .prng_seed = 0x11d_0009 });
}
