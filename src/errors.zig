//! Shared error taxonomy for public API boundaries.

pub const Category = enum {
    container,
    resource_limit,
    unsupported,
    bitstream,
    allocation,
};

pub const Error = error{
    AllocationLimitExceeded,
    CanvasTooLarge,
    ChunkTooLarge,
    CorpusUnavailable,
    DimensionsOverflow,
    DuplicateChunk,
    DuplicateImageData,
    DuplicateMetadata,
    FileTooLarge,
    FrameCountTooLarge,
    InputTooLarge,
    InputTooSmall,
    InvalidAlphaChunk,
    InvalidAnimationChunk,
    InvalidCanvasSize,
    InvalidChunkOrder,
    InvalidChunkPadding,
    InvalidCorpusPath,
    InvalidExtendedHeaderReservedBits,
    InvalidExtendedHeaderSize,
    InvalidFeatureFlags,
    InvalidFrameChunk,
    InvalidBitCount,
    InvalidHuffmanCode,
    InvalidHuffmanTree,
    InvalidMuxChunk,
    InvalidRiffSignature,
    InvalidRiffSize,
    InvalidSimpleChunk,
    InvalidVP8Header,
    InvalidVP8LHeader,
    InvalidVP8LTransform,
    InvalidWebPSignature,
    MissingAnimationControl,
    MissingExtendedHeader,
    MissingImageData,
    MissingRequiredChunk,
    OutputTooLarge,
    TooManyChunks,
    TrailingData,
    TruncatedBitstream,
    TruncatedChunkHeader,
    TruncatedChunkPayload,
    UnsupportedAnimationMux,
    OutOfMemory,
};

pub fn category(err: Error) Category {
    return switch (err) {
        error.AllocationLimitExceeded,
        error.OutOfMemory,
        => .allocation,

        error.CanvasTooLarge,
        error.ChunkTooLarge,
        error.DimensionsOverflow,
        error.FileTooLarge,
        error.FrameCountTooLarge,
        error.InputTooLarge,
        error.InvalidCanvasSize,
        error.OutputTooLarge,
        error.TooManyChunks,
        => .resource_limit,

        error.InvalidBitCount,
        error.InvalidHuffmanCode,
        error.InvalidHuffmanTree,
        error.InvalidVP8Header,
        error.InvalidVP8LHeader,
        error.InvalidVP8LTransform,
        error.TruncatedBitstream,
        => .bitstream,

        error.UnsupportedAnimationMux,
        => .unsupported,

        error.CorpusUnavailable,
        error.DuplicateChunk,
        error.DuplicateImageData,
        error.DuplicateMetadata,
        error.InputTooSmall,
        error.InvalidAlphaChunk,
        error.InvalidAnimationChunk,
        error.InvalidChunkOrder,
        error.InvalidChunkPadding,
        error.InvalidCorpusPath,
        error.InvalidExtendedHeaderReservedBits,
        error.InvalidExtendedHeaderSize,
        error.InvalidFeatureFlags,
        error.InvalidFrameChunk,
        error.InvalidMuxChunk,
        error.InvalidRiffSignature,
        error.InvalidRiffSize,
        error.InvalidSimpleChunk,
        error.InvalidWebPSignature,
        error.MissingAnimationControl,
        error.MissingExtendedHeader,
        error.MissingImageData,
        error.MissingRequiredChunk,
        error.TrailingData,
        error.TruncatedChunkHeader,
        error.TruncatedChunkPayload,
        => .container,
    };
}

test "classifies representative errors" {
    const std = @import("std");

    try std.testing.expectEqual(Category.container, category(error.InvalidRiffSize));
    try std.testing.expectEqual(Category.resource_limit, category(error.InputTooLarge));
    try std.testing.expectEqual(Category.bitstream, category(error.InvalidVP8Header));
    try std.testing.expectEqual(Category.bitstream, category(error.InvalidHuffmanTree));
    try std.testing.expectEqual(Category.bitstream, category(error.InvalidVP8LTransform));
    try std.testing.expectEqual(Category.bitstream, category(error.TruncatedBitstream));
    try std.testing.expectEqual(Category.unsupported, category(error.UnsupportedAnimationMux));
    try std.testing.expectEqual(Category.allocation, category(error.OutOfMemory));
}
