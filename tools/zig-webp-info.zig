const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);
    if (ctx.args.len != 2) {
        ctx.usageError("usage: zig-webp-info INPUT.webp\n");
    }

    const input_path = ctx.args[1];
    const bytes = try ctx.readInput(input_path);
    defer ctx.gpa.free(bytes);

    var result = try webp.parseWebP(ctx.gpa, bytes, .{});
    defer result.deinit();

    var report: std.Io.Writer.Allocating = .init(ctx.gpa);
    defer report.deinit();

    const format_name: []const u8 = if (result.features.format) |format|
        @tagName(format)
    else
        "none";

    try report.writer.print(
        \\file: {s}
        \\file_size: {d}
        \\kind: {s}
        \\format: {s}
        \\canvas: {d}x{d}
        \\alpha: {}
        \\animation: {}
        \\metadata: iccp={} exif={} xmp={}
        \\chunks: {d}
        \\
    ,
        .{
            input_path,
            result.file_size_bytes,
            @tagName(result.features.file_kind),
            format_name,
            result.features.canvas.width,
            result.features.canvas.height,
            result.features.has_alpha,
            result.features.is_animation,
            result.features.metadata.color_profile,
            result.features.metadata.exif,
            result.features.metadata.xmp,
            result.features.chunk_count,
        },
    );

    for (result.chunks) |chunk| {
        try report.writer.print(
            "  {s} offset={d} size={d}\n",
            .{ chunk.tag.bytes[0..], chunk.offset, chunk.payload_size },
        );
    }

    try report.writer.print("unknown_chunks: {d}\n", .{result.unknown_chunks.len});
    for (result.unknown_chunks) |chunk| {
        try report.writer.print(
            "  {s} offset={d} size={d}\n",
            .{ chunk.tag.bytes[0..], chunk.offset, chunk.payload_size },
        );
    }

    if (result.animation_info) |anim| {
        switch (anim.loop_count) {
            .infinite => try report.writer.print("loop_count: infinite\n", .{}),
            .count => |count| try report.writer.print("loop_count: {d}\n", .{count}),
        }
        try report.writer.print(
            "background_bgra: {d},{d},{d},{d}\n",
            .{
                anim.background_bgra[0],
                anim.background_bgra[1],
                anim.background_bgra[2],
                anim.background_bgra[3],
            },
        );
        try report.writer.print("frames: {d}\n", .{result.frames.len});
        for (result.frames, 0..) |frame, i| {
            try report.writer.print(
                "  frame {d}: rect={d},{d} {d}x{d} duration={d}ms dispose={s} blend={s}\n",
                .{
                    i,
                    frame.rect.x,
                    frame.rect.y,
                    frame.rect.width,
                    frame.rect.height,
                    frame.duration_ms,
                    @tagName(frame.dispose_method),
                    @tagName(frame.blend_method),
                },
            );
        }
    }

    try ctx.writeStdout(report.written());
}
