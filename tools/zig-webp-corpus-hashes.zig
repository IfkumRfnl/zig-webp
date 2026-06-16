const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

const corpus = webp.testing.corpus;

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);
    if (ctx.args.len > 3) {
        ctx.usageError(
            "usage: zig-webp-corpus-hashes [CORPUS_DIR] [OUTPUT.tsv]\n" ++
                "Writes SHA-256 hashes of decoded corpus planes as TSV rows.\n",
        );
    }

    const corpus_path = if (ctx.args.len > 1) ctx.args[1] else corpus.default_root_path;
    const output_path = if (ctx.args.len > 2)
        ctx.args[2]
    else
        corpus.hash_manifest_root_path ++ "/" ++ corpus.hash_manifest_file_name;

    var corpus_dir = try std.Io.Dir.cwd().openDir(ctx.io, corpus_path, .{ .iterate = true });
    defer corpus_dir.close(ctx.io);

    var file_names = try cli.collectWebpFileNames(ctx.gpa, ctx.io, corpus_dir);
    defer cli.freeFileNames(ctx.gpa, &file_names);

    var manifest: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer manifest.deinit();
    try manifest.writer.writeAll(
        "# SHA-256 hashes of zig-webp decoded planes, one tab-separated row\n" ++
            "# per file and plane kind. Regenerate with `zig build corpus-hashes`\n" ++
            "# only after a corpus-wide oracle run confirms the decoded planes.\n",
    );

    var row_count: u32 = 0;
    for (file_names.items) |file_name| {
        const file_bytes = try corpus_dir.readFileAlloc(
            ctx.io,
            file_name,
            ctx.gpa,
            .limited64((webp.ResourceLimits{}).input_bytes_max),
        );
        defer ctx.gpa.free(file_bytes);

        var parsed = try webp.parseWebP(ctx.gpa, file_bytes, .{
            .limits = corpus.plane_hash_demux_limits,
        });
        defer parsed.deinit();

        if (parsed.features.is_animation) continue;

        _ = parsed.features.format orelse continue;
        if (parsed.features.image_data != null) {
            const digest = try corpus.hashStillRGBA(ctx.gpa, file_bytes);
            try manifest.writer.print("{s}\trgba\t{s}\n", .{
                file_name,
                &std.fmt.bytesToHex(digest, .lower),
            });
            row_count += 1;
        }
        if (parsed.features.alpha != null) {
            const digest = try corpus.hashAlphaPlane(ctx.gpa, file_bytes);
            try manifest.writer.print("{s}\talpha\t{s}\n", .{
                file_name,
                &std.fmt.bytesToHex(digest, .lower),
            });
            row_count += 1;
        }
    }

    try ctx.writeOutput(output_path, manifest.written());

    var message_buffer: [256]u8 = undefined;
    const message = try std.fmt.bufPrint(
        &message_buffer,
        "wrote {d} rows to {s}\n",
        .{ row_count, output_path },
    );
    try ctx.writeStderr(message);
}
