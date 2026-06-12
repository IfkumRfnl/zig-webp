//! Helpers for committed WebP corpus files.

const std = @import("std");

const demux = @import("../demux.zig");
const errors = @import("../errors.zig");
const limits = @import("../limits.zig");

pub const default_root_path = "testdata/libwebp-test-data";
pub const default_webp_file_count = 131;
pub const default_lossy_still_file_count = 88;

pub const Options = struct {
    root_path: []const u8 = default_root_path,
    limits: limits.ResourceLimits = .{},
};

pub fn readFileAlloc(
    gpa: std.mem.Allocator,
    relative_path: []const u8,
    options: Options,
) ![]u8 {
    try validateRelativePath(relative_path);

    const io = std.Io.Threaded.global_single_threaded.io();
    var root = std.Io.Dir.cwd().openDir(io, options.root_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.CorpusUnavailable,
        error.NotDir => return error.CorpusUnavailable,
        else => return err,
    };
    defer root.close(io);

    const bytes = root.readFileAlloc(
        io,
        relative_path,
        gpa,
        inclusiveInputLimit(options.limits.input_bytes_max),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.InputTooLarge,
        error.FileNotFound => return error.CorpusUnavailable,
        else => return err,
    };
    errdefer gpa.free(bytes);

    try options.limits.validateInputBytes(bytes.len);
    return bytes;
}

fn inclusiveInputLimit(input_bytes_max: u64) std.Io.Limit {
    const exclusive_limit = std.math.add(u64, input_bytes_max, 1) catch {
        return .unlimited;
    };

    return .limited64(exclusive_limit);
}

fn validateRelativePath(path: []const u8) errors.Error!void {
    if (path.len == 0) return error.InvalidCorpusPath;
    if (std.fs.path.isAbsolute(path)) return error.InvalidCorpusPath;
    if (std.fs.path.parsePathWindows(u8, path).kind != .relative) {
        return error.InvalidCorpusPath;
    }

    var posix_iterator = std.fs.path.ComponentIterator(.posix, u8).init(path);
    while (posix_iterator.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) return error.InvalidCorpusPath;
    }

    var windows_iterator = std.fs.path.ComponentIterator(.windows, u8).init(path);
    while (windows_iterator.next()) |component| {
        if (std.mem.eql(u8, component.name, "..")) return error.InvalidCorpusPath;
    }
}

test "reads corpus files from an explicit local root" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "sample.webp",
        .data = "webp",
    });

    var root_path_buffer: [128]u8 = undefined;
    const root_path = try std.fmt.bufPrint(
        &root_path_buffer,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    const bytes = try readFileAlloc(std.testing.allocator, "sample.webp", .{
        .root_path = root_path,
    });
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, "webp", bytes);
}

test "accepts corpus files exactly at the configured input limit" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{
        .sub_path = "sample.webp",
        .data = "webp",
    });

    var root_path_buffer: [128]u8 = undefined;
    const root_path = try std.fmt.bufPrint(
        &root_path_buffer,
        ".zig-cache/tmp/{s}",
        .{tmp.sub_path},
    );
    const bytes = try readFileAlloc(std.testing.allocator, "sample.webp", .{
        .root_path = root_path,
        .limits = .{ .input_bytes_max = 4 },
    });
    defer std.testing.allocator.free(bytes);

    try std.testing.expectEqualSlices(u8, "webp", bytes);
}

test "parses committed libwebp WebP corpus" {
    const io = std.Io.Threaded.global_single_threaded.io();
    var root = std.Io.Dir.cwd().openDir(io, default_root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        error.NotDir => return error.SkipZigTest,
        else => return err,
    };
    defer root.close(io);

    const corpus_limits = limits.ResourceLimits{
        .output_pixels_max = std.math.maxInt(u32),
        .animation_canvas_pixels_max = std.math.maxInt(u32),
    };

    var parsed_count: u32 = 0;
    var iterator = root.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".webp")) continue;

        {
            const bytes = try readFileAlloc(std.testing.allocator, entry.name, .{
                .limits = corpus_limits,
            });
            defer std.testing.allocator.free(bytes);

            var result = demux.parse(std.testing.allocator, bytes, .{
                .limits = corpus_limits,
            }) catch |err| {
                std.debug.print("failed to parse corpus file {s}: {s}\n", .{
                    entry.name,
                    @errorName(err),
                });
                return err;
            };
            defer result.deinit();
        }

        parsed_count += 1;
    }

    try std.testing.expectEqual(@as(u32, default_webp_file_count), parsed_count);
}

test "decodes alpha planes from the committed corpus" {
    const alpha = @import("../alpha.zig");

    const alpha_files = [_]struct {
        name: []const u8,
        compression: alpha.Compression,
        filter: alpha.Filter,
    }{
        .{ .name = "alpha_no_compression.webp", .compression = .none, .filter = .none },
        .{ .name = "alpha_filter_0_method_0.webp", .compression = .none, .filter = .none },
        .{ .name = "alpha_filter_1_method_0.webp", .compression = .none, .filter = .horizontal },
        .{ .name = "alpha_filter_2_method_0.webp", .compression = .none, .filter = .vertical },
        .{ .name = "alpha_filter_3_method_0.webp", .compression = .none, .filter = .gradient },
        .{ .name = "alpha_filter_0_method_1.webp", .compression = .lossless, .filter = .none },
        .{ .name = "alpha_filter_1_method_1.webp", .compression = .lossless, .filter = .horizontal },
        .{ .name = "alpha_filter_2_method_1.webp", .compression = .lossless, .filter = .vertical },
        .{ .name = "alpha_filter_3_method_1.webp", .compression = .lossless, .filter = .gradient },
        .{ .name = "alpha_filter_1.webp", .compression = .lossless, .filter = .horizontal },
        .{ .name = "alpha_filter_2.webp", .compression = .lossless, .filter = .vertical },
        .{ .name = "alpha_filter_3.webp", .compression = .lossless, .filter = .gradient },
        .{ .name = "alpha_color_cache.webp", .compression = .lossless, .filter = .none },
        .{ .name = "lossy_alpha1.webp", .compression = .lossless, .filter = .none },
    };

    for (alpha_files) |corpus_file| {
        const bytes = readFileAlloc(
            std.testing.allocator,
            corpus_file.name,
            .{},
        ) catch |err| switch (err) {
            error.CorpusUnavailable => return error.SkipZigTest,
            else => return err,
        };
        defer std.testing.allocator.free(bytes);

        var result = try demux.parse(std.testing.allocator, bytes, .{});
        defer result.deinit();

        const location = result.features.alpha orelse return error.TestUnexpectedResult;
        const dimensions = result.features.canvas;
        const pixel_count: usize = @intCast(try dimensions.pixelCount());

        const plane = try std.testing.allocator.alloc(u8, pixel_count);
        defer std.testing.allocator.free(plane);

        const header = try alpha.decodePlaneAlloc(
            std.testing.allocator,
            location.payload(bytes),
            dimensions,
            plane,
        );

        try std.testing.expectEqual(corpus_file.compression, header.compression);
        try std.testing.expectEqual(corpus_file.filter, header.filter);
    }
}

test "parses VP8 frame headers from the committed corpus" {
    const frame_header = @import("../vp8/frame_header.zig");

    const io = std.Io.Threaded.global_single_threaded.io();
    var root = std.Io.Dir.cwd().openDir(io, default_root_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        error.NotDir => return error.SkipZigTest,
        else => return err,
    };
    defer root.close(io);

    const corpus_limits = limits.ResourceLimits{
        .output_pixels_max = std.math.maxInt(u32),
        .animation_canvas_pixels_max = std.math.maxInt(u32),
    };

    var parsed_count: u32 = 0;
    var iterator = root.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".webp")) continue;

        const bytes = try readFileAlloc(std.testing.allocator, entry.name, .{
            .limits = corpus_limits,
        });
        defer std.testing.allocator.free(bytes);

        var result = try demux.parse(std.testing.allocator, bytes, .{
            .limits = corpus_limits,
        });
        defer result.deinit();

        if (result.features.is_animation) continue;
        const format = result.features.format orelse continue;
        if (format != .lossy) continue;
        const image_chunk = result.features.image_data orelse continue;

        var parsed: frame_header.Parsed = undefined;
        frame_header.parse(image_chunk.payload(bytes), &parsed) catch |err| {
            std.debug.print("failed to parse VP8 frame header in {s}: {s}\n", .{
                entry.name,
                @errorName(err),
            });
            return err;
        };

        try std.testing.expectEqual(
            result.features.canvas.width,
            parsed.header.picture.dimensions.width,
        );
        try std.testing.expectEqual(
            result.features.canvas.height,
            parsed.header.picture.dimensions.height,
        );

        parsed_count += 1;
    }

    try std.testing.expectEqual(@as(u32, default_lossy_still_file_count), parsed_count);
}

test "rejects corpus paths that escape the configured root" {
    try std.testing.expectError(
        error.InvalidCorpusPath,
        validateRelativePath("../x.webp"),
    );
    try std.testing.expectError(
        error.InvalidCorpusPath,
        validateRelativePath("/tmp/x.webp"),
    );
    try std.testing.expectError(
        error.InvalidCorpusPath,
        validateRelativePath("..\\x.webp"),
    );
    try std.testing.expectError(
        error.InvalidCorpusPath,
        validateRelativePath("C:\\tmp\\x.webp"),
    );
}
