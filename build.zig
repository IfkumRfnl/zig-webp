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

    const unit_tests = b.addTest(.{
        .root_module = webp_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
