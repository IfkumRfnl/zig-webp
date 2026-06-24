//! Automatic animation frame optimization (step 9 slice 9c).
//!
//! `encodeAnimationMinimized` takes a sequence of *full-canvas* frames — the
//! desired display at each timestamp — plus timing and per-frame codec, and
//! derives a minimal `ANMF` layout (sub-rectangles, blend/dispose methods, and
//! keyframes) that composites back to exactly those frames. It then encodes the
//! derived frames with the slice-9b per-frame encoder (`animation_encode`) and
//! muxes them via `mux.encodeAnimation`. This is the pixel-level analogue of
//! libwebp's `WebPAnimEncoder`; the explicit-rect `encodeAnimationFromBuffers`
//! (slice 9b) stays the manual API.
//!
//! The four PLAN.MD §9 features all live here:
//!  - **sub-rectangle detection:** the minimal bounding box of pixels that
//!    differ from the decoder's reconstructed previous canvas
//!    (`changeRect`, mirroring libwebp's `MinimizeChangeRectangle`).
//!  - **inter-frame differencing + blend strategy:** inside the diff rect,
//!    pixels equal to the previous canvas are made transparent and the frame is
//!    `alpha_blend`ed so the previous canvas shows through; otherwise the frame
//!    is a verbatim `replace`. A blend candidate is only chosen when it
//!    provably reconstructs exactly (`blendCandidateExact`).
//!  - **dispose strategy:** a frame uses dispose-to-background when clearing its
//!    rectangle shrinks the next frame's diff rect (one-frame lookahead). The
//!    optimizer tracks the canvas exactly as the decoder will — including the
//!    dispose it chose — so any dispose choice stays byte-exact.
//!  - **keyframe insertion:** frame 0 is a full-canvas `replace` keyframe;
//!    further keyframes are forced when the diff rect is the whole canvas or a
//!    bounded interval elapses, keeping frames independent enough to seek.
//!
//! THE correctness invariant: the optimized output, decoded via
//! `animation_decode.decodeAnimationAlloc`, reproduces the input canvases. For
//! all-lossless input this is byte-exact (the CI gate). The optimizer always
//! tracks the decoder's *reconstructed* canvas (`prev_canvas`, re-decoding each
//! frame it encodes and compositing with the exact `animation_decode` rules), so
//! lossy reconstruction error never accumulates and every frame composites onto
//! exactly what the decoder holds.
//!
//! **Lossy frames (slice 9c-2):** a lossy frame is never byte-exact, so diffing
//! it against the reconstructed previous canvas would flag almost every pixel as
//! "changed" (VP8 noise differs everywhere) and the rect would be the whole
//! canvas every frame — that is why 9c punted on lossy shrink. 9c-2 fixes it with
//! two coordinated mechanisms:
//!  - A *source-quality* carryover canvas: a **lossy** frame detects its rect by
//!    diffing the carryover (original source pixels) against the current source,
//!    so VP8 noise never inflates it. A **lossless** frame must reproduce its
//!    source exactly, so it diffs against `prev_canvas` (the reconstruction the
//!    decoder holds) and re-emits any pixel where a prior lossy frame's artifacts
//!    drifted from the lossless source. For all-lossless input the two references
//!    coincide, so the byte-exact gate is unchanged.
//!  - A *content-change tolerance* `T` for the lossy diff: a pixel counts as
//!    unchanged when its alpha matches and every RGB channel differs by at most
//!    `T` (weighted by destination alpha, mirroring libwebp's `PixelsAreSimilar`).
//!    Pixels within tolerance are inherited from the previous decoded frame —
//!    visually close, not exact. `T` defaults to a quality-derived value
//!    (`qualityToMaxDiff`, libwebp's `QualityToMaxDiff`); a caller may override it
//!    via `Options.tolerance`. Lossless frames always use `T = 0` (exact).
//!
//! The blend/transparent path still uses exact equality even for lossy (only the
//! rect *detection* uses tolerance). A frame that matches the previous canvas
//! (exactly, or within tolerance for lossy) emits a synthetic 1x1 no-op that
//! copies the held pixel from `prev_canvas` — a true canvas-preserving no-op, not
//! a near-equal `target` pixel that would flicker at (0,0). Bounded drift from
//! inherited regions is capped by the existing `keyframe_interval`.

const std = @import("std");
const assert = std.debug.assert;

const animation = @import("animation.zig");
const animation_encode = @import("animation_encode.zig");
const decode = @import("decode.zig");
const errors = @import("errors.zig");
const features = @import("features.zig");
const image = @import("image.zig");
const limits = @import("limits.zig");
const metadata = @import("metadata.zig");
const mux = @import("mux.zig");

/// One full-canvas source frame for `encodeAnimationMinimized`: the desired
/// canvas-sized display at this timestamp, its duration, and its codec. Unlike
/// `animation_encode.FrameSource`, the caller does NOT pick a rectangle, blend,
/// or dispose — the optimizer derives those. The buffer's dimensions must equal
/// the animation canvas.
pub const FrameInput = struct {
    /// The full canvas at this frame, any supported `image.PixelFormat`, read
    /// row-major honoring `buffer.stride`. `buffer.dimensions` must equal the
    /// canvas in `Options`.
    buffer: image.Buffer,
    /// Display duration in milliseconds; stored as a 24-bit field.
    duration_ms: u32 = 0,
    /// Per-frame codec: `.lossy` or `.lossless`. Lossless input is byte-exact on
    /// round-trip *after transparent-RGB canonicalization*: fully-transparent
    /// pixels are normalized to `0,0,0,0` (matching libwebp `anim_dump`
    /// composition), so RGB hidden behind alpha=0 is not preserved. Lossy input
    /// round-trips within the codec's tolerance.
    format: features.FormatKind,
};

/// Options for `encodeAnimationMinimized`: the same animation-level knobs as
/// slice 9b's `Options` plus the keyframe interval. The per-frame compositing is
/// derived by the optimizer, so (unlike 9b) there are no per-frame rect/blend
/// fields.
pub const Options = struct {
    /// The animation canvas. Every input frame's dimensions must equal it.
    canvas: image.Dimensions,
    loop_count: animation.LoopCount = .infinite,
    /// Background color (B, G, R, A) stored in the `ANIM` chunk. Informational:
    /// the animation decoder composites over a transparent canvas.
    background_bgra: [4]u8 = .{ 0, 0, 0, 0 },
    metadata: metadata.RawPayloads = .{},
    limits: limits.ResourceLimits = .{},
    /// Color quantizer for `.lossy` frames (0..100).
    quality: u8 = 75,
    /// Rate-distortion search effort for `.lossy` frames (0..6).
    method: u8 = 4,
    /// Alpha-plane compression effort for `.lossy` frames carrying transparency.
    alpha_quality: u8 = 100,
    /// Maximum number of frames between forced keyframes (clamped to
    /// `[1, keyframe_interval_max]`). A keyframe is also forced whenever a frame
    /// changes the whole canvas. Bounds how far decode must walk back to seek.
    keyframe_interval: u32 = 16,
    /// Per-channel content-change tolerance for `.lossy` frames (0..255). A
    /// pixel counts as unchanged when its alpha matches the previous canvas and
    /// every RGB channel differs by at most this many levels (alpha-weighted),
    /// so a smaller diff rectangle is detected and inherited regions are reused.
    /// `null` (the default) derives it from `quality` via `qualityToMaxDiff`
    /// (libwebp's `QualityToMaxDiff`: ~5 at q=75, 1 at q=100, 31 at q=0); set it
    /// explicitly to trade size against drift. Lossless frames always use 0
    /// (exact), so this knob never affects the byte-exact lossless path.
    tolerance: ?u8 = null,
};

/// Upper bound on `keyframe_interval`, so a hostile option cannot defer
/// keyframes unboundedly. 4096 matches `ResourceLimits.frame_count_max`.
pub const keyframe_interval_max: u32 = 4096;

const channels = 4;

/// Encodes a sequence of full-canvas frames into a minimized animated WebP: the
/// optimizer derives sub-rectangles, blend/dispose methods, and keyframes that
/// composite back to the input canvases, then reuses the slice-9b per-frame
/// encoder and `mux.encodeAnimation`. The output round-trips through
/// `decodeAnimation` (byte-exact for all-lossless input, after transparent-RGB
/// canonicalization: fully-transparent pixels are normalized to `0,0,0,0` to
/// match libwebp `anim_dump`, so RGB hidden behind alpha=0 is not preserved;
/// within the codec's tolerance for lossy frames, which also shrink — see
/// `Options.tolerance`) and
/// is accepted by `webpinfo`/`webpmux`/`anim_dump`.
///
/// Returns caller-owned bytes (free with `gpa`).
pub fn encodeAnimationMinimized(
    gpa: std.mem.Allocator,
    frames: []const FrameInput,
    encode_options: Options,
) errors.Error![]u8 {
    if (frames.len == 0) return error.MissingImageData;

    const canvas = encode_options.canvas;
    try encode_options.limits.validateCanvas(canvas.width, canvas.height, true);
    const frame_count = std.math.cast(u32, frames.len) orelse return error.FrameCountTooLarge;
    try encode_options.limits.validateFrameCount(frame_count);

    // Every input must be a full-canvas buffer with the declared dimensions.
    for (frames) |frame| {
        try frame.buffer.validate();
        if (frame.buffer.dimensions.width != canvas.width or
            frame.buffer.dimensions.height != canvas.height)
        {
            return error.InvalidCanvasSize;
        }
    }

    var optimizer = try Optimizer.init(gpa, canvas, encode_options);
    defer optimizer.deinit();

    // Build one muxer FrameImage per input frame. Built incrementally so a
    // mid-list failure frees every bitstream encoded so far.
    const frame_images = try gpa.alloc(mux.FrameImage, frames.len);
    var encoded_count: usize = 0;
    defer gpa.free(frame_images);
    errdefer freeEncodedFrames(gpa, frame_images[0..encoded_count]);

    for (frames, 0..) |frame, index| {
        const is_last = index + 1 == frames.len;
        const next: ?FrameInput = if (is_last) null else frames[index + 1];
        frame_images[index] = try optimizer.encodeNext(frame, next);
        encoded_count += 1;
    }

    const file = try mux.encodeAnimation(gpa, .{
        .canvas = canvas,
        .loop_count = encode_options.loop_count,
        .background_bgra = encode_options.background_bgra,
        .frames = frame_images,
        .metadata = encode_options.metadata,
    }, .{ .limits = encode_options.limits });

    freeEncodedFrames(gpa, frame_images[0..encoded_count]);
    return file;
}

/// Frees the encoded bitstream and optional ALPH payload of every frame image.
fn freeEncodedFrames(gpa: std.mem.Allocator, frame_images: []mux.FrameImage) void {
    for (frame_images) |frame_image| freeFrameImage(gpa, frame_image);
}

fn freeFrameImage(gpa: std.mem.Allocator, frame_image: mux.FrameImage) void {
    gpa.free(frame_image.bitstream);
    if (frame_image.alpha) |payload| gpa.free(payload);
}

/// An inclusive-min, exclusive-max change rectangle in canvas coordinates. A
/// width or height of zero means "no change" (an empty rect).
const Rect = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,

    fn isEmpty(self: Rect) bool {
        return self.width == 0 or self.height == 0;
    }

    fn isFullCanvas(self: Rect, canvas: image.Dimensions) bool {
        return self.x == 0 and self.y == 0 and
            self.width == canvas.width and self.height == canvas.height;
    }

    fn frameRect(self: Rect) animation.FrameRect {
        return .{ .x = self.x, .y = self.y, .width = self.width, .height = self.height };
    }
};

/// Carries the optimizer's running state across frames: the decoder's
/// reconstructed canvas (`prev_canvas`), a *source-quality* carryover canvas
/// (`carryover`), the previous frame's rectangle and keyframe status (mirroring
/// `animation_decode.Decoder.PrevFrame`, needed to reproduce the "skip blending
/// inside the previous background-disposed rect" rule and keyframe detection),
/// and the keyframe counter.
const Optimizer = struct {
    gpa: std.mem.Allocator,
    canvas: image.Dimensions,
    encode_options: Options,
    stride: u32,

    /// What the decoder holds *before* the next frame (i.e. after the previous
    /// frame was composited and its dispose applied). Packed RGBA, canvas-sized,
    /// with fully-transparent pixels' RGB zeroed (matching the decoder). Used for
    /// the blend-exactness check and the reconstructed-canvas correctness model.
    prev_canvas: []u8,
    /// The lossy change-rect reference canvas: the *original source* pixels
    /// carried over frame to frame — the rect region updated to each emitted
    /// frame's source, inherited regions keeping the earlier source, dispose
    /// clears applied. A *lossy* frame diffs `carryover` vs the current source
    /// `target`, so VP8 reconstruction noise (which lives only in `prev_canvas`)
    /// never inflates the rect. A *lossless* frame instead diffs against
    /// `prev_canvas`, so it re-emits every pixel where the reconstruction drifted
    /// from its exact source. For all-lossless input `carryover == prev_canvas`
    /// exactly (the source round-trips bit-for-bit), so the two references
    /// coincide and the byte-exact gate is unchanged. Mirrors libwebp's
    /// `canvas_carryover`.
    carryover: []u8,
    /// Canvas-sized scratch reused to gather each frame's desired RGBA canvas.
    target: []u8,

    /// The previous emitted frame's rectangle / dispose / keyframe status. Null
    /// before the first frame.
    prev: ?Prev,
    frames_since_keyframe: u32,

    const Prev = struct {
        rect: animation.FrameRect,
        dispose: animation.DisposeMethod,
        was_keyframe: bool,
    };

    fn init(
        gpa: std.mem.Allocator,
        canvas: image.Dimensions,
        encode_options: Options,
    ) errors.Error!Optimizer {
        const pixel_count = try canvas.pixelCount();
        const row_bytes = @as(u64, canvas.width) * channels;
        if (row_bytes > std.math.maxInt(u32)) return error.OutputTooLarge;
        const canvas_bytes = pixel_count * channels;

        // Three canvas-sized scratch buffers; bound against the budget up front
        // (the per-frame encoder charges its own scratch separately).
        var budget: u64 = 0;
        budget = try addBytes(budget, canvas_bytes);
        budget = try addBytes(budget, canvas_bytes);
        budget = try addBytes(budget, canvas_bytes);
        try encode_options.limits.validateAllocationBytes(budget);

        const prev_canvas = try gpa.alloc(u8, @intCast(canvas_bytes));
        errdefer gpa.free(prev_canvas);
        @memset(prev_canvas, 0);

        const carryover = try gpa.alloc(u8, @intCast(canvas_bytes));
        errdefer gpa.free(carryover);
        @memset(carryover, 0);

        const target = try gpa.alloc(u8, @intCast(canvas_bytes));
        errdefer gpa.free(target);

        return .{
            .gpa = gpa,
            .canvas = canvas,
            .encode_options = encode_options,
            .stride = @intCast(row_bytes),
            .prev_canvas = prev_canvas,
            .carryover = carryover,
            .target = target,
            .prev = null,
            .frames_since_keyframe = 0,
        };
    }

    fn deinit(self: *Optimizer) void {
        self.gpa.free(self.prev_canvas);
        self.gpa.free(self.carryover);
        self.gpa.free(self.target);
        self.* = undefined;
    }

    /// Derives the rectangle, blend, and dispose for one frame, encodes it via
    /// the slice-9b per-frame encoder, then updates `prev_canvas` (the decoder's
    /// reconstruction) and `carryover` (the source-quality reference) for the
    /// next frame. `next`, if present, is the following input frame (used only
    /// for the dispose lookahead).
    fn encodeNext(
        self: *Optimizer,
        input: FrameInput,
        next: ?FrameInput,
    ) errors.Error!mux.FrameImage {
        // Gather the desired canvas into packed RGBA with transparent-RGB
        // zeroing, so it equals the decoder's reconstructed canvas model.
        gatherCanvasRgba(input.buffer, self.target, self.stride);
        const target = self.target;

        // The content-change tolerance is 0 (exact) for lossless frames and the
        // configured / quality-derived value for lossy frames. It drives the
        // sub-rect detection and dispose lookahead.
        const tolerance = self.toleranceFor(input.format);
        const lossy = input.format == .lossy;

        // The change-rect reference canvas depends on the codec:
        //  - A *lossy* frame diffs against the *source-quality* `carryover` (not
        //    the reconstruction), so VP8 noise — which differs on essentially
        //    every pixel — never inflates the rect to the whole canvas.
        //  - A *lossless* frame must reproduce its source EXACTLY, so it diffs
        //    against `prev_canvas`, the reconstruction the decoder actually
        //    holds. After a lossy frame `carryover` (original source) and
        //    `prev_canvas` (the approximate VP8 reconstruction) disagree;
        //    diffing a lossless frame against `carryover` would miss the pixels
        //    where the reconstruction drifted from the lossless source and leave
        //    the previous frame's lossy artifacts visible everywhere outside the
        //    rect. For all-lossless input `carryover == prev_canvas`, so this is
        //    identical there and the byte-exact lossless gate is unchanged.
        const diff_base = if (lossy) self.carryover else self.prev_canvas;
        const diff = self.changeRect(diff_base, target, tolerance);
        const interval = std.math.clamp(self.encode_options.keyframe_interval, 1, keyframe_interval_max);
        const force_interval = self.frames_since_keyframe + 1 >= interval;
        const full_change = !diff.isEmpty() and diff.isFullCanvas(self.canvas);
        const is_keyframe = self.prev == null or full_change or force_interval;

        var rect: Rect = undefined;
        var blend: animation.BlendMethod = undefined;
        var dispose: animation.DisposeMethod = .none;
        var make_transparent = false;
        // Codec for this frame. Defaults to the caller's choice, but the
        // unchanged-frame no-op below forces lossless so the synthetic 1x1
        // composites back to the exact previous pixel (see that branch).
        var frame_format = input.format;
        // When set, the emitted frame must leave the canvas untouched: its 1x1
        // sub-frame copies the pixel the decoder ALREADY holds (`prev_canvas`),
        // not this frame's source — so the carryover bookkeeping inherits from
        // `prev_canvas` too (see `buildSubFrame`/`commit`).
        var no_op = false;

        if (is_keyframe) {
            // Full-canvas verbatim replace: the decoder clears then copies, so
            // the reconstruction equals `target` (within the codec's tolerance).
            rect = .{ .x = 0, .y = 0, .width = self.canvas.width, .height = self.canvas.height };
            blend = .replace;
        } else if (diff.isEmpty()) {
            // Degenerate: this frame matches the previous canvas (exactly for a
            // lossless frame; within tolerance for a lossy one). Emit a tiny 1x1
            // no-op that the decoder composites back to the unchanged canvas.
            //
            // Force lossless AND copy `prev_canvas` (not `target`): a `.lossy`
            // 1x1 would quantize the pixel, and even a lossless 1x1 of `target`
            // would copy a *changed* pixel when the lossy source only matched
            // within tolerance — either way one pixel at (0,0) would flicker and
            // seed later diffs. A lossless 1x1 of the pixel the decoder already
            // holds reproduces it exactly, keeping this a true no-op for both
            // exact-lossless and tolerance-matched-lossy frames.
            rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
            blend = .replace;
            frame_format = .lossless;
            no_op = true;
        } else {
            // A sub-rectangle frame. Snap to even offsets (the container stores
            // them in 2-pixel units), then decide blend vs replace. The
            // blend/transparent path is restricted to lossless: it relies on
            // equal-to-prev pixels reconstructing exactly, which a lossy frame
            // cannot guarantee, so lossy sub-rects are always verbatim replace.
            rect = snapToEvenOffsets(diff, self.canvas);
            if (!lossy and self.blendCandidateExact(target, rect)) {
                blend = .alpha_blend;
                make_transparent = true;
            } else {
                blend = .replace;
            }
            dispose = self.chooseDispose(next, rect, tolerance);
        }

        // Build the cropped sub-frame the per-frame encoder will compress. A
        // no-op copies what the decoder already holds (`prev_canvas`) so it
        // reproduces the unchanged canvas; every other case copies `target`.
        const sub_source = if (no_op) self.prev_canvas else target;
        const sub_pixels = try self.buildSubFrame(sub_source, rect, make_transparent);
        defer self.gpa.free(sub_pixels);

        const source = animation_encode.FrameSource{
            .buffer = .{
                .pixels = sub_pixels,
                .dimensions = try image.Dimensions.init(rect.width, rect.height),
                .stride = rect.width * channels,
                .format = .rgba,
            },
            .x = rect.x,
            .y = rect.y,
            .duration_ms = input.duration_ms,
            .blend_method = blend,
            .dispose_method = dispose,
            .format = frame_format,
        };

        const frame_image = try animation_encode.encodeFrameForOptimizer(
            self.gpa,
            source,
            self.encodeOptionsForFrame(),
        );
        errdefer freeFrameImage(self.gpa, frame_image);

        // Update prev_canvas to exactly what the decoder will hold after this
        // frame: re-decode the bitstream we just produced and composite with the
        // same rules (the lossy-correctness step), then apply this dispose.
        try self.commit(frame_image, rect, blend, dispose, is_keyframe, no_op);

        if (is_keyframe) {
            self.frames_since_keyframe = 0;
        } else {
            self.frames_since_keyframe += 1;
        }
        return frame_image;
    }

    fn encodeOptionsForFrame(self: *const Optimizer) animation_encode.Options {
        return .{
            .canvas = self.canvas,
            .loop_count = self.encode_options.loop_count,
            .background_bgra = self.encode_options.background_bgra,
            .limits = self.encode_options.limits,
            .quality = self.encode_options.quality,
            .method = self.encode_options.method,
            .alpha_quality = self.encode_options.alpha_quality,
        };
    }

    /// The content-change tolerance for a frame of the given codec: 0 (exact)
    /// for lossless, and the configured / quality-derived value for lossy. A
    /// lossless frame must round-trip byte-exactly, so it can never tolerate a
    /// nonzero diff; only lossy frames inherit near-equal pixels.
    fn toleranceFor(self: *const Optimizer, format: features.FormatKind) u8 {
        return switch (format) {
            .lossless => 0,
            .lossy => self.encode_options.tolerance orelse
                qualityToMaxDiff(self.encode_options.quality),
        };
    }

    /// Re-decodes `frame_image`'s bitstream and composites it into `prev_canvas`
    /// (the decoder's reconstruction), and in parallel updates `carryover` (the
    /// source-quality reference) with this frame's `target` content over the same
    /// rect, then applies this frame's dispose to both — leaving each equal to
    /// its respective canvas before the next frame. `no_op` marks the degenerate
    /// 1x1 inherit-the-canvas frame: it composites the held pixel back unchanged
    /// and must NOT overwrite the carryover with this frame's near-equal source.
    fn commit(
        self: *Optimizer,
        frame_image: mux.FrameImage,
        rect: Rect,
        blend: animation.BlendMethod,
        dispose: animation.DisposeMethod,
        is_keyframe: bool,
        no_op: bool,
    ) errors.Error!void {
        var decoded = try decode.decodeImage(self.gpa, .{
            .format = frame_image.format,
            .bitstream = frame_image.bitstream,
            .alpha = frame_image.alpha,
            .dimensions = try image.Dimensions.init(rect.width, rect.height),
        }, .{
            .output_format = .rgba,
            .limits = self.encode_options.limits,
        });
        defer decoded.deinit();

        // Match the decoder: zero RGB of fully-transparent decoded pixels.
        zeroTransparentPixels(decoded.buffer);

        if (is_keyframe) @memset(self.prev_canvas, 0);
        self.composite(rect, blend, is_keyframe, decoded.buffer);

        // Maintain the source-quality carryover alongside the reconstruction:
        // the rect region takes this frame's source pixels (`target`), which is
        // the content the decoder shows there (exactly for replace/keyframe;
        // within tolerance for a lossy rect; equal to prev for a lossless blend).
        // Inherited regions keep their earlier source pixels untouched.
        //
        // A no-op frame leaves the canvas untouched and its synthetic 1x1 copies
        // the held pixel, not `target`; overwriting the carryover with `target`
        // (which differs within tolerance for a lossy no-op) would silently drift
        // the source-quality reference at (0,0). Skip it so the carryover keeps
        // exactly the previous frame's content, matching the unchanged canvas.
        if (!no_op) self.copyTargetIntoCarryover(rect);

        // The previous frame's dispose was applied at its own commit (mirroring
        // the decoder applying it before this frame). Apply this dispose now,
        // for the next frame.
        if (dispose == .background) {
            self.clearRect(self.prev_canvas, rect);
            self.clearRect(self.carryover, rect);
        }

        self.prev = .{ .rect = rect.frameRect(), .dispose = dispose, .was_keyframe = is_keyframe };
    }

    /// Copies the current frame's source `target` pixels into `carryover` over
    /// `rect`, so the carryover reflects the content this frame established (in
    /// source quality) for the next frame's change-rect comparison.
    fn copyTargetIntoCarryover(self: *Optimizer, rect: Rect) void {
        const row_span = @as(usize, rect.width) * channels;
        var y: u32 = 0;
        while (y < rect.height) : (y += 1) {
            const canvas_y = rect.y + y;
            const off = @as(usize, canvas_y) * self.stride + @as(usize, rect.x) * channels;
            @memcpy(self.carryover[off..][0..row_span], self.target[off..][0..row_span]);
        }
    }

    /// Composites a decoded sub-frame onto `prev_canvas`, bit-for-bit matching
    /// `animation_decode.Decoder.composite`.
    fn composite(
        self: *Optimizer,
        rect: Rect,
        blend: animation.BlendMethod,
        is_keyframe: bool,
        decoded: image.Buffer,
    ) void {
        const blend_active = !is_keyframe and blend == .alpha_blend;
        const prev_background = if (self.prev) |prev| prev.dispose == .background else false;
        const prev_rect: ?animation.FrameRect = if (self.prev) |prev| prev.rect else null;

        var y: u32 = 0;
        while (y < rect.height) : (y += 1) {
            const canvas_y = rect.y + y;
            const canvas_row = self.prev_canvas[@as(usize, canvas_y) * self.stride ..];
            const decoded_row = decoded.pixels[@as(usize, y) * decoded.stride ..];
            var x: u32 = 0;
            while (x < rect.width) : (x += 1) {
                const canvas_x = rect.x + x;
                const dst = canvas_row[@as(usize, canvas_x) * channels ..][0..4];
                const src = decoded_row[@as(usize, x) * channels ..][0..4];
                const inside_prev = prev_background and prev_rect != null and
                    pointInRect(canvas_x, canvas_y, prev_rect.?);
                if (blend_active and !inside_prev and src[3] != 255) {
                    blendPixelNonPremult(dst, src);
                } else {
                    @memcpy(dst, src);
                }
            }
        }
    }

    /// Clears `rect` of `canvas` to fully-transparent (RGBA zero), modeling
    /// dispose-to-background. Applied to both `prev_canvas` and `carryover`.
    fn clearRect(self: *Optimizer, canvas: []u8, rect: Rect) void {
        const row_span = @as(usize, rect.width) * channels;
        var y: u32 = 0;
        while (y < rect.height) : (y += 1) {
            const canvas_y = rect.y + y;
            const row = canvas[@as(usize, canvas_y) * self.stride ..];
            @memset(row[@as(usize, rect.x) * channels ..][0..row_span], 0);
        }
    }

    /// Computes the minimal change rectangle between `base` (the source-quality
    /// carryover canvas) and `target` (the desired source canvas), both packed
    /// RGBA at `self.stride`. Mirrors libwebp's `MinimizeChangeRectangle`: a
    /// pixel counts as changed when it is not `pixelsSimilar` within `tolerance`
    /// (0 = exact, for lossless; >0 inherits near-equal pixels, for lossy).
    /// Returns an empty rect when no pixel changed.
    fn changeRect(self: *const Optimizer, base: []const u8, target: []const u8, tolerance: u8) Rect {
        const w = self.canvas.width;
        const h = self.canvas.height;

        var min_x: u32 = w;
        var min_y: u32 = h;
        var max_x: u32 = 0; // exclusive bound built as max index + 1
        var max_y: u32 = 0;

        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const base_row = base[@as(usize, y) * self.stride ..];
            const target_row = target[@as(usize, y) * self.stride ..];
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const off = @as(usize, x) * channels;
                if (!pixelsSimilar(base_row[off..][0..4], target_row[off..][0..4], tolerance)) {
                    if (x < min_x) min_x = x;
                    if (x + 1 > max_x) max_x = x + 1;
                    if (y < min_y) min_y = y;
                    if (y + 1 > max_y) max_y = y + 1;
                }
            }
        }

        if (max_x == 0 or max_y == 0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return .{ .x = min_x, .y = min_y, .width = max_x - min_x, .height = max_y - min_y };
    }

    /// True iff every pixel of `target` inside `rect` can be reconstructed
    /// exactly by an `alpha_blend` frame whose equal-to-prev pixels are made
    /// transparent. Sound subset of libwebp's `IsLosslessBlendingPossible`:
    ///  - a pixel equal to the previous canvas → made transparent → the decoder
    ///    blends a transparent source (no-op) → reproduces prev == target;
    ///  - a changed pixel that is fully opaque → kept verbatim → the decoder
    ///    copies it (alpha-255 path) → reproduces target.
    /// A changed pixel with alpha < 255 would be blended onto prev and not
    /// reproduce target exactly, so it disqualifies blending.
    fn blendCandidateExact(self: *const Optimizer, target: []const u8, rect: Rect) bool {
        var y: u32 = rect.y;
        while (y < rect.y + rect.height) : (y += 1) {
            const prev_row = self.prev_canvas[@as(usize, y) * self.stride ..];
            const target_row = target[@as(usize, y) * self.stride ..];
            var x: u32 = rect.x;
            while (x < rect.x + rect.width) : (x += 1) {
                const off = @as(usize, x) * channels;
                const t = target_row[off..][0..4];
                const p = prev_row[off..][0..4];
                if (std.mem.eql(u8, t, p)) continue; // becomes transparent
                if (t[3] != 255) return false; // changed + non-opaque → unsafe
            }
        }
        return true;
    }

    /// Builds the cropped sub-frame pixels for `rect`: a fresh packed-RGBA
    /// buffer the per-frame encoder compresses. When `make_transparent`, pixels
    /// equal to `prev_canvas` are written fully transparent so the previous
    /// canvas shows through on blend; otherwise target pixels are copied
    /// verbatim. Caller owns the returned slice.
    fn buildSubFrame(
        self: *Optimizer,
        target: []const u8,
        rect: Rect,
        make_transparent: bool,
    ) errors.Error![]u8 {
        const pixel_count = @as(u64, rect.width) * @as(u64, rect.height);
        const byte_count = pixel_count * channels;
        try self.encode_options.limits.validateAllocationBytes(byte_count);
        const pixels = try self.gpa.alloc(u8, @intCast(byte_count));
        errdefer self.gpa.free(pixels);

        const sub_stride = rect.width * channels;
        var y: u32 = 0;
        while (y < rect.height) : (y += 1) {
            const canvas_y = rect.y + y;
            const target_row = target[@as(usize, canvas_y) * self.stride ..];
            const prev_row = self.prev_canvas[@as(usize, canvas_y) * self.stride ..];
            const sub_row = pixels[@as(usize, y) * sub_stride ..];
            var x: u32 = 0;
            while (x < rect.width) : (x += 1) {
                const canvas_x = rect.x + x;
                const t = target_row[@as(usize, canvas_x) * channels ..][0..4];
                const dst = sub_row[@as(usize, x) * channels ..][0..4];
                if (make_transparent) {
                    const p = prev_row[@as(usize, canvas_x) * channels ..][0..4];
                    if (std.mem.eql(u8, t, p)) {
                        @memset(dst, 0); // transparent → prev shows through
                        continue;
                    }
                }
                @memcpy(dst, t);
            }
        }
        return pixels;
    }

    /// One-frame dispose lookahead. Returns `.background` when clearing this
    /// frame's rect would give the *next* frame a strictly smaller change rect
    /// than leaving the canvas intact; otherwise `.none`. Correct regardless,
    /// because `commit` re-tracks the canvas with whatever dispose we return.
    ///
    /// The lookahead compares against `target` (the canvas this frame produces,
    /// which by construction it reproduces) — not the not-yet-known decoded
    /// canvas — so it never reads `prev_canvas` after `commit`. With dispose
    /// none the after-canvas is `target`; with dispose background it is `target`
    /// with `rect` cleared.
    fn chooseDispose(
        self: *const Optimizer,
        next: ?FrameInput,
        rect: Rect,
        tolerance: u8,
    ) animation.DisposeMethod {
        const next_input = next orelse return .none;
        const next_buffer = next_input.buffer;
        // The next frame will detect its own rect with its own codec's
        // tolerance; use the larger of this frame's and the next frame's so the
        // lookahead estimate matches whichever diff that frame actually runs.
        const next_tolerance = @max(tolerance, self.toleranceFor(next_input.format));
        const none_area = self.lookaheadDiffArea(self.target, next_buffer, null, next_tolerance);
        const bg_area = self.lookaheadDiffArea(self.target, next_buffer, rect, next_tolerance);
        return if (bg_area < none_area) .background else .none;
    }

    /// Change-rect area between the canvas-after-this-frame (`after_canvas`) and
    /// the next frame's desired canvas. `clear`, if set, treats that rectangle
    /// of the after-canvas as transparent (modeling dispose-to-background).
    /// `tolerance` matches the next frame's content-change criterion. Returns
    /// only the area, for comparing dispose choices.
    fn lookaheadDiffArea(
        self: *const Optimizer,
        after_canvas: []const u8,
        next_buffer: image.Buffer,
        clear: ?Rect,
        tolerance: u8,
    ) u64 {
        const w = self.canvas.width;
        const h = self.canvas.height;
        var min_x: u32 = w;
        var min_y: u32 = h;
        var max_x: u32 = 0;
        var max_y: u32 = 0;
        const transparent = [_]u8{ 0, 0, 0, 0 };

        var y: u32 = 0;
        while (y < h) : (y += 1) {
            const after_row = after_canvas[@as(usize, y) * self.stride ..];
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const off = @as(usize, x) * channels;
                const cleared = clear != null and pointInRect(x, y, clear.?.frameRect());
                const after_pixel = if (cleared) transparent[0..4] else after_row[off..][0..4];
                var next_pixel: [4]u8 = undefined;
                gatherPixelRgba(next_buffer, x, y, &next_pixel);
                // The next canvas is also gathered with transparent-RGB zeroing.
                if (next_pixel[3] == 0) next_pixel = transparent;
                if (!pixelsSimilar(after_pixel, next_pixel[0..4], tolerance)) {
                    if (x < min_x) min_x = x;
                    if (x + 1 > max_x) max_x = x + 1;
                    if (y < min_y) min_y = y;
                    if (y + 1 > max_y) max_y = y + 1;
                }
            }
        }
        if (max_x == 0 or max_y == 0) return 0;
        return @as(u64, max_x - min_x) * @as(u64, max_y - min_y);
    }
};

fn addBytes(acc: u64, add: u64) errors.Error!u64 {
    return std.math.add(u64, acc, add) catch error.AllocationLimitExceeded;
}

/// Maps a 0..100 quality to a per-channel content-change tolerance, matching
/// libwebp's `QualityToMaxDiff` (`max_diff = 31*(1-sqrt(q/100)) + 1*sqrt(q/100)`,
/// rounded): 31 at q=0, ~5 at q=75, 1 at q=100. A higher quality demands a
/// tighter match before a pixel is treated as unchanged.
pub fn qualityToMaxDiff(quality: u8) u8 {
    const q = @as(f64, @floatFromInt(@min(quality, 100)));
    const val = std.math.sqrt(q / 100.0);
    const max_diff = 31.0 * (1.0 - val) + 1.0 * val;
    return @intFromFloat(max_diff + 0.5);
}

/// True when two packed-RGBA pixels are within `tolerance` per channel. With
/// `tolerance == 0` this is exact equality (the lossless criterion). Otherwise
/// it mirrors libwebp's `PixelsAreSimilar`: alpha must match exactly, and each
/// RGB channel's absolute difference, weighted by the destination alpha, must be
/// at most `tolerance * 255` — so a fully transparent target ignores RGB and a
/// fully opaque one requires `|diff| <= tolerance`.
fn pixelsSimilar(a: *const [4]u8, b: *const [4]u8, tolerance: u8) bool {
    if (tolerance == 0) return std.mem.eql(u8, a, b);
    if (a[3] != b[3]) return false;
    const dst_alpha: u32 = b[3];
    const bound: u32 = @as(u32, tolerance) * 255;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const diff: u32 = @abs(@as(i32, a[i]) - @as(i32, b[i]));
        if (diff * dst_alpha > bound) return false;
    }
    return true;
}

/// Snaps a change rect to even x/y offsets (the container stores offsets in
/// 2-pixel units), growing width/height to keep the original area covered, and
/// clamping to the canvas. Mirrors libwebp's `SnapToEvenOffsets`.
fn snapToEvenOffsets(rect: Rect, canvas: image.Dimensions) Rect {
    var out = rect;
    out.width += (out.x & 1);
    out.height += (out.y & 1);
    out.x &= ~@as(u32, 1);
    out.y &= ~@as(u32, 1);
    // Snapping cannot push the rect past the canvas, but clamp defensively.
    if (out.x + out.width > canvas.width) out.width = canvas.width - out.x;
    if (out.y + out.height > canvas.height) out.height = canvas.height - out.y;
    return out;
}

fn pointInRect(x: u32, y: u32, rect: animation.FrameRect) bool {
    return x >= rect.x and x < rect.x + rect.width and
        y >= rect.y and y < rect.y + rect.height;
}

/// Gathers a full canvas buffer into packed RGBA at `stride`, zeroing the RGB of
/// fully-transparent pixels to match the decoder's reconstructed canvas model.
fn gatherCanvasRgba(buffer: image.Buffer, out: []u8, stride: u32) void {
    const w = buffer.dimensions.width;
    const h = buffer.dimensions.height;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const out_row = out[@as(usize, y) * stride ..];
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            var pixel: [4]u8 = undefined;
            gatherPixelRgba(buffer, x, y, &pixel);
            const dst = out_row[@as(usize, x) * channels ..][0..4];
            if (pixel[3] == 0) {
                @memset(dst, 0);
            } else {
                @memcpy(dst, pixel[0..4]);
            }
        }
    }
}

/// Reads pixel (x, y) of any supported `image.Buffer` as RGBA into `out`.
fn gatherPixelRgba(buffer: image.Buffer, x: u32, y: u32, out: *[4]u8) void {
    const row = buffer.pixels[@as(usize, y) * buffer.stride ..];
    const ch = buffer.format.channelCount();
    const sample = row[@as(usize, x) * ch ..];
    switch (buffer.format) {
        .rgba => out.* = .{ sample[0], sample[1], sample[2], sample[3] },
        .bgra => out.* = .{ sample[2], sample[1], sample[0], sample[3] },
        .argb => out.* = .{ sample[1], sample[2], sample[3], sample[0] },
        .rgb => out.* = .{ sample[0], sample[1], sample[2], 255 },
    }
}

/// Zeroes the RGB of fully-transparent pixels in a decoded buffer, matching
/// `animation_decode.zeroTransparentPixels`.
fn zeroTransparentPixels(buffer: image.Buffer) void {
    const w = buffer.dimensions.width;
    var y: u32 = 0;
    while (y < buffer.dimensions.height) : (y += 1) {
        const row = buffer.pixels[@as(usize, y) * buffer.stride ..];
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const pixel = row[@as(usize, x) * channels ..][0..4];
            if (pixel[3] == 0) @memset(pixel, 0);
        }
    }
}

/// Source-over non-premultiplied blend, bit-for-bit identical to
/// `animation_decode.blendPixelNonPremult` (RGBA alpha offset 3).
fn blendPixelNonPremult(dst: []u8, src: []const u8) void {
    const src_a: u32 = src[3];
    if (src_a == 0) return;
    const dst_a: u32 = dst[3];
    const dst_factor_a: u32 = (dst_a * (256 - src_a)) >> 8;
    const blend_a: u32 = src_a + dst_factor_a;
    assert(blend_a > 0 and blend_a < 256);
    const scale: u32 = (@as(u32, 1) << 24) / blend_a;
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        const blend_unscaled: u64 = @as(u32, src[i]) * src_a + @as(u32, dst[i]) * dst_factor_a;
        dst[i] = @intCast((blend_unscaled * scale) >> 24);
    }
    dst[3] = @intCast(blend_a);
}

// --- Tests ------------------------------------------------------------------

const testing = std.testing;
const animation_decode = @import("animation_decode.zig");
const demux = @import("demux.zig");
const metrics = @import("testing/metrics.zig");

fn rgbaBuffer(pixels: []u8, width: u32, height: u32) errors.Error!image.Buffer {
    return .{
        .pixels = pixels,
        .dimensions = try image.Dimensions.init(width, height),
        .stride = width * channels,
        .format = .rgba,
    };
}

fn fillConstant(pixels: []u8, color_rgba: [4]u8) void {
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        pixels[i + 0] = color_rgba[0];
        pixels[i + 1] = color_rgba[1];
        pixels[i + 2] = color_rgba[2];
        pixels[i + 3] = color_rgba[3];
    }
}

fn paintSquare(pixels: []u8, canvas_w: u32, x0: u32, y0: u32, sw: u32, sh: u32, color: [4]u8) void {
    var y: u32 = 0;
    while (y < sh) : (y += 1) {
        var x: u32 = 0;
        while (x < sw) : (x += 1) {
            const base = ((y0 + y) * canvas_w + (x0 + x)) * 4;
            pixels[base + 0] = color[0];
            pixels[base + 1] = color[1];
            pixels[base + 2] = color[2];
            pixels[base + 3] = color[3];
        }
    }
}

/// Decodes `encoded` and asserts every composited frame equals the matching
/// full-canvas source byte-for-byte (the all-lossless CI gate).
fn expectByteExactRoundTrip(
    gpa: std.mem.Allocator,
    encoded: []const u8,
    sources: []const []const u8,
) !void {
    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();
    try testing.expectEqual(sources.len, animated.frames.len);
    for (sources, 0..) |source, index| {
        try testing.expectEqualSlices(u8, source, animated.frames[index].buffer.pixels);
    }
}

test "static background with a small moving opaque sub-region round-trips and shrinks" {
    const gpa = testing.allocator;
    const w = 16;
    const h = 12;

    var bg: [w * h * 4]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            const base = (y * w + x) * 4;
            bg[base + 0] = @intCast((x * 13) % 256);
            bg[base + 1] = @intCast((y * 17) % 256);
            bg[base + 2] = @intCast(((x + y) * 7) % 256);
            bg[base + 3] = 255;
        }
    }

    var f1 = bg;
    var f2 = bg;
    paintSquare(&f1, w, 4, 4, 4, 4, .{ 255, 255, 255, 255 });
    paintSquare(&f2, w, 8, 6, 4, 4, .{ 0, 0, 0, 255 });

    const frames = [_]FrameInput{
        .{ .buffer = try rgbaBuffer(&bg, w, h), .duration_ms = 100, .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f1, w, h), .duration_ms = 100, .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f2, w, h), .duration_ms = 100, .format = .lossless },
    };

    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
    });
    defer gpa.free(encoded);

    try expectByteExactRoundTrip(gpa, encoded, &.{ &bg, &f1, &f2 });

    // At least one ANMF rect must be smaller than the canvas (sub-rect shrink).
    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 3), parsed.frames.len);
    var any_shrunk = false;
    for (parsed.frames) |frame| {
        if (frame.rect.width < w or frame.rect.height < h) any_shrunk = true;
    }
    try testing.expect(any_shrunk);
    // Frame 0 is a full-canvas keyframe.
    try testing.expectEqual(@as(u32, w), parsed.frames[0].rect.width);
    try testing.expectEqual(@as(u32, h), parsed.frames[0].rect.height);
}

test "a frame identical to the previous degenerates to a tiny rect and round-trips" {
    const gpa = testing.allocator;
    const w = 8;
    const h = 8;
    var f0: [w * h * 4]u8 = undefined;
    fillConstant(&f0, .{ 10, 120, 200, 255 });
    var f1 = f0; // identical

    const frames = [_]FrameInput{
        .{ .buffer = try rgbaBuffer(&f0, w, h), .duration_ms = 50, .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f1, w, h), .duration_ms = 50, .format = .lossless },
    };
    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
    });
    defer gpa.free(encoded);

    try expectByteExactRoundTrip(gpa, encoded, &.{ &f0, &f1 });

    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 1), parsed.frames[1].rect.width);
    try testing.expectEqual(@as(u32, 1), parsed.frames[1].rect.height);
}

test "an unchanged lossy frame stays a byte-exact no-op (no 1px drift)" {
    const gpa = testing.allocator;
    const w = 8;
    const h = 8;
    // Frame 0 is a lossless keyframe, so the decoder's reconstructed canvas
    // equals the source exactly. Frame 1 is identical content but declared
    // `.lossy`, so the optimizer's diff is empty and it emits a synthetic 1x1
    // no-op rect. That rect MUST be forced lossless: a `.lossy` 1x1 would
    // quantize the pixel, and the decoder would copy a *changed* pixel onto the
    // otherwise-unchanged canvas — flickering one pixel. With the fix the 1x1 is
    // lossless, so frame 1 decodes byte-identical to frame 0 (no drift).
    var f0: [w * h * 4]u8 = undefined;
    fillConstant(&f0, .{ 37, 211, 83, 255 });
    var f1 = f0; // identical content, but encoded as `.lossy`

    const frames = [_]FrameInput{
        .{ .buffer = try rgbaBuffer(&f0, w, h), .duration_ms = 40, .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f1, w, h), .duration_ms = 40, .format = .lossy },
    };
    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
    });
    defer gpa.free(encoded);

    // Both decoded frames must equal the source byte-for-byte; in particular
    // frame 1 must match frame 0 (no single-pixel quantization drift).
    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();
    try testing.expectEqual(@as(usize, 2), animated.frames.len);
    try testing.expectEqualSlices(u8, &f0, animated.frames[0].buffer.pixels);
    try testing.expectEqualSlices(u8, &f1, animated.frames[1].buffer.pixels);
    try testing.expectEqualSlices(u8, animated.frames[0].buffer.pixels, animated.frames[1].buffer.pixels);

    // The no-op frame still degenerates to a 1x1 rect.
    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 1), parsed.frames[1].rect.width);
    try testing.expectEqual(@as(u32, 1), parsed.frames[1].rect.height);
}

test "a lossless frame after a lossy frame diffs the reconstructed canvas (byte-exact)" {
    // Finding 1 regression: frame 0 is `.lossy`, so the decoder's reconstructed
    // canvas (`prev_canvas`) drifts from the source (VP8 is approximate) while
    // the source-quality `carryover` still holds the exact frame-0 source. Frame
    // 1 is `.lossless` with the SAME source content as frame 0. Diffing frame 1
    // against `carryover` (the old bug) sees no change and emits a 1x1 no-op,
    // leaving frame 0's lossy artifacts visible across the rest of the canvas, so
    // frame 1 decodes to the lossy reconstruction — NOT its exact source. The fix
    // diffs a lossless frame against `prev_canvas`, re-emitting every pixel where
    // the reconstruction drifted, so frame 1 is byte-exact to its source.
    const gpa = testing.allocator;
    const w = 16;
    const h = 16;

    // A textured frame so VP8 lossy actually introduces per-pixel error.
    var f0: [w * h * 4]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            const base = (y * w + x) * 4;
            f0[base + 0] = @intCast((x * 11 + y * 5) % 256);
            f0[base + 1] = @intCast((y * 9 + x * 3) % 256);
            f0[base + 2] = @intCast((x * 7 + y * 13 + 20) % 256);
            f0[base + 3] = 255;
        }
    }
    var f1 = f0; // identical source content, but emitted as `.lossless`

    const frames = [_]FrameInput{
        .{ .buffer = try rgbaBuffer(&f0, w, h), .duration_ms = 60, .format = .lossy },
        .{ .buffer = try rgbaBuffer(&f1, w, h), .duration_ms = 60, .format = .lossless },
    };
    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
        .quality = 75,
    });
    defer gpa.free(encoded);

    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();
    try testing.expectEqual(@as(usize, 2), animated.frames.len);
    // The lossless frame must reproduce its source EXACTLY, regardless of the
    // lossy artifacts left on the reconstructed canvas by frame 0.
    try testing.expectEqualSlices(u8, &f1, animated.frames[1].buffer.pixels);
}

test "a tolerance-matched lossy no-op preserves the inherited canvas (no 0,0 drift)" {
    // Finding 2 regression: frame 0 is a lossless keyframe (exact reconstruction).
    // Frame 1 is `.lossy` with content that differs from frame 0 by less than the
    // q=75 tolerance (~5) on every pixel, so the tolerance diff against the
    // carryover is EMPTY and frame 1 enters the degenerate 1x1 no-op branch. The
    // old behavior copied frame 1's own source pixel at (0,0); since that pixel
    // differs from the inherited canvas (frame 0) by a few levels, the decoder
    // composited a *changed* pixel at (0,0) — a one-pixel drift. The fix copies
    // the pixel the decoder already holds (`prev_canvas`), so the no-op leaves the
    // canvas byte-identical to frame 0, including (0,0).
    const gpa = testing.allocator;
    const w = 8;
    const h = 8;
    var f0: [w * h * 4]u8 = undefined;
    fillConstant(&f0, .{ 120, 130, 140, 255 });
    var f1 = f0;
    // Shift every channel by +3 (<= the q=75 tolerance of 5): within tolerance,
    // so the rect diff is empty, but NOT byte-equal, so a naive 1x1-of-target
    // would drift (0,0).
    var i: usize = 0;
    while (i < f1.len) : (i += 4) {
        f1[i + 0] +%= 3;
        f1[i + 1] +%= 3;
        f1[i + 2] +%= 3;
    }

    const frames = [_]FrameInput{
        .{ .buffer = try rgbaBuffer(&f0, w, h), .duration_ms = 40, .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f1, w, h), .duration_ms = 40, .format = .lossy },
    };
    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
        .quality = 75,
    });
    defer gpa.free(encoded);

    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();
    try testing.expectEqual(@as(usize, 2), animated.frames.len);
    // The tolerance-matched no-op must inherit frame 0 exactly, with no drift at
    // (0,0): decoded frame 1 == decoded frame 0 == frame 0 source, byte-for-byte.
    try testing.expectEqualSlices(u8, &f0, animated.frames[0].buffer.pixels);
    try testing.expectEqualSlices(u8, &f0, animated.frames[1].buffer.pixels);
    try testing.expectEqualSlices(u8, animated.frames[0].buffer.pixels, animated.frames[1].buffer.pixels);

    // It still degenerates to a 1x1 rect (the no-op stayed tiny).
    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, 1), parsed.frames[1].rect.width);
    try testing.expectEqual(@as(u32, 1), parsed.frames[1].rect.height);
}

test "a full-canvas change forces a keyframe and round-trips" {
    const gpa = testing.allocator;
    const w = 8;
    const h = 8;
    var f0: [w * h * 4]u8 = undefined;
    var f1: [w * h * 4]u8 = undefined;
    fillConstant(&f0, .{ 200, 30, 30, 255 });
    fillConstant(&f1, .{ 30, 200, 30, 255 }); // every pixel changes

    const frames = [_]FrameInput{
        .{ .buffer = try rgbaBuffer(&f0, w, h), .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f1, w, h), .format = .lossless },
    };
    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
    });
    defer gpa.free(encoded);

    try expectByteExactRoundTrip(gpa, encoded, &.{ &f0, &f1 });

    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(u32, w), parsed.frames[1].rect.width);
    try testing.expectEqual(@as(u32, h), parsed.frames[1].rect.height);
    try testing.expectEqual(animation.BlendMethod.replace, parsed.frames[1].blend_method);
}

test "an opaque sub-region over an opaque background round-trips byte-for-byte" {
    const gpa = testing.allocator;
    const w = 8;
    const h = 8;

    var f0: [w * h * 4]u8 = undefined;
    fillConstant(&f0, .{ 90, 90, 90, 255 });
    var f1 = f0;
    for (0..4) |y| {
        for (0..4) |x| {
            const base = (y * w + x) * 4;
            f1[base + 0] = @intCast(x * 60);
            f1[base + 1] = @intCast(y * 60);
            f1[base + 2] = 200;
            f1[base + 3] = 255;
        }
    }

    const frames = [_]FrameInput{
        .{ .buffer = try rgbaBuffer(&f0, w, h), .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f1, w, h), .format = .lossless },
    };
    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
    });
    defer gpa.free(encoded);

    try expectByteExactRoundTrip(gpa, encoded, &.{ &f0, &f1 });
}

test "a frame that reveals transparency where prev was opaque round-trips" {
    const gpa = testing.allocator;
    const w = 8;
    const h = 8;

    // f0 fully opaque. f1 makes a sub-region fully transparent (RGB zeroed).
    // A blend frame cannot reproduce transparent-over-opaque, so the optimizer
    // must fall back to a verbatim replace sub-rect; the round-trip stays exact.
    var f0: [w * h * 4]u8 = undefined;
    fillConstant(&f0, .{ 50, 150, 250, 255 });
    var f1 = f0;
    paintSquare(&f1, w, 2, 2, 4, 4, .{ 0, 0, 0, 0 });

    const frames = [_]FrameInput{
        .{ .buffer = try rgbaBuffer(&f0, w, h), .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f1, w, h), .format = .lossless },
    };
    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
    });
    defer gpa.free(encoded);

    try expectByteExactRoundTrip(gpa, encoded, &.{ &f0, &f1 });

    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    try testing.expectEqual(animation.BlendMethod.replace, parsed.frames[1].blend_method);
    try testing.expect(parsed.frames[1].rect.width < w or parsed.frames[1].rect.height < h);
}

test "a multi-frame sequence exercising blend and dispose round-trips" {
    const gpa = testing.allocator;
    const w = 12;
    const h = 12;

    var bg: [w * h * 4]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            const base = (y * w + x) * 4;
            bg[base + 0] = @intCast((x * 9 + 3) % 256);
            bg[base + 1] = @intCast((y * 11 + 7) % 256);
            bg[base + 2] = @intCast(((x ^ y) * 5) % 256);
            bg[base + 3] = 255;
        }
    }
    var f1 = bg;
    var f2 = bg;
    var f3 = bg; // back to bare background
    paintSquare(&f1, w, 2, 2, 4, 4, .{ 255, 0, 0, 255 });
    paintSquare(&f2, w, 6, 6, 4, 4, .{ 0, 255, 0, 255 });

    const frames = [_]FrameInput{
        .{ .buffer = try rgbaBuffer(&bg, w, h), .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f1, w, h), .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f2, w, h), .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f3, w, h), .format = .lossless },
    };
    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
    });
    defer gpa.free(encoded);

    try expectByteExactRoundTrip(gpa, encoded, &.{ &bg, &f1, &f2, &f3 });
}

test "the keyframe interval forces periodic full-canvas frames" {
    const gpa = testing.allocator;
    const w = 8;
    const h = 8;

    var buffers: [6][w * h * 4]u8 = undefined;
    var base: [w * h * 4]u8 = undefined;
    fillConstant(&base, .{ 20, 40, 60, 255 });
    for (0..6) |i| {
        buffers[i] = base;
        paintSquare(&buffers[i], w, @intCast((i % 3) * 2), 0, 2, 2, .{ @intCast(i * 30), 0, 0, 255 });
    }

    var frames: [6]FrameInput = undefined;
    for (0..6) |i| {
        frames[i] = .{ .buffer = try rgbaBuffer(&buffers[i], w, h), .format = .lossless };
    }
    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
        .keyframe_interval = 2,
    });
    defer gpa.free(encoded);

    var sources: [6][]const u8 = undefined;
    for (0..6) |i| sources[i] = &buffers[i];
    try expectByteExactRoundTrip(gpa, encoded, &sources);

    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    // Frames 0, 2, 4 are full-canvas keyframes (interval 2).
    for ([_]usize{ 0, 2, 4 }) |i| {
        try testing.expectEqual(@as(u32, w), parsed.frames[i].rect.width);
        try testing.expectEqual(@as(u32, h), parsed.frames[i].rect.height);
        try testing.expectEqual(animation.BlendMethod.replace, parsed.frames[i].blend_method);
    }
}

test "a lossy minimized animation decodes at the canvas dimensions" {
    const gpa = testing.allocator;
    const w = 16;
    const h = 16;

    var f0: [w * h * 4]u8 = undefined;
    var f1: [w * h * 4]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            const base = (y * w + x) * 4;
            f0[base + 0] = @intCast((x * 16) % 256);
            f0[base + 1] = @intCast((y * 16) % 256);
            f0[base + 2] = 100;
            f0[base + 3] = 255;
            f1[base + 0] = @intCast((x * 16) % 256);
            f1[base + 1] = @intCast((y * 16) % 256);
            f1[base + 2] = if (x >= 4 and x < 12 and y >= 4 and y < 12) 200 else 100;
            f1[base + 3] = 255;
        }
    }

    const frames = [_]FrameInput{
        .{ .buffer = try rgbaBuffer(&f0, w, h), .format = .lossy },
        .{ .buffer = try rgbaBuffer(&f1, w, h), .format = .lossy },
    };
    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
        .quality = 80,
    });
    defer gpa.free(encoded);

    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();
    try testing.expectEqual(@as(usize, 2), animated.frames.len);
    for (animated.frames) |frame| {
        try testing.expectEqual(@as(u32, w), frame.buffer.dimensions.width);
        try testing.expectEqual(@as(u32, h), frame.buffer.dimensions.height);
    }
}

test "rejects an empty frame list" {
    try testing.expectError(error.MissingImageData, encodeAnimationMinimized(
        testing.allocator,
        &.{},
        .{ .canvas = try image.Dimensions.init(2, 2) },
    ));
}

test "rejects an input frame whose dimensions disagree with the canvas" {
    const gpa = testing.allocator;
    var pixels: [2 * 2 * 4]u8 = undefined;
    fillConstant(&pixels, .{ 1, 2, 3, 255 });
    const frames = [_]FrameInput{.{ .buffer = try rgbaBuffer(&pixels, 2, 2), .format = .lossless }};
    try testing.expectError(error.InvalidCanvasSize, encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(4, 4),
    }));
}

fn minimizedAllocationProbe(gpa: std.mem.Allocator, frames: []const FrameInput) !void {
    const encoded = try encodeAnimationMinimized(gpa, frames, .{
        .canvas = image.Dimensions.init(8, 8) catch unreachable,
        .keyframe_interval = 4,
    });
    gpa.free(encoded);
}

test "minimized encode survives allocation failure at every site" {
    const gpa = testing.allocator;
    const w = 8;
    const h = 8;
    var f0: [w * h * 4]u8 = undefined;
    var f1: [w * h * 4]u8 = undefined;
    fillConstant(&f0, .{ 30, 60, 90, 255 });
    f1 = f0;
    paintSquare(&f1, w, 2, 2, 4, 4, .{ 200, 200, 200, 255 });

    const frames = [_]FrameInput{
        .{ .buffer = try rgbaBuffer(&f0, w, h), .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f1, w, h), .format = .lossy },
    };
    try testing.checkAllAllocationFailures(gpa, minimizedAllocationProbe, .{@as([]const FrameInput, &frames)});
}

test "qualityToMaxDiff matches libwebp's QualityToMaxDiff at reference points" {
    // 31*(1-sqrt(q/100)) + 1*sqrt(q/100), rounded — libwebp's table.
    try testing.expectEqual(@as(u8, 31), qualityToMaxDiff(0));
    try testing.expectEqual(@as(u8, 10), qualityToMaxDiff(50));
    try testing.expectEqual(@as(u8, 5), qualityToMaxDiff(75));
    try testing.expectEqual(@as(u8, 4), qualityToMaxDiff(80));
    try testing.expectEqual(@as(u8, 1), qualityToMaxDiff(100));
}

test "pixelsSimilar is exact at tolerance 0 and alpha-weighted above it" {
    const a = [_]u8{ 100, 100, 100, 255 };
    const b = [_]u8{ 103, 100, 100, 255 }; // R off by 3
    // Exact compare: a difference of 3 is "changed".
    try testing.expect(!pixelsSimilar(&a, &b, 0));
    // Tolerance 5 on a fully-opaque pixel admits |diff| <= 5.
    try testing.expect(pixelsSimilar(&a, &b, 5));
    try testing.expect(!pixelsSimilar(&a, &.{ 110, 100, 100, 255 }, 5)); // off by 10
    // Alpha must match exactly even within tolerance.
    try testing.expect(!pixelsSimilar(&a, &.{ 100, 100, 100, 254 }, 5));
    // A fully-transparent destination ignores RGB (dst_alpha == 0).
    try testing.expect(pixelsSimilar(&.{ 9, 9, 9, 0 }, &.{ 250, 250, 250, 0 }, 1));
}

/// Builds a `frame_count`-frame moving-region animation: a fixed textured
/// background with an opaque square that slides diagonally across the canvas.
/// Each frame is a freshly allocated full-canvas RGBA buffer the caller frees.
fn buildMovingRegionFrames(
    gpa: std.mem.Allocator,
    w: u32,
    h: u32,
    frame_count: u32,
    square: u32,
) ![]const []u8 {
    const buffers = try gpa.alloc([]u8, frame_count);
    var built: usize = 0;
    errdefer {
        for (buffers[0..built]) |b| gpa.free(b);
        gpa.free(buffers);
    }
    var i: u32 = 0;
    while (i < frame_count) : (i += 1) {
        const buf = try gpa.alloc(u8, @as(usize, w) * h * 4);
        built += 1;
        // Smoothly varying textured background (good lossy target).
        var y: u32 = 0;
        while (y < h) : (y += 1) {
            var x: u32 = 0;
            while (x < w) : (x += 1) {
                const base = (@as(usize, y) * w + x) * 4;
                buf[base + 0] = @intCast((x * 4 + y * 2) % 256);
                buf[base + 1] = @intCast((y * 4 + x) % 256);
                buf[base + 2] = @intCast((x * 2 + y * 3 + 40) % 256);
                buf[base + 3] = 255;
            }
        }
        // The moving opaque square (even offsets so the rect needs no snapping).
        const sx = (i * 2) % (w - square);
        const sy = (i * 2) % (h - square);
        paintSquare(buf, w, sx & ~@as(u32, 1), sy & ~@as(u32, 1), square, square, .{ 240, 30, 30, 255 });
        buffers[i] = buf;
    }
    return buffers;
}

fn freeFrameBuffers(gpa: std.mem.Allocator, buffers: []const []u8) void {
    for (buffers) |b| gpa.free(b);
    gpa.free(@constCast(buffers));
}

test "a lossy moving-region animation shrinks at least one ANMF rect and decodes valid" {
    const gpa = testing.allocator;
    const w = 64;
    const h = 48;
    const frame_count = 5;

    const buffers = try buildMovingRegionFrames(gpa, w, h, frame_count, 16);
    defer freeFrameBuffers(gpa, buffers);

    var frames: [frame_count]FrameInput = undefined;
    for (buffers, 0..) |buf, idx| {
        frames[idx] = .{ .buffer = try rgbaBuffer(buf, w, h), .duration_ms = 100, .format = .lossy };
    }

    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
        .quality = 75,
        .keyframe_interval = 16,
    });
    defer gpa.free(encoded);

    // Decodes without error at the canvas dimensions for every frame.
    var animated = try animation_decode.decodeAnimationAlloc(gpa, encoded, .{});
    defer animated.deinit();
    try testing.expectEqual(@as(usize, frame_count), animated.frames.len);
    for (animated.frames) |frame| {
        try testing.expectEqual(@as(u32, w), frame.buffer.dimensions.width);
        try testing.expectEqual(@as(u32, h), frame.buffer.dimensions.height);
    }

    // At least one ANMF rect must be smaller than the canvas — the whole point
    // of lossy inter-frame optimization (9c emitted only full-canvas keyframes).
    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    var any_shrunk = false;
    for (parsed.frames) |frame| {
        if (frame.rect.width < w or frame.rect.height < h) any_shrunk = true;
    }
    try testing.expect(any_shrunk);
}

test "lossy minimized PSNR stays within tolerance of the naive full-canvas encode" {
    const gpa = testing.allocator;
    const w = 64;
    const h = 48;
    const frame_count = 6;

    const buffers = try buildMovingRegionFrames(gpa, w, h, frame_count, 16);
    defer freeFrameBuffers(gpa, buffers);

    // Optimized (minimized) encode.
    var min_frames: [frame_count]FrameInput = undefined;
    for (buffers, 0..) |buf, idx| {
        min_frames[idx] = .{ .buffer = try rgbaBuffer(buf, w, h), .duration_ms = 100, .format = .lossy };
    }
    const minimized = try encodeAnimationMinimized(gpa, &min_frames, .{
        .canvas = try image.Dimensions.init(w, h),
        .quality = 75,
    });
    defer gpa.free(minimized);

    // Naive: every frame a full-canvas lossy replace keyframe (9b API), the
    // baseline the optimizer must not meaningfully degrade against.
    var naive_sources: [frame_count]animation_encode.FrameSource = undefined;
    for (buffers, 0..) |buf, idx| {
        naive_sources[idx] = .{
            .buffer = try rgbaBuffer(buf, w, h),
            .duration_ms = 100,
            .blend_method = .replace,
            .format = .lossy,
        };
    }
    const naive = try animation_encode.encodeAnimationFromBuffers(gpa, &naive_sources, .{
        .canvas = try image.Dimensions.init(w, h),
        .quality = 75,
    });
    defer gpa.free(naive);

    // Mean per-frame luma PSNR of each encode vs the SOURCE frames.
    var min_dec = try animation_decode.decodeAnimationAlloc(gpa, minimized, .{});
    defer min_dec.deinit();
    var naive_dec = try animation_decode.decodeAnimationAlloc(gpa, naive, .{});
    defer naive_dec.deinit();
    try testing.expectEqual(@as(usize, frame_count), min_dec.frames.len);
    try testing.expectEqual(@as(usize, frame_count), naive_dec.frames.len);

    var min_sum: f64 = 0;
    var naive_sum: f64 = 0;
    for (buffers, 0..) |src, idx| {
        min_sum += metrics.psnrLuma(src, min_dec.frames[idx].buffer.pixels, channels);
        naive_sum += metrics.psnrLuma(src, naive_dec.frames[idx].buffer.pixels, channels);
    }
    const min_mean = min_sum / @as(f64, frame_count);
    const naive_mean = naive_sum / @as(f64, frame_count);

    // Tolerance: optimized mean luma PSNR must be at most 0.5 dB below naive.
    // Inherited (non-rect) regions carry the previous frame's lossy values
    // rather than this frame's, so a small drop is expected and bounded.
    try testing.expect(min_mean >= naive_mean - 0.5);

    // The optimized stream must actually be smaller (the win).
    try testing.expect(minimized.len < naive.len);
}
