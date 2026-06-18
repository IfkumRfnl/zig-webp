//! Reports this library's lossless (VP8L) encoder over the encode corpus:
//! the synthetic source matrix (`synth.zig`), the committed CC0 photographs
//! (`testdata/photos`), and optionally the in-tree lossless WebP corpus
//! (`--with-corpus`).
//!
//! For each source it encodes losslessly, decodes the result back, confirms a
//! bit-exact round-trip, and emits a TSV row: family, name, dimensions, source
//! format, raw pixel bytes, encoded bytes, bits-per-pixel, PSNR (inf for a
//! lossless round-trip), and the round-trip verdict. PSNR/round-trip are
//! trivial today but the plumbing is what step 8's lossy encoder will report
//! against `cwebp`.
//!
//! Usage: zig-webp-encode-report [--with-corpus] [OUTPUT.tsv]
//! With no OUTPUT.tsv the report goes to stdout. Regenerate the committed
//! baseline with `zig build encode-report -- testdata/encode-corpus-sizes.tsv`.

const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

const synth = webp.testing.synth;
const encode_corpus = webp.testing.encode_corpus;
const corpus = webp.testing.corpus;

// Trusted fixtures: relax the per-image limits to admit the largest canvases.
const report_limits = webp.ResourceLimits{
    .output_pixels_max = std.math.maxInt(u32),
    .animation_canvas_pixels_max = std.math.maxInt(u32),
};

const Stats = struct {
    sources: u32 = 0,
    mismatches: u32 = 0,
    raw_bytes: u64 = 0,
    encoded_bytes: u64 = 0,
};

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);

    var with_corpus = false;
    var output_path: ?[]const u8 = null;
    for (ctx.args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--with-corpus")) {
            with_corpus = true;
        } else if (output_path == null) {
            output_path = arg;
        } else {
            ctx.usageError(
                "usage: zig-webp-encode-report [--with-corpus] [OUTPUT.tsv]\n" ++
                    "Reports the lossless encoder's size and round-trip over the encode corpus.\n",
            );
        }
    }

    var report: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer report.deinit();
    try report.writer.writeAll(
        "# zig-webp lossless encode report: encoded size and round-trip per source.\n" ++
            "# Regenerate with `zig build encode-report -- testdata/encode-corpus-sizes.tsv`.\n" ++
            "family\tname\twidth\theight\tformat\traw_bytes\tencoded_bytes\tbpp\tpsnr_db\troundtrip\n",
    );

    var stats: Stats = .{};

    // Synthetic sources: generated in memory.
    for (synth.sources) |source| {
        const rendered = try synth.render(ctx.gpa, source);
        defer rendered.deinit();
        try reportBuffer(&report.writer, ctx.gpa, "synthetic", source.name, rendered.buffer, &stats);
    }

    // Committed CC0 photographs (decoded to pristine pixels).
    try reportWebpDir(&report.writer, ctx, "photo", encode_corpus.photos_root_path, &stats);

    // In-tree lossless WebP corpus (local size cross-check; opt-in).
    if (with_corpus) {
        try reportWebpDir(&report.writer, ctx, "corpus", corpus.default_root_path, &stats);
    }

    if (output_path) |path| {
        try ctx.writeOutput(path, report.written());
    } else {
        try ctx.writeStdout(report.written());
    }

    var summary_buffer: [256]u8 = undefined;
    const summary = try std.fmt.bufPrint(
        &summary_buffer,
        "encode-report: {d} sources, {d} round-trip mismatches, {d} raw bytes -> {d} encoded bytes\n",
        .{ stats.sources, stats.mismatches, stats.raw_bytes, stats.encoded_bytes },
    );
    try ctx.writeStderr(summary);
    if (stats.mismatches != 0) std.process.exit(1);
}

/// Iterates `*.webp` files under `dir_path`, decoding each still lossless file
/// to RGBA and reporting its re-encode. Missing directories are skipped (the
/// photo corpus or the in-tree corpus may be absent in a given checkout).
fn reportWebpDir(
    writer: *std.Io.Writer,
    ctx: cli.Cli,
    family: []const u8,
    dir_path: []const u8,
    stats: *Stats,
) !void {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        error.NotDir => return,
        else => return err,
    };
    defer dir.close(ctx.io);

    var file_names = try cli.collectWebpFileNames(ctx.gpa, ctx.io, dir);
    defer cli.freeFileNames(ctx.gpa, &file_names);

    for (file_names.items) |name| {
        const bytes = try corpus.readFileAlloc(ctx.gpa, name, .{
            .root_path = dir_path,
            .limits = report_limits,
        });
        defer ctx.gpa.free(bytes);

        // Only still lossless files are valid encode sources here.
        var result = try webp.parseWebP(ctx.gpa, bytes, .{ .limits = report_limits });
        const is_lossless_still = !result.features.is_animation and result.features.format == .lossless;
        result.deinit();
        if (!is_lossless_still) continue;

        var source = try webp.decodeStatic(ctx.gpa, bytes, .{
            .output_format = .rgba,
            .limits = report_limits,
        });
        defer source.deinit();

        try reportBuffer(writer, ctx.gpa, family, name, source.buffer, stats);
    }
}

/// Encodes `buffer` losslessly, decodes it back in the buffer's own format,
/// and writes one TSV row plus updates `stats`.
fn reportBuffer(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    family: []const u8,
    name: []const u8,
    buffer: webp.ImageBuffer,
    stats: *Stats,
) !void {
    const encoded = try webp.encodeLossless(gpa, buffer, .{ .limits = report_limits });
    defer gpa.free(encoded);

    var decoded = try webp.decodeStatic(gpa, encoded, .{
        .output_format = buffer.format,
        .limits = report_limits,
    });
    defer decoded.deinit();

    const width = buffer.dimensions.width;
    const height = buffer.dimensions.height;
    const channels: u64 = buffer.format.channelCount();
    const raw_bytes: u64 = @as(u64, width) * @as(u64, height) * channels;
    const pixel_count: u64 = @as(u64, width) * @as(u64, height);
    const bpp: f64 = if (pixel_count == 0)
        0
    else
        @as(f64, @floatFromInt(encoded.len * 8)) / @as(f64, @floatFromInt(pixel_count));

    const matches = std.mem.eql(u8, buffer.pixels[0..raw_bytes], decoded.buffer.pixels);
    const psnr = webp.testing.metrics.psnrBytes(buffer.pixels[0..raw_bytes], decoded.buffer.pixels);

    stats.sources += 1;
    stats.raw_bytes += raw_bytes;
    stats.encoded_bytes += encoded.len;
    if (!matches) stats.mismatches += 1;

    try writer.print("{s}\t{s}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d:.4}\t", .{
        family,
        name,
        width,
        height,
        formatName(buffer.format),
        raw_bytes,
        encoded.len,
        bpp,
    });
    if (std.math.isInf(psnr)) {
        try writer.writeAll("inf\t");
    } else {
        try writer.print("{d:.3}\t", .{psnr});
    }
    try writer.writeAll(if (matches) "ok\n" else "MISMATCH\n");
}

fn formatName(format: webp.image.PixelFormat) []const u8 {
    return switch (format) {
        .rgb => "rgb",
        .rgba => "rgba",
        .bgra => "bgra",
        .argb => "argb",
    };
}
