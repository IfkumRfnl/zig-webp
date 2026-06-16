//! Shared boilerplate for the `zig-webp-*` CLI tools.
//!
//! Every tool wires up the same process scaffolding (general-purpose
//! allocator, the `std.Io` handle, argv) and then performs a handful of the
//! same side effects (read a file into a buffer, write a buffer out, print a
//! usage string and exit 2, print a skip message and exit). Hoisting that here
//! keeps each tool focused on its codec-specific work without changing any
//! observable behavior: the same arguments, output bytes, exit codes, and
//! messages flow through these helpers as the tools used inline before.

const std = @import("std");
const webp = @import("webp");

/// Exit code for a usage error (wrong argument count / unknown flag). Matches
/// the convention every tool used inline before this module existed.
pub const usage_exit_code = 2;

/// Process scaffolding shared by every tool. Built once at the top of `main`
/// from the `std.process.Init` the runtime hands us, then threaded through the
/// I/O helpers below.
pub const Cli = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    args: []const []const u8,

    /// Destructure `std.process.Init` into the pieces the tools actually use.
    /// `args` is allocated from the init arena, so it lives for the whole
    /// process and never needs freeing.
    pub fn init(process: std.process.Init) !Cli {
        return .{
            .gpa = process.gpa,
            .io = process.io,
            .args = try process.minimal.args.toSlice(process.arena.allocator()),
        };
    }

    /// Print `usage` to stderr and exit with the usage exit code. `usage` is
    /// tool-specific and stays in each tool; only the write-and-exit pattern is
    /// shared. Never returns.
    pub fn usageError(cli: Cli, usage: []const u8) noreturn {
        // A failed usage write still means a usage error, so swallow any write
        // failure and exit with the usage code regardless.
        std.Io.File.stderr().writeStreamingAll(cli.io, usage) catch {};
        std.process.exit(usage_exit_code);
    }

    /// Print `message` to stderr and exit with `code`. Used by tools that skip
    /// inputs they cannot handle (e.g. "not a static lossy image" with exit 3).
    /// Never returns.
    pub fn exitWithMessage(cli: Cli, message: []const u8, code: u8) noreturn {
        std.Io.File.stderr().writeStreamingAll(cli.io, message) catch {};
        std.process.exit(code);
    }

    /// Read the file at `path` into a freshly allocated buffer, bounded by the
    /// default `input_bytes_max` limit the tools all used. The caller owns the
    /// returned slice and must free it with `cli.gpa`.
    pub fn readInput(cli: Cli, path: []const u8) ![]u8 {
        return std.Io.Dir.cwd().readFileAlloc(
            cli.io,
            path,
            cli.gpa,
            .limited64((webp.ResourceLimits{}).input_bytes_max),
        );
    }

    /// Write `data` to the file at `path` in the current working directory,
    /// creating or truncating it. Mirrors the `writeFile` call every tool made.
    pub fn writeOutput(cli: Cli, path: []const u8, data: []const u8) !void {
        try std.Io.Dir.cwd().writeFile(cli.io, .{
            .sub_path = path,
            .data = data,
        });
    }

    /// Write `text` to stdout. Mirrors the `stdout` summary writes the tools
    /// performed inline.
    pub fn writeStdout(cli: Cli, text: []const u8) !void {
        try std.Io.File.stdout().writeStreamingAll(cli.io, text);
    }

    /// Write `text` to stderr without exiting. For status lines (e.g. the hash
    /// tools' "wrote N rows" summary) that the tools sent to stderr.
    pub fn writeStderr(cli: Cli, text: []const u8) !void {
        try std.Io.File.stderr().writeStreamingAll(cli.io, text);
    }
};

/// Two input/output paths plus the optional `--nofilter` flag, as parsed from
/// argv by `parseNoFilterTwoPaths`.
pub const NoFilterTwoPaths = struct {
    input_path: []const u8,
    output_path: []const u8,
    nofilter: bool,
};

/// Parse the `[--nofilter] INPUT OUTPUT` argv shape shared by the `yuv` and
/// `rgb` tools: an optional `--nofilter` flag in any position plus exactly two
/// positionals. On any other shape, print `usage` and exit (never returns).
pub fn parseNoFilterTwoPaths(ctx: Cli, usage: []const u8) NoFilterTwoPaths {
    var nofilter = false;
    var positional: [2][]const u8 = undefined;
    var positional_count: usize = 0;
    for (ctx.args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--nofilter")) {
            nofilter = true;
        } else if (positional_count < 2) {
            positional[positional_count] = arg;
            positional_count += 1;
        } else {
            positional_count = 3;
            break;
        }
    }
    if (positional_count != 2) {
        ctx.usageError(usage);
    }
    return .{
        .input_path = positional[0],
        .output_path = positional[1],
        .nofilter = nofilter,
    };
}

/// Build a PAM (`P7`) header for an RGBA image of the given dimensions. Three
/// tools (`decode`, `rgb`, `anim`) emit byte-identical headers; this keeps the
/// exact format string in one place. The caller owns the returned slice and
/// must free it with `gpa`.
pub fn pamHeaderRgbaAlloc(gpa: std.mem.Allocator, width: u32, height: u32) ![]u8 {
    return std.fmt.allocPrint(
        gpa,
        "P7\nWIDTH {d}\nHEIGHT {d}\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\nENDHDR\n",
        .{ width, height },
    );
}

/// Concatenate a PAM `header` and `pixels` into one freshly allocated buffer,
/// matching the header-then-pixels layout the tools assembled by hand. The
/// caller owns the returned slice and must free it with `gpa`.
pub fn pamConcatAlloc(gpa: std.mem.Allocator, header: []const u8, pixels: []const u8) ![]u8 {
    const pam = try gpa.alloc(u8, header.len + pixels.len);
    @memcpy(pam[0..header.len], header);
    @memcpy(pam[header.len..], pixels);
    return pam;
}

/// Open `dir_path` (relative to cwd) and collect the names of every `*.webp`
/// file in it, sorted lexicographically. The returned list and each name are
/// owned by `gpa`; the caller frees them with `freeFileNames`. Used by the two
/// hash-manifest tools, which iterated and sorted a directory identically.
pub fn collectWebpFileNames(
    gpa: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
) !std.ArrayList([]u8) {
    var file_names: std.ArrayList([]u8) = .empty;
    errdefer freeFileNames(gpa, &file_names);

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".webp")) continue;

        try file_names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, file_names.items, {}, fileNameLessThan);
    return file_names;
}

/// Free a list built by `collectWebpFileNames`, including every owned name.
pub fn freeFileNames(gpa: std.mem.Allocator, file_names: *std.ArrayList([]u8)) void {
    for (file_names.items) |name| gpa.free(name);
    file_names.deinit(gpa);
}

fn fileNameLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
