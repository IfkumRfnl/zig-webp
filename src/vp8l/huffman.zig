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

/// Classification of a packed `Entry` relative to a table's `root_bits`.
pub const EntryKind = enum {
    invalid,
    symbol,
    table,
};
pub const PeekedSymbol = struct {
    symbol: u16,
    bit_count: u6,
};

/// Two-byte Huffman lookup entry (bits:u4 + payload:u12).
///
/// The low 4 bits hold a bit width and the high 12 bits hold either a symbol
/// or an absolute subtable start index. Kind is not stored: decode/build sites
/// classify with `kind(root_bits)`:
/// - `bits == 0` and `payload == invalid_payload` → unfilled / invalid
/// - `bits <= root_bits` → symbol (`payload` is the symbol; `bits` is the
///   consumed length at root or the subtable-local length in a secondary slot)
/// - `bits > root_bits` → table pointer (`payload` is the absolute subtable
///   start; `bits` is `root_bits + subtable_bits`)
///
/// Bounds (8-bit root, alphabet ≤ 2328): symbol ≤ 2327 and table size ≤ 2704
/// (Mark Adler `enough.c` / libwebp `kTableSize` green) both fit in 12 bits.
pub const Entry = packed struct(u16) {
    bits: u4 = 0,
    payload: u12 = invalid_payload,

    /// Sentinel for unfilled slots. Never a valid symbol (max 2327) or table
    /// offset under the `enough.c` entry-count bound (≤ 2704).
    pub const invalid_payload: u12 = std.math.maxInt(u12);

    pub fn invalid() Entry {
        return .{};
    }

    pub fn symbol(symbol_value: u16, bit_count: u8) Entry {
        assert(symbol_value < invalid_payload);
        assert(bit_count <= std.math.maxInt(u4));

        return .{
            .bits = @intCast(bit_count),
            .payload = @intCast(symbol_value),
        };
    }

    pub fn table(offset: u16, root_bits: u5, total_bits: u8) Entry {
        assert(offset < invalid_payload);
        assert(total_bits > root_bits);
        assert(total_bits <= std.math.maxInt(u4));

        return .{
            .bits = @intCast(total_bits),
            .payload = @intCast(offset),
        };
    }

    pub fn isInvalid(self: Entry) bool {
        return self.bits == 0 and self.payload == invalid_payload;
    }

    pub fn kind(self: Entry, root_bits: u5) EntryKind {
        if (self.isInvalid()) return .invalid;
        if (self.bits > root_bits) return .table;
        return .symbol;
    }

    pub fn symbolValue(self: Entry, root_bits: u5) u16 {
        assert(self.kind(root_bits) == .symbol);
        return self.payload;
    }

    pub fn tableOffset(self: Entry, root_bits: u5) u16 {
        assert(self.kind(root_bits) == .table);
        return self.payload;
    }

    pub fn subtableBits(self: Entry, root_bits: u5) u4 {
        assert(self.kind(root_bits) == .table);
        assert(self.bits > root_bits);

        return self.bits - @as(u4, @intCast(root_bits));
    }
};

/// enough.c / libwebp bound: worst-case root+secondary size for an 8-bit first
/// level with alphabet size ≤ `green_alphabet_size_max` (2328).
pub const symbol_table_entry_count_enough = 2704;

comptime {
    assert(@sizeOf(Entry) == 2);
    assert(@alignOf(Entry) == 2);
    assert(@bitSizeOf(Entry) == 16);
    assert(code_length_code_order.len == code_length_code_count);
    assert(code_length_code_bits_max < max_code_bits);
    assert(distance_alphabet_size < literal_alphabet_size);
    assert(green_alphabet_size_max == 2328);
    assert(green_alphabet_size_max <= Entry.invalid_payload);
    assert(symbol_table_entry_count_enough <= Entry.invalid_payload);
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
    // Tight enough.c / geometry bound so absolute offsets fit in Entry.payload (u12).
    const entry_count_max = if (root_bits == root_bits_default)
        symbol_table_entry_count_enough
    else
        root_entry_count + root_entry_count * (@as(usize, 1) << (code_bits_max - root_bits));
    const code_bits_max_u6: u6 = @intCast(code_bits_max);
    const root_bits_u6: u6 = @intCast(root_bits);

    comptime {
        assert(alphabet_size_max <= Entry.invalid_payload);
        assert(entry_count_max <= Entry.invalid_payload);
    }

    return struct {
        entries_ptr: [*]const Entry,
        entries_len: u16,
        single_symbol: ?u16 = null,

        const Self = @This();
        comptime {
            const pointer_size = @sizeOf([*]const Entry);
            assert(pointer_size == 4 or pointer_size == 8);
            assert(@sizeOf(Self) == if (pointer_size == 4) 12 else 16);
        }

        pub const alphabet_size_limit = alphabet_size_max;
        pub const root_bit_count = root_bits;
        pub const code_bit_count_max = code_bits_max;
        pub const root_entry_count_max = root_entry_count;
        pub const entry_count_limit = entry_count_max;
        pub inline fn entriesSlice(self: Self) []const Entry {
            return self.entries_ptr[0..self.entries_len];
        }

        /// Builds the canonical table for VP8L's compact one/two-symbol encoding.
        pub fn buildSimple(
            entries_buffer: []Entry,
            symbol0: u16,
            symbol1: ?u16,
        ) Error!Self {
            if (entries_buffer.len < root_entry_count) return error.OutputTooLarge;
            if (symbol0 >= alphabet_size_max) return error.InvalidHuffmanTree;

            const second = symbol1 orelse {
                return .{
                    .entries_ptr = entries_buffer.ptr,
                    .entries_len = 0,
                    .single_symbol = symbol0,
                };
            };
            if (second >= alphabet_size_max) return error.InvalidHuffmanTree;
            if (second == symbol0) {
                return .{
                    .entries_ptr = entries_buffer.ptr,
                    .entries_len = 0,
                    .single_symbol = symbol0,
                };
            }

            const symbol_low = @min(symbol0, second);
            const symbol_high = @max(symbol0, second);
            const entry_low = Entry.symbol(symbol_low, 1);
            const entry_high = Entry.symbol(symbol_high, 1);
            var index: usize = 0;
            while (index < root_entry_count) : (index += 2) {
                entries_buffer[index] = entry_low;
                entries_buffer[index + 1] = entry_high;
            }

            return .{
                .entries_ptr = entries_buffer.ptr,
                .entries_len = root_entry_count,
            };
        }

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
                // The VP8L single-leaf exception is encoded with length 1.
                if (code_lengths[@intCast(last_symbol)] != 1) return error.InvalidHuffmanTree;

                return .{
                    .entries_ptr = entries_buffer.ptr,
                    .entries_len = 0,
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

            @memset(entries_buffer[0..root_entry_count], Entry.invalid());

            var entry_count = root_entry_count;
            var subtable_offsets: [root_entry_count]u16 = .{0} ** root_entry_count;
            for (max_extra_bits_by_root, 0..) |extra_bits, root_index| {
                if (extra_bits == 0) continue;

                const subtable_entry_count = @as(usize, 1) << @intCast(extra_bits);
                if (subtable_entry_count > entries_buffer.len - entry_count) {
                    return error.OutputTooLarge;
                }

                const offset: u16 = @intCast(entry_count);
                const end = entry_count + subtable_entry_count;
                @memset(entries_buffer[entry_count..end], Entry.invalid());

                subtable_offsets[root_index] = offset;
                entries_buffer[root_index] = Entry.table(
                    offset,
                    root_bits,
                    @as(u8, root_bits) + extra_bits,
                );
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

            return .{
                .entries_ptr = entries_buffer.ptr,
                .entries_len = @intCast(entry_count),
            };
        }

        pub fn decode(self: Self, reader: *bit_reader.BitReader) Error!u16 {
            if (self.single_symbol) |symbol| return symbol;

            assert(self.entries_len >= root_entry_count);

            if (reader.remainingBits() < root_bits) {
                return self.decodeSlow(reader);
            }

            const root_value = try reader.peekBits(root_bits_u6);
            const root_index: usize = @intCast(root_value & root_mask_u32);
            const root_entry = self.entries_ptr[root_index];
            switch (root_entry.kind(root_bits)) {
                .invalid => return error.InvalidHuffmanCode,
                .symbol => {
                    try reader.dropBits(@intCast(root_entry.bits));

                    return root_entry.symbolValue(root_bits);
                },
                .table => {
                    const subtable_bits: u6 = @intCast(root_entry.subtableBits(root_bits));
                    const total_bits = root_bits_u6 + subtable_bits;
                    if (reader.remainingBits() < total_bits) {
                        return self.decodeSlow(reader);
                    }

                    const value = try reader.peekBits(total_bits);
                    const subtable_mask = maskBits(subtable_bits);
                    const subtable_index: usize = @as(usize, root_entry.tableOffset(root_bits)) +
                        @as(usize, @intCast((value >> root_bits) & subtable_mask));
                    const subtable_entry = self.entries_ptr[subtable_index];
                    if (subtable_entry.kind(root_bits) != .symbol) {
                        return error.InvalidHuffmanCode;
                    }

                    try reader.dropBits(root_bits_u6 + @as(u6, @intCast(subtable_entry.bits)));

                    return subtable_entry.symbolValue(root_bits);
                },
            }
        }

        /// Decodes from the entropy loop's token-prefilled bit buffer.
        ///
        /// The normal `decode` path remains the checked authority for parsing
        /// and the short physical tail. With `code_bits_max` buffered, every
        /// valid primary or secondary lookup can consume without another
        /// refill or bounds check.
        pub inline fn decodeBuffered(self: Self, reader: *bit_reader.BitReader) Error!u16 {
            if (self.single_symbol) |symbol| return symbol;

            if (reader.bufferedBits() < code_bits_max_u6) {
                reader.fill();
                if (reader.bufferedBits() < code_bits_max_u6) {
                    return self.decode(reader);
                }
            }

            return self.decodePrefilled(reader);
        }

        /// Decodes without a refill after the caller has reserved enough bits
        /// for the entire maximum-length code.
        pub inline fn decodePrefilled(
            self: Self,
            reader: *bit_reader.BitReader,
        ) Error!u16 {
            if (self.single_symbol) |symbol| return symbol;
            assert(reader.bufferedBits() >= code_bits_max_u6);
            assert(self.entries_len >= root_entry_count);

            const value: u32 = @truncate(reader.peekFull());
            const root_index: usize = @intCast(value & root_mask_u32);
            const root_entry = self.entries_ptr[root_index];
            if (root_entry.bits <= root_bits) {
                reader.dropBitsBuffered(@intCast(root_entry.bits));
                return root_entry.symbolValue(root_bits);
            }

            const subtable_bits: u6 = @intCast(root_entry.subtableBits(root_bits));
            const subtable_mask = maskBits(subtable_bits);
            const subtable_index: usize =
                @as(usize, root_entry.tableOffset(root_bits)) +
                @as(usize, @intCast((value >> root_bits) & subtable_mask));
            const subtable_entry = self.entries_ptr[subtable_index];
            const consumed_bits =
                root_bits_u6 + @as(u6, @intCast(subtable_entry.bits));
            reader.dropBitsBuffered(consumed_bits);
            return subtable_entry.symbolValue(root_bits);
        }

        /// Peeks a symbol that is fully represented by the root table.
        ///
        /// The entropy loop uses this to consume adjacent color-cache symbols
        /// without repeating its tile-selection and dispatch work.
        pub inline fn peekBuffered(
            self: Self,
            reader: *const bit_reader.BitReader,
        ) ?PeekedSymbol {
            if (self.single_symbol) |symbol| {
                return .{ .symbol = symbol, .bit_count = 0 };
            }
            if (reader.bufferedBits() < root_bits_u6) return null;

            const value: u32 = @truncate(reader.peekFull());
            const root_index: usize = @intCast(value & root_mask_u32);
            const root_entry = self.entries_ptr[root_index];
            if (root_entry.bits > root_bits) return null;

            return .{
                .symbol = root_entry.symbolValue(root_bits),
                .bit_count = @intCast(root_entry.bits),
            };
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
                const entry = self.entries_ptr[root_index];
                if (entry.kind(root_bits) == .symbol and entry.bits == length) {
                    return entry.symbolValue(root_bits);
                }

                return null;
            }

            const root_index: usize = @intCast(code & root_mask_u32);
            const root_entry = self.entries_ptr[root_index];
            if (root_entry.kind(root_bits) != .table) return null;

            const extra_bits = length - root_bits_u6;
            if (extra_bits > root_entry.subtableBits(root_bits)) return null;

            const subtable_index: usize = @as(usize, root_entry.tableOffset(root_bits)) +
                @as(usize, @intCast((code >> root_bits) & maskBits(extra_bits)));
            const entry = self.entries_ptr[subtable_index];
            if (entry.kind(root_bits) == .symbol and entry.bits == extra_bits) {
                return entry.symbolValue(root_bits);
            }

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

            const stride = @as(usize, 1) << @intCast(length);
            var index: usize = @intCast(reversed);
            while (index < root_entry_count) : (index += stride) {
                if (!entries[index].isInvalid()) return error.InvalidHuffmanTree;
                entries[index] = Entry.symbol(symbol, length);
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
            if (root_entry.kind(root_bits) != .table) return error.InvalidHuffmanTree;
            assert(subtable_offsets[root_index] == root_entry.tableOffset(root_bits));

            const extra_bits = length - root_bits;
            const root_subtable_bits = root_entry.subtableBits(root_bits);
            assert(extra_bits <= root_subtable_bits);

            const subtable_entry_count = @as(usize, 1) << @intCast(root_subtable_bits);
            const subtable_code = (reversed >> root_bits) & maskBits(@intCast(extra_bits));
            const stride = @as(usize, 1) << @intCast(extra_bits);
            var index: usize = @intCast(subtable_code);
            while (index < subtable_entry_count) : (index += stride) {
                const entry_index = @as(usize, root_entry.tableOffset(root_bits)) + index;
                assert(entry_index < entries.len);
                if (!entries[entry_index].isInvalid()) return error.InvalidHuffmanTree;
                entries[entry_index] = Entry.symbol(symbol, extra_bits);
            }
        }

        fn validateTable(entries: []const Entry) Error!void {
            assert(entries.len >= root_entry_count);
            assert(entries.len <= entry_count_max);

            for (entries[0..root_entry_count]) |root_entry| {
                switch (root_entry.kind(root_bits)) {
                    .invalid => return error.InvalidHuffmanTree,
                    .symbol => {},
                    .table => {
                        const subtable_start = @as(usize, root_entry.tableOffset(root_bits));
                        const subtable_len = @as(usize, 1) << @intCast(root_entry.subtableBits(root_bits));
                        const subtable_end = subtable_start + subtable_len;
                        if (subtable_start < root_entry_count) return error.InvalidHuffmanTree;
                        if (subtable_end > entries.len) return error.InvalidHuffmanTree;

                        for (entries[subtable_start..subtable_end]) |subtable_entry| {
                            if (subtable_entry.kind(root_bits) != .symbol) {
                                return error.InvalidHuffmanTree;
                            }
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

comptime {
    assert(SymbolTable.root_entry_count_max == 1 << root_bits_default);
    assert(SymbolTable.entry_count_limit == symbol_table_entry_count_enough);
    assert(CodeLengthTable.root_entry_count_max == 32);
    assert(CodeLengthTable.entry_count_limit == 160);
}

test "VP8L Huffman table constants match format limits" {
    try std.testing.expectEqual(@as(usize, 19), code_length_code_order.len);
    try std.testing.expectEqual(@as(u16, 2328), green_alphabet_size_max);
    try std.testing.expectEqual(@as(usize, 2704), SymbolTable.entry_count_limit);
    try std.testing.expectEqual(@as(usize, 160), CodeLengthTable.entry_count_limit);
}

test "VP8L Huffman Entry is exactly two bytes" {
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(Entry));
    try std.testing.expectEqual(@as(usize, 2), @alignOf(Entry));
    try std.testing.expectEqual(@as(usize, 16), @bitSizeOf(Entry));
}

test "VP8L Huffman Entry constructors classify by root_bits" {
    const invalid = Entry.invalid();
    try std.testing.expect(invalid.isInvalid());
    try std.testing.expectEqual(EntryKind.invalid, invalid.kind(root_bits_default));
    try std.testing.expectEqual(Entry.invalid_payload, invalid.payload);
    try std.testing.expectEqual(@as(u4, 0), invalid.bits);
    const default: Entry = .{};
    try std.testing.expect(default.isInvalid());
    try std.testing.expectEqual(invalid, default);

    const symbol = Entry.symbol(42, 3);
    try std.testing.expectEqual(EntryKind.symbol, symbol.kind(root_bits_default));
    try std.testing.expectEqual(@as(u12, 42), symbol.payload);
    try std.testing.expectEqual(@as(u4, 3), symbol.bits);
    try std.testing.expectEqual(@as(u16, 42), symbol.symbolValue(root_bits_default));

    const max_symbol = Entry.symbol(green_alphabet_size_max - 1, root_bits_default);
    try std.testing.expectEqual(EntryKind.symbol, max_symbol.kind(root_bits_default));
    try std.testing.expectEqual(
        @as(u16, green_alphabet_size_max - 1),
        max_symbol.symbolValue(root_bits_default),
    );

    const table = Entry.table(256, root_bits_default, root_bits_default + 4);
    try std.testing.expectEqual(EntryKind.table, table.kind(root_bits_default));
    try std.testing.expectEqual(@as(u12, 256), table.payload);
    try std.testing.expectEqual(@as(u4, root_bits_default + 4), table.bits);
    try std.testing.expectEqual(@as(u4, 4), table.subtableBits(root_bits_default));
    try std.testing.expectEqual(@as(u16, 256), table.tableOffset(root_bits_default));

    const max_offset = Entry.table(
        symbol_table_entry_count_enough - 1,
        root_bits_default,
        root_bits_default + 1,
    );
    try std.testing.expectEqual(
        @as(u16, symbol_table_entry_count_enough - 1),
        max_offset.tableOffset(root_bits_default),
    );
}

test "VP8L Huffman table decodes a single leaf without consuming bits" {
    var entries: [SymbolTable.entry_count_limit]Entry = undefined;
    const code_lengths = [_]u8{0} ** 42 ++ [_]u8{1};
    const table = try SymbolTable.build(&entries, &code_lengths);
    try std.testing.expectEqual(@as(usize, 0), table.entriesSlice().len);

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

    var buffered_reader = bit_reader.BitReader.init(try writer.finish());
    buffered_reader.fill();
    try std.testing.expectEqual(@as(u16, 0), try table.decodeBuffered(&buffered_reader));
    try std.testing.expectEqual(@as(u16, 1), try table.decodeBuffered(&buffered_reader));
}

test "VP8L Huffman simple builder preserves canonical symbol order" {
    var entries: [SymbolTable.entry_count_limit]Entry = undefined;
    const table = try SymbolTable.buildSimple(&entries, 42, 7);
    try std.testing.expectEqual(SymbolTable.root_entry_count_max, table.entriesSlice().len);
    try std.testing.expectEqual(@as(?u16, null), table.single_symbol);

    const encoded = [_]u8{0b0000_0010};
    var reader = bit_reader.BitReader.init(&encoded);
    try std.testing.expectEqual(@as(u16, 7), try table.decode(&reader));
    try std.testing.expectEqual(@as(u16, 42), try table.decode(&reader));

    const duplicate = try SymbolTable.buildSimple(&entries, 42, 42);
    try std.testing.expectEqual(@as(?u16, 42), duplicate.single_symbol);
    try std.testing.expectEqual(@as(usize, 0), duplicate.entriesSlice().len);

    try std.testing.expectError(
        error.InvalidHuffmanTree,
        SymbolTable.buildSimple(&entries, SymbolTable.alphabet_size_limit, null),
    );
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

    // Codes longer than root_bits must land in a second-level table entry.
    var saw_table_entry = false;
    for (table.entriesSlice()[0..SymbolTable.root_entry_count_max]) |root_entry| {
        if (root_entry.kind(root_bits_default) != .table) continue;
        saw_table_entry = true;
        try std.testing.expect(
            root_entry.tableOffset(root_bits_default) >= SymbolTable.root_entry_count_max,
        );
        try std.testing.expect(root_entry.subtableBits(root_bits_default) > 0);
        const sub = table.entriesSlice()[root_entry.tableOffset(root_bits_default)];
        try std.testing.expect(!sub.isInvalid());
        _ = sub.symbolValue(root_bits_default);
    }
    try std.testing.expect(saw_table_entry);

    var encoded: [4]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writer.writeBits(reverseBits(0b111111110, 9), 9);
    try writer.writeBits(reverseBits(0b111111111, 9), 9);

    var reader = bit_reader.BitReader.init(try writer.finish());
    try std.testing.expectEqual(@as(u16, 8), try table.decode(&reader));
    try std.testing.expectEqual(@as(u16, 9), try table.decode(&reader));

    var buffered_reader = bit_reader.BitReader.init(try writer.finish());
    buffered_reader.fill();
    try std.testing.expectEqual(@as(u16, 8), try table.decodeBuffered(&buffered_reader));
    try std.testing.expectEqual(@as(u16, 9), try table.decodeBuffered(&buffered_reader));
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

    var buffered_reader = bit_reader.BitReader.init(&encoded);
    try buffered_reader.dropBits(7);
    try std.testing.expectEqual(@as(u16, 0), try table.decodeBuffered(&buffered_reader));
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
    try std.testing.expect(table.single_symbol == null);

    var reader = bit_reader.BitReader.init(&.{});
    try std.testing.expectError(error.TruncatedBitstream, table.decode(&reader));

    // After the final available bit is consumed, further decode truncates.
    // Single-symbol tables still decode without needing bits.
    const encoded = [_]u8{0};
    var limited = bit_reader.BitReader.init(&encoded);
    try limited.dropBits(7);
    try std.testing.expectEqual(@as(usize, 1), limited.remainingBits());
    try std.testing.expectEqual(@as(u16, 0), try table.decode(&limited));
    try std.testing.expectError(error.TruncatedBitstream, table.decode(&limited));

    var single_entries: [SymbolTable.entry_count_limit]Entry = undefined;
    const single = try SymbolTable.build(&single_entries, &.{ 0, 0, 1 });
    var empty = bit_reader.BitReader.init(&.{});
    try std.testing.expectEqual(@as(u16, 2), try single.decode(&empty));
}

test "VP8L Huffman compact Entry keeps distinct absolute subtable offsets" {
    // Goal: after packing symbol/subtable into one u16 payload, two root
    // `.table` entries must carry different absolute offsets. A tree with
    // 254 length-8 symbols and 4 length-9 symbols is complete (Kraft = 1)
    // and spreads the long codes across at least two root prefixes.
    const bit_writer = @import("../bit_writer.zig");

    var code_lengths: [258]u8 = undefined;
    @memset(code_lengths[0..254], 8);
    @memset(code_lengths[254..], 9);

    var entries: [SymbolTable.entry_count_limit]Entry = undefined;
    const table = try SymbolTable.build(&entries, &code_lengths);

    var offsets: [8]u16 = undefined;
    var offset_count: usize = 0;
    for (table.entriesSlice()[0..SymbolTable.root_entry_count_max]) |root_entry| {
        if (root_entry.kind(root_bits_default) != .table) continue;

        const offset = root_entry.tableOffset(root_bits_default);
        try std.testing.expect(offset >= SymbolTable.root_entry_count_max);
        try std.testing.expect(root_entry.subtableBits(root_bits_default) > 0);

        var seen = false;
        for (offsets[0..offset_count]) |existing| {
            if (existing == offset) seen = true;
        }
        if (!seen) {
            try std.testing.expect(offset_count < offsets.len);
            offsets[offset_count] = offset;
            offset_count += 1;
        }
    }
    try std.testing.expect(offset_count >= 2);
    try std.testing.expect(offsets[0] != offsets[1]);

    // Every length-9 symbol must decode from a second-level table.
    var found = [_]bool{false} ** 4;
    var pattern: u32 = 0;
    while (pattern < 512) : (pattern += 1) {
        var encoded: [2]u8 = undefined;
        var writer = bit_writer.BitWriter.init(&encoded);
        try writer.writeBits(pattern, 9);
        var reader = bit_reader.BitReader.init(try writer.finish());
        const symbol = table.decode(&reader) catch continue;
        if (symbol >= 254 and symbol <= 257) {
            found[symbol - 254] = true;
        }
    }
    try std.testing.expect(found[0] and found[1] and found[2] and found[3]);
}

test "VP8L Huffman two-byte Entry packs payload beside bits" {
    // Goal: wasm-safe packed u16 load recovers bits/payload without padding.
    const entry = Entry.symbol(2327, 8);
    const raw: u16 = @bitCast(entry);
    try std.testing.expectEqual(@as(u16, (2327 << 4) | 8), raw);

    const restored: Entry = @bitCast(raw);
    try std.testing.expectEqual(@as(u4, 8), restored.bits);
    try std.testing.expectEqual(@as(u12, 2327), restored.payload);
}

test "VP8L Huffman root-only buffer rejects trees that need a subtable" {
    var tiny: [SymbolTable.root_entry_count_max]Entry = undefined;
    const long_lengths = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 9 };
    try std.testing.expectError(
        error.OutputTooLarge,
        SymbolTable.build(&tiny, &long_lengths),
    );
}

test "VP8L Huffman code-length table fits two-byte entries with 5-bit root" {
    var entries: [CodeLengthTable.entry_count_limit]Entry = undefined;
    const code_lengths = [_]u8{ 1, 2, 3, 4, 5, 6, 6 };
    const table = try CodeLengthTable.build(&entries, &code_lengths);

    var saw_table = false;
    for (table.entriesSlice()[0..CodeLengthTable.root_entry_count_max]) |root_entry| {
        switch (root_entry.kind(code_length_root_bits)) {
            .invalid => try std.testing.expect(false),
            .symbol => try std.testing.expect(root_entry.bits <= code_length_root_bits),
            .table => {
                saw_table = true;
                try std.testing.expect(root_entry.bits > code_length_root_bits);
                try std.testing.expect(
                    root_entry.tableOffset(code_length_root_bits) >=
                        CodeLengthTable.root_entry_count_max,
                );
            },
        }
    }
    try std.testing.expect(saw_table);
}
