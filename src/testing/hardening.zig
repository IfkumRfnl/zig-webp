//! Step 11a — limits & malicious-input contract matrix.
//!
//! End-to-end proof that every public entry point honors a caller-supplied
//! `ResourceLimits`. Most tests build a valid input in-process via the public
//! encoders (no corpus-file dependency), then tighten exactly one limit knob and
//! assert the exact rejection error. Targeted malformed RIFF inputs cover
//! bitstream-reachable overflow paths that the encoders cannot produce.
//! Building uses default limits; only the decode/parse/encode call under test
//! gets the tight limit.
//!
//! This module is test-only and registered from `root.zig`. It deliberately
//! captures the public hardening contract: a failing test here is a library bug.
//!
//! ── Adversarial-input coverage audit (PLAN.MD step 11) ───────────────────
//! | Adversarial input        | Enforced at                      | Existing test                         | Covered here |
//! |--------------------------|----------------------------------|---------------------------------------|--------------|
//! | Huge canvas (pixels > output_pixels_max) | limits.validateCanvas (CanvasTooLarge) | this module | matrix (CanvasTooLarge) |
//! | Dimension overflow (w*h > u32 max) | VP8X parseExtendedHeader -> limits.pixelCount (DimensionsOverflow) | this module | matrix (DimensionsOverflow) |
//! | Over-count chunks (chunk_count_max) | demux validateChunkCount, demux.zig:99 | demux "enforces configured chunk count limits" (:1151) | matrix (TooManyChunks) |
//! | Oversized/truncated chunk payload | demux readChunkLocation (TruncatedChunkHeader :216, TruncatedChunkPayload :202/:223) | none today — container-level malformation, gap for demux unit tests / 11c fuzz | not in matrix |
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
const assert = std.debug.assert;

const animation = @import("../animation.zig");
const animation_decode = @import("../animation_decode.zig");
const animation_encode = @import("../animation_encode.zig");
const animation_optimize = @import("../animation_optimize.zig");
const container = @import("../container.zig");
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

fn writeChunk(out: []u8, offset: *usize, comptime tag: []const u8, payload: []const u8) void {
    comptime {
        if (tag.len != container.fourcc_size) @compileError("chunk tag must be four bytes");
    }

    @memcpy(out[offset.*..][0..container.fourcc_size], tag);
    container.writeLittleU32(out[offset.* + container.fourcc_size ..][0..4], @intCast(payload.len));
    offset.* += container.chunk_header_size;
    @memcpy(out[offset.*..][0..payload.len], payload);
    offset.* += payload.len;
    if ((payload.len & 1) != 0) {
        out[offset.*] = 0;
        offset.* += 1;
    }
}

fn buildVP8XDimensionOverflowFile() [container.riff_header_size + container.chunk_header_size + 10]u8 {
    const side: u32 = 65_536;
    var vp8x = [_]u8{0} ** 10;
    container.writeLittleU24(vp8x[4..7], side - 1);
    container.writeLittleU24(vp8x[7..10], side - 1);

    var bytes: [container.riff_header_size + container.chunk_header_size + vp8x.len]u8 = undefined;
    @memcpy(bytes[0..4], "RIFF");
    container.writeLittleU32(bytes[4..8], @intCast(bytes.len - 8));
    @memcpy(bytes[8..12], "WEBP");
    var offset: usize = container.riff_header_size;
    writeChunk(&bytes, &offset, "VP8X", &vp8x);
    assert(offset == bytes.len);
    return bytes;
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

const lossy_allocation_w: u32 = 16;
const lossy_allocation_h: u32 = 16;

/// Slightly larger lossy still whose padded VP8 reconstruction buffers exceed
/// the output-only allocation budget while demux bookkeeping remains below it.
fn buildLossyAllocationStill(gpa: std.mem.Allocator) ![]u8 {
    var pixels: [lossy_allocation_w * lossy_allocation_h * 4]u8 = undefined;
    fillGradient(&pixels, lossy_allocation_w, lossy_allocation_h);
    const buffer = image.Buffer{
        .pixels = &pixels,
        .dimensions = try image.Dimensions.init(lossy_allocation_w, lossy_allocation_h),
        .stride = lossy_allocation_w * 4,
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

    // Cap above demux's chunk-list bookkeeping for this still (a handful of
    // 32-byte ChunkLocation entries, well under 1 KiB) but below decodeLossless's
    // cumulative reservation (argb 256 + transform 1284 = 1540 > 1024), so the
    // failure comes from the decode stage's `reserveElements`, not a duplicate of
    // the demux allocation test. If decode stopped enforcing allocation_bytes_max
    // here, decodeStatic would succeed and this assertion would fail.
    try testing.expectError(error.AllocationLimitExceeded, decode.decodeStatic(
        testing.allocator,
        file,
        .{ .limits = .{ .allocation_bytes_max = 1024 } },
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

test "decodeStatic honors allocation_bytes_max for lossy" {
    const file = try buildLossyAllocationStill(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.AllocationLimitExceeded, decode.decodeStatic(
        testing.allocator,
        file,
        .{ .limits = .{ .allocation_bytes_max = 1280 } },
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

test "demux.parse rejects VP8X dimension overflow" {
    const file = buildVP8XDimensionOverflowFile();

    try testing.expectError(error.DimensionsOverflow, demux.parse(
        testing.allocator,
        &file,
        .{},
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

test "demux.parseFeatures honors output_pixels_max" {
    const file = try buildLosslessStill(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.CanvasTooLarge, demux.parseFeatures(
        testing.allocator,
        file,
        .{ .limits = .{ .output_pixels_max = still_px - 1 } },
    ));
}

test "demux.parseFeatures honors animation_canvas_pixels_max" {
    const file = try buildAnimationFile(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.CanvasTooLarge, demux.parseFeatures(
        testing.allocator,
        file,
        .{ .limits = .{ .animation_canvas_pixels_max = anim_px - 1 } },
    ));
}

test "demux.parseFeatures honors chunk_count_max" {
    const file = try buildAnimationFile(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.TooManyChunks, demux.parseFeatures(
        testing.allocator,
        file,
        .{ .limits = .{ .chunk_count_max = 1 } },
    ));
}

test "demux.parseFeatures honors frame_count_max" {
    const file = try buildAnimationFile(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.FrameCountTooLarge, demux.parseFeatures(
        testing.allocator,
        file,
        .{ .limits = .{ .frame_count_max = 1 } },
    ));
}

test "demux.parseFeatures honors allocation_bytes_max" {
    const file = try buildAnimationFile(testing.allocator);
    defer testing.allocator.free(file);

    try testing.expectError(error.AllocationLimitExceeded, demux.parseFeatures(
        testing.allocator,
        file,
        .{ .limits = .{ .allocation_bytes_max = 16 } },
    ));
}

test "demux.parseFeatures rejects VP8X dimension overflow" {
    const file = buildVP8XDimensionOverflowFile();

    try testing.expectError(error.DimensionsOverflow, demux.parseFeatures(
        testing.allocator,
        &file,
        .{},
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

test "decodeAnimationAlloc honors allocation_bytes_max (owned-frame budget)" {
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
        .format = .lossy,
    };
    const sources = [_]animation_encode.FrameSource{ frame, frame, frame, frame, frame, frame };
    const file = try animation_encode.encodeAnimationFromBuffers(testing.allocator, &sources, .{
        .canvas = try image.Dimensions.init(anim_w, anim_h),
    });
    defer testing.allocator.free(file);

    // Cap above demux bookkeeping, the canvas buffer check, and one lossy
    // frame's charged decode budget, but below the total owned-frame bytes the
    // API reserves up front (stride*height*frame_count = 256*6 = 1536). The
    // failure is the owned-frame budget check at animation_decode.zig:317.
    try testing.expectError(error.AllocationLimitExceeded, animation_decode.decodeAnimationAlloc(
        testing.allocator,
        file,
        .{ .limits = .{ .allocation_bytes_max = 1400 } },
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
