const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const webp_module = b.addModule("webp", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = false,
    });

    const webp_library = b.addLibrary(.{
        .name = "zig-webp",
        .root_module = webp_module,
        .linkage = .static,
    });
    b.installArtifact(webp_library);

    const check_step = b.step("check", "Compile the library");
    check_step.dependOn(&webp_library.step);

    const decode_tool = b.addExecutable(.{
        .name = "zig-webp-decode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zig-webp-decode.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "webp", .module = webp_module },
            },
        }),
    });
    const run_decode_tool = b.addRunArtifact(decode_tool);
    if (b.args) |args| {
        run_decode_tool.addArgs(args);
    }
    const decode_step = b.step("decode", "Decode a static lossless WebP to PAM");
    decode_step.dependOn(&run_decode_tool.step);

    const alpha_tool = b.addExecutable(.{
        .name = "zig-webp-alpha",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/zig-webp-alpha.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "webp", .module = webp_module },
            },
        }),
    });
    b.installArtifact(alpha_tool);
    const run_alpha_tool = b.addRunArtifact(alpha_tool);
    if (b.args) |args| {
        run_alpha_tool.addArgs(args);
    }
    const alpha_step = b.step("alpha", "Decode a WebP ALPH chunk to a raw alpha plane");
    alpha_step.dependOn(&run_alpha_tool.step);

    const unit_tests = b.addTest(.{
        .root_module = webp_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
