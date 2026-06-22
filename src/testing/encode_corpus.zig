//! Encode corpus: round-trips a defined set of *source* images through the
//! lossless encoder and back through this library's decoder, asserting
//! bit-exact recovery. This is the encode-side analogue of the decode corpus
//! and the harness PLAN.MD step 7 measures size on (and step 8 will extend to
//! lossy validity).
//!
//! Three source families make up the corpus:
//!
//! 1. Synthetic images from `synth.zig` — an edge-dimension and
//!    content/alpha matrix generated at test time (no committed bytes).
//! 2. Committed CC0 photographs under `testdata/photos/`, decoded to pristine
//!    pixels (the WebP files are `cwebp -lossless`, so the decode is exact).
//!    Provenance is recorded in `testdata/photos/PROVENANCE.md`.
//! 3. The in-tree lossless WebP corpus — already round-tripped by the
//!    "VP8L encoder round-trips every lossless corpus image" test in
//!    `corpus.zig`, so it is referenced there rather than duplicated here.
//!
//! Lossless round-tripping is bit-exact, so these tests need no committed
//! hashes: the source pixels are the oracle. Size is measured separately by
//! the `zig-webp-encode-report` tool, not gated here.

const std = @import("std");

const color = @import("../color.zig");
const corpus = @import("corpus.zig");
const decode = @import("../decode.zig");
const encode = @import("../encode.zig");
const image = @import("../image.zig");
const limits = @import("../limits.zig");
const metrics = @import("metrics.zig");
const synth = @import("synth.zig");
const vp8_decoder = @import("../vp8/decoder.zig");
const vp8_encoder = @import("../vp8/encoder.zig");
const vp8_quant = @import("../vp8/quant.zig");

/// Directory of committed CC0 source photographs, relative to the repo root.
pub const photos_root_path = "testdata/photos";

/// Corpus files are trusted fixtures, so the per-image limits are relaxed to
/// admit the largest committed canvases (mirrors `corpus.zig`).
const corpus_limits = limits.ResourceLimits{
    .output_pixels_max = std.math.maxInt(u32),
    .animation_canvas_pixels_max = std.math.maxInt(u32),
};

/// Encodes `buffer` losslessly, decodes the result back in `format`, and
/// asserts the decoded pixels equal `expected` byte-for-byte. `expected` is
/// the tightly packed source plane (every corpus source has a tight stride).
fn assertRoundTrips(
    gpa: std.mem.Allocator,
    expected: []const u8,
    buffer: image.Buffer,
    format: image.PixelFormat,
) !void {
    const encoded = try encode.encodeStaticLossless(gpa, buffer, .{ .limits = corpus_limits });
    defer gpa.free(encoded);

    var decoded = try decode.decodeStatic(gpa, encoded, .{
        .output_format = format,
        .limits = corpus_limits,
    });
    defer decoded.deinit();

    try std.testing.expectEqualSlices(u8, expected, decoded.buffer.pixels);
}

test "lossless encoder round-trips every synthetic source bit-exactly" {
    for (synth.sources) |source| {
        const rendered = try synth.render(std.testing.allocator, source);
        defer rendered.deinit();

        assertRoundTrips(
            std.testing.allocator,
            rendered.pixels,
            rendered.buffer,
            source.format,
        ) catch |err| {
            std.debug.print("synthetic source {s} failed round-trip: {s}\n", .{ source.name, @errorName(err) });
            return err;
        };
    }
}

test "lossless encoder round-trips every committed CC0 photo bit-exactly" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, photos_root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        error.NotDir => return error.SkipZigTest,
        else => return err,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".webp")) continue;

        const bytes = try corpus.readFileAlloc(std.testing.allocator, entry.name, .{
            .root_path = photos_root_path,
            .limits = corpus_limits,
        });
        defer std.testing.allocator.free(bytes);

        // Decode the (lossless) photo to pristine RGBA: these are the source
        // pixels the encoder must reproduce exactly.
        var source = try decode.decodeStatic(std.testing.allocator, bytes, .{
            .output_format = .rgba,
            .limits = corpus_limits,
        });
        defer source.deinit();

        assertRoundTrips(
            std.testing.allocator,
            source.buffer.pixels,
            source.buffer,
            .rgba,
        ) catch |err| {
            std.debug.print("photo {s} failed round-trip: {s}\n", .{ entry.name, @errorName(err) });
            return err;
        };
    }
}

// --- Lossy (VP8) round-trip ------------------------------------------------
//
// The step 8a gate is reconstruction self-consistency: the decoder must
// reproduce the encoder's own reconstruction byte-for-byte at the YUV layer.
// We run it over the same source corpus through the low-level encoder (which
// exposes its reconstruction), and add an end-to-end PSNR sanity floor on
// smooth content (alpha excluded — 8a encodes color only).

const lossy_quality = 75;

/// Lossily encodes `argb`, asserts the decoder reproduces the encoder's
/// reconstruction byte-for-byte (the hard 8a gate), and optionally asserts the
/// reconstructed color stays within `psnr_floor` dB of the source.
fn assertLossyRoundTrip(
    gpa: std.mem.Allocator,
    argb: []const u32,
    width: u32,
    height: u32,
    psnr_floor: ?f64,
) !void {
    var source = try color.rgbaToYuv420Alloc(gpa, argb, width, height);
    defer source.deinit(gpa);

    var result = try vp8_encoder.encodeAlloc(gpa, &source, .{ .base_quant_index = vp8_quant.baseQuantIndexForQuality(lossy_quality) });
    defer result.deinit(gpa);

    var frame = try vp8_decoder.decodeFrame(gpa, result.bitstream, .{ .apply_loop_filter = true });
    defer frame.deinit();

    try std.testing.expectEqualSlices(u8, result.reconstruction.luma, frame.luma);
    try std.testing.expectEqualSlices(u8, result.reconstruction.chroma_u, frame.chroma_u);
    try std.testing.expectEqualSlices(u8, result.reconstruction.chroma_v, frame.chroma_v);

    const floor = psnr_floor orelse return;

    const pixel_count: usize = @as(usize, width) * height;
    const recon_rgb = try gpa.alloc(u8, pixel_count * 3);
    defer gpa.free(recon_rgb);
    color.upsampleFancy(.rgb, result.reconstruction.view(), recon_rgb, @as(usize, width) * 3);

    const source_rgb = try gpa.alloc(u8, pixel_count * 3);
    defer gpa.free(source_rgb);
    for (argb, 0..) |p, i| {
        source_rgb[i * 3 + 0] = @intCast((p >> 16) & 0xff);
        source_rgb[i * 3 + 1] = @intCast((p >> 8) & 0xff);
        source_rgb[i * 3 + 2] = @intCast(p & 0xff);
    }

    const psnr = metrics.psnrBytes(recon_rgb, source_rgb);
    if (psnr < floor) {
        std.debug.print("lossy RGB PSNR {d:.2} dB below floor {d:.2} ({d}x{d})\n", .{ psnr, floor, width, height });
        return error.PsnrBelowFloor;
    }
}

test "lossy encoder reconstruction matches the decoder for every synthetic source" {
    for (synth.sources) |source| {
        const rendered = try synth.render(std.testing.allocator, source);
        defer rendered.deinit();

        const argb = try encode.gatherArgbAlloc(std.testing.allocator, rendered.buffer);
        defer std.testing.allocator.free(argb);

        // Hard YUV gate only: synthetic content includes adversarial high
        // frequency (checker, noise) whose lossy PSNR is legitimately low.
        assertLossyRoundTrip(std.testing.allocator, argb, source.width, source.height, null) catch |err| {
            std.debug.print("synthetic source {s} failed lossy round-trip: {s}\n", .{ source.name, @errorName(err) });
            return err;
        };
    }
}

test "lossy encoder preserves the color of fully transparent pixels" {
    // Alpha 0 but a real RGB color: 8a converts from raw RGB, so the color must
    // survive the round-trip (a flat field reconstructs near-losslessly).
    const width = 32;
    const height = 32;
    const argb = try std.testing.allocator.alloc(u32, width * height);
    defer std.testing.allocator.free(argb);
    @memset(argb, 0x0033_99cc); // A=0, R=0x33, G=0x99, B=0xcc

    try assertLossyRoundTrip(std.testing.allocator, argb, width, height, 35.0);
}

test "lossy encoder reproduces committed photos within a PSNR floor" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = std.Io.Dir.cwd().openDir(io, photos_root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        error.NotDir => return error.SkipZigTest,
        else => return err,
    };
    defer dir.close(io);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".webp")) continue;

        const bytes = try corpus.readFileAlloc(std.testing.allocator, entry.name, .{
            .root_path = photos_root_path,
            .limits = corpus_limits,
        });
        defer std.testing.allocator.free(bytes);

        var source = try decode.decodeStatic(std.testing.allocator, bytes, .{
            .output_format = .rgba,
            .limits = corpus_limits,
        });
        defer source.deinit();

        const argb = try encode.gatherArgbAlloc(std.testing.allocator, source.buffer);
        defer std.testing.allocator.free(argb);

        // Smooth photographic content: a correct DC-baseline encode at q75 stays
        // well above this conservative floor; it mainly guards the color path.
        assertLossyRoundTrip(
            std.testing.allocator,
            argb,
            source.buffer.dimensions.width,
            source.buffer.dimensions.height,
            20.0,
        ) catch |err| {
            std.debug.print("photo {s} failed lossy round-trip: {s}\n", .{ entry.name, @errorName(err) });
            return err;
        };
    }
}
