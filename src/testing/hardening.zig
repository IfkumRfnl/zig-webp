//! Step 11a — limits & malicious-input contract matrix.
//!
//! End-to-end proof that every public entry point honors a caller-supplied
//! `ResourceLimits`. Each test builds a VALID input in-process via the public
//! encoders (no corpus-file dependency), then tightens exactly ONE limit knob
//! and asserts the exact rejection error. Building uses default limits; only
//! the decode/parse/encode call under test gets the tight limit.
//!
//! This module is test-only and registered from `root.zig`. It deliberately
//! changes no enforcement code: a failing test here is a library bug to report,
//! not to patch (see plans/006).
//!
//! ── Adversarial-input coverage audit (PLAN.MD step 11) ───────────────────
//! | Adversarial input        | Enforced at                      | Existing test                         | Covered here |
//! |--------------------------|----------------------------------|---------------------------------------|--------------|
//! | Huge dimensions (overflow)| limits.pixelCount (DimensionsOverflow) | limits.zig:60, image.zig:95     | matrix (CanvasTooLarge) |
//! | Oversized / over-count chunks | demux readChunkLocation + validateChunkCount | demux "enforces chunk count" | matrix (TooManyChunks, AllocationLimitExceeded) |
//! | Invalid LZ77 distances   | vp8l/image_data.zig:202          | vp8l/image_data.zig:725               | unit (referenced) |
//! | Invalid Huffman trees    | vp8l/huffman buildTable          | vp8l/huffman.zig:542                  | unit (referenced) |
//! | Recursive/duplicate VP8L transforms | vp8l/transform.zig:70, :278 | vp8l/transform.zig:278, inverse_transform.zig:411 | unit (referenced) |
//! | Animation frame counts   | demux:371,:463; encoders         | demux "enforces frame count"          | matrix (FrameCountTooLarge) |
//! | Input too large          | demux.parse:81                   | (this module)                         | matrix (InputTooLarge) |
//!
//! ── Bounded-loop audit (confirmed by reading at planning commit) ─────────
//! Each parsing/decoding loop is bounded by a parsed-and-validated quantity.
//! Re-confirmed during Step 5 of plans/006 at commit `e824d0c`; an unbounded
//! loop is a STOP condition.
//! | Loop                          | Site                    | Bound |
//! |-------------------------------|-------------------------|-------|
//! | demux top-level chunk walk    | demux.zig:97            | file_end + validateChunkCount |
//! | demux animation frame parse   | demux.zig (frame loop)  | file_end + validateFrameCount |
//! | VP8L image-data decode        | vp8l/image_data.zig     | pixel_count |
//! | VP8 macroblock reconstruction | vp8/decoder.zig         | mb_w * mb_h |
//! | alpha plane fill              | alpha.zig               | pixel_count |
//! | YUV->RGB upsample             | color.zig               | width * height |

const std = @import("std");

const animation = @import("../animation.zig");
const animation_decode = @import("../animation_decode.zig");
const animation_encode = @import("../animation_encode.zig");
const animation_optimize = @import("../animation_optimize.zig");
const decode = @import("../decode.zig");
const demux = @import("../demux.zig");
const encode = @import("../encode.zig");
const features = @import("../features.zig");
const image = @import("../image.zig");
const limits = @import("../limits.zig");

const testing = std.testing;

/// Canvas used by the still builders: 8x8 = 64 px.
const still_w: u32 = 8;
const still_h: u32 = 8;
const still_px: u64 = still_w * still_h; // 64

fn fillGradient(pixels: []u8, w: u32, h: u32) void {
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const base = (y * w + x) * 4;
            pixels[base + 0] = @intCast((x * 32) & 0xff);
            pixels[base + 1] = @intCast((y * 32) & 0xff);
            pixels[base + 2] = @intCast(((x + y) * 16) & 0xff);
            pixels[base + 3] = 255;
        }
    }
}

/// Encodes an 8x8 lossless still through the public encoder with default
/// limits. Caller frees the returned bytes.
fn buildLosslessStill(gpa: std.mem.Allocator) ![]u8 {
    var pixels: [still_w * still_h * 4]u8 = undefined;
    fillGradient(&pixels, still_w, still_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(still_w, still_h),
        .stride = still_w * 4,
        .format = .rgba,
    };
    return encode.encodeStaticLossless(gpa, buffer, .{ .format = .lossless });
}

/// Encodes an 8x8 lossy still through the public encoder with default limits.
fn buildLossyStill(gpa: std.mem.Allocator) ![]u8 {
    var pixels: [still_w * still_h * 4]u8 = undefined;
    fillGradient(&pixels, still_w, still_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(still_w, still_h),
        .stride = still_w * 4,
        .format = .rgba,
    };
    return encode.encodeStaticLossy(gpa, buffer, .{ .format = .lossy, .quality = 75 });
}

const anim_w: u32 = 8;
const anim_h: u32 = 8;
const anim_px: u64 = anim_w * anim_h; // 64
const anim_frames: u32 = 3;

/// Three full-canvas lossless frames muxed via the public buffer encoder.
fn buildAnimationFile(gpa: std.mem.Allocator) ![]u8 {
    var pixels: [anim_w * anim_h * 4]u8 = undefined;
    fillGradient(&pixels, anim_w, anim_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(anim_w, anim_h),
        .stride = anim_w * 4,
        .format = .rgba,
    };
    const frame = animation_encode.FrameSource{
        .buffer = buffer,
        .duration_ms = 100,
        .format = .lossless,
    };
    const sources = [_]animation_encode.FrameSource{ frame, frame, frame };
    return animation_encode.encodeAnimationFromBuffers(gpa, &sources, .{
        .canvas = try image.Dimensions.init(anim_w, anim_h),
    });
}

// ── Decode/parse contract matrix (Step 3) ──────────────────────────────────

test "decodeStatic honors input_bytes_max" {
    const file = try buildLosslessStill(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.InputTooLarge, decode.decodeStatic(
        testing.allocator,
        file,
        .{ .limits = .{ .input_bytes_max = 8 } },
    ));
}

test "decodeStatic honors output_pixels_max for lossless" {
    const file = try buildLosslessStill(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.CanvasTooLarge, decode.decodeStatic(
        testing.allocator,
        file,
        .{ .limits = .{ .output_pixels_max = still_px - 1 } },
    ));
}

test "decodeStatic honors allocation_bytes_max" {
    const file = try buildLosslessStill(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.AllocationLimitExceeded, decode.decodeStatic(
        testing.allocator,
        file,
        .{ .limits = .{ .allocation_bytes_max = 16 } },
    ));
}

test "decodeStatic honors output_pixels_max for lossy" {
    const file = try buildLossyStill(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.CanvasTooLarge, decode.decodeStatic(
        testing.allocator,
        file,
        .{ .limits = .{ .output_pixels_max = still_px - 1 } },
    ));
}

test "demux.parse honors input_bytes_max" {
    const file = try buildLosslessStill(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.InputTooLarge, demux.parse(
        testing.allocator,
        file,
        .{ .limits = .{ .input_bytes_max = 8 } },
    ));
}

test "demux.parse honors chunk_count_max" {
    const file = try buildAnimationFile(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.TooManyChunks, demux.parse(
        testing.allocator,
        file,
        .{ .limits = .{ .chunk_count_max = 1 } },
    ));
}

test "demux.parse honors frame_count_max" {
    const file = try buildAnimationFile(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.FrameCountTooLarge, demux.parse(
        testing.allocator,
        file,
        .{ .limits = .{ .frame_count_max = 1 } },
    ));
}

test "demux.parse honors allocation_bytes_max" {
    const file = try buildAnimationFile(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.AllocationLimitExceeded, demux.parse(
        testing.allocator,
        file,
        .{ .limits = .{ .allocation_bytes_max = 16 } },
    ));
}

test "demux.parseFeatures honors input_bytes_max" {
    const file = try buildLosslessStill(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.InputTooLarge, demux.parseFeatures(
        testing.allocator,
        file,
        .{ .limits = .{ .input_bytes_max = 8 } },
    ));
}

test "decodeAnimationAlloc honors input_bytes_max" {
    const file = try buildAnimationFile(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.InputTooLarge, animation_decode.decodeAnimationAlloc(
        testing.allocator,
        file,
        .{ .limits = .{ .input_bytes_max = 8 } },
    ));
}

test "decodeAnimationAlloc honors animation_canvas_pixels_max" {
    const file = try buildAnimationFile(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.CanvasTooLarge, animation_decode.decodeAnimationAlloc(
        testing.allocator,
        file,
        .{ .limits = .{ .animation_canvas_pixels_max = anim_px - 1 } },
    ));
}

test "decodeAnimationAlloc honors frame_count_max" {
    const file = try buildAnimationFile(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.FrameCountTooLarge, animation_decode.decodeAnimationAlloc(
        testing.allocator,
        file,
        .{ .limits = .{ .frame_count_max = 1 } },
    ));
}

test "decodeAnimationAlloc honors chunk_count_max" {
    const file = try buildAnimationFile(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.TooManyChunks, animation_decode.decodeAnimationAlloc(
        testing.allocator,
        file,
        .{ .limits = .{ .chunk_count_max = 1 } },
    ));
}

// ── Encode contract matrix (Step 4) ─────────────────────────────────────────

test "encodeStaticLossless honors output_pixels_max" {
    var pixels: [still_w * still_h * 4]u8 = undefined;
    fillGradient(&pixels, still_w, still_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(still_w, still_h),
        .stride = still_w * 4,
        .format = .rgba,
    };

    try testing.expectError(error.CanvasTooLarge, encode.encodeStaticLossless(
        testing.allocator,
        buffer,
        .{ .format = .lossless, .limits = .{ .output_pixels_max = still_px - 1 } },
    ));
}

test "encodeStaticLossy honors output_pixels_max" {
    var pixels: [still_w * still_h * 4]u8 = undefined;
    fillGradient(&pixels, still_w, still_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(still_w, still_h),
        .stride = still_w * 4,
        .format = .rgba,
    };

    try testing.expectError(error.CanvasTooLarge, encode.encodeStaticLossy(
        testing.allocator,
        buffer,
        .{ .format = .lossy, .quality = 75, .limits = .{ .output_pixels_max = still_px - 1 } },
    ));
}

test "encodeAnimationFromBuffers honors animation_canvas_pixels_max" {
    var pixels: [anim_w * anim_h * 4]u8 = undefined;
    fillGradient(&pixels, anim_w, anim_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(anim_w, anim_h),
        .stride = anim_w * 4,
        .format = .rgba,
    };
    const frame = animation_encode.FrameSource{
        .buffer = buffer,
        .duration_ms = 100,
        .format = .lossless,
    };
    const sources = [_]animation_encode.FrameSource{ frame, frame, frame };

    try testing.expectError(error.CanvasTooLarge, animation_encode.encodeAnimationFromBuffers(
        testing.allocator,
        &sources,
        .{
            .canvas = try image.Dimensions.init(anim_w, anim_h),
            .limits = .{ .animation_canvas_pixels_max = anim_px - 1 },
        },
    ));
}

test "encodeAnimationFromBuffers honors frame_count_max" {
    var pixels: [anim_w * anim_h * 4]u8 = undefined;
    fillGradient(&pixels, anim_w, anim_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(anim_w, anim_h),
        .stride = anim_w * 4,
        .format = .rgba,
    };
    const frame = animation_encode.FrameSource{
        .buffer = buffer,
        .duration_ms = 100,
        .format = .lossless,
    };
    const sources = [_]animation_encode.FrameSource{ frame, frame, frame };

    try testing.expectError(error.FrameCountTooLarge, animation_encode.encodeAnimationFromBuffers(
        testing.allocator,
        &sources,
        .{
            .canvas = try image.Dimensions.init(anim_w, anim_h),
            .limits = .{ .frame_count_max = 1 },
        },
    ));
}

test "encodeAnimationMinimized honors animation_canvas_pixels_max" {
    var pixels: [anim_w * anim_h * 4]u8 = undefined;
    fillGradient(&pixels, anim_w, anim_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(anim_w, anim_h),
        .stride = anim_w * 4,
        .format = .rgba,
    };
    const frame = animation_optimize.FrameInput{
        .buffer = buffer,
        .duration_ms = 100,
        .format = .lossless,
    };
    const frames = [_]animation_optimize.FrameInput{ frame, frame, frame };

    try testing.expectError(error.CanvasTooLarge, animation_optimize.encodeAnimationMinimized(
        testing.allocator,
        &frames,
        .{
            .canvas = try image.Dimensions.init(anim_w, anim_h),
            .limits = .{ .animation_canvas_pixels_max = anim_px - 1 },
        },
    ));
}

test "encodeAnimationMinimized honors frame_count_max" {
    var pixels: [anim_w * anim_h * 4]u8 = undefined;
    fillGradient(&pixels, anim_w, anim_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(anim_w, anim_h),
        .stride = anim_w * 4,
        .format = .rgba,
    };
    const frame = animation_optimize.FrameInput{
        .buffer = buffer,
        .duration_ms = 100,
        .format = .lossless,
    };
    const frames = [_]animation_optimize.FrameInput{ frame, frame, frame };

    try testing.expectError(error.FrameCountTooLarge, animation_optimize.encodeAnimationMinimized(
        testing.allocator,
        &frames,
        .{
            .canvas = try image.Dimensions.init(anim_w, anim_h),
            .limits = .{ .frame_count_max = 1 },
        },
    ));
}
