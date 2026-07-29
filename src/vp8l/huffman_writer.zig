//! Canonical VP8L Huffman code construction and emission.
//!
//! This is the exact inverse of `huffman.zig`'s reader. The reader assigns
//! canonical codes in ascending (length, symbol) order via its `buildNextCodes`
//! and then bit-reverses them for LSB-first reading; this writer assigns the
//! same canonical codes and stores their reversed form so hot-path emission is
//! a direct table lookup.

const std = @import("std");
const assert = std.debug.assert;

const bit_writer = @import("../bit_writer.zig");
const errors = @import("../errors.zig");
const huffman = @import("huffman.zig");

pub const max_code_bits = huffman.max_code_bits;

/// A prefix code over an alphabet: per-symbol code lengths plus the
/// LSB-first code value for each populated symbol. Lengths of 0 mean a symbol
/// is unused. `build` reverses canonical codes once, before emission.
pub const Code = struct {
    /// Code length per symbol (0 = unused), sized to the alphabet.
    lengths: []const u8,
    /// LSB-first code per symbol; only meaningful where `lengths[i] != 0`.
    codes: []const u16,
    /// Set to the lone symbol when the code has exactly one populated symbol.
    /// The reader's single-leaf table returns that symbol without consuming any
    /// bits, so `writeSymbol` must likewise emit nothing for it.
    single_symbol: ?usize = null,

    pub fn writeSymbol(
        self: Code,
        writer: *bit_writer.BitWriter,
        symbol: usize,
    ) errors.Error!void {
        assert(symbol < self.lengths.len);

        if (self.single_symbol) |lone| {
            // Mirror the reader: a single-leaf code carries no bits.
            assert(symbol == lone);
            return;
        }

        const length = self.lengths[symbol];
        assert(length > 0);
        assert(length <= max_code_bits);

        try writer.writeBits(self.codes[symbol], @intCast(length));
    }
};

/// Returns the lone populated symbol if exactly one symbol has a nonzero
/// length, else null. Used to drive the single-leaf zero-bit emission.
pub fn singleSymbol(lengths: []const u8) ?usize {
    var found: ?usize = null;
    for (lengths, 0..) |l, symbol| {
        if (l == 0) continue;
        if (found != null) return null;
        found = symbol;
    }
    return found;
}

/// Builds a length-limited (<= `max_code_bits`) canonical Huffman code from
/// per-symbol histogram counts, writing the resulting lengths and codes into
/// the caller-supplied buffers (both sized to the alphabet). A symbol with a
/// zero count gets length 0.
///
/// The VP8L single-symbol exception (a populated alphabet with exactly one
/// used symbol) is encoded by giving that symbol length 1, matching the
/// reader's special case.
pub fn build(
    counts: []const u32,
    lengths: []u8,
    codes: []u16,
) void {
    buildLimited(counts, lengths, codes, max_code_bits);
}

/// Like `build`, but limits the maximum code length to `length_limit` (which
/// must be in 1..=`max_code_bits`). VP8L's code-length-code is itself capped at
/// 7 bits, so the encoder builds that meta-code with `length_limit == 7`.
pub fn buildLimited(
    counts: []const u32,
    lengths: []u8,
    codes: []u16,
    length_limit: u8,
) void {
    assert(counts.len == lengths.len);
    assert(counts.len == codes.len);
    assert(counts.len > 0);
    assert(length_limit >= 1);
    assert(length_limit <= max_code_bits);

    assignLengths(counts, lengths, length_limit);
    assignCodes(lengths, codes);
    for (lengths, codes) |length, *code| {
        if (length == 0) continue;
        code.* = @intCast(reverseBits(code.*, length));
    }
}

/// Computes length-limited code lengths from histogram counts using a
/// package-merge-free greedy build followed by length limiting. The approach
/// mirrors libwebp's `GenerateOptimalTree` shape (sort by frequency, build a
/// Huffman tree, then enforce the depth limit) but is reimplemented from the
/// algorithm description, not copied.
fn assignLengths(counts: []const u32, lengths: []u8, length_limit: u8) void {
    assert(counts.len == lengths.len);

    @memset(lengths, 0);

    var used_count: usize = 0;
    var last_used: usize = 0;
    for (counts, 0..) |count, symbol| {
        if (count != 0) {
            used_count += 1;
            last_used = symbol;
        }
    }

    if (used_count == 0) return;
    if (used_count == 1) {
        // VP8L single-leaf exception: length 1 for the lone symbol.
        lengths[last_used] = 1;
        return;
    }

    buildLengthLimited(counts, lengths, length_limit);
}

const symbol_count_max = huffman.green_alphabet_size_max;

/// A node in the working Huffman forest.
const Node = struct {
    count: u64,
    /// Index of the symbol for a leaf, or `node_internal` for an internal node.
    symbol: usize,
    left: usize,
    right: usize,
};

const node_internal = std.math.maxInt(usize);

fn buildLengthLimited(counts: []const u32, lengths: []u8, length_limit: u8) void {
    assert(counts.len == lengths.len);
    assert(counts.len <= symbol_count_max);
    assert(length_limit >= 1);
    assert(length_limit <= max_code_bits);

    // Collect populated symbols.
    var leaf_symbols: [symbol_count_max]usize = undefined;
    var leaf_counts: [symbol_count_max]u64 = undefined;
    var leaf_count: usize = 0;
    for (counts, 0..) |count, symbol| {
        if (count == 0) continue;
        leaf_symbols[leaf_count] = symbol;
        leaf_counts[leaf_count] = count;
        leaf_count += 1;
    }
    assert(leaf_count >= 2);

    // Build a Huffman tree by repeatedly merging the two least-frequent nodes.
    // `nodes` holds leaves first, then internal nodes appended on each merge.
    var nodes: [2 * symbol_count_max]Node = undefined;
    var node_count: usize = 0;
    for (0..leaf_count) |i| {
        nodes[node_count] = .{
            .count = leaf_counts[i],
            .symbol = leaf_symbols[i],
            .left = node_internal,
            .right = node_internal,
        };
        node_count += 1;
    }

    // Active set of node indices to merge; bounded by node_count.
    var active: [2 * symbol_count_max]usize = undefined;
    var active_count: usize = leaf_count;
    for (0..leaf_count) |i| active[i] = i;

    while (active_count > 1) {
        // Find the two smallest-count active nodes.
        var min0: usize = 0;
        var min1: usize = 1;
        if (nodes[active[min1]].count < nodes[active[min0]].count) {
            const tmp = min0;
            min0 = min1;
            min1 = tmp;
        }
        var i: usize = 2;
        while (i < active_count) : (i += 1) {
            const c = nodes[active[i]].count;
            if (c < nodes[active[min0]].count) {
                min1 = min0;
                min0 = i;
            } else if (c < nodes[active[min1]].count) {
                min1 = i;
            }
        }

        const left_idx = active[min0];
        const right_idx = active[min1];
        nodes[node_count] = .{
            .count = nodes[left_idx].count + nodes[right_idx].count,
            .symbol = node_internal,
            .left = left_idx,
            .right = right_idx,
        };
        const merged = node_count;
        node_count += 1;

        // Replace the two minima with the merged node in the active set.
        // Remove the larger index first to keep the other index valid.
        const hi = @max(min0, min1);
        const lo = @min(min0, min1);
        active[hi] = active[active_count - 1];
        active_count -= 1;
        active[lo] = merged;
    }

    const root = active[0];

    // Derive per-symbol depths by walking the tree.
    var depths: [symbol_count_max]u8 = .{0} ** symbol_count_max;
    assignDepths(&nodes, &depths, root);

    // Map leaf depths back to per-symbol lengths, limiting to the depth cap.
    var symbol_lengths: [symbol_count_max]u8 = undefined;
    for (0..leaf_count) |i| symbol_lengths[i] = depths[i];
    limitLengths(symbol_lengths[0..leaf_count], length_limit);

    for (0..leaf_count) |i| {
        lengths[leaf_symbols[i]] = symbol_lengths[i];
    }
}

/// Walks the tree to record each leaf's depth, indexed by leaf order. `depths`
/// is indexed by leaf position (0..leaf_count); the symbol is looked up via the
/// node's stored symbol against the leaf list.
fn assignDepths(
    nodes: *const [2 * symbol_count_max]Node,
    depths: *[symbol_count_max]u8,
    root: usize,
) void {
    const Frame = struct {
        node: usize,
        depth: u16,
    };
    var stack: [2 * symbol_count_max]Frame = undefined;
    var stack_len: usize = 0;
    stack[stack_len] = .{ .node = root, .depth = 0 };
    stack_len += 1;

    while (stack_len > 0) {
        stack_len -= 1;
        const frame = stack[stack_len];
        const node = nodes[frame.node];
        if (node.symbol == node_internal) {
            stack[stack_len] = .{ .node = node.left, .depth = frame.depth + 1 };
            stack_len += 1;
            stack[stack_len] = .{ .node = node.right, .depth = frame.depth + 1 };
            stack_len += 1;
        } else {
            // Leaf nodes are inserted first and retain their leaf-order index.
            assert(frame.node < symbol_count_max);
            const depth: u8 = if (frame.depth == 0) 1 else @intCast(@min(frame.depth, 255));
            depths[frame.node] = depth;
        }
    }
}

/// Enforces a `length_limit` depth cap on a set of code lengths while keeping
/// the code complete (Kraft sum == 1). Clamps over-long lengths to the limit,
/// then repairs the Kraft inequality by lengthening short codes (when
/// over-full) or shortening long codes (when under-full).
fn limitLengths(lengths: []u8, length_limit: u8) void {
    assert(length_limit >= 1);
    assert(length_limit <= max_code_bits);

    // Clamp everything to the limit.
    for (lengths) |*l| {
        if (l.* > length_limit) l.* = length_limit;
    }

    // Compute the Kraft sum in units of 2^-length_limit.
    const one: u64 = @as(u64, 1) << @as(u6, @intCast(length_limit));
    var total: u64 = 0;
    for (lengths) |l| {
        if (l == 0) continue;
        total += one >> @as(u6, @intCast(l));
    }

    // While the code is over-full (sum > 1), lengthen the currently shortest
    // code by one bit. Lengthening a code of length L by one reduces the sum
    // by 2^-(L+1).
    while (total > one) {
        // Find a symbol with the smallest length that can be lengthened.
        var best: ?usize = null;
        var best_len: u8 = length_limit + 1;
        for (lengths, 0..) |l, i| {
            if (l == 0) continue;
            if (l < length_limit and l < best_len) {
                best_len = l;
                best = i;
            }
        }
        // A complete code over >=2 symbols with all lengths clamped to the
        // limit always leaves a shorter code to lengthen while over-full.
        const idx = best.?;
        const l = lengths[idx];
        total -= one >> @as(u6, @intCast(l + 1));
        lengths[idx] = l + 1;
    }

    // The code may now be under-full (sum < 1) after redistribution. Shorten
    // codes to restore completeness: shortening a code of length L by one
    // increases the sum by 2^-(L) (since 2^-(L-1) - 2^-L = 2^-L).
    while (total < one) {
        const deficit = one - total;
        // Find the longest code whose shortening does not overshoot.
        var best: ?usize = null;
        var best_len: u8 = 0;
        for (lengths, 0..) |l, i| {
            if (l <= 1) continue;
            const gain = one >> @as(u6, @intCast(l));
            if (gain > deficit) continue;
            if (l > best_len) {
                best_len = l;
                best = i;
            }
        }
        if (best) |idx| {
            const l = lengths[idx];
            total += one >> @as(u6, @intCast(l));
            lengths[idx] = l - 1;
        } else {
            // No single shorten fits exactly; nudge the longest code anyway to
            // make progress toward completeness.
            var longest: ?usize = null;
            var longest_len: u8 = 0;
            for (lengths, 0..) |l, i| {
                if (l <= 1) continue;
                if (l > longest_len) {
                    longest_len = l;
                    longest = i;
                }
            }
            const idx = longest orelse break;
            const l = lengths[idx];
            total += one >> @as(u6, @intCast(l));
            lengths[idx] = l - 1;
        }
    }
}

/// Assigns canonical code values from code lengths, in the exact order the
/// reader expects: ascending length, then ascending symbol within a length.
fn assignCodes(lengths: []const u8, codes: []u16) void {
    assert(lengths.len == codes.len);

    // Count only populated lengths. The reader's `buildNextCodes` never counts
    // length-0 (unused) symbols, so neither may this writer: counting them in
    // `length_counts[0]` would shift the canonical codes and desynchronize the
    // two sides for any code with mixed lengths.
    var length_counts: [max_code_bits + 1]u16 = .{0} ** (max_code_bits + 1);
    for (lengths) |l| {
        assert(l <= max_code_bits);
        if (l == 0) continue;
        length_counts[l] += 1;
    }

    // next_codes[L] is the first canonical code of length L, matching the
    // reader's buildNextCodes.
    var next_codes: [max_code_bits + 1]u32 = .{0} ** (max_code_bits + 1);
    var code: u32 = 0;
    var length: usize = 1;
    while (length <= max_code_bits) : (length += 1) {
        code = (code + length_counts[length - 1]) << 1;
        next_codes[length] = code;
    }

    for (lengths, 0..) |l, symbol| {
        if (l == 0) {
            codes[symbol] = 0;
            continue;
        }
        codes[symbol] = @intCast(next_codes[l]);
        next_codes[l] += 1;
    }
}

fn reverseBits(value: u16, bits: u8) u32 {
    assert(bits > 0);
    assert(bits <= max_code_bits);

    var remaining: u8 = bits;
    var source: u32 = value;
    var reversed: u32 = 0;
    while (remaining > 0) : (remaining -= 1) {
        reversed = (reversed << 1) | (source & 1);
        source >>= 1;
    }
    return reversed;
}

const testing = std.testing;

fn roundTrip(counts: []const u32) !void {
    const alphabet = counts.len;
    var lengths_buf: [symbol_count_max]u8 = undefined;
    var codes_buf: [symbol_count_max]u16 = undefined;
    const lengths = lengths_buf[0..alphabet];
    const codes = codes_buf[0..alphabet];
    build(counts, lengths, codes);

    const Code_ = Code{ .lengths = lengths, .codes = codes };

    // Build a reader table from the same lengths and confirm every populated
    // symbol round-trips.
    var entries: [huffman.SymbolTable.entry_count_limit]huffman.Entry = undefined;
    const table = try huffman.SymbolTable.build(&entries, lengths);

    for (counts, 0..) |count, symbol| {
        if (count == 0) continue;

        var out: [4]u8 = undefined;
        var writer = bit_writer.BitWriter.init(&out);
        try Code_.writeSymbol(&writer, symbol);
        const encoded = try writer.finish();

        var reader = @import("../bit_reader.zig").BitReader.init(encoded);
        const decoded = try table.decode(&reader);
        try testing.expectEqual(@as(u16, @intCast(symbol)), decoded);
    }

    // Verify length limit.
    for (lengths) |l| try testing.expect(l <= max_code_bits);
}

test "huffman writer round-trips a two-symbol code" {
    try roundTrip(&.{ 5, 3 });
}

test "huffman writer round-trips a single-symbol code" {
    try roundTrip(&.{ 0, 0, 7, 0 });
}

test "huffman writer round-trips a skewed multi-symbol code" {
    try roundTrip(&.{ 100, 1, 1, 1, 50, 25, 12, 6, 3, 2 });
}

test "huffman writer round-trips a full 256-symbol uniform code" {
    var counts: [256]u32 = undefined;
    for (&counts, 0..) |*c, i| c.* = @intCast(i + 1);
    try roundTrip(&counts);
}

test "huffman writer enforces the 15-bit length limit on a deep distribution" {
    // A Fibonacci-like distribution forces a degenerate (very deep) tree, which
    // must be clamped to 15 bits while staying a complete, decodable code.
    var counts: [40]u32 = undefined;
    var a: u32 = 1;
    var b: u32 = 1;
    for (&counts) |*c| {
        c.* = a;
        const next = a +% b;
        a = b;
        b = next;
    }
    try roundTrip(&counts);
}

test "single-leaf code emits zero bits, matching the reader" {
    const counts = [_]u32{ 0, 0, 0, 9, 0 };
    var lengths: [5]u8 = undefined;
    var codes: [5]u16 = undefined;
    build(&counts, &lengths, &codes);

    try testing.expectEqual(@as(?usize, 3), singleSymbol(&lengths));

    const code = Code{
        .lengths = &lengths,
        .codes = &codes,
        .single_symbol = singleSymbol(&lengths),
    };

    var out: [4]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&out);
    try code.writeSymbol(&writer, 3);
    // No bits buffered or flushed: the single-leaf symbol carries no code.
    try testing.expectEqual(@as(u6, 0), writer.pendingBits());
    try testing.expectEqual(@as(usize, 0), writer.written().len);
}

test "assigned codes match the reader canonical order" {
    // Three symbols, lengths {1,2,2}: canonical codes are 0, 10, 11.
    const lengths = [_]u8{ 1, 2, 2 };
    var codes: [3]u16 = undefined;
    assignCodes(&lengths, &codes);
    try testing.expectEqual(@as(u16, 0b0), codes[0]);
    try testing.expectEqual(@as(u16, 0b10), codes[1]);
    try testing.expectEqual(@as(u16, 0b11), codes[2]);
}
