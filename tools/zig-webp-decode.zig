const std = @import("std");
const webp = @import("webp");
const cli = @import("cli_common");

pub fn main(init: std.process.Init) !void {
    const ctx = try cli.Cli.init(init);
    if (ctx.args.len != 3) {
        ctx.usageError("usage: zig-webp-decode INPUT.webp OUTPUT.pam\n");
    }

    const input_path = ctx.args[1];
    const output_path = ctx.args[2];

    const bytes = try ctx.readInput(input_path);
    defer ctx.gpa.free(bytes);

    var decoded = try webp.decodeStatic(ctx.gpa, bytes, .{ .output_format = .rgba });
    defer decoded.deinit();

    const pam = try encodePam(ctx.gpa, decoded.buffer);
    defer ctx.gpa.free(pam);

    try ctx.writeOutput(output_path, pam);
}

fn encodePam(gpa: std.mem.Allocator, buffer: webp.ImageBuffer) ![]u8 {
    try buffer.validate();
    std.debug.assert(buffer.format == .rgba);

    const header = try cli.pamHeaderRgbaAlloc(
        gpa,
        buffer.dimensions.width,
        buffer.dimensions.height,
    );
    defer gpa.free(header);

    return cli.pamConcatAlloc(gpa, header, buffer.pixels);
}
