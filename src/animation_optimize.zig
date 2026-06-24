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
//!    rectangle shrinks the next frame's diff rect (one-frame lookahead). This
//!    applies to keyframes / full-canvas frames too: a keyframe followed by a
//!    mostly-transparent or small-object frame can clear the whole canvas so the
//!    next frame's rect is tiny. The optimizer tracks the canvas exactly as the
//!    decoder will — including the dispose it chose — so any dispose choice stays
//!    byte-exact.
//!  - **keyframe insertion:** frame 0 is a full-canvas `replace` keyframe;
//!    further keyframes are forced when the diff rect is the whole canvas or a
//!    bounded interval elapses, keeping frames independent enough to seek.
//!
//! THE correctness invariant: the optimized output, decoded via
//! `animation_decode.decodeAnimationAlloc`, reproduces the input canvases. For
//! all-lossless input this is byte-exact (the CI gate). The optimizer never
//! diffs against the *source* canvas — it tracks the decoder's *reconstructed*
//! canvas (re-decoding each frame it encodes and compositing with the exact
//! `animation_decode` rules), so lossy reconstruction error never accumulates.

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
};

/// Upper bound on `keyframe_interval`, so a hostile option cannot defer
/// keyframes unboundedly. 4096 matches `ResourceLimits.frame_count_max`.
pub const keyframe_interval_max: u32 = 4096;

const channels = 4;

/// Encodes a sequence of full-canvas frames into a minimized animated WebP: the
/// optimizer derives sub-rectangles, blend/dispose methods, and keyframes that
/// composite back to exactly the input canvases, then reuses the slice-9b
/// per-frame encoder and `mux.encodeAnimation`. The output round-trips through
/// `decodeAnimation` (byte-exact for all-lossless input, after transparent-RGB
/// canonicalization: fully-transparent pixels are normalized to `0,0,0,0` to
/// match libwebp `anim_dump`, so RGB hidden behind alpha=0 is not preserved) and
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
/// reconstructed canvas (`prev_canvas`), the previous frame's rectangle and
/// keyframe status (mirroring `animation_decode.Decoder.PrevFrame`, needed to
/// reproduce the "skip blending inside the previous background-disposed rect"
/// rule and keyframe detection), and the keyframe counter.
const Optimizer = struct {
    gpa: std.mem.Allocator,
    canvas: image.Dimensions,
    encode_options: Options,
    stride: u32,

    /// What the decoder holds *before* the next frame (i.e. after the previous
    /// frame was composited and its dispose applied). Packed RGBA, canvas-sized,
    /// with fully-transparent pixels' RGB zeroed (matching the decoder).
    prev_canvas: []u8,
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

        // Two canvas-sized scratch buffers; bound against the budget up front
        // (the per-frame encoder charges its own scratch separately).
        var budget: u64 = 0;
        budget = try addBytes(budget, canvas_bytes);
        budget = try addBytes(budget, canvas_bytes);
        try encode_options.limits.validateAllocationBytes(budget);

        const prev_canvas = try gpa.alloc(u8, @intCast(canvas_bytes));
        errdefer gpa.free(prev_canvas);
        @memset(prev_canvas, 0);

        const target = try gpa.alloc(u8, @intCast(canvas_bytes));
        errdefer gpa.free(target);

        return .{
            .gpa = gpa,
            .canvas = canvas,
            .encode_options = encode_options,
            .stride = @intCast(row_bytes),
            .prev_canvas = prev_canvas,
            .target = target,
            .prev = null,
            .frames_since_keyframe = 0,
        };
    }

    fn deinit(self: *Optimizer) void {
        self.gpa.free(self.prev_canvas);
        self.gpa.free(self.target);
        self.* = undefined;
    }

    /// Derives the rectangle, blend, and dispose for one frame, encodes it via
    /// the slice-9b per-frame encoder, then updates `prev_canvas` to exactly
    /// what the decoder will hold after this frame (re-decoding the bitstream
    /// and compositing with the `animation_decode` rules). `next`, if present,
    /// is the following input frame (used only for the dispose lookahead).
    fn encodeNext(
        self: *Optimizer,
        input: FrameInput,
        next: ?FrameInput,
    ) errors.Error!mux.FrameImage {
        // Gather the desired canvas into packed RGBA with transparent-RGB
        // zeroing, so it equals the decoder's reconstructed canvas model.
        gatherCanvasRgba(input.buffer, self.target, self.stride);
        const target = self.target;

        const diff = self.changeRect(self.prev_canvas, target);
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

        if (is_keyframe) {
            // Full-canvas verbatim replace: the decoder clears then copies, so
            // the reconstruction equals `target` exactly. Run the same one-frame
            // dispose lookahead as a sub-rect frame: clearing the full canvas to
            // background can shrink the next frame's diff rect when the keyframe
            // is followed by a mostly-transparent or small-object frame (a
            // scene-cut / flash). `commit` re-tracks the canvas with whatever
            // dispose we pick, so the choice stays byte-exact.
            rect = .{ .x = 0, .y = 0, .width = self.canvas.width, .height = self.canvas.height };
            blend = .replace;
            dispose = self.chooseDispose(next, rect);
        } else if (diff.isEmpty()) {
            // Degenerate: this frame equals the previous canvas. Emit a tiny 1x1
            // verbatim copy (a no-op the decoder composites to the same canvas).
            // Force lossless: a `.lossy` 1x1 would quantize the pixel, so the
            // decoder would copy a *changed* pixel onto an otherwise-unchanged
            // canvas (one-pixel flicker that also seeds later diffs). Lossless
            // 1x1 reproduces the exact pixel, keeping this a true no-op.
            rect = .{ .x = 0, .y = 0, .width = 1, .height = 1 };
            blend = .replace;
            frame_format = .lossless;
        } else {
            // A sub-rectangle frame. Snap to even offsets (the container stores
            // them in 2-pixel units), then decide blend vs replace.
            rect = snapToEvenOffsets(diff, self.canvas);
            if (self.blendCandidateExact(target, rect)) {
                blend = .alpha_blend;
                make_transparent = true;
            } else {
                blend = .replace;
            }
            dispose = self.chooseDispose(next, rect);
        }

        // Build the cropped sub-frame the per-frame encoder will compress.
        const sub_pixels = try self.buildSubFrame(target, rect, make_transparent);
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
        try self.commit(frame_image, rect, blend, dispose, is_keyframe);

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

    /// Re-decodes `frame_image`'s bitstream and composites it into `prev_canvas`
    /// using the exact `animation_decode` rules, then applies this frame's
    /// dispose — leaving `prev_canvas` equal to what the decoder holds before
    /// the next frame.
    fn commit(
        self: *Optimizer,
        frame_image: mux.FrameImage,
        rect: Rect,
        blend: animation.BlendMethod,
        dispose: animation.DisposeMethod,
        is_keyframe: bool,
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

        // The previous frame's dispose was applied at its own commit (mirroring
        // the decoder applying it before this frame). Apply this dispose now,
        // for the next frame.
        if (dispose == .background) self.clearRect(rect);

        self.prev = .{ .rect = rect.frameRect(), .dispose = dispose, .was_keyframe = is_keyframe };
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

    fn clearRect(self: *Optimizer, rect: Rect) void {
        const row_span = @as(usize, rect.width) * channels;
        var y: u32 = 0;
        while (y < rect.height) : (y += 1) {
            const canvas_y = rect.y + y;
            const row = self.prev_canvas[@as(usize, canvas_y) * self.stride ..];
            @memset(row[@as(usize, rect.x) * channels ..][0..row_span], 0);
        }
    }

    /// Computes the minimal change rectangle between `base` (the previous
    /// reconstructed canvas) and `target` (the desired canvas), both packed
    /// RGBA at `self.stride`. Mirrors libwebp's `MinimizeChangeRectangle` for
    /// lossless (exact pixel compare). Returns an empty rect if identical.
    fn changeRect(self: *const Optimizer, base: []const u8, target: []const u8) Rect {
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
                if (!std.mem.eql(u8, base_row[off..][0..4], target_row[off..][0..4])) {
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
    fn chooseDispose(self: *const Optimizer, next: ?FrameInput, rect: Rect) animation.DisposeMethod {
        const next_input = next orelse return .none;
        const next_buffer = next_input.buffer;
        const none_area = self.lookaheadDiffArea(self.target, next_buffer, null);
        const bg_area = self.lookaheadDiffArea(self.target, next_buffer, rect);
        return if (bg_area < none_area) .background else .none;
    }

    /// Change-rect area between the canvas-after-this-frame (`after_canvas`) and
    /// the next frame's desired canvas. `clear`, if set, treats that rectangle
    /// of the after-canvas as transparent (modeling dispose-to-background).
    /// Returns only the area, for comparing dispose choices.
    fn lookaheadDiffArea(
        self: *const Optimizer,
        after_canvas: []const u8,
        next_buffer: image.Buffer,
        clear: ?Rect,
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
                if (!std.mem.eql(u8, after_pixel, next_pixel[0..4])) {
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

test "a keyframe followed by a sparse frame disposes to background and shrinks the next rect" {
    const gpa = testing.allocator;
    const w = 16;
    const h = 16;

    // Frame 0 is a full-canvas opaque keyframe (a scene). Frame 1 is a scene cut
    // to a mostly-transparent canvas with a single small opaque square. Without
    // dispose lookahead on the keyframe, frame 1's diff against the opaque
    // frame-0 canvas covers everywhere the opaque pixels turned transparent — the
    // whole canvas — so frame 1 becomes another full-canvas keyframe. With the
    // lookahead, the keyframe disposes to background (clears the canvas), so
    // frame 1's diff against the transparent canvas is just the small square.
    var f0: [w * h * 4]u8 = undefined;
    fillConstant(&f0, .{ 180, 60, 220, 255 });
    var f1: [w * h * 4]u8 = undefined;
    fillConstant(&f1, .{ 0, 0, 0, 0 }); // fully transparent
    paintSquare(&f1, w, 2, 2, 4, 4, .{ 255, 255, 255, 255 }); // one small opaque object

    const frames = [_]FrameInput{
        .{ .buffer = try rgbaBuffer(&f0, w, h), .duration_ms = 100, .format = .lossless },
        .{ .buffer = try rgbaBuffer(&f1, w, h), .duration_ms = 100, .format = .lossless },
    };
    const encoded = try encodeAnimationMinimized(gpa, &frames, .{
        .canvas = try image.Dimensions.init(w, h),
    });
    defer gpa.free(encoded);

    // (a) Correctness: still composites back byte-exactly. `f1`'s transparent
    // pixels canonicalize to 0,0,0,0, which is exactly how it was authored.
    try expectByteExactRoundTrip(gpa, encoded, &.{ &f0, &f1 });

    var parsed = try demux.parse(gpa, encoded, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, 2), parsed.frames.len);

    // (b1) The keyframe now selects `.background` dispose so the next frame can
    // diff against a cleared canvas.
    try testing.expectEqual(@as(u32, w), parsed.frames[0].rect.width);
    try testing.expectEqual(@as(u32, h), parsed.frames[0].rect.height);
    try testing.expectEqual(animation.DisposeMethod.background, parsed.frames[0].dispose_method);

    // (b2) Frame 1's rect is the small object, far smaller than the canvas —
    // without the lookahead it would span the whole canvas.
    try testing.expect(parsed.frames[1].rect.width < w);
    try testing.expect(parsed.frames[1].rect.height < h);
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
