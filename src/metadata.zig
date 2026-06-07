//! Raw metadata payload references exposed by demuxing APIs.

const container = @import("container.zig");

pub const Kind = enum {
    color_profile,
    exif,
    xmp,
};

pub const Presence = struct {
    color_profile: bool = false,
    exif: bool = false,
    xmp: bool = false,

    pub fn any(self: Presence) bool {
        return self.color_profile or self.exif or self.xmp;
    }
};

pub const RawPayloads = struct {
    color_profile: ?[]const u8 = null,
    exif: ?[]const u8 = null,
    xmp: ?[]const u8 = null,

    pub fn presence(self: RawPayloads) Presence {
        return .{
            .color_profile = self.color_profile != null,
            .exif = self.exif != null,
            .xmp = self.xmp != null,
        };
    }
};

pub const RawLocations = struct {
    color_profile: ?container.ChunkLocation = null,
    exif: ?container.ChunkLocation = null,
    xmp: ?container.ChunkLocation = null,

    pub fn presence(self: RawLocations) Presence {
        return .{
            .color_profile = self.color_profile != null,
            .exif = self.exif != null,
            .xmp = self.xmp != null,
        };
    }

    pub fn payloads(self: RawLocations, bytes: []const u8) RawPayloads {
        return .{
            .color_profile = if (self.color_profile) |chunk| chunk.payload(bytes) else null,
            .exif = if (self.exif) |chunk| chunk.payload(bytes) else null,
            .xmp = if (self.xmp) |chunk| chunk.payload(bytes) else null,
        };
    }
};
