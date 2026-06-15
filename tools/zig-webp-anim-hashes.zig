const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

const corpus = webp.testing.corpus;

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);
    if (ctx.args.len > 3) {
        ctx.usageError(
            "usage: zig-webp-anim-hashes [ANIM_DIR] [OUTPUT.tsv]\n" ++
                "Writes SHA-256 hashes of composited animation frames as TSV rows.\n",
        );
    }

    const anim_path = if (ctx.args.len > 1) ctx.args[1] else corpus.default_animation_root_path;
    const output_path = if (ctx.args.len > 2)
        ctx.args[2]
    else
        corpus.default_animation_root_path ++ "/" ++ corpus.animation_hash_manifest_file_name;

    var anim_dir = try std.Io.Dir.cwd().openDir(ctx.io, anim_path, .{ .iterate = true });
    defer anim_dir.close(ctx.io);

    var file_names = try cli.collectWebpFileNames(ctx.gpa, ctx.io, anim_dir);
    defer cli.freeFileNames(ctx.gpa, &file_names);

    var manifest: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer manifest.deinit();
    try manifest.writer.writeAll(
        "# SHA-256 hashes of zig-webp composited animation frames, one\n" ++
            "# tab-separated row (file, frame count, hash) per animation.\n" ++
            "# Regenerate with `zig build anim-hashes` only after a corpus-wide\n" ++
            "# `compare-anim` oracle run confirms the composited frames.\n",
    );

    var row_count: u32 = 0;
    for (file_names.items) |file_name| {
        const file_bytes = try anim_dir.readFileAlloc(
            ctx.io,
            file_name,
            ctx.gpa,
            .limited64((webp.ResourceLimits{}).input_bytes_max),
        );
        defer ctx.gpa.free(file_bytes);

        const result = try corpus.hashAnimation(ctx.gpa, file_bytes);
        try manifest.writer.print("{s}\t{d}\t{s}\n", .{
            file_name,
            result.frame_count,
            &std.fmt.bytesToHex(result.digest, .lower),
        });
        row_count += 1;
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
