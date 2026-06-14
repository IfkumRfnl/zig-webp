//! Animated WebP decode: per-frame reconstruction and canvas compositing.
//!
//! Composites animation frames to match libwebp's `anim_dump` byte-for-byte:
//!
//! - The canvas starts fully transparent. The `ANIM` background color is
//!   informational only (exposed via `Info.background_bgra`); libwebp's
//!   animation decoder never paints it, and neither do we.
//! - Each frame's own pixels are reconstructed through the shared still decoder
//!   (`decode.decodeImage`), so VP8/VP8L/alpha logic is reused rather than
//!   duplicated.
//! - A frame is a "keyframe" (its result is independent of earlier frames) when
//!   it is the first frame, a full-canvas opaque/replace frame, or it follows a
//!   full-canvas / keyframe background-dispose; the canvas is cleared before it.
//! - Otherwise the frame is either copied verbatim (blend method 1, "do not
//!   blend") or composited with source-over, non-premultiplied alpha (blend
//!   method 0). Blending is skipped inside the previous frame's
//!   background-disposed rectangle, where libwebp keeps the source verbatim.
//! - libwebp's animation decoder does not preserve the RGB of fully transparent
//!   pixels (unlike `-exact` static decode), so those are zeroed to match.
//! - After a frame is shown, a dispose-to-background frame restores its own
//!   rectangle to transparent for the next frame.
//!
//! Two entry points share one compositing core: `Decoder` yields composited
//! frames one at a time over a single reused canvas (bounded memory), and
//! `decodeAnimationAlloc` returns every frame as its own owned buffer.

const std = @import("std");
const assert = std.debug.assert;

const animation = @import("animation.zig");
const decode = @import("decode.zig");
const demux = @import("demux.zig");
const errors = @import("errors.zig");
const image = @import("image.zig");
const options = @import("options.zig");

pub const Error = errors.Error;

/// Global animation properties, mirroring `WebPAnimInfo`.
pub const Info = struct {
    canvas: image.Dimensions,
    frame_count: u32,
    loop_count: animation.LoopCount,
    /// Background color as stored in the `ANIM` chunk (B, G, R, A). Purely
    /// informational: compositing always uses a transparent canvas.
    background_bgra: [4]u8,
};

/// One composited frame. `pixels` borrows the decoder's internal canvas and is
/// valid only until the next `Decoder.next`/`reset`/`deinit` call; copy it out
/// (or use `decodeAnimationAlloc`) to retain it.
pub const Frame = struct {
    pixels: []const u8,
    dimensions: image.Dimensions,
    stride: u32,
    format: image.PixelFormat,
    /// Zero-based index of this frame within the animation.
    index: u32,
    /// This frame's own display duration in milliseconds.
    duration_ms: u32,
    /// Cumulative end timestamp in milliseconds (sum of durations so far).
    timestamp_ms: u64,
};

/// Streaming animation decoder: composites one frame per `next` call onto a
/// single reused canvas. The caller owns the decoder and must `deinit` it; the
/// `bytes` passed to `init` must outlive the decoder.
pub const Decoder = struct {
    gpa: std.mem.Allocator,
    bytes: []const u8,
    parsed: demux.Result,
    decode_options: options.DecoderOptions,
    canvas: []u8,
    canvas_dims: image.Dimensions,
    stride: u32,
    next_index: u32,
    timestamp_ms: u64,
    /// Info about the previously produced frame, used to dispose it, to detect
    /// the next keyframe, and to skip blending inside a background-disposed
    /// rectangle. Null before the first frame.
    prev: ?PrevFrame,

    const PrevFrame = struct {
        rect: animation.FrameRect,
        dispose: animation.DisposeMethod,
        was_keyframe: bool,
    };

    pub fn init(
        gpa: std.mem.Allocator,
        bytes: []const u8,
        decode_options: options.DecoderOptions,
    ) Error!Decoder {
        // Compositing needs an alpha channel; libwebp's animation decoder is
        // likewise restricted to 4-channel output modes.
        if (decode_options.output_format.channelCount() != 4) {
            return error.UnsupportedImageFormat;
        }

        var parsed = try demux.parse(gpa, bytes, .{ .limits = decode_options.limits });
        errdefer parsed.deinit();
        if (!parsed.features.is_animation) return error.NotAnimated;

        const canvas_dims = parsed.features.canvas;
        const stride = try rowBytes(canvas_dims, decode_options.output_format);
        const canvas_bytes = @as(u64, stride) * @as(u64, canvas_dims.height);
        try decode_options.limits.validateAllocationBytes(canvas_bytes);

        const canvas = try gpa.alloc(u8, @intCast(canvas_bytes));
        errdefer gpa.free(canvas);
        @memset(canvas, 0);

        return .{
            .gpa = gpa,
            .bytes = bytes,
            .parsed = parsed,
            .decode_options = decode_options,
            .canvas = canvas,
            .canvas_dims = canvas_dims,
            .stride = stride,
            .next_index = 0,
            .timestamp_ms = 0,
            .prev = null,
        };
    }

    pub fn deinit(self: *Decoder) void {
        self.gpa.free(self.canvas);
        self.parsed.deinit();
        self.* = undefined;
    }

    pub fn info(self: *const Decoder) Info {
        return .{
            .canvas = self.canvas_dims,
            .frame_count = @intCast(self.parsed.frames.len),
            .loop_count = if (self.parsed.animation_info) |a| a.loop_count else .{ .count = 1 },
            .background_bgra = if (self.parsed.animation_info) |a| a.background_bgra else .{ 0, 0, 0, 0 },
        };
    }

    /// Rewinds to the first frame. The canvas is reset on the next `next` call
    /// (the first frame is always a keyframe and clears it).
    pub fn reset(self: *Decoder) void {
        self.next_index = 0;
        self.timestamp_ms = 0;
        self.prev = null;
        @memset(self.canvas, 0);
    }

    /// Composites the next frame onto the canvas and returns a borrowed view of
    /// it, or null once every frame has been produced.
    pub fn next(self: *Decoder) Error!?Frame {
        if (self.next_index >= self.parsed.frames.len) return null;

        // Apply the previous frame's dispose now, not at the end of the prior
        // call, so the view returned last time stayed valid until this call.
        if (self.prev) |prev| {
            if (prev.dispose == .background) self.clearRect(prev.rect);
        }

        const frame = self.parsed.frames[self.next_index];
        const frame_num = self.next_index + 1;
        const is_key = self.isKeyFrame(frame, frame_num);

        const format = self.decode_options.output_format;
        const alpha_off = alphaOffset(format);
        var decoded = try decode.decodeImage(self.gpa, .{
            .format = frame.format orelse return error.MissingImageData,
            .bitstream = (frame.bitstream_chunk orelse return error.MissingImageData).payload(self.bytes),
            .alpha = if (frame.alpha_chunk) |location| location.payload(self.bytes) else null,
            .dimensions = try frame.rect.dimensions(),
        }, .{
            .output_format = format,
            .limits = self.decode_options.limits,
        });
        defer decoded.deinit();

        // libwebp's animation decoder does not preserve the RGB of fully
        // transparent pixels (unlike static decode with `-exact`): they read
        // back as 0,0,0,0. Match that before compositing.
        zeroTransparentPixels(decoded.buffer, alpha_off);

        if (is_key) @memset(self.canvas, 0);
        self.composite(frame, is_key, decoded.buffer, alpha_off);

        self.timestamp_ms += frame.duration_ms;
        const result = Frame{
            .pixels = self.canvas,
            .dimensions = self.canvas_dims,
            .stride = self.stride,
            .format = format,
            .index = self.next_index,
            .duration_ms = frame.duration_ms,
            .timestamp_ms = self.timestamp_ms,
        };

        self.prev = .{
            .rect = frame.rect,
            .dispose = frame.dispose_method,
            .was_keyframe = is_key,
        };
        self.next_index += 1;
        return result;
    }

    /// A keyframe's result is independent of earlier frames, so the canvas is
    /// cleared before it. Mirrors libwebp's `IsKeyFrame`.
    fn isKeyFrame(self: *const Decoder, frame: animation.Frame, frame_num: u32) bool {
        if (frame_num == 1) return true;

        const opaque_or_no_blend = !frame.has_alpha or frame.blend_method == .replace;
        if (opaque_or_no_blend and isFullFrame(frame.rect, self.canvas_dims)) return true;

        const prev = self.prev.?; // frame_num > 1 implies a previous frame.
        return prev.dispose == .background and
            (isFullFrame(prev.rect, self.canvas_dims) or prev.was_keyframe);
    }

    fn composite(
        self: *Decoder,
        frame: animation.Frame,
        is_key: bool,
        decoded: image.Buffer,
        alpha_off: usize,
    ) void {
        // A "do not blend" frame, a keyframe, or any fully opaque pixel is
        // copied verbatim. Otherwise the pixel is source-over blended onto the
        // canvas — except inside the previous frame's background-disposed
        // (now transparent) rectangle, where libwebp keeps the source verbatim.
        const blend_active = !is_key and frame.blend_method == .alpha_blend;
        const prev_background = if (self.prev) |prev| prev.dispose == .background else false;
        const prev_rect = if (self.prev) |prev| prev.rect else null;

        const channels: usize = self.canvas_dims_channels();
        const rect = frame.rect;

        var y: u32 = 0;
        while (y < rect.height) : (y += 1) {
            const canvas_y = rect.y + y;
            const canvas_row = self.canvas[@as(usize, canvas_y) * self.stride ..];
            const decoded_row = decoded.pixels[@as(usize, y) * decoded.stride ..];

            var x: u32 = 0;
            while (x < rect.width) : (x += 1) {
                const canvas_x = rect.x + x;
                const dst = canvas_row[@as(usize, canvas_x) * channels ..][0..4];
                const src = decoded_row[@as(usize, x) * channels ..][0..4];

                const inside_prev = prev_background and prev_rect != null and
                    pointInRect(canvas_x, canvas_y, prev_rect.?);
                if (blend_active and !inside_prev and src[alpha_off] != 255) {
                    blendPixelNonPremult(dst, src, alpha_off);
                } else {
                    @memcpy(dst, src);
                }
            }
        }
    }

    fn clearRect(self: *Decoder, rect: animation.FrameRect) void {
        const channels: usize = self.canvas_dims_channels();
        const row_span = @as(usize, rect.width) * channels;
        var y: u32 = 0;
        while (y < rect.height) : (y += 1) {
            const canvas_y = rect.y + y;
            const row = self.canvas[@as(usize, canvas_y) * self.stride ..];
            @memset(row[@as(usize, rect.x) * channels ..][0..row_span], 0);
        }
    }

    fn canvas_dims_channels(self: *const Decoder) usize {
        return self.decode_options.output_format.channelCount();
    }
};

/// One composited frame with its own pixel buffer (owned by `OwnedAnimation`).
pub const OwnedFrame = struct {
    buffer: image.Buffer,
    duration_ms: u32,
    timestamp_ms: u64,
};

/// Every composited frame of an animation, each as its own buffer. Holds all
/// frames in memory at once; use `Decoder` for bounded per-frame memory.
pub const OwnedAnimation = struct {
    gpa: std.mem.Allocator,
    info: Info,
    frames: []OwnedFrame,

    pub fn deinit(self: *OwnedAnimation) void {
        for (self.frames) |frame| self.gpa.free(frame.buffer.pixels);
        self.gpa.free(self.frames);
        self.* = undefined;
    }
};

/// Decodes every frame of an animated WebP into its own composited buffer.
/// The caller frees the result via `OwnedAnimation.deinit`.
pub fn decodeAnimationAlloc(
    gpa: std.mem.Allocator,
    bytes: []const u8,
    decode_options: options.DecoderOptions,
) Error!OwnedAnimation {
    var decoder = try Decoder.init(gpa, bytes, decode_options);
    defer decoder.deinit();

    const info = decoder.info();

    // Bound the total holding cost (frame_count copies of the canvas) against
    // the allocation budget up front; the streaming Decoder is the option for
    // strictly bounded memory.
    const frame_bytes = @as(u64, decoder.stride) * @as(u64, info.canvas.height);
    const total_bytes = std.math.mul(u64, frame_bytes, info.frame_count) catch {
        return error.AllocationLimitExceeded;
    };
    try decode_options.limits.validateAllocationBytes(total_bytes);

    var frames: std.ArrayList(OwnedFrame) = .empty;
    errdefer {
        for (frames.items) |frame| gpa.free(frame.buffer.pixels);
        frames.deinit(gpa);
    }
    try frames.ensureTotalCapacityPrecise(gpa, info.frame_count);

    while (try decoder.next()) |frame| {
        const pixels = try gpa.dupe(u8, frame.pixels);
        errdefer gpa.free(pixels);
        try frames.append(gpa, .{
            .buffer = .{
                .pixels = pixels,
                .dimensions = frame.dimensions,
                .stride = frame.stride,
                .format = frame.format,
            },
            .duration_ms = frame.duration_ms,
            .timestamp_ms = frame.timestamp_ms,
        });
    }

    return .{
        .gpa = gpa,
        .info = info,
        .frames = try frames.toOwnedSlice(gpa),
    };
}

fn rowBytes(dimensions: image.Dimensions, format: image.PixelFormat) Error!u32 {
    const bytes = @as(u64, dimensions.width) * @as(u64, format.channelCount());
    if (bytes > std.math.maxInt(u32)) return error.OutputTooLarge;
    return @intCast(bytes);
}

fn isFullFrame(rect: animation.FrameRect, canvas: image.Dimensions) bool {
    return rect.width == canvas.width and rect.height == canvas.height;
}

fn pointInRect(x: u32, y: u32, rect: animation.FrameRect) bool {
    return x >= rect.x and x < rect.x + rect.width and
        y >= rect.y and y < rect.y + rect.height;
}

/// Zeroes the color channels of every fully transparent pixel in `buffer`,
/// matching libwebp's animation decode (which, unlike `-exact` static decode,
/// does not preserve the RGB of `alpha == 0` pixels).
fn zeroTransparentPixels(buffer: image.Buffer, alpha_off: usize) void {
    const channels: usize = buffer.format.channelCount();
    const width: usize = buffer.dimensions.width;
    var y: usize = 0;
    while (y < buffer.dimensions.height) : (y += 1) {
        const row = buffer.pixels[y * buffer.stride ..];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            const pixel = row[x * channels ..][0..4];
            if (pixel[alpha_off] == 0) @memset(pixel, 0);
        }
    }
}

fn alphaOffset(format: image.PixelFormat) usize {
    return switch (format) {
        .rgba, .bgra => 3,
        .argb => 0,
        .rgb => unreachable, // init rejects non-4-channel formats.
    };
}

/// Source-over blend of a non-premultiplied `src` pixel onto `dst`, writing the
/// result into `dst`. Bit-for-bit identical to libwebp's `BlendPixelNonPremult`
/// (the integer approximation `WebPAnimDecoder` uses for `MODE_RGBA`), so
/// composited output matches `anim_dump`.
fn blendPixelNonPremult(dst: []u8, src: []const u8, alpha_off: usize) void {
    const src_a: u32 = src[alpha_off];
    if (src_a == 0) return; // result is dst unchanged.

    const dst_a: u32 = dst[alpha_off];
    const dst_factor_a: u32 = (dst_a * (256 - src_a)) >> 8;
    const blend_a: u32 = src_a + dst_factor_a;
    assert(blend_a > 0 and blend_a < 256);
    const scale: u32 = (@as(u32, 1) << 24) / blend_a;

    var i: usize = 0;
    while (i < 4) : (i += 1) {
        if (i == alpha_off) continue;
        const blend_unscaled: u64 = @as(u32, src[i]) * src_a + @as(u32, dst[i]) * dst_factor_a;
        dst[i] = @intCast((blend_unscaled * scale) >> 24);
    }
    dst[alpha_off] = @intCast(blend_a);
}

const testing = std.testing;
const container = @import("container.zig");
const vp8l_header = @import("vp8l/header.zig");
const bit_writer = @import("bit_writer.zig");
const vp8l_pixel = @import("vp8l/pixel.zig");

test "blends a half-transparent pixel exactly like libwebp" {
    // Independently hand-computed from the integer formula:
    //   dst_factor_a = (255 * (256-128)) >> 8 = 127; blend_a = 255;
    //   scale = (1<<24)/255 = 65793;
    //   r: (200*128 + 40*127)*65793 >> 24 = 120
    //   g: (100*128 + 80*127)*65793 >> 24 = 90
    //   b: ( 50*128 +120*127)*65793 >> 24 = 84
    var dst = [_]u8{ 40, 80, 120, 255 };
    const src = [_]u8{ 200, 100, 50, 128 };
    blendPixelNonPremult(&dst, &src, 3);
    try testing.expectEqual([_]u8{ 120, 90, 84, 255 }, dst);
}

test "fully transparent source leaves the destination untouched" {
    var dst = [_]u8{ 10, 20, 30, 40 };
    const src = [_]u8{ 200, 200, 200, 0 };
    blendPixelNonPremult(&dst, &src, 3);
    try testing.expectEqual([_]u8{ 10, 20, 30, 40 }, dst);
}

// --- In-memory animation builder for structural tests ------------------------

const TestFrameSpec = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    color: [4]u8, // R, G, B, A as stored in the constant VP8L bitstream.
    duration_ms: u24 = 0,
    blend: animation.BlendMethod = .alpha_blend,
    dispose: animation.DisposeMethod = .none,
};

fn writeConstantPrefixCode(writer: *bit_writer.BitWriter, symbol: u8) !void {
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(if (symbol <= 1) 0 else 1);
    try writer.writeBits(symbol, if (symbol <= 1) 1 else 8);
}

/// Builds a constant-color VP8L bitstream (header + image data) into `out`.
fn makeConstantVP8L(out: []u8, width: u32, height: u32, color: [4]u8) ![]const u8 {
    out[0] = vp8l_header.signature;
    const has_alpha = color[3] != 255;
    const bits = (width - 1) | ((height - 1) << 14) | (@as(u32, @intFromBool(has_alpha)) << 28);
    container.writeLittleU32(out[1..vp8l_header.byte_count], bits);

    var writer = bit_writer.BitWriter.init(out[vp8l_header.byte_count..]);
    try writer.writeBit(0); // no transforms
    try writer.writeBit(0); // no color cache
    try writer.writeBit(0); // single huffman group (not meta)
    try writeConstantPrefixCode(&writer, color[1]); // green
    try writeConstantPrefixCode(&writer, color[0]); // red
    try writeConstantPrefixCode(&writer, color[2]); // blue
    try writeConstantPrefixCode(&writer, color[3]); // alpha
    try writeConstantPrefixCode(&writer, 0); // distance
    const image_data = try writer.finish();
    return out[0 .. vp8l_header.byte_count + image_data.len];
}

fn appendChunk(list: *std.ArrayList(u8), gpa: std.mem.Allocator, tag: []const u8, payload: []const u8) !void {
    try list.appendSlice(gpa, tag);
    var size: [4]u8 = undefined;
    container.writeLittleU32(&size, @intCast(payload.len));
    try list.appendSlice(gpa, &size);
    try list.appendSlice(gpa, payload);
    if (payload.len & 1 != 0) try list.append(gpa, 0);
}

/// Assembles an animated WebP (VP8X + ANIM + N ANMF/VP8L frames) in memory.
fn buildAnimation(
    gpa: std.mem.Allocator,
    canvas_w: u32,
    canvas_h: u32,
    frames: []const TestFrameSpec,
) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    var any_alpha = false;
    for (frames) |spec| {
        if (spec.color[3] != 255) any_alpha = true;
    }
    // VP8X flags: animation (0x02), plus alpha (0x10) iff a frame carries it;
    // demux requires the flag to match the frames exactly.
    var vp8x: [10]u8 = .{ 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    if (any_alpha) vp8x[0] |= 0x10;
    container.writeLittleU24(vp8x[4..7], canvas_w - 1);
    container.writeLittleU24(vp8x[7..10], canvas_h - 1);
    try appendChunk(&body, gpa, "VP8X", &vp8x);

    const anim: [6]u8 = .{ 0, 0, 0, 0, 0, 0 }; // transparent bg, infinite loop
    try appendChunk(&body, gpa, "ANIM", &anim);

    for (frames) |spec| {
        var anmf: std.ArrayList(u8) = .empty;
        defer anmf.deinit(gpa);

        var rect_header: [16]u8 = undefined;
        container.writeLittleU24(rect_header[0..3], spec.x / 2);
        container.writeLittleU24(rect_header[3..6], spec.y / 2);
        container.writeLittleU24(rect_header[6..9], spec.width - 1);
        container.writeLittleU24(rect_header[9..12], spec.height - 1);
        container.writeLittleU24(rect_header[12..15], spec.duration_ms);
        rect_header[15] = (@as(u8, @intFromEnum(spec.blend)) << 1) | @intFromEnum(spec.dispose);
        try anmf.appendSlice(gpa, &rect_header);

        var vp8l_buffer: [64]u8 = undefined;
        const vp8l = try makeConstantVP8L(&vp8l_buffer, spec.width, spec.height, spec.color);
        try appendChunk(&anmf, gpa, "VP8L", vp8l);

        try appendChunk(&body, gpa, "ANMF", anmf.items);
    }

    var file: std.ArrayList(u8) = .empty;
    errdefer file.deinit(gpa);
    try file.appendSlice(gpa, "RIFF");
    var riff_size: [4]u8 = undefined;
    container.writeLittleU32(&riff_size, @intCast(4 + body.items.len));
    try file.appendSlice(gpa, &riff_size);
    try file.appendSlice(gpa, "WEBP");
    try file.appendSlice(gpa, body.items);
    return file.toOwnedSlice(gpa);
}

fn expectPixel(frame: Frame, x: u32, y: u32, expected: [4]u8) !void {
    const offset = y * frame.stride + x * 4;
    try testing.expectEqualSlices(u8, &expected, frame.pixels[offset..][0..4]);
}

test "composites replace and dispose-to-background frames" {
    const gpa = testing.allocator;
    // Frame 0 fills the canvas opaque red (full-frame, replace -> keyframe).
    // Frame 1 paints an opaque green 2x2 square at (2,2) and disposes to
    // background. Frame 2 paints an opaque blue 2x2 at (0,0): the square from
    // frame 1 must have been cleared back to transparent first. (WebP frame
    // offsets are stored in 2-pixel units, so they are always even.)
    const file = try buildAnimation(gpa, 4, 4, &.{
        .{ .x = 0, .y = 0, .width = 4, .height = 4, .color = .{ 255, 0, 0, 255 }, .blend = .replace },
        .{ .x = 2, .y = 2, .width = 2, .height = 2, .color = .{ 0, 255, 0, 255 }, .dispose = .background },
        .{ .x = 0, .y = 0, .width = 2, .height = 2, .color = .{ 0, 0, 255, 255 } },
    });
    defer gpa.free(file);

    var decoder = try Decoder.init(gpa, file, .{});
    defer decoder.deinit();

    try testing.expectEqual(@as(u32, 3), decoder.info().frame_count);

    const frame0 = (try decoder.next()).?;
    try expectPixel(frame0, 0, 0, .{ 255, 0, 0, 255 });
    try expectPixel(frame0, 3, 3, .{ 255, 0, 0, 255 });

    const frame1 = (try decoder.next()).?;
    try expectPixel(frame1, 2, 2, .{ 0, 255, 0, 255 }); // green square
    try expectPixel(frame1, 3, 3, .{ 0, 255, 0, 255 });
    try expectPixel(frame1, 0, 0, .{ 255, 0, 0, 255 }); // background unchanged

    const frame2 = (try decoder.next()).?;
    try expectPixel(frame2, 0, 0, .{ 0, 0, 255, 255 }); // new blue square
    try expectPixel(frame2, 1, 1, .{ 0, 0, 255, 255 });
    // The green square was disposed to background (transparent) before frame 2.
    try expectPixel(frame2, 2, 2, .{ 0, 0, 0, 0 });
    try expectPixel(frame2, 3, 3, .{ 0, 0, 0, 0 });
    // The rest of frame 0's red survives (dispose only cleared the square).
    try expectPixel(frame2, 3, 0, .{ 255, 0, 0, 255 });
    try expectPixel(frame2, 0, 3, .{ 255, 0, 0, 255 });

    try testing.expect((try decoder.next()) == null);
}

test "alpha-blends a transparent overlay over the previous canvas" {
    const gpa = testing.allocator;
    // Frame 0 is opaque red over the whole canvas. Frame 1 overlays a fully
    // transparent pixel with blend=alpha_blend at (0,0): the red must show
    // through, while an opaque pixel elsewhere in the overlay replaces it.
    const file = try buildAnimation(gpa, 2, 1, &.{
        .{ .x = 0, .y = 0, .width = 2, .height = 1, .color = .{ 255, 0, 0, 255 }, .blend = .replace },
        .{ .x = 0, .y = 0, .width = 2, .height = 1, .color = .{ 0, 0, 255, 0 } },
    });
    defer gpa.free(file);

    var animated = try decodeAnimationAlloc(gpa, file, .{});
    defer animated.deinit();

    try testing.expectEqual(@as(usize, 2), animated.frames.len);
    // Transparent overlay -> previous red shows through, byte-for-byte.
    const second = animated.frames[1].buffer.pixels;
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, second[0..4]);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255 }, second[4..8]);
}

test "rejects still images and non-alpha output formats" {
    const gpa = testing.allocator;
    const file = try buildAnimation(gpa, 2, 1, &.{
        .{ .x = 0, .y = 0, .width = 2, .height = 1, .color = .{ 1, 2, 3, 255 }, .blend = .replace },
    });
    defer gpa.free(file);

    try testing.expectError(error.UnsupportedImageFormat, Decoder.init(gpa, file, .{
        .output_format = .rgb,
    }));

    // A plain still lossless file is not an animation.
    var still_buffer: [64]u8 = undefined;
    const still_vp8l = try makeConstantVP8L(&still_buffer, 1, 1, .{ 1, 2, 3, 255 });
    var still: std.ArrayList(u8) = .empty;
    defer still.deinit(gpa);
    try still.appendSlice(gpa, "RIFF");
    var size: [4]u8 = undefined;
    container.writeLittleU32(&size, @intCast(4 + 8 + still_vp8l.len + (still_vp8l.len & 1)));
    try still.appendSlice(gpa, &size);
    try still.appendSlice(gpa, "WEBP");
    try appendChunk(&still, gpa, "VP8L", still_vp8l);
    try testing.expectError(error.NotAnimated, Decoder.init(gpa, still.items, .{}));
}
