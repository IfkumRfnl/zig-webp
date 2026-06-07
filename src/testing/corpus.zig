//! Helpers for committed WebP corpus files.

const std = @import("std");

const demux = @import("../demux.zig");
const errors = @import("../errors.zig");
const limits = @import("../limits.zig");

pub const default_root_path = "testdata/libwebp-test-data";
pub const default_webp_file_count = 131;

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
