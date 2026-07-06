//! Helpers for fuzz targets built on Zig's built-in fuzzer.

const std = @import("std");
const assert = std.debug.assert;

pub const slice_length_prefix_size = 4;

/// Frames `payload` as a `std.testing.Smith` input stream so a corpus entry
/// reaches a single `smith.slice` call byte-for-byte: the slice protocol
/// expects a little-endian u32 length followed by the bytes themselves.
pub fn sliceCorpusEntry(buffer: []u8, payload: []const u8) []const u8 {
    assert(buffer.len >= payload.len + slice_length_prefix_size);

    std.mem.writeInt(u32, buffer[0..slice_length_prefix_size], @intCast(payload.len), .little);
    @memcpy(buffer[slice_length_prefix_size..][0..payload.len], payload);
    return buffer[0 .. slice_length_prefix_size + payload.len];
}

test "framed corpus entries round-trip through a Smith slice read" {
    var entry_buffer: [16]u8 = undefined;
    const entry = sliceCorpusEntry(&entry_buffer, "abc");
    try std.testing.expectEqualSlices(u8, &.{ 3, 0, 0, 0, 'a', 'b', 'c' }, entry);

    var smith = std.testing.Smith{ .in = entry };
    var out: [8]u8 = undefined;
    const out_len = smith.slice(&out);
    try std.testing.expectEqualSlices(u8, "abc", out[0..out_len]);
}

/// Options for `runMutations`. Keep the per-target budget small: the goal is
/// exploration-per-millisecond, not exhaustiveness.
pub const MutationOptions = struct {
    /// Number of mutated variants to run.
    variant_count: usize = 128,
    /// Fixed PRNG seed — determinism is load-bearing (no CI flake, and any
    /// failure is reproducible). Vary per call site so targets diverge.
    prng_seed: u64,
};

/// Feeds `body` (a `std.testing.fuzz`-shaped function) `variant_count`
/// deterministic mutations of `payload`, each framed exactly like a corpus
/// entry so the body's `smith.slice` read sees the mutated bytes.
///
/// Each variant is the payload with 1–8 random byte substitutions at random
/// offsets; with probability 1/8 it is first truncated to a random length in
/// [0, payload.len] (empty included, the key parser boundary). The PRNG is a
/// fixed-seed `std.Random.DefaultPrng` — no entropy — so
/// a failure under this helper is a permanent, reproducible regression test.
/// Bounded and allocation-free: all scratch lives on the stack of the caller.
pub fn runMutations(
    comptime body: fn (void, *std.testing.Smith) anyerror!void,
    payload: []const u8,
    mutation_options: MutationOptions,
) !void {
    const max_payload: usize = 4096;
    assert(payload.len <= max_payload);

    var prng = std.Random.DefaultPrng.init(mutation_options.prng_seed);
    const random = prng.random();

    var mutation_buffer: [max_payload]u8 = undefined;
    var frame_buffer: [max_payload + slice_length_prefix_size]u8 = undefined;

    var i: usize = 0;
    while (i < mutation_options.variant_count) : (i += 1) {
        const base_len: usize = payload.len;
        // With probability 1/8, truncate to a random length in [0, base_len]
        // (empty included): the zero-length boundary is the most important one
        // for parsers and was previously unreachable here.
        const len: usize = if (base_len == 0) 0 else if (random.uintLessThan(u8, 8) == 0)
            random.uintLessThan(usize, base_len + 1)
        else
            base_len;

        @memcpy(mutation_buffer[0..len], payload[0..len]);

        if (len > 0) {
            const subs: usize = 1 + random.uintLessThan(u8, 8);
            var s: usize = 0;
            while (s < subs) : (s += 1) {
                const offset = random.uintLessThan(usize, len);
                mutation_buffer[offset] = random.int(u8);
            }
        }

        const entry = sliceCorpusEntry(&frame_buffer, mutation_buffer[0..len]);
        var smith = std.testing.Smith{ .in = entry };
        try body({}, &smith);
    }
}

test "runMutations invokes body exactly variant_count times" {
    const Recorder = struct {
        var calls: usize = 0;
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            calls += 1;
            var buf: [128]u8 = undefined;
            const len = smith.slice(&buf);
            try std.testing.expect(@as(usize, len) <= buf.len);
        }
    };
    Recorder.calls = 0;
    try runMutations(Recorder.run, "bounded-mutation-recorder-payload", .{
        .variant_count = 32,
        .prng_seed = 0x11d_0000,
    });
    try std.testing.expectEqual(@as(usize, 32), Recorder.calls);
}

test "runMutations reproduces identical variants for a fixed seed" {
    const Capture = struct {
        var first: [128]u8 = undefined;
        var first_len: usize = 0;
        var captured: bool = false;
        fn run(_: void, smith: *std.testing.Smith) anyerror!void {
            if (!captured) {
                var buf: [128]u8 = undefined;
                const len = smith.slice(&buf);
                const n = @min(@as(usize, len), first.len);
                first_len = n;
                @memcpy(first[0..n], buf[0..n]);
                captured = true;
            }
        }
    };

    Capture.captured = false;
    Capture.first_len = 0;
    try runMutations(Capture.run, "deterministic-mutation-seed-payload", .{
        .variant_count = 8,
        .prng_seed = 0x11d_00aa,
    });
    const a_len = Capture.first_len;
    var a: [128]u8 = Capture.first;

    Capture.captured = false;
    Capture.first_len = 0;
    try runMutations(Capture.run, "deterministic-mutation-seed-payload", .{
        .variant_count = 8,
        .prng_seed = 0x11d_00aa,
    });
    try std.testing.expectEqualSlices(u8, a[0..a_len], Capture.first[0..Capture.first_len]);
}
