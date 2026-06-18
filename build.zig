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

    // Boilerplate shared by every `zig-webp-*` CLI tool, imported as `cli_common`.
    const cli_common_module = b.createModule(.{
        .root_source_file = b.path("tools/cli_common.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "webp", .module = webp_module },
        },
    });

    // Each CLI tool is wired identically: a one-source executable that imports
    // the `webp` library and the shared `cli_common` module, plus a named run
    // step (forwarding `-- ARGS`). The `check` step depends on all of them so
    // CI keeps compiling every tool. `install` requests whether `zig build`
    // (no step) installs the binary, matching prior per-tool behavior.
    const Tool = struct {
        name: []const u8,
        source: []const u8,
        step: []const u8,
        description: []const u8,
        install: bool,
        // Tools that read fixture directories run from the repo root.
        cwd_repo_root: bool = false,
    };
    const tools = [_]Tool{
        .{
            .name = "zig-webp-decode",
            .source = "tools/zig-webp-decode.zig",
            .step = "decode",
            .description = "Decode a static lossless WebP to PAM",
            .install = false,
        },
        .{
            .name = "zig-webp-alpha",
            .source = "tools/zig-webp-alpha.zig",
            .step = "alpha",
            .description = "Decode a WebP ALPH chunk to a raw alpha plane",
            .install = true,
        },
        .{
            .name = "zig-webp-yuv",
            .source = "tools/zig-webp-yuv.zig",
            .step = "yuv",
            .description = "Decode a lossy WebP to raw YUV planes",
            .install = true,
        },
        .{
            .name = "zig-webp-rgb",
            .source = "tools/zig-webp-rgb.zig",
            .step = "rgb",
            .description = "Decode a lossy WebP to RGBA (fancy upsampling) as PAM",
            .install = true,
        },
        .{
            .name = "zig-webp-anim",
            .source = "tools/zig-webp-anim.zig",
            .step = "anim",
            .description = "Decode an animated WebP to per-frame PAM files",
            .install = true,
        },
        .{
            .name = "zig-webp-corpus-hashes",
            .source = "tools/zig-webp-corpus-hashes.zig",
            .step = "corpus-hashes",
            .description = "Regenerate testdata/corpus-hashes.tsv from decoded corpus planes",
            .install = false,
            .cwd_repo_root = true,
        },
        .{
            .name = "zig-webp-anim-hashes",
            .source = "tools/zig-webp-anim-hashes.zig",
            .step = "anim-hashes",
            .description = "Regenerate testdata/animation/hashes.tsv from composited frames",
            .install = false,
            .cwd_repo_root = true,
        },
        .{
            .name = "zig-webp-encode-report",
            .source = "tools/zig-webp-encode-report.zig",
            .step = "encode-report",
            .description = "Report lossless encoder size + round-trip over the encode corpus",
            .install = false,
            .cwd_repo_root = true,
        },
    };

    const check_step = b.step("check", "Compile the library and tools");
    check_step.dependOn(&webp_library.step);

    for (tools) |tool| {
        const exe = b.addExecutable(.{
            .name = tool.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(tool.source),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "webp", .module = webp_module },
                    .{ .name = "cli_common", .module = cli_common_module },
                },
            }),
        });
        if (tool.install) {
            b.installArtifact(exe);
        }

        const run = b.addRunArtifact(exe);
        if (tool.cwd_repo_root) {
            run.setCwd(b.path("."));
        }
        if (b.args) |args| {
            run.addArgs(args);
        }
        const step = b.step(tool.step, tool.description);
        step.dependOn(&run.step);

        check_step.dependOn(&exe.step);
    }

    const unit_tests = b.addTest(.{
        .root_module = webp_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
