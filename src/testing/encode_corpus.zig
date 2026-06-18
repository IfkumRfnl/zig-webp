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

const corpus = @import("corpus.zig");
const decode = @import("../decode.zig");
const encode = @import("../encode.zig");
const image = @import("../image.zig");
const limits = @import("../limits.zig");
const synth = @import("synth.zig");

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
