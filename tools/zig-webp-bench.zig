//! In-memory performance benchmark for this library's public decode and encode
//! entry points. It establishes the scalar baseline that PLAN.MD step 10
//! (performance work) optimizes against, and lets later slices measure their
//! own before/after deltas with the same tool.
//!
//! It times the work in memory only — no PAM/file writes — so the numbers
//! reflect codec time, not disk I/O. For each input it runs a few untimed
//! warmup iterations (to fill caches), then repeated timed iterations, and
//! reports the **median** wall-clock time (robust to scheduler noise) plus the
//! minimum and the sample count. A per-measurement time budget caps how long
//! any single huge image is timed, so the whole run stays bounded.
//!
//! What it measures, by asset class drawn from `testdata/`:
//! - DECODE: every `*.webp` under `testdata/photos`, `testdata/libwebp-test-data`,
//!   and `testdata/animation`, decoded to RGBA (static) or composited (animation).
//!   Each file is bucketed into one asset class (animation / alpha / large /
//!   icon / photo) so the report aggregates cleanly; the raw format, alpha flag,
//!   and dimensions ride along as columns.
//! - ENCODE: the in-memory synthetic source matrix (`synth.zig`) plus the
//!   committed CC0 photographs (decoded to pristine RGBA first), each encoded
//!   losslessly (VP8L) and lossily (VP8 at quality 75, the matched-size gate's
//!   quality). The corpus stills are not re-encoded here — that would dominate
//!   the run time; the synthetic + photo sources are representative and bounded.
//!
//! Throughput is reported in megapixels/second (decode: output/composited
//! pixels; encode: source pixels), alongside the encoded byte size for encode
//! rows. Correctness is **not** re-checked here — that is the job of
//! `zig build test` (the committed-hash corpus regression and encoder
//! self-consistency gates). Run the tests first; this tool assumes a build that
//! already passes them and only measures its speed.
//!
//! Timing numbers are environment-dependent (CPU, thermal state, scheduler) and
//! are therefore a local/manual report, not a CI gate. The optional companion
//! `tools/webp-bench.sh` times libwebp's `dwebp`/`cwebp` over the same files for
//! a same-machine ratio. The optional `tools/webp-rust-bench.sh` driver can
//! pair this tool's still `decode-into` rows with a local `image-webp` (Rust)
//! harness materialized under `.zig-cache/` — never a package/CI dependency.
//!
//! Still decode emits two operations per file: allocating `decode` (RGBA, as
//! before) and `decode-into` via `decodeStaticInto` into a reused buffer
//! (`.rgb` when opaque, `.rgba` when alpha). Destination allocation and a
//! correctness check against allocating `decodeStatic` sit outside the timed
//! interval.
//!
//! Usage: zig-webp-bench [--iters N] [--warmup N] [--budget-ms N]
//!                       [--filter SUBSTR] [--file PATH]...
//!                       [--decode-only|--encode-only]
//!                       [--write-digests PATH] [OUTPUT.tsv]
//! With no OUTPUT.tsv the report goes to stdout; a one-line summary goes to
//! stderr either way. `--write-digests` records still `decode-into` SHA-256
//! digests (file, sha256, format, alpha, width, height) for the Rust driver.

const std = @import("std");
const builtin = @import("builtin");
const webp = @import("webp");
const cli = @import("cli_common");

const synth = webp.testing.synth;
const encode_corpus = webp.testing.encode_corpus;
const corpus = webp.testing.corpus;

/// Trusted fixtures: relax the per-image limits so the largest canvases (and
/// the animation samples) are admitted without tripping a resource guard.
const bench_limits = webp.ResourceLimits{
    .output_pixels_max = std.math.maxInt(u32),
    .allocation_bytes_max = std.math.maxInt(u64),
    .animation_canvas_pixels_max = std.math.maxInt(u32),
};

/// Lossy encode quality: matches the existing matched-size PSNR gate and the
/// `encode-lossy-report` tool, so the numbers are comparable across tools.
const lossy_quality = 75;

/// Monotonic, suspend-excluding clock — the right one for short wall-clock
/// measurements (it is not affected by settable-clock jumps).
const clock = std.Io.Clock.awake;

/// Upper bound on timed samples held for the median. The time budget normally
/// stops a measurement well before this for anything but the tiniest inputs.
const max_samples = 64;

const Config = struct {
    warmup: u32 = 2,
    /// Requested timed iterations; the time budget may stop a measurement early.
    iters: u32 = 15,
    /// Per-measurement wall-clock cap in nanoseconds. Once a measurement's timed
    /// iterations exceed this it stops (after at least one sample), so a single
    /// multi-second image cannot blow up the run.
    budget_ns: u64 = 1_500 * std.time.ns_per_ms,
    filter: ?[]const u8 = null,
    /// When non-empty, decode only these paths instead of scanning corpus dirs.
    explicit_files: []const []const u8 = &.{},
    do_decode: bool = true,
    do_encode: bool = true,
    /// When set, still `decode-into` rows also append digest TSV lines here.
    digests_path: ?[]const u8 = null,
};

/// The result of timing one input: how many timed samples were taken, the
/// median, and the fastest.
const Measurement = struct {
    samples: u32,
    median_ns: u64,
    min_ns: u64,
};

/// Times `ctx.runOnce()` (which performs one complete operation and frees its
/// own allocations) `warmup` untimed times, then up to `iters` timed times,
/// stopping early once the cumulative timed duration exceeds the budget. Returns
/// the median and minimum of the timed samples.
fn timeMedian(io: std.Io, config: Config, ctx: anytype) !Measurement {
    var warmups: u32 = 0;
    while (warmups < config.warmup) : (warmups += 1) try ctx.runOnce();

    var samples: [max_samples]u64 = undefined;
    var count: u32 = 0;
    var total: u64 = 0;
    const want = @min(config.iters, max_samples);
    while (count < want) {
        const start = clock.now(io);
        try ctx.runOnce();
        const elapsed: u64 = @intCast(start.durationTo(clock.now(io)).nanoseconds);
        samples[count] = elapsed;
        count += 1;
        total += elapsed;
        if (total >= config.budget_ns) break;
    }

    std.mem.sort(u64, samples[0..count], {}, std.sort.asc(u64));
    return .{ .samples = count, .median_ns = samples[count / 2], .min_ns = samples[0] };
}

// --- Operation contexts (each `runOnce` does one full op + frees) ----------

const DecodeStaticCtx = struct {
    gpa: std.mem.Allocator,
    bytes: []const u8,
    fn runOnce(self: @This()) !void {
        var decoded = try webp.decodeStatic(self.gpa, self.bytes, .{
            .output_format = .rgba,
            .limits = bench_limits,
        });
        decoded.deinit();
    }
};

/// Caller-owned still decode into a pre-allocated `dest` (allocated outside the
/// timed loop). Format is `.rgb`/`.rgba` to match `image-webp`'s output layout.
const DecodeStaticIntoCtx = struct {
    gpa: std.mem.Allocator,
    bytes: []const u8,
    dest: webp.ImageBuffer,
    fn runOnce(self: @This()) !void {
        try webp.decodeStaticInto(self.gpa, self.bytes, self.dest, .{
            .limits = bench_limits,
        });
    }
};

const DecodeAnimCtx = struct {
    gpa: std.mem.Allocator,
    bytes: []const u8,
    fn runOnce(self: @This()) !void {
        var animation = try webp.decodeAnimation(self.gpa, self.bytes, .{
            .output_format = .rgba,
            .limits = bench_limits,
        });
        animation.deinit();
    }
};

const EncodeLosslessCtx = struct {
    gpa: std.mem.Allocator,
    buffer: webp.ImageBuffer,
    fn runOnce(self: @This()) !void {
        const out = try webp.encodeLossless(self.gpa, self.buffer, .{ .limits = bench_limits });
        self.gpa.free(out);
    }
};

const EncodeLossyCtx = struct {
    gpa: std.mem.Allocator,
    buffer: webp.ImageBuffer,
    fn runOnce(self: @This()) !void {
        const out = try webp.encodeLossy(self.gpa, self.buffer, .{
            .format = .lossy,
            .quality = lossy_quality,
            .limits = bench_limits,
        });
        self.gpa.free(out);
    }
};

// --- Reporting -------------------------------------------------------------

const Stats = struct {
    rows: u32 = 0,
};

fn megapixelsPerSecond(pixels: u64, median_ns: u64) f64 {
    if (median_ns == 0 or pixels == 0) return 0;
    const seconds = @as(f64, @floatFromInt(median_ns)) / @as(f64, std.time.ns_per_s);
    return @as(f64, @floatFromInt(pixels)) / seconds / 1_000_000.0;
}

fn writeRow(
    writer: *std.Io.Writer,
    stats: *Stats,
    asset_class: []const u8,
    file: []const u8,
    operation: []const u8,
    format: []const u8,
    alpha: bool,
    width: u32,
    height: u32,
    pixels: u64,
    measurement: Measurement,
    bytes: u64,
) !void {
    const median_ms = @as(f64, @floatFromInt(measurement.median_ns)) / @as(f64, std.time.ns_per_ms);
    const min_ms = @as(f64, @floatFromInt(measurement.min_ns)) / @as(f64, std.time.ns_per_ms);
    try writer.print("{s}\t{s}\t{s}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d:.4}\t{d:.4}\t{d:.2}\t{d}\n", .{
        asset_class,
        file,
        operation,
        format,
        if (alpha) "alpha" else "opaque",
        width,
        height,
        pixels,
        measurement.samples,
        median_ms,
        min_ms,
        megapixelsPerSecond(pixels, measurement.median_ns),
        bytes,
    });
    stats.rows += 1;
}

// --- Decode benchmark ------------------------------------------------------

/// Single coarse asset class for a still/animation, so the report aggregates
/// cleanly. Precedence: animation, then alpha, then size buckets. The raw
/// format and alpha flag are separate columns, so this is only the bucket label.
fn classify(features: webp.FeatureSummary) []const u8 {
    if (features.is_animation) return "animation";
    if (features.has_alpha) return "alpha";
    const pixels = @as(u64, features.canvas.width) * features.canvas.height;
    if (pixels > 1 << 20) return "large"; // > ~1 megapixel
    if (pixels <= 64 * 64) return "icon";
    return "photo";
}

fn formatName(format: ?webp.features.FormatKind) []const u8 {
    return switch (format orelse return "none") {
        .lossy => "lossy",
        .lossless => "lossless",
    };
}

fn benchDecode(
    writer: *std.Io.Writer,
    digests_writer: ?*std.Io.Writer,
    ctx: cli.Cli,
    config: Config,
    stats: *Stats,
) !void {
    if (config.explicit_files.len != 0) {
        for (config.explicit_files) |path| {
            try benchDecodePath(writer, digests_writer, ctx, config, stats, path);
        }
        return;
    }
    try benchDecodeDir(writer, digests_writer, ctx, config, stats, encode_corpus.photos_root_path);
    try benchDecodeDir(writer, digests_writer, ctx, config, stats, corpus.default_root_path);
    try benchDecodeDir(writer, digests_writer, ctx, config, stats, corpus.default_animation_root_path);
}

/// Times decode of one caller-supplied WebP path (used by `--file`).
fn benchDecodePath(
    writer: *std.Io.Writer,
    digests_writer: ?*std.Io.Writer,
    ctx: cli.Cli,
    config: Config,
    stats: *Stats,
    path: []const u8,
) !void {
    const name = std.fs.path.basename(path);
    if (config.filter) |needle| {
        if (std.mem.indexOf(u8, name, needle) == null) return;
    }

    const bytes = try ctx.readInput(path);
    defer ctx.gpa.free(bytes);
    try benchDecodeBytes(writer, digests_writer, ctx, config, stats, name, bytes);
}

/// Times decode of every `*.webp` under `dir_path`. Missing directories are
/// skipped (a checkout may lack the in-tree corpus).
fn benchDecodeDir(
    writer: *std.Io.Writer,
    digests_writer: ?*std.Io.Writer,
    ctx: cli.Cli,
    config: Config,
    stats: *Stats,
    dir_path: []const u8,
) !void {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(ctx.io);

    var file_names = try cli.collectWebpFileNames(ctx.gpa, ctx.io, dir);
    defer cli.freeFileNames(ctx.gpa, &file_names);

    for (file_names.items) |name| {
        if (config.filter) |needle| {
            if (std.mem.indexOf(u8, name, needle) == null) continue;
        }

        const bytes = try corpus.readFileAlloc(ctx.gpa, name, .{
            .root_path = dir_path,
            .limits = bench_limits,
        });
        defer ctx.gpa.free(bytes);
        try benchDecodeBytes(writer, digests_writer, ctx, config, stats, name, bytes);
    }
}

/// Shared still/animation decode timing for one in-memory WebP payload.
fn benchDecodeBytes(
    writer: *std.Io.Writer,
    digests_writer: ?*std.Io.Writer,
    ctx: cli.Cli,
    config: Config,
    stats: *Stats,
    name: []const u8,
    bytes: []const u8,
) !void {
    var parsed = webp.parseWebP(ctx.gpa, bytes, .{ .limits = bench_limits }) catch return;
    const features = parsed.features;
    parsed.deinit();

    const asset_class = classify(features);
    const width = features.canvas.width;
    const height = features.canvas.height;
    const canvas_pixels = @as(u64, width) * height;

    if (features.is_animation) {
        // One untimed decode tells us the frame count for an honest
        // composited-pixel throughput; it doubles as a warmup.
        var probe = try webp.decodeAnimation(ctx.gpa, bytes, .{
            .output_format = .rgba,
            .limits = bench_limits,
        });
        const frame_count = probe.info.frame_count;
        probe.deinit();

        const measurement = try timeMedian(ctx.io, config, DecodeAnimCtx{ .gpa = ctx.gpa, .bytes = bytes });
        try writeRow(writer, stats, asset_class, name, "decode", formatName(features.format), features.has_alpha, width, height, canvas_pixels * frame_count, measurement, 0);
    } else {
        const measurement = timeMedian(ctx.io, config, DecodeStaticCtx{ .gpa = ctx.gpa, .bytes = bytes }) catch |err| {
            // A corpus file this build cannot decode is reported as a skip
            // on stderr rather than aborting the whole run.
            const msg = try std.fmt.allocPrint(ctx.gpa, "bench: skip {s} (decode error: {s})\n", .{ name, @errorName(err) });
            defer ctx.gpa.free(msg);
            try ctx.writeStderr(msg);
            return;
        };
        try writeRow(writer, stats, asset_class, name, "decode", formatName(features.format), features.has_alpha, width, height, canvas_pixels, measurement, 0);

        // decode-into: reuse a caller-owned buffer (rgb/rgba) allocated
        // outside timing; validate against allocating decodeStatic first.
        try benchDecodeStaticInto(
            writer,
            digests_writer,
            ctx,
            config,
            stats,
            asset_class,
            name,
            bytes,
            features,
            width,
            height,
            canvas_pixels,
        );
    }
}

/// Times `decodeStaticInto` into a reused destination. Allocates `dest`,
/// validates one untimed decode against allocating `decodeStatic` with the
/// same rgb/rgba format, then times repeated into-decodes. Digests (when
/// requested) and `doNotOptimizeAway` sit outside the timed interval.
fn benchDecodeStaticInto(
    writer: *std.Io.Writer,
    digests_writer: ?*std.Io.Writer,
    ctx: cli.Cli,
    config: Config,
    stats: *Stats,
    asset_class: []const u8,
    name: []const u8,
    bytes: []const u8,
    features: webp.FeatureSummary,
    width: u32,
    height: u32,
    canvas_pixels: u64,
) !void {
    const pixel_format: webp.image.PixelFormat = if (features.has_alpha) .rgba else .rgb;
    const channels: u32 = pixel_format.channelCount();
    const stride: u32 = width * channels;
    const dest_len: usize = @as(usize, stride) * @as(usize, height);
    const dest_pixels = try ctx.gpa.alloc(u8, dest_len);
    defer ctx.gpa.free(dest_pixels);
    const dest = webp.ImageBuffer{
        .pixels = dest_pixels,
        .dimensions = .{ .width = width, .height = height },
        .stride = stride,
        .format = pixel_format,
    };

    // Untimed reference: allocating decode in the same packed format.
    var reference = webp.decodeStatic(ctx.gpa, bytes, .{
        .output_format = pixel_format,
        .limits = bench_limits,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.gpa, "bench: skip {s} (decode-into reference error: {s})\n", .{ name, @errorName(err) });
        defer ctx.gpa.free(msg);
        try ctx.writeStderr(msg);
        return;
    };
    defer reference.deinit();

    webp.decodeStaticInto(ctx.gpa, bytes, dest, .{ .limits = bench_limits }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.gpa, "bench: skip {s} (decode-into error: {s})\n", .{ name, @errorName(err) });
        defer ctx.gpa.free(msg);
        try ctx.writeStderr(msg);
        return;
    };

    if (!std.mem.eql(u8, dest_pixels, reference.buffer.pixels)) {
        const msg = try std.fmt.allocPrint(ctx.gpa, "bench: skip {s} (decode-into mismatch vs decodeStatic)\n", .{name});
        defer ctx.gpa.free(msg);
        try ctx.writeStderr(msg);
        return;
    }

    if (digests_writer) |dw| {
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(dest_pixels, &digest, .{});
        try dw.print("{s}\t{s}\t{s}\t{s}\t{d}\t{d}\n", .{
            name,
            std.fmt.bytesToHex(&digest, .lower),
            formatName(features.format),
            if (features.has_alpha) "alpha" else "opaque",
            width,
            height,
        });
    }

    const into_measurement = timeMedian(ctx.io, config, DecodeStaticIntoCtx{
        .gpa = ctx.gpa,
        .bytes = bytes,
        .dest = dest,
    }) catch |err| {
        const msg = try std.fmt.allocPrint(ctx.gpa, "bench: skip {s} (decode-into timing error: {s})\n", .{ name, @errorName(err) });
        defer ctx.gpa.free(msg);
        try ctx.writeStderr(msg);
        return;
    };
    // Keep the reused buffer live across timing so the writes cannot be DCE'd.
    std.mem.doNotOptimizeAway(dest_pixels[0]);
    std.mem.doNotOptimizeAway(dest_pixels[dest_pixels.len - 1]);

    try writeRow(
        writer,
        stats,
        asset_class,
        name,
        "decode-into",
        formatName(features.format),
        features.has_alpha,
        width,
        height,
        canvas_pixels,
        into_measurement,
        0,
    );
}

// --- Encode benchmark ------------------------------------------------------

fn benchEncode(writer: *std.Io.Writer, ctx: cli.Cli, config: Config, stats: *Stats) !void {
    // Synthetic in-memory sources.
    for (synth.sources) |source| {
        if (config.filter) |needle| {
            if (std.mem.indexOf(u8, source.name, needle) == null) continue;
        }
        const rendered = try synth.render(ctx.gpa, source);
        defer rendered.deinit();
        try benchEncodeBuffer(writer, ctx, config, stats, "synthetic", source.name, rendered.buffer);
    }

    // The committed CC0 photographs, decoded to pristine RGBA first.
    try benchEncodeDir(writer, ctx, config, stats, encode_corpus.photos_root_path);
}

/// Decodes each still `*.webp` under `dir_path` to RGBA and benchmarks encoding
/// those source pixels. Missing directories are skipped.
fn benchEncodeDir(
    writer: *std.Io.Writer,
    ctx: cli.Cli,
    config: Config,
    stats: *Stats,
    dir_path: []const u8,
) !void {
    var dir = std.Io.Dir.cwd().openDir(ctx.io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return,
        else => return err,
    };
    defer dir.close(ctx.io);

    var file_names = try cli.collectWebpFileNames(ctx.gpa, ctx.io, dir);
    defer cli.freeFileNames(ctx.gpa, &file_names);

    for (file_names.items) |name| {
        if (config.filter) |needle| {
            if (std.mem.indexOf(u8, name, needle) == null) continue;
        }
        const bytes = try corpus.readFileAlloc(ctx.gpa, name, .{
            .root_path = dir_path,
            .limits = bench_limits,
        });
        defer ctx.gpa.free(bytes);

        var source = webp.decodeStatic(ctx.gpa, bytes, .{
            .output_format = .rgba,
            .limits = bench_limits,
        }) catch continue;
        defer source.deinit();

        try benchEncodeBuffer(writer, ctx, config, stats, "photo", name, source.buffer);
    }
}

fn benchEncodeBuffer(
    writer: *std.Io.Writer,
    ctx: cli.Cli,
    config: Config,
    stats: *Stats,
    asset_class: []const u8,
    name: []const u8,
    buffer: webp.ImageBuffer,
) !void {
    const width = buffer.dimensions.width;
    const height = buffer.dimensions.height;
    const pixels = @as(u64, width) * height;
    // The encoders only emit an ALPH chunk (and run the alpha path) when the
    // source actually carries transparency, so label the row by that, not by
    // whether the format merely has an alpha channel.
    const alpha = bufferHasTransparency(buffer);

    // Encoded size is informative for an encode benchmark, so re-encode once
    // (untimed) to capture it.
    const lossless_bytes = blk: {
        const out = try webp.encodeLossless(ctx.gpa, buffer, .{ .limits = bench_limits });
        defer ctx.gpa.free(out);
        break :blk out.len;
    };
    const lossless = try timeMedian(ctx.io, config, EncodeLosslessCtx{ .gpa = ctx.gpa, .buffer = buffer });
    try writeRow(writer, stats, asset_class, name, "encode-lossless", "lossless", alpha, width, height, pixels, lossless, lossless_bytes);

    const lossy_bytes = blk: {
        const out = try webp.encodeLossy(ctx.gpa, buffer, .{ .format = .lossy, .quality = lossy_quality, .limits = bench_limits });
        defer ctx.gpa.free(out);
        break :blk out.len;
    };
    const lossy = try timeMedian(ctx.io, config, EncodeLossyCtx{ .gpa = ctx.gpa, .buffer = buffer });
    try writeRow(writer, stats, asset_class, name, "encode-lossy", "lossy", alpha, width, height, pixels, lossy, lossy_bytes);
}

/// True when `buffer` has an alpha channel and at least one pixel is not fully
/// opaque — the condition under which the encoders run the alpha path.
fn bufferHasTransparency(buffer: webp.ImageBuffer) bool {
    const channels: usize = buffer.format.channelCount();
    const alpha_offset: usize = switch (buffer.format) {
        .rgb => return false,
        .rgba, .bgra => 3,
        .argb => 0,
    };
    const width: usize = buffer.dimensions.width;
    const height: usize = buffer.dimensions.height;
    const stride: usize = buffer.stride;
    var y: usize = 0;
    while (y < height) : (y += 1) {
        const row = buffer.pixels[y * stride ..][0 .. width * channels];
        var x: usize = 0;
        while (x < width) : (x += 1) {
            if (row[x * channels + alpha_offset] != 255) return true;
        }
    }
    return false;
}

// --- Argument parsing + main ----------------------------------------------

fn parseU32(ctx: cli.Cli, value: []const u8, usage_text: []const u8) u32 {
    return std.fmt.parseInt(u32, value, 10) catch ctx.usageError(usage_text);
}

const usage =
    "usage: zig-webp-bench [--iters N] [--warmup N] [--budget-ms N]\n" ++
    "                      [--filter SUBSTR] [--file PATH]...\n" ++
    "                      [--decode-only|--encode-only]\n" ++
    "                      [--write-digests PATH] [OUTPUT.tsv]\n" ++
    "Benchmarks this library's decode/encode entry points in memory and writes a TSV.\n" ++
    "`--file` (repeatable) times the supplied path(s) instead of scanning corpus dirs.\n";

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);

    // Debug builds are instrumented and several times slower; their timings are
    // not comparable to the committed ReleaseFast baseline, so warn loudly.
    if (builtin.mode == .Debug) {
        try ctx.writeStderr("bench: warning: built in Debug; rebuild with `-Doptimize=ReleaseFast` for meaningful timings.\n");
    }

    var config = Config{};
    var output_path: ?[]const u8 = null;
    var explicit_files: std.ArrayList([]const u8) = .empty;
    defer explicit_files.deinit(ctx.gpa);

    var i: usize = 1;
    while (i < ctx.args.len) : (i += 1) {
        const arg = ctx.args[i];
        if (std.mem.eql(u8, arg, "--iters")) {
            i += 1;
            if (i >= ctx.args.len) ctx.usageError(usage);
            config.iters = @max(1, parseU32(ctx, ctx.args[i], usage));
        } else if (std.mem.eql(u8, arg, "--warmup")) {
            i += 1;
            if (i >= ctx.args.len) ctx.usageError(usage);
            config.warmup = parseU32(ctx, ctx.args[i], usage);
        } else if (std.mem.eql(u8, arg, "--budget-ms")) {
            i += 1;
            if (i >= ctx.args.len) ctx.usageError(usage);
            config.budget_ns = @as(u64, parseU32(ctx, ctx.args[i], usage)) * std.time.ns_per_ms;
        } else if (std.mem.eql(u8, arg, "--filter")) {
            i += 1;
            if (i >= ctx.args.len) ctx.usageError(usage);
            config.filter = ctx.args[i];
        } else if (std.mem.eql(u8, arg, "--file")) {
            i += 1;
            if (i >= ctx.args.len) ctx.usageError(usage);
            try explicit_files.append(ctx.gpa, ctx.args[i]);
        } else if (std.mem.eql(u8, arg, "--decode-only")) {
            config.do_encode = false;
        } else if (std.mem.eql(u8, arg, "--encode-only")) {
            config.do_decode = false;
        } else if (std.mem.eql(u8, arg, "--write-digests")) {
            i += 1;
            if (i >= ctx.args.len) ctx.usageError(usage);
            config.digests_path = ctx.args[i];
        } else if (output_path == null and !std.mem.startsWith(u8, arg, "--")) {
            output_path = arg;
        } else {
            ctx.usageError(usage);
        }
    }
    config.explicit_files = explicit_files.items;

    var report: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer report.deinit();
    const writer = &report.writer;
    try writer.print(
        "# zig-webp performance benchmark: median of up to {d} timed runs ({d} warmup, {d} ms budget).\n" ++
            "# Wall-clock, in-memory, environment-dependent — a local report, not a CI gate.\n" ++
            "asset_class\tfile\toperation\tformat\talpha\twidth\theight\tpixels\tsamples\tmedian_ms\tmin_ms\tmpps\tbytes\n",
        .{ config.iters, config.warmup, config.budget_ns / std.time.ns_per_ms },
    );

    var digests_report: ?std.Io.Writer.Allocating = if (config.digests_path != null) .init(ctx.gpa) else null;
    defer if (digests_report) |*dr| dr.deinit();
    const digests_writer: ?*std.Io.Writer = if (digests_report) |*dr| &dr.writer else null;
    if (digests_writer) |dw| {
        try dw.writeAll("# zig-webp decode-into digests (SHA-256 of packed rgb/rgba pixels)\n");
        try dw.writeAll("file\tsha256\tformat\talpha\twidth\theight\n");
    }

    var stats = Stats{};
    if (config.do_decode) try benchDecode(writer, digests_writer, ctx, config, &stats);
    if (config.do_encode) try benchEncode(writer, ctx, config, &stats);

    if (config.digests_path) |digests_path| {
        const payload = digests_report.?.written();
        try ctx.writeOutput(digests_path, payload);
    }

    if (output_path) |path| {
        try ctx.writeOutput(path, report.written());
    } else {
        try ctx.writeStdout(report.written());
    }

    var summary_buffer: [128]u8 = undefined;
    const summary = try std.fmt.bufPrint(&summary_buffer, "bench: {d} rows measured\n", .{stats.rows});
    try ctx.writeStderr(summary);
}
