//! Canonical VP8L Huffman table construction and symbol lookup.

const std = @import("std");
const assert = std.debug.assert;

const bit_reader = @import("../bit_reader.zig");
const errors = @import("../errors.zig");

pub const Error = errors.Error;

pub const max_code_bits = 15;
pub const code_length_code_bits_max = 7;
pub const code_length_code_count = 19;
pub const code_length_code_order = [_]u8{
    17,
    18,
    0,
    1,
    2,
    3,
    4,
    5,
    16,
    6,
    7,
    8,
    9,
    10,
    11,
    12,
    13,
    14,
    15,
};

pub const literal_alphabet_size = 256;
pub const length_code_count = 24;
pub const distance_alphabet_size = 40;
pub const color_cache_bits_max = 11;
pub const color_cache_size_max = 1 << color_cache_bits_max;
pub const green_alphabet_size_max = literal_alphabet_size + length_code_count +
    color_cache_size_max;

pub const root_bits_default = 8;
pub const code_length_root_bits = 5;

pub const SymbolTable = Table(.{
    .alphabet_size_max = green_alphabet_size_max,
    .root_bits = root_bits_default,
    .code_bits_max = max_code_bits,
});

pub const CodeLengthTable = Table(.{
    .alphabet_size_max = code_length_code_count,
    .root_bits = code_length_root_bits,
    .code_bits_max = code_length_code_bits_max,
});

pub const TableOptions = struct {
    alphabet_size_max: u16,
    root_bits: u5,
    code_bits_max: u5,
};

pub const EntryOp = enum(u8) {
    invalid,
    symbol,
    table,
};

pub const Entry = struct {
    symbol: u16 = 0,
    offset: u16 = 0,
    bits: u8 = 0,
    op: EntryOp = .invalid,
};

comptime {
    assert(@sizeOf(Entry) == 6);
    assert(code_length_code_order.len == code_length_code_count);
    assert(code_length_code_bits_max < max_code_bits);
    assert(distance_alphabet_size < literal_alphabet_size);
    assert(green_alphabet_size_max == 2328);
}

pub fn Table(comptime options: TableOptions) type {
    comptime {
        assert(options.alphabet_size_max > 0);
        assert(options.root_bits > 0);
        assert(options.code_bits_max > 0);
        assert(options.root_bits <= options.code_bits_max);
        assert(options.code_bits_max <= max_code_bits);
        assert(options.root_bits <= root_bits_default);
    }

    const alphabet_size_max = options.alphabet_size_max;
    const root_bits = options.root_bits;
    const code_bits_max = options.code_bits_max;
    const root_entry_count = @as(usize, 1) << root_bits;
    const root_mask = root_entry_count - 1;
    const root_mask_u32: u32 = @intCast(root_mask);
    const entry_count_max = root_entry_count + (@as(usize, 1) << code_bits_max);
    const code_bits_max_u6: u6 = @intCast(code_bits_max);
    const root_bits_u6: u6 = @intCast(root_bits);

    comptime {
        assert(entry_count_max <= std.math.maxInt(u16));
    }

    return struct {
        entries: []const Entry,
        single_symbol: ?u16 = null,

        const Self = @This();

        pub const alphabet_size_limit = alphabet_size_max;
        pub const root_bit_count = root_bits;
        pub const code_bit_count_max = code_bits_max;
        pub const root_entry_count_max = root_entry_count;
        pub const entry_count_limit = entry_count_max;

        pub fn build(entries_buffer: []Entry, code_lengths: []const u8) Error!Self {
            if (code_lengths.len == 0) return error.InvalidHuffmanTree;
            if (code_lengths.len > alphabet_size_max) return error.InvalidHuffmanTree;
            if (entries_buffer.len < root_entry_count) return error.OutputTooLarge;

            var length_counts: [code_bits_max + 1]u16 = .{0} ** (code_bits_max + 1);
            var populated_symbols: u16 = 0;
            var last_symbol: u16 = 0;

            for (code_lengths, 0..) |length, symbol| {
                if (length > code_bits_max) return error.InvalidHuffmanTree;
                if (length == 0) continue;

                length_counts[length] += 1;
                populated_symbols += 1;
                last_symbol = @intCast(symbol);
            }

            if (populated_symbols == 0) return error.InvalidHuffmanTree;

            if (populated_symbols == 1) {
                if (code_lengths[@intCast(last_symbol)] != 1) return error.InvalidHuffmanTree;

                @memset(entries_buffer[0..root_entry_count], symbolEntry(last_symbol, 0));

                return .{
                    .entries = entries_buffer[0..root_entry_count],
                    .single_symbol = last_symbol,
                };
            }

            try validateCompleteTree(length_counts[0..]);

            var max_extra_bits_by_root: [root_entry_count]u8 = .{0} ** root_entry_count;
            var next_codes = buildNextCodes(&length_counts);
            for (code_lengths) |length| {
                if (length == 0) continue;

                const code = next_codes[length];
                next_codes[length] += 1;
                if (length <= root_bits) continue;

                const reversed = reverseBits(code, @intCast(length));
                const root_index: usize = @intCast(reversed & root_mask_u32);
                const extra_bits = length - root_bits;
                if (max_extra_bits_by_root[root_index] < extra_bits) {
                    max_extra_bits_by_root[root_index] = extra_bits;
                }
            }

            @memset(entries_buffer[0..root_entry_count], invalidEntry());

            var entry_count = root_entry_count;
            var subtable_offsets: [root_entry_count]u16 = .{0} ** root_entry_count;
            for (max_extra_bits_by_root, 0..) |extra_bits, root_index| {
                if (extra_bits == 0) continue;

                const subtable_entry_count = @as(usize, 1) << @as(u6, @intCast(extra_bits));
                if (subtable_entry_count > entries_buffer.len - entry_count) {
                    return error.OutputTooLarge;
                }

                const offset: u16 = @intCast(entry_count);
                const end = entry_count + subtable_entry_count;
                @memset(entries_buffer[entry_count..end], invalidEntry());

                subtable_offsets[root_index] = offset;
                entries_buffer[root_index] = tableEntry(offset, extra_bits);
                entry_count = end;
            }

            next_codes = buildNextCodes(&length_counts);
            for (code_lengths, 0..) |length, symbol| {
                if (length == 0) continue;

                const code = next_codes[length];
                next_codes[length] += 1;
                const reversed = reverseBits(code, @intCast(length));
                if (length <= root_bits) {
                    try fillRoot(entries_buffer[0..root_entry_count], reversed, length, @intCast(symbol));
                } else {
                    try fillSubtable(
                        entries_buffer[0..entry_count],
                        subtable_offsets,
                        reversed,
                        length,
                        @intCast(symbol),
                    );
                }
            }

            try validateTable(entries_buffer[0..entry_count]);

            return .{ .entries = entries_buffer[0..entry_count] };
        }

        pub fn decode(self: Self, reader: *bit_reader.BitReader) Error!u16 {
            if (self.single_symbol) |symbol| return symbol;

            assert(self.entries.len >= root_entry_count);

            if (reader.remainingBits() < root_bits) {
                return self.decodeSlow(reader);
            }

            const root_value = try reader.peekBits(root_bits_u6);
            const root_index: usize = @intCast(root_value & root_mask_u32);
            const root_entry = self.entries[root_index];
            switch (root_entry.op) {
                .invalid => return error.InvalidHuffmanCode,
                .symbol => {
                    try reader.dropBits(@intCast(root_entry.bits));

                    return root_entry.symbol;
                },
                .table => {
                    const subtable_bits: u6 = @intCast(root_entry.bits);
                    const total_bits = root_bits_u6 + subtable_bits;
                    if (reader.remainingBits() < total_bits) {
                        return self.decodeSlow(reader);
                    }

                    const value = try reader.peekBits(total_bits);
                    const subtable_mask = maskBits(subtable_bits);
                    const subtable_index: usize = @as(usize, root_entry.offset) +
                        @as(usize, @intCast((value >> root_bits) & subtable_mask));
                    const subtable_entry = self.entries[subtable_index];
                    if (subtable_entry.op != .symbol) return error.InvalidHuffmanCode;

                    try reader.dropBits(root_bits_u6 + @as(u6, @intCast(subtable_entry.bits)));

                    return subtable_entry.symbol;
                },
            }
        }

        fn decodeSlow(self: Self, reader: *bit_reader.BitReader) Error!u16 {
            var length: u6 = 1;
            while (length <= code_bits_max_u6) : (length += 1) {
                if (reader.remainingBits() < length) return error.TruncatedBitstream;

                const code = try reader.peekBits(length);
                if (self.lookupExact(code, length)) |symbol| {
                    try reader.dropBits(length);

                    return symbol;
                }
            }

            return error.InvalidHuffmanCode;
        }

        fn lookupExact(self: Self, code: u32, length: u6) ?u16 {
            assert(length > 0);
            assert(length <= code_bits_max_u6);

            if (length <= root_bits_u6) {
                const root_index: usize = @intCast(code);
                const entry = self.entries[root_index];
                if (entry.op == .symbol and entry.bits == length) return entry.symbol;

                return null;
            }

            const root_index: usize = @intCast(code & root_mask_u32);
            const root_entry = self.entries[root_index];
            if (root_entry.op != .table) return null;

            const extra_bits = length - root_bits_u6;
            if (extra_bits > root_entry.bits) return null;

            const subtable_index: usize = @as(usize, root_entry.offset) +
                @as(usize, @intCast((code >> root_bits) & maskBits(extra_bits)));
            const entry = self.entries[subtable_index];
            if (entry.op == .symbol and entry.bits == extra_bits) return entry.symbol;

            return null;
        }

        fn fillRoot(
            entries: []Entry,
            reversed: u32,
            length: u8,
            symbol: u16,
        ) Error!void {
            assert(length > 0);
            assert(length <= root_bits);
            assert(entries.len == root_entry_count);

            const stride = @as(usize, 1) << @as(u6, @intCast(length));
            var index: usize = @intCast(reversed);
            while (index < root_entry_count) : (index += stride) {
                if (entries[index].op != .invalid) return error.InvalidHuffmanTree;
                entries[index] = symbolEntry(symbol, length);
            }
        }

        fn fillSubtable(
            entries: []Entry,
            subtable_offsets: [root_entry_count]u16,
            reversed: u32,
            length: u8,
            symbol: u16,
        ) Error!void {
            assert(length > root_bits);
            assert(length <= code_bits_max);
            assert(entries.len <= entry_count_max);

            const root_index: usize = @intCast(reversed & root_mask_u32);
            const root_entry = entries[root_index];
            if (root_entry.op != .table) return error.InvalidHuffmanTree;
            assert(subtable_offsets[root_index] == root_entry.offset);

            const extra_bits = length - root_bits;
            assert(extra_bits <= root_entry.bits);

            const subtable_entry_count = @as(usize, 1) << @as(u6, @intCast(root_entry.bits));
            const subtable_code = (reversed >> root_bits) & maskBits(@intCast(extra_bits));
            const stride = @as(usize, 1) << @as(u6, @intCast(extra_bits));
            var index: usize = @intCast(subtable_code);
            while (index < subtable_entry_count) : (index += stride) {
                const entry_index = @as(usize, root_entry.offset) + index;
                assert(entry_index < entries.len);
                if (entries[entry_index].op != .invalid) return error.InvalidHuffmanTree;
                entries[entry_index] = symbolEntry(symbol, extra_bits);
            }
        }

        fn validateTable(entries: []const Entry) Error!void {
            assert(entries.len >= root_entry_count);
            assert(entries.len <= entry_count_max);

            for (entries[0..root_entry_count]) |root_entry| {
                switch (root_entry.op) {
                    .invalid => return error.InvalidHuffmanTree,
                    .symbol => {},
                    .table => {
                        const subtable_start = @as(usize, root_entry.offset);
                        const subtable_len = @as(usize, 1) << @as(u6, @intCast(root_entry.bits));
                        const subtable_end = subtable_start + subtable_len;
                        if (subtable_start < root_entry_count) return error.InvalidHuffmanTree;
                        if (subtable_end > entries.len) return error.InvalidHuffmanTree;

                        for (entries[subtable_start..subtable_end]) |subtable_entry| {
                            if (subtable_entry.op != .symbol) return error.InvalidHuffmanTree;
                        }
                    },
                }
            }
        }

        fn buildNextCodes(length_counts: *const [code_bits_max + 1]u16) [code_bits_max + 1]u32 {
            var next_codes: [code_bits_max + 1]u32 = .{0} ** (code_bits_max + 1);
            var code: u32 = 0;

            var length: usize = 1;
            while (length <= code_bits_max) : (length += 1) {
                code = (code + length_counts[length - 1]) << 1;
                next_codes[length] = code;
            }

            return next_codes;
        }
    };
}

fn validateCompleteTree(length_counts: []const u16) Error!void {
    assert(length_counts.len > 1);
    assert(length_counts.len <= max_code_bits + 1);

    var remaining_slots: i32 = 1;
    var length: usize = 1;
    while (length < length_counts.len) : (length += 1) {
        remaining_slots *= 2;
        remaining_slots -= @intCast(length_counts[length]);
        if (remaining_slots < 0) return error.InvalidHuffmanTree;
    }

    if (remaining_slots != 0) return error.InvalidHuffmanTree;
}

fn reverseBits(value: u32, bits: u6) u32 {
    assert(bits <= 32);
    if (bits == 0) return 0;

    var remaining = bits;
    var source = value;
    var reversed: u32 = 0;
    while (remaining > 0) : (remaining -= 1) {
        reversed = (reversed << 1) | (source & 1);
        source >>= 1;
    }

    return reversed;
}

fn maskBits(bits: u6) u32 {
    assert(bits < 32);

    return (@as(u32, 1) << @as(u5, @intCast(bits))) - 1;
}

fn invalidEntry() Entry {
    return .{};
}

fn symbolEntry(symbol: u16, bits: u8) Entry {
    return .{
        .symbol = symbol,
        .bits = bits,
        .op = .symbol,
    };
}

fn tableEntry(offset: u16, bits: u8) Entry {
    assert(bits > 0);

    return .{
        .offset = offset,
        .bits = bits,
        .op = .table,
    };
}

comptime {
    assert(SymbolTable.root_entry_count_max == 256);
    assert(SymbolTable.entry_count_limit == 33024);
    assert(CodeLengthTable.root_entry_count_max == 32);
    assert(CodeLengthTable.entry_count_limit == 160);
}

test "VP8L Huffman table constants match format limits" {
    try std.testing.expectEqual(@as(usize, 19), code_length_code_order.len);
    try std.testing.expectEqual(@as(u16, 2328), green_alphabet_size_max);
    try std.testing.expectEqual(@as(usize, 33024), SymbolTable.entry_count_limit);
    try std.testing.expectEqual(@as(usize, 160), CodeLengthTable.entry_count_limit);
}

test "VP8L Huffman table decodes a single leaf without consuming bits" {
    var entries: [SymbolTable.entry_count_limit]Entry = undefined;
    const code_lengths = [_]u8{0} ** 42 ++ [_]u8{1};
    const table = try SymbolTable.build(&entries, &code_lengths);

    var reader = bit_reader.BitReader.init(&.{});

    try std.testing.expectEqual(@as(u16, 42), try table.decode(&reader));
    try std.testing.expectEqual(@as(usize, 0), reader.loadedBytes());
    try std.testing.expectEqual(@as(usize, 0), reader.remainingBits());
}

test "VP8L Huffman table decodes canonical two-symbol codes" {
    const bit_writer = @import("../bit_writer.zig");

    var entries: [SymbolTable.entry_count_limit]Entry = undefined;
    const code_lengths = [_]u8{ 1, 1 };
    const table = try SymbolTable.build(&entries, &code_lengths);

    var encoded: [1]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBits(0, 1);
    try writer.writeBits(1, 1);

    var reader = bit_reader.BitReader.init(try writer.finish());
    try std.testing.expectEqual(@as(u16, 0), try table.decode(&reader));
    try std.testing.expectEqual(@as(u16, 1), try table.decode(&reader));
}

test "VP8L Huffman table decodes reversed canonical bit order" {
    const bit_writer = @import("../bit_writer.zig");

    var entries: [SymbolTable.entry_count_limit]Entry = undefined;
    const code_lengths = [_]u8{ 2, 2, 2, 2 };
    const table = try SymbolTable.build(&entries, &code_lengths);

    var encoded: [1]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBits(reverseBits(0b00, 2), 2);
    try writer.writeBits(reverseBits(0b01, 2), 2);
    try writer.writeBits(reverseBits(0b10, 2), 2);
    try writer.writeBits(reverseBits(0b11, 2), 2);

    var reader = bit_reader.BitReader.init(try writer.finish());
    try std.testing.expectEqual(@as(u16, 0), try table.decode(&reader));
    try std.testing.expectEqual(@as(u16, 1), try table.decode(&reader));
    try std.testing.expectEqual(@as(u16, 2), try table.decode(&reader));
    try std.testing.expectEqual(@as(u16, 3), try table.decode(&reader));
}

test "VP8L Huffman table decodes symbols from a second-level table" {
    const bit_writer = @import("../bit_writer.zig");

    var entries: [SymbolTable.entry_count_limit]Entry = undefined;
    const code_lengths = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 9 };
    const table = try SymbolTable.build(&entries, &code_lengths);

    var encoded: [4]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBits(reverseBits(0b111111110, 9), 9);
    try writer.writeBits(reverseBits(0b111111111, 9), 9);

    var reader = bit_reader.BitReader.init(try writer.finish());
    try std.testing.expectEqual(@as(u16, 8), try table.decode(&reader));
    try std.testing.expectEqual(@as(u16, 9), try table.decode(&reader));
}

test "VP8L Huffman table falls back when fewer than root bits remain" {
    var entries: [SymbolTable.entry_count_limit]Entry = undefined;
    const code_lengths = [_]u8{ 1, 2, 2 };
    const table = try SymbolTable.build(&entries, &code_lengths);

    const encoded = [_]u8{0};
    var reader = bit_reader.BitReader.init(&encoded);
    try reader.dropBits(7);

    try std.testing.expectEqual(@as(usize, 1), reader.remainingBits());
    try std.testing.expectEqual(@as(u16, 0), try table.decode(&reader));
    try std.testing.expectEqual(@as(usize, 0), reader.remainingBits());
}

test "VP8L Huffman table rejects invalid trees" {
    var entries: [SymbolTable.entry_count_limit]Entry = undefined;

    try std.testing.expectError(error.InvalidHuffmanTree, SymbolTable.build(&entries, &.{}));
    try std.testing.expectError(error.InvalidHuffmanTree, SymbolTable.build(&entries, &.{ 1, 1, 1 }));
    try std.testing.expectError(error.InvalidHuffmanTree, SymbolTable.build(&entries, &.{ 2, 2 }));
    try std.testing.expectError(error.InvalidHuffmanTree, SymbolTable.build(&entries, &.{ 0, 2 }));
    try std.testing.expectError(error.InvalidHuffmanTree, SymbolTable.build(&entries, &.{16}));
}

test "VP8L Huffman table reports bounded table buffers and truncated input" {
    var short_entries: [SymbolTable.root_entry_count_max - 1]Entry = undefined;
    try std.testing.expectError(
        error.OutputTooLarge,
        SymbolTable.build(&short_entries, &.{ 1, 1 }),
    );

    var entries: [SymbolTable.entry_count_limit]Entry = undefined;
    const table = try SymbolTable.build(&entries, &.{ 1, 2, 2 });
    var reader = bit_reader.BitReader.init(&.{});

    try std.testing.expectError(error.TruncatedBitstream, table.decode(&reader));
}
