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
