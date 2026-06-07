//! Feature summary for a WebP file without full pixel decode.

const container = @import("container.zig");
const image = @import("image.zig");
const metadata = @import("metadata.zig");

pub const FileKind = enum {
    simple,
    extended,
};

pub const FormatKind = enum {
    lossy,
    lossless,

    pub fn chunkKind(self: FormatKind) container.ChunkKind {
        return switch (self) {
            .lossy => .lossy_bitstream,
            .lossless => .lossless_bitstream,
        };
    }
};

pub const Summary = struct {
    file_kind: FileKind,
    format: ?FormatKind,
    canvas: image.Dimensions,
    has_alpha: bool,
    is_animation: bool,
    metadata: metadata.Presence,
    chunk_count: u32,
    extended_header: ?container.ChunkLocation = null,
    image_data: ?container.ChunkLocation = null,
    alpha: ?container.ChunkLocation = null,
    animation_control: ?container.ChunkLocation = null,
    first_animation_frame: ?container.ChunkLocation = null,
};
