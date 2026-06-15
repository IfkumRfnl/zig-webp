const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

const skip_exit_code = 3;

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);
    if (ctx.args.len != 3) {
        ctx.usageError(
            "usage: zig-webp-anim INPUT.webp OUT_DIR\n" ++
                "Decodes an animated WebP and writes each composited frame as\n" ++
                "OUT_DIR/frame_NNNN.pam (RGBA, zero-based, matching `anim_dump\n" ++
                "-pam`). OUT_DIR must already exist. Exits 3 when the file is\n" ++
                "not an animation.\n",
        );
    }

    const input_path = ctx.args[1];
    const out_dir = ctx.args[2];

    const relaxed = webp.ResourceLimits{
        .output_pixels_max = std.math.maxInt(u32),
        .animation_canvas_pixels_max = std.math.maxInt(u32),
        .allocation_bytes_max = std.math.maxInt(u64),
    };

    // Read with the relaxed input limit rather than the shared default, so the
    // animation corpus' larger files parse; hence this read stays inline.
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        ctx.io,
        input_path,
        ctx.gpa,
        .limited64(relaxed.input_bytes_max),
    );
    defer ctx.gpa.free(bytes);

    var animated = webp.decodeAnimation(ctx.gpa, bytes, .{
        .limits = relaxed,
        .output_format = .rgba,
    }) catch |err| switch (err) {
        error.NotAnimated => {
            ctx.exitWithMessage("not an animation\n", skip_exit_code);
        },
        else => return err,
    };
    defer animated.deinit();

    const width = animated.info.canvas.width;
    const height = animated.info.canvas.height;
    const header = try cli.pamHeaderRgbaAlloc(ctx.gpa, width, height);
    defer ctx.gpa.free(header);

    for (animated.frames, 0..) |frame, index| {
        const path = try std.fmt.allocPrint(ctx.gpa, "{s}/frame_{d:0>4}.pam", .{ out_dir, index });
        defer ctx.gpa.free(path);

        const pam = try cli.pamConcatAlloc(ctx.gpa, header, frame.buffer.pixels);
        defer ctx.gpa.free(pam);

        try ctx.writeOutput(path, pam);
    }

    const summary = try std.fmt.allocPrint(
        ctx.gpa,
        "frames {d}\n",
        .{animated.frames.len},
    );
    defer ctx.gpa.free(summary);
    try ctx.writeStdout(summary);
}
