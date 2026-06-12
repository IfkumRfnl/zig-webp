const std = @import("std");
const webp = @import("webp");

const corpus = webp.testing.corpus;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len > 3) {
        try std.Io.File.stderr().writeStreamingAll(
            io,
            "usage: zig-webp-corpus-hashes [CORPUS_DIR] [OUTPUT.tsv]\n" ++
                "Writes SHA-256 hashes of decoded corpus planes as TSV rows.\n",
        );
        std.process.exit(2);
    }

    const corpus_path = if (args.len > 1) args[1] else corpus.default_root_path;
    const output_path = if (args.len > 2)
        args[2]
    else
        corpus.hash_manifest_root_path ++ "/" ++ corpus.hash_manifest_file_name;

    var corpus_dir = try std.Io.Dir.cwd().openDir(io, corpus_path, .{ .iterate = true });
    defer corpus_dir.close(io);

    var file_names: std.ArrayList([]u8) = .empty;
    defer {
        for (file_names.items) |name| gpa.free(name);
        file_names.deinit(gpa);
    }

    var iterator = corpus_dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".webp")) continue;

        try file_names.append(gpa, try gpa.dupe(u8, entry.name));
    }
    std.mem.sort([]u8, file_names.items, {}, fileNameLessThan);

    var manifest: std.Io.Writer.Allocating = .init(gpa);
    defer manifest.deinit();
    try manifest.writer.writeAll(
        "# SHA-256 hashes of zig-webp decoded planes, one tab-separated row\n" ++
            "# per file and plane kind. Regenerate with `zig build corpus-hashes`\n" ++
            "# only after a corpus-wide oracle run confirms the decoded planes.\n",
    );

    var row_count: u32 = 0;
    for (file_names.items) |file_name| {
        const file_bytes = try corpus_dir.readFileAlloc(
            io,
            file_name,
            gpa,
            .limited64((webp.ResourceLimits{}).input_bytes_max),
        );
        defer gpa.free(file_bytes);

        var parsed = try webp.parseWebP(gpa, file_bytes, .{
            .limits = corpus.plane_hash_demux_limits,
        });
        defer parsed.deinit();

        if (parsed.features.is_animation) continue;

        const format = parsed.features.format orelse continue;
        if (format == .lossless and parsed.features.image_data != null) {
            const digest = try corpus.hashStillLosslessRGBA(gpa, file_bytes);
            try manifest.writer.print("{s}\trgba\t{s}\n", .{
                file_name,
                &std.fmt.bytesToHex(digest, .lower),
            });
            row_count += 1;
        }
        if (parsed.features.alpha != null) {
            const digest = try corpus.hashAlphaPlane(gpa, file_bytes);
            try manifest.writer.print("{s}\talpha\t{s}\n", .{
                file_name,
                &std.fmt.bytesToHex(digest, .lower),
            });
            row_count += 1;
        }
    }

    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = output_path,
        .data = manifest.written(),
    });

    var message_buffer: [256]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &message_buffer,
        "wrote {d} rows to {s}\n",
        .{ row_count, output_path },
    );
    try std.Io.File.stderr().writeStreamingAll(io, message);
}

fn fileNameLessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}
