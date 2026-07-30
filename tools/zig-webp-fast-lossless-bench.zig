//! Narrow Plan 030 benchmark helper. The shell driver owns orchestration and the
//! local C adapter; this executable prepares pinned RGBA buffers, measures the
//! Zig lossless encoder, and validates dwebp's decoded PAM output.

const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

const clock = std.Io.Clock.awake;
const warmup_count: u32 = 3;
const sample_count: u32 = 15;
const sample_count_max: u32 = 31;
const batch_pixels_target: u32 = 262_144;
const batch_count_max: u32 = 256;
const raw_header_size = 12;
const raw_magic = "RGBA";

const Entry = struct {
    id: []const u8,
    class: []const u8,
    kind: []const u8,
    source: []const u8,
    provenance: []const u8,
};

const Raw = struct {
    storage: []u8,
    pixels: []u8,
    width: u32,
    height: u32,

    fn deinit(raw: Raw, gpa: std.mem.Allocator) void {
        gpa.free(raw.storage);
    }
};

const usage =
    "usage: zig-webp-fast-lossless-bench prepare-bench MANIFEST WORK OUTPUT.tsv METHOD\n" ++
    "       zig-webp-fast-lossless-bench validate RAW PAM\n";

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);
    if (ctx.args.len == 6 and std.mem.eql(u8, ctx.args[1], "prepare-bench")) {
        const method = try std.fmt.parseInt(u8, ctx.args[5], 10);
        if (method > 6) return error.InvalidMethod;
        try prepareAndBench(ctx, ctx.args[2], ctx.args[3], ctx.args[4], method);
        return;
    }
    if (ctx.args.len == 4 and std.mem.eql(u8, ctx.args[1], "validate")) {
        try validatePam(ctx, ctx.args[2], ctx.args[3]);
        return;
    }
    ctx.usageError(usage);
}

fn prepareAndBench(
    ctx: cli.Cli,
    manifest_path: []const u8,
    work_path: []const u8,
    output_path: []const u8,
    method: u8,
) !void {
    const manifest = try ctx.readInput(manifest_path);
    defer ctx.gpa.free(manifest);

    var report: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer report.deinit();

    var lines = std.mem.splitScalar(u8, manifest, '\n');
    while (lines.next()) |line| {
        const entry = (try parseEntry(line)) orelse continue;
        var pixels = if (std.mem.eql(u8, entry.kind, "generated"))
            try generate(ctx.gpa, entry.source)
        else if (std.mem.eql(u8, entry.kind, "webp"))
            try decodeSource(ctx, entry.source)
        else
            return error.InvalidManifest;
        defer pixels.deinit(ctx.gpa);

        const raw_path = try std.fmt.allocPrint(
            ctx.gpa,
            "{s}/raw/{s}.rgba",
            .{ work_path, entry.id },
        );
        defer ctx.gpa.free(raw_path);
        try writeRaw(ctx, raw_path, pixels);

        const output_webp = try std.fmt.allocPrint(
            ctx.gpa,
            "{s}/out/{s}.zig.webp",
            .{ work_path, entry.id },
        );
        defer ctx.gpa.free(output_webp);
        try benchOne(ctx, &report.writer, entry, pixels, output_webp, method);
    }
    try ctx.writeOutput(output_path, report.written());
}

fn parseEntry(line: []const u8) !?Entry {
    if (line.len == 0 or line[0] == '#') return null;
    if (std.mem.startsWith(u8, line, "id\tclass\t")) return null;
    var fields = std.mem.splitScalar(u8, line, '\t');
    const id = fields.next() orelse return error.InvalidManifest;
    const class = fields.next() orelse return error.InvalidManifest;
    const kind = fields.next() orelse return error.InvalidManifest;
    const source = fields.next() orelse return error.InvalidManifest;
    const provenance = fields.next() orelse return error.InvalidManifest;
    _ = fields.next() orelse return error.InvalidManifest;
    if (fields.next() != null) return error.InvalidManifest;
    return .{
        .id = id,
        .class = class,
        .kind = kind,
        .source = source,
        .provenance = provenance,
    };
}

fn decodeSource(ctx: cli.Cli, path: []const u8) !Raw {
    const encoded = try ctx.readInput(path);
    defer ctx.gpa.free(encoded);
    var decoded = try webp.decodeStatic(ctx.gpa, encoded, .{ .output_format = .rgba });
    defer decoded.deinit();
    const pixel_count = @as(usize, decoded.buffer.dimensions.width) *
        decoded.buffer.dimensions.height;
    const storage = try ctx.gpa.dupe(u8, decoded.buffer.pixels[0 .. pixel_count * 4]);
    return .{
        .storage = storage,
        .pixels = storage,
        .width = decoded.buffer.dimensions.width,
        .height = decoded.buffer.dimensions.height,
    };
}

fn generate(gpa: std.mem.Allocator, name: []const u8) !Raw {
    const dimensions: struct { width: u32, height: u32 } =
        if (std.mem.eql(u8, name, "toolbar-17"))
            .{ .width = 17, .height = 17 }
        else if (std.mem.eql(u8, name, "dashboard-320"))
            .{ .width = 320, .height = 180 }
        else if (std.mem.eql(u8, name, "alpha-icon-32"))
            .{ .width = 32, .height = 32 }
        else if (std.mem.eql(u8, name, "alpha-badge-193"))
            .{ .width = 193, .height = 71 }
        else if (std.mem.eql(u8, name, "gradient-257"))
            .{ .width = 257, .height = 129 }
        else
            return error.InvalidManifest;

    const pixel_count = @as(usize, dimensions.width) * dimensions.height;
    const pixels = try gpa.alloc(u8, pixel_count * 4);
    errdefer gpa.free(pixels);
    var y: u32 = 0;
    while (y < dimensions.height) : (y += 1) {
        var x: u32 = 0;
        while (x < dimensions.width) : (x += 1) {
            const offset = (@as(usize, y) * dimensions.width + x) * 4;
            var rgba: [4]u8 = undefined;
            if (std.mem.eql(u8, name, "toolbar-17")) {
                const color = (x / 4 + y / 6) % 6;
                rgba = .{
                    @intCast(24 + color * 31),
                    @intCast(40 + color * 17),
                    @intCast(60 + color * 11),
                    255,
                };
            } else if (std.mem.eql(u8, name, "dashboard-320")) {
                const panel = ((x / 40) + (y / 30) * 3) % 16;
                rgba = .{
                    @intCast(panel * 13),
                    @intCast(32 + panel * 9),
                    @intCast(80 + panel * 7),
                    255,
                };
            } else if (std.mem.eql(u8, name, "alpha-icon-32")) {
                const dx: i32 = @as(i32, @intCast(x)) - 15;
                const dy: i32 = @as(i32, @intCast(y)) - 15;
                const distance: u32 = @min(
                    @as(u32, @intCast(@abs(dx) + @abs(dy))),
                    @as(u32, 31),
                );
                const alpha: u8 = if (distance < 10)
                    255
                else if (distance < 16)
                    @intCast((16 - distance) * 42)
                else
                    0;
                rgba = .{ 28, 132, 220, alpha };
            } else if (std.mem.eql(u8, name, "alpha-badge-193")) {
                const edge = @min(
                    @min(x, dimensions.width - 1 - x),
                    @min(y, dimensions.height - 1 - y),
                );
                const alpha: u8 = if (edge >= 5) 224 else @intCast(edge * 44);
                const stripe: u8 = @intCast((x / 16) % 4);
                rgba = .{
                    @intCast(40 + stripe * 35),
                    @intCast(90 + stripe * 20),
                    180,
                    alpha,
                };
            } else {
                rgba = .{
                    @truncate(x),
                    @truncate(y * 2),
                    @truncate(x + y),
                    @intCast(96 + ((x + y) % 160)),
                };
            }
            @memcpy(pixels[offset..][0..4], &rgba);
        }
    }
    return .{
        .storage = pixels,
        .pixels = pixels,
        .width = dimensions.width,
        .height = dimensions.height,
    };
}

fn writeRaw(ctx: cli.Cli, path: []const u8, raw: Raw) !void {
    const bytes = try ctx.gpa.alloc(u8, raw_header_size + raw.pixels.len);
    defer ctx.gpa.free(bytes);
    @memcpy(bytes[0..4], raw_magic);
    std.mem.writeInt(u32, bytes[4..8], raw.width, .little);
    std.mem.writeInt(u32, bytes[8..12], raw.height, .little);
    @memcpy(bytes[raw_header_size..], raw.pixels);
    try ctx.writeOutput(path, bytes);
}

fn readRaw(ctx: cli.Cli, path: []const u8) !Raw {
    const storage = try ctx.readInput(path);
    errdefer ctx.gpa.free(storage);
    if (storage.len < raw_header_size) return error.InvalidRaw;
    if (!std.mem.eql(u8, storage[0..4], raw_magic)) return error.InvalidRaw;
    const width = std.mem.readInt(u32, storage[4..8], .little);
    const height = std.mem.readInt(u32, storage[8..12], .little);
    const byte_count = @as(u64, width) * height * 4;
    if (byte_count != storage.len - raw_header_size) return error.InvalidRaw;
    return .{
        .storage = storage,
        .pixels = storage[raw_header_size..],
        .width = width,
        .height = height,
    };
}

fn benchOne(
    ctx: cli.Cli,
    writer: *std.Io.Writer,
    entry: Entry,
    raw: Raw,
    output_path: []const u8,
    method: u8,
) !void {
    const buffer = webp.ImageBuffer{
        .pixels = raw.pixels,
        .dimensions = .{ .width = raw.width, .height = raw.height },
        .stride = raw.width * 4,
        .format = .rgba,
    };
    const pixel_count = raw.width * raw.height;
    const batch_count = @min(
        batch_count_max,
        @max(1, batch_pixels_target / @max(1, pixel_count)),
    );

    var warmup_index: u32 = 0;
    while (warmup_index < warmup_count) : (warmup_index += 1) {
        try encodeBatch(ctx.gpa, buffer, batch_count, method);
    }

    var samples: [sample_count_max]u64 = undefined;
    var sample_index: u32 = 0;
    while (sample_index < sample_count) : (sample_index += 1) {
        const start = clock.now(ctx.io);
        try encodeBatch(ctx.gpa, buffer, batch_count, method);
        const elapsed: u64 = @intCast(start.durationTo(clock.now(ctx.io)).nanoseconds);
        samples[sample_index] = elapsed / batch_count;
    }
    std.mem.sort(u64, samples[0..sample_count], {}, std.sort.asc(u64));
    const median_ns = samples[sample_count / 2];

    const encoded = try webp.encodeLossless(ctx.gpa, buffer, .{ .method = method });
    defer ctx.gpa.free(encoded);
    try ctx.writeOutput(output_path, encoded);
    var decoded = try webp.decodeStatic(ctx.gpa, encoded, .{ .output_format = .rgba });
    defer decoded.deinit();
    const roundtrip = decoded.buffer.dimensions.width == raw.width and
        decoded.buffer.dimensions.height == raw.height and
        std.mem.eql(u8, decoded.buffer.pixels, raw.pixels);
    if (!roundtrip) return error.RoundTripMismatch;

    const colors = colorCount(raw.pixels);
    const has_alpha = hasAlpha(raw.pixels);
    const mpps = @as(f64, @floatFromInt(pixel_count)) * 1000.0 /
        @as(f64, @floatFromInt(median_ns));
    try writer.print(
        "file\t{s}\t{s}\t{s}\tzig-current\tmethod-{d}\t{d}\t{d}\t{d}\t{d}\t" ++
            "{s}\t{s}\t{d}\t{d}\t{d}\t{d:.6}\t{d}\tyes\tyes\n",
        .{
            entry.class, entry.id, entry.provenance,     method,           raw.width,    raw.height,
            pixel_count, colors,   yesNo(colors <= 256), yesNo(has_alpha), sample_count, batch_count,
            median_ns,   mpps,     encoded.len,
        },
    );
}

fn encodeBatch(
    gpa: std.mem.Allocator,
    buffer: webp.ImageBuffer,
    batch_count: u32,
    method: u8,
) !void {
    var index: u32 = 0;
    while (index < batch_count) : (index += 1) {
        const encoded = try webp.encodeLossless(gpa, buffer, .{ .method = method });
        gpa.free(encoded);
    }
}

fn colorCount(pixels: []const u8) u32 {
    var colors: [256]u32 = undefined;
    var count: u32 = 0;
    var offset: usize = 0;
    while (offset < pixels.len) : (offset += 4) {
        const color = std.mem.readInt(u32, pixels[offset..][0..4], .little);
        var found = false;
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            if (colors[index] == color) {
                found = true;
                break;
            }
        }
        if (!found) {
            if (count == colors.len) return count + 1;
            colors[count] = color;
            count += 1;
        }
    }
    return count;
}

fn hasAlpha(pixels: []const u8) bool {
    var offset: usize = 3;
    while (offset < pixels.len) : (offset += 4) {
        if (pixels[offset] != 255) return true;
    }
    return false;
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

fn validatePam(ctx: cli.Cli, raw_path: []const u8, pam_path: []const u8) !void {
    const raw = try readRaw(ctx, raw_path);
    defer raw.deinit(ctx.gpa);
    const pam = try ctx.readInput(pam_path);
    defer ctx.gpa.free(pam);
    const marker = "ENDHDR\n";
    const marker_offset = std.mem.indexOf(u8, pam, marker) orelse return error.InvalidPam;
    const header = pam[0..marker_offset];
    const payload = pam[marker_offset + marker.len ..];
    const is_rgba = std.mem.indexOf(u8, header, "DEPTH 4") != null;
    const is_rgb = std.mem.indexOf(u8, header, "DEPTH 3") != null;
    if (is_rgba) {
        if (!std.mem.eql(u8, payload, raw.pixels)) return error.RoundTripMismatch;
    } else if (is_rgb) {
        const pixel_count = @as(usize, raw.width) * raw.height;
        if (payload.len != pixel_count * 3) return error.InvalidPam;
        var pixel_index: usize = 0;
        while (pixel_index < pixel_count) : (pixel_index += 1) {
            const source = raw.pixels[pixel_index * 4 ..][0..3];
            if (!std.mem.eql(u8, payload[pixel_index * 3 ..][0..3], source)) {
                return error.RoundTripMismatch;
            }
            if (raw.pixels[pixel_index * 4 + 3] != 255) return error.RoundTripMismatch;
        }
    } else {
        return error.InvalidPam;
    }
}
