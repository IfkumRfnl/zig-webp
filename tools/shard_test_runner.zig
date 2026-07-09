//! Sharded simple-mode test runner (used by `zig build test -Dtest-shards=N`;
//! plans/019). Runs the subset of `builtin.test_functions` whose index `i`
//! satisfies `i % TEST_SHARD_COUNT == TEST_SHARD_INDEX`, so N processes
//! cover the full suite by construction — no name filters, no drift risk.
//!
//! Behavior mirrors the terminal path of Zig 0.16.0's default test runner
//! (`lib/compiler/test_runner.zig`, `mainTerminal`): per-test testing
//! allocator and io instance, leak accounting, `error.SkipZigTest`
//! handling, error-log counting, and a nonzero exit code on any failure,
//! leak, or error log. `pub fn fuzz` mirrors the default runner's
//! non-fuzz-mode behavior (`std.testing.fuzz` dispatches to
//! `@import("root").fuzz`). Re-sync both on Zig upgrades.

const builtin = @import("builtin");
const std = @import("std");
const testing = std.testing;

pub const std_options: std.Options = .{ .logFn = log };

var log_err_count: usize = 0;

pub fn main(init: std.process.Init.Minimal) void {
    const shard_count = envUsize(init, "TEST_SHARD_COUNT") orelse 1;
    const shard_index = envUsize(init, "TEST_SHARD_INDEX") orelse 0;
    if (shard_count == 0 or shard_index >= shard_count) {
        std.debug.print(
            "invalid shard config: TEST_SHARD_INDEX={d} TEST_SHARD_COUNT={d}\n",
            .{ shard_index, shard_count },
        );
        std.process.exit(1);
    }

    var ran: usize = 0;
    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leaks: usize = 0;

    for (builtin.test_functions, 0..) |test_fn, i| {
        if (i % shard_count != shard_index) continue;
        ran += 1;

        testing.allocator_instance = .{};
        testing.io_instance = .init(testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        defer {
            testing.io_instance.deinit();
            if (testing.allocator_instance.deinit() == .leak) {
                leaks += 1;
                std.debug.print("LEAK: {s}\n", .{test_fn.name});
            }
        }
        testing.log_level = .warn;
        testing.environ = init.environ;

        if (test_fn.func()) |_| {
            ok_count += 1;
        } else |err| switch (err) {
            error.SkipZigTest => skip_count += 1,
            else => {
                fail_count += 1;
                std.debug.print("FAIL: {s} ({t})\n", .{ test_fn.name, err });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpErrorReturnTrace(trace);
                }
            },
        }
    }

    std.debug.print(
        "shard {d}/{d}: ran {d} of {d} tests; {d} passed; {d} skipped; " ++
            "{d} failed; {d} leaked; {d} error logs\n",
        .{
            shard_index,   shard_count, ran,        builtin.test_functions.len,
            ok_count,      skip_count,  fail_count, leaks,
            log_err_count,
        },
    );
    if (fail_count != 0 or leaks != 0 or log_err_count != 0) {
        std.process.exit(1);
    }
}

/// `std.testing.fuzz` dispatches here via `@import("root")`. Mirrors the
/// default runner's non-fuzz-mode behavior: run every corpus input, then an
/// empty input as a smoke test.
pub fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *testing.Smith) anyerror!void,
    options: testing.FuzzInputOptions,
) anyerror!void {
    for (options.corpus) |input| {
        var smith: testing.Smith = .{ .in = input };
        try testOne(context, &smith);
    }
    var smith: testing.Smith = .{ .in = "" };
    try testOne(context, &smith);
}

pub fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}

fn envUsize(init: std.process.Init.Minimal, key: []const u8) ?usize {
    const value = init.environ.getPosix(key) orelse return null;
    return std.fmt.parseUnsigned(usize, value, 10) catch {
        std.debug.print("invalid {s}: {s}\n", .{ key, value });
        std.process.exit(1);
    };
}
