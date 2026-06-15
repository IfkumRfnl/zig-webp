const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

const no_alpha_exit_code = 3;

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);
    if (ctx.args.len != 3) {
        ctx.usageError(
            "usage: zig-webp-alpha INPUT.webp OUTPUT.raw\n" ++
                "Writes the decoded ALPH plane as row-major bytes.\n" ++
                "Exits 3 when the file has no static ALPH chunk.\n",
        );
    }

    const input_path = ctx.args[1];
    const output_path = ctx.args[2];

    const bytes = try ctx.readInput(input_path);
    defer ctx.gpa.free(bytes);

    // Match the corpus demux limits so oversized no-alpha files still parse
    // far enough to be reported as skips instead of failures.
    var parsed = try webp.parseWebP(ctx.gpa, bytes, .{
        .limits = .{
            .output_pixels_max = std.math.maxInt(u32),
            .animation_canvas_pixels_max = std.math.maxInt(u32),
        },
    });
    defer parsed.deinit();

    const location = parsed.features.alpha orelse {
        ctx.exitWithMessage("no static ALPH chunk\n", no_alpha_exit_code);
    };
    const dimensions = parsed.features.canvas;
    const pixel_count: usize = @intCast(try dimensions.pixelCount());

    const plane = try ctx.gpa.alloc(u8, pixel_count);
    defer ctx.gpa.free(plane);

    _ = try webp.alpha.decodePlaneAlloc(ctx.gpa, location.payload(bytes), dimensions, plane);

    try ctx.writeOutput(output_path, plane);
}
