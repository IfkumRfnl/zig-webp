//! VP8L prefix-code group storage for spatial entropy decoding.

const std = @import("std");
const assert = std.debug.assert;

const bit_reader = @import("../bit_reader.zig");
const bit_writer = @import("../bit_writer.zig");
const errors = @import("../errors.zig");
const huffman = @import("huffman.zig");
const image = @import("../image.zig");
const image_data = @import("image_data.zig");
const limits = @import("../limits.zig");
const meta_prefix = @import("meta_prefix.zig");
const pixel = @import("pixel.zig");

const allocation_bytes_default = (limits.ResourceLimits{}).allocation_bytes_max;

pub const Options = struct {
    allocation_bytes_max: u64 = allocation_bytes_default,
    group_count_max: u32 = meta_prefix.group_count_max,
};

pub const WorkBuffers = struct {
    prefix_code_group: image_data.PrefixCodeGroupBuffers = .{},
};

pub const Store = struct {
    gpa: std.mem.Allocator,
    groups: []image_data.PrefixCodeGroup,
    initialized_count: usize = 0,
    allocation_bytes: u64 = 0,

    pub fn readAll(
        gpa: std.mem.Allocator,
        reader: *bit_reader.BitReader,
        group_count: u32,
        color_cache_size: u16,
        options: Options,
        buffers: *WorkBuffers,
    ) errors.Error!Store {
        if (group_count == 0) return error.InvalidVP8LImageData;
        if (group_count > meta_prefix.group_count_max) return error.InvalidVP8LImageData;
        if (group_count > options.group_count_max) return error.InvalidVP8LImageData;

        var allocation_bytes: u64 = 0;
        const groups_bytes = try allocationBytes(
            image_data.PrefixCodeGroup,
            group_count,
            &allocation_bytes,
            options,
        );
        _ = groups_bytes;

        var store = Store{
            .gpa = gpa,
            .groups = try gpa.alloc(image_data.PrefixCodeGroup, group_count),
            .allocation_bytes = allocation_bytes,
        };
        errdefer store.deinit();

        var group_index: usize = 0;
        while (group_index < group_count) : (group_index += 1) {
            const prefix_group = try image_data.readPrefixCodeGroup(
                reader,
                color_cache_size,
                &buffers.prefix_code_group,
            );
            store.groups[group_index] = try store.copyGroup(prefix_group, options);
            store.initialized_count += 1;
        }

        return store;
    }

    pub fn deinit(self: *Store) void {
        var group_index: usize = 0;
        while (group_index < self.initialized_count) : (group_index += 1) {
            self.freeGroup(self.groups[group_index]);
        }

        self.gpa.free(self.groups);
        self.* = .{
            .gpa = self.gpa,
            .groups = &.{},
        };
    }

    pub fn group(self: Store, group_index: u16) errors.Error!image_data.PrefixCodeGroup {
        if (group_index >= self.initialized_count) return error.InvalidVP8LImageData;

        return self.groups[group_index];
    }

    pub fn groupForPixel(
        self: Store,
        info: meta_prefix.Info,
        entropy_image: []const pixel.Pixel,
        x: u32,
        y: u32,
    ) errors.Error!image_data.PrefixCodeGroup {
        return self.group(try info.groupIndex(entropy_image, x, y));
    }

    fn copyGroup(
        self: *Store,
        prefix_group: image_data.PrefixCodeGroup,
        options: Options,
    ) errors.Error!image_data.PrefixCodeGroup {
        var copied: image_data.PrefixCodeGroup = undefined;

        copied.green = try self.copyTable(prefix_group.green, options);
        errdefer self.gpa.free(copied.green.entries);

        copied.red = try self.copyTable(prefix_group.red, options);
        errdefer self.gpa.free(copied.red.entries);

        copied.blue = try self.copyTable(prefix_group.blue, options);
        errdefer self.gpa.free(copied.blue.entries);

        copied.alpha = try self.copyTable(prefix_group.alpha, options);
        errdefer self.gpa.free(copied.alpha.entries);

        copied.distance = try self.copyTable(prefix_group.distance, options);

        return copied;
    }

    fn copyTable(
        self: *Store,
        table: huffman.SymbolTable,
        options: Options,
    ) errors.Error!huffman.SymbolTable {
        _ = try allocationBytes(huffman.Entry, table.entries.len, &self.allocation_bytes, options);

        const entries = try self.gpa.alloc(huffman.Entry, table.entries.len);
        errdefer self.gpa.free(entries);
        @memcpy(entries, table.entries);

        return .{
            .entries = entries,
            .single_symbol = table.single_symbol,
        };
    }

    fn freeGroup(self: Store, prefix_group: image_data.PrefixCodeGroup) void {
        self.gpa.free(prefix_group.green.entries);
        self.gpa.free(prefix_group.red.entries);
        self.gpa.free(prefix_group.blue.entries);
        self.gpa.free(prefix_group.alpha.entries);
        self.gpa.free(prefix_group.distance.entries);
    }
};

fn allocationBytes(
    comptime T: type,
    count: u64,
    allocation_bytes: *u64,
    options: Options,
) errors.Error!u64 {
    if (count > std.math.maxInt(usize)) return error.AllocationLimitExceeded;
    if (count > std.math.maxInt(u64) / @sizeOf(T)) return error.AllocationLimitExceeded;

    const bytes = count * @sizeOf(T);
    if (bytes > options.allocation_bytes_max -| allocation_bytes.*) {
        return error.AllocationLimitExceeded;
    }

    allocation_bytes.* += bytes;
    return bytes;
}

fn writeSimplePrefixCode(writer: *bit_writer.BitWriter, symbol: u8) errors.Error!void {
    try writer.writeBit(1);
    try writer.writeBit(0);
    try writer.writeBit(if (symbol <= 1) 0 else 1);
    try writer.writeBits(symbol, if (symbol <= 1) 1 else 8);
}

fn writeConstantPrefixCodeGroup(
    writer: *bit_writer.BitWriter,
    green_symbol: u8,
) errors.Error!void {
    try writeSimplePrefixCode(writer, green_symbol);
    try writeSimplePrefixCode(writer, 0);
    try writeSimplePrefixCode(writer, 0);
    try writeSimplePrefixCode(writer, 0);
    try writeSimplePrefixCode(writer, 0);
}

comptime {
    assert(@sizeOf(huffman.Entry) == 6);
    assert(meta_prefix.group_count_max == 65_536);
}

test "VP8L prefix group store reads and owns multiple groups" {
    var encoded: [32]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writeConstantPrefixCodeGroup(&writer, 0);
    try writeConstantPrefixCodeGroup(&writer, 1);

    var reader = bit_reader.BitReader.init(try writer.finish());
    const buffers = try std.testing.allocator.create(WorkBuffers);
    defer std.testing.allocator.destroy(buffers);
    buffers.* = .{};

    var store = try Store.readAll(std.testing.allocator, &reader, 2, 0, .{}, buffers);
    defer store.deinit();

    var symbol_reader = bit_reader.BitReader.init(&.{});
    try std.testing.expectEqual(
        @as(u16, 0),
        try (try store.group(0)).green.decode(&symbol_reader),
    );
    try std.testing.expectEqual(
        @as(u16, 1),
        try (try store.group(1)).green.decode(&symbol_reader),
    );
    try std.testing.expectError(error.InvalidVP8LImageData, store.group(2));
}

test "VP8L prefix group store selects groups through meta-prefix blocks" {
    var encoded: [32]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writeConstantPrefixCodeGroup(&writer, 0);
    try writeConstantPrefixCodeGroup(&writer, 1);

    var reader = bit_reader.BitReader.init(try writer.finish());
    const buffers = try std.testing.allocator.create(WorkBuffers);
    defer std.testing.allocator.destroy(buffers);
    buffers.* = .{};

    var store = try Store.readAll(std.testing.allocator, &reader, 2, 0, .{}, buffers);
    defer store.deinit();

    const info = meta_prefix.Info{
        .prefix_bits = 2,
        .block_size = 4,
        .image_dimensions = try image.Dimensions.init(8, 1),
        .entropy_dimensions = try image.Dimensions.init(2, 1),
        .group_count = 2,
    };
    const entropy_image = [_]pixel.Pixel{
        pixel.fromChannels(0, 0, 0, 0),
        pixel.fromChannels(0, 0, 1, 0),
    };

    var symbol_reader = bit_reader.BitReader.init(&.{});
    try std.testing.expectEqual(
        @as(u16, 0),
        try (try store.groupForPixel(info, &entropy_image, 0, 0)).green.decode(&symbol_reader),
    );
    try std.testing.expectEqual(
        @as(u16, 1),
        try (try store.groupForPixel(info, &entropy_image, 4, 0)).green.decode(&symbol_reader),
    );
}

test "VP8L prefix group store enforces group and allocation limits" {
    var encoded: [16]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writeConstantPrefixCodeGroup(&writer, 0);

    const buffers = try std.testing.allocator.create(WorkBuffers);
    defer std.testing.allocator.destroy(buffers);

    var zero_reader = bit_reader.BitReader.init(try writer.finish());
    buffers.* = .{};
    try std.testing.expectError(
        error.InvalidVP8LImageData,
        Store.readAll(std.testing.allocator, &zero_reader, 0, 0, .{}, buffers),
    );

    var limited_reader = bit_reader.BitReader.init(try writer.finish());
    buffers.* = .{};
    try std.testing.expectError(
        error.AllocationLimitExceeded,
        Store.readAll(std.testing.allocator, &limited_reader, 1, 0, .{
            .allocation_bytes_max = 1,
        }, buffers),
    );
}

test "VP8L prefix group store cleans up partial group copies on limit failure" {
    var encoded: [16]u8 = undefined;
    var writer = bit_writer.BitWriter.init(&encoded);
    try writeConstantPrefixCodeGroup(&writer, 0);

    const one_table_bytes = @sizeOf(huffman.Entry) * huffman.SymbolTable.root_entry_count_max;
    const partial_limit = @sizeOf(image_data.PrefixCodeGroup) + one_table_bytes;

    const buffers = try std.testing.allocator.create(WorkBuffers);
    defer std.testing.allocator.destroy(buffers);
    buffers.* = .{};

    var reader = bit_reader.BitReader.init(try writer.finish());
    try std.testing.expectError(
        error.AllocationLimitExceeded,
        Store.readAll(std.testing.allocator, &reader, 1, 0, .{
            .allocation_bytes_max = partial_limit,
        }, buffers),
    );
}
