//! Reports this library's lossy (VP8) encoder over the encode corpus: the
//! synthetic source matrix (`synth.zig`), the committed CC0 photographs
//! (`testdata/photos`), and optionally the in-tree lossless WebP corpus
//! (`--with-corpus`), all decoded to pristine source pixels first.
//!
//! For each source it encodes with the step 8a baseline encoder at a fixed
//! quality, decodes the result back, and emits a TSV row: family, name,
//! dimensions, source format, raw pixel bytes, encoded bytes, bits-per-pixel,
//! and BT.601 luma PSNR (the metric the step 8b quality gate will use). Size is
//! reported, not gated; the values feed the `compare-encode-lossy` oracle and
//! the PROGRESS.MD oracle row.
//!
//! Usage: zig-webp-encode-lossy-report [--with-corpus] [OUTPUT.tsv]
//! With no OUTPUT.tsv the report goes to stdout.

const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

const synth = webp.testing.synth;
const encode_corpus = webp.testing.encode_corpus;
const corpus = webp.testing.corpus;

// The fixed quality the baseline encoder uses for this report; the oracle pairs
// it against `cwebp -q <quality> -noalpha`.
const quality = 75;

// Trusted fixtures: relax the per-image limits to admit the largest canvases.
const report_limits = webp.ResourceLimits{
    .output_pixels_max = std.math.maxInt(u32),
    .allocation_bytes_max = std.math.maxInt(u64),
    .animation_canvas_pixels_max = std.math.maxInt(u32),
};

const Stats = struct {
    sources: u32 = 0,
    raw_bytes: u64 = 0,
    encoded_bytes: u64 = 0,
    luma_psnr_sum: f64 = 0,
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
                "usage: zig-webp-encode-lossy-report [--with-corpus] [OUTPUT.tsv]\n" ++
                    "Reports the lossy (VP8) encoder's size and PSNR over the encode corpus.\n",
            );
        }
    }

    var report: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer report.deinit();
    try report.writer.print(
        "# zig-webp lossy (VP8) encode report at quality {d}: size and luma PSNR per source.\n" ++
            "family\tname\twidth\theight\tformat\traw_bytes\tencoded_bytes\tbpp\tluma_psnr_db\n",
        .{quality},
    );

    var stats: Stats = .{};

    for (synth.sources) |source| {
        const rendered = try synth.render(ctx.gpa, source);
        defer rendered.deinit();
        try reportBuffer(&report.writer, ctx.gpa, "synthetic", source.name, rendered.buffer, &stats);
    }

    try reportWebpDir(&report.writer, ctx, "photo", encode_corpus.photos_root_path, &stats);
    if (with_corpus) {
        try reportWebpDir(&report.writer, ctx, "corpus", corpus.default_root_path, &stats);
    }

    if (output_path) |path| {
        try ctx.writeOutput(path, report.written());
    } else {
        try ctx.writeStdout(report.written());
    }

    const mean_psnr: f64 = if (stats.sources == 0)
        0
    else
        stats.luma_psnr_sum / @as(f64, @floatFromInt(stats.sources));
    var summary_buffer: [256]u8 = undefined;
    const summary = try std.fmt.bufPrint(
        &summary_buffer,
        "encode-lossy-report: {d} sources, {d} -> {d} bytes, mean luma PSNR {d:.2} dB\n",
        .{ stats.sources, stats.raw_bytes, stats.encoded_bytes, mean_psnr },
    );
    try ctx.writeStderr(summary);
}

/// Iterates `*.webp` files under `dir_path`, decoding each still lossless file
/// to pristine RGBA and reporting its lossy re-encode. Missing directories are
/// skipped (a checkout may lack the photo or in-tree corpus).
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

/// Encodes `buffer` lossily at the fixed quality, decodes it back to RGBA, and
/// writes one TSV row with the encoded size and luma PSNR versus the source.
fn reportBuffer(
    writer: *std.Io.Writer,
    gpa: std.mem.Allocator,
    family: []const u8,
    name: []const u8,
    buffer: webp.ImageBuffer,
    stats: *Stats,
) !void {
    const encoded = try webp.encodeLossy(gpa, buffer, .{ .format = .lossy, .quality = quality, .limits = report_limits });
    defer gpa.free(encoded);

    var decoded = try webp.decodeStatic(gpa, encoded, .{
        .output_format = .rgba,
        .limits = report_limits,
    });
    defer decoded.deinit();

    // Compare luma in a common RGBA layout so the source's channel order and
    // dropped alpha do not skew the metric.
    const source_rgba = try gatherRgbaAlloc(gpa, buffer);
    defer gpa.free(source_rgba);

    const width = buffer.dimensions.width;
    const height = buffer.dimensions.height;
    const channels: u64 = buffer.format.channelCount();
    const raw_bytes: u64 = @as(u64, width) * @as(u64, height) * channels;
    const pixel_count: u64 = @as(u64, width) * @as(u64, height);
    const bpp: f64 = if (pixel_count == 0)
        0
    else
        @as(f64, @floatFromInt(encoded.len * 8)) / @as(f64, @floatFromInt(pixel_count));
    const luma_psnr = webp.testing.metrics.psnrLuma(source_rgba, decoded.buffer.pixels, 4);

    stats.sources += 1;
    stats.raw_bytes += raw_bytes;
    stats.encoded_bytes += encoded.len;
    if (!std.math.isInf(luma_psnr)) stats.luma_psnr_sum += luma_psnr;

    try writer.print("{s}\t{s}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d:.4}\t", .{
        family, name, width, height, formatName(buffer.format), raw_bytes, encoded.len, bpp,
    });
    if (std.math.isInf(luma_psnr)) {
        try writer.writeAll("inf\n");
    } else {
        try writer.print("{d:.3}\n", .{luma_psnr});
    }
}

/// Packs an image buffer of any supported format into tightly packed RGBA.
fn gatherRgbaAlloc(gpa: std.mem.Allocator, buffer: webp.ImageBuffer) ![]u8 {
    const width: usize = buffer.dimensions.width;
    const height: usize = buffer.dimensions.height;
    const channels: usize = @intCast(buffer.format.channelCount());
    const out = try gpa.alloc(u8, width * height * 4);
    errdefer gpa.free(out);
    for (0..height) |y| {
        const row = buffer.pixels[y * buffer.stride ..][0 .. width * channels];
        for (0..width) |x| {
            const s = row[x * channels ..][0..channels];
            const dst = out[(y * width + x) * 4 ..][0..4];
            switch (buffer.format) {
                .rgb => dst.* = .{ s[0], s[1], s[2], 255 },
                .rgba => dst.* = .{ s[0], s[1], s[2], s[3] },
                .bgra => dst.* = .{ s[2], s[1], s[0], s[3] },
                .argb => dst.* = .{ s[1], s[2], s[3], s[0] },
            }
        }
    }
    return out;
}

fn formatName(format: webp.image.PixelFormat) []const u8 {
    return switch (format) {
        .rgb => "rgb",
        .rgba => "rgba",
        .bgra => "bgra",
        .argb => "argb",
    };
}
