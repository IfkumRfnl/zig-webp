//! Public decoder and encoder option types.

const features = @import("features.zig");
const image = @import("image.zig");
const limits = @import("limits.zig");
const metadata = @import("metadata.zig");

pub const DecoderOptions = struct {
    limits: limits.ResourceLimits = .{},
    output_format: image.PixelFormat = .rgba,
    /// Reserved for a future metadata-bearing decode result; metadata chunks
    /// are currently always exposed via demux results (`parseWebP`), so this
    /// flag has no effect on `decodeStatic` today.
    preserve_metadata: bool = true,
    /// Reserved: `decodeStatic` always rejects animated inputs with
    /// `error.UnsupportedAnimationDecode`, so this flag has no effect today;
    /// decode animations via `decodeAnimation` / `AnimationDecoder` instead.
    decode_animation: bool = true,
};

/// Options bag for the still pixel encoders (`encodeLossless`/`encodeLossy`).
/// The lower-level mux (`mux.encodeStatic`) takes its own `mux.Options`.
pub const EncoderOptions = struct {
    limits: limits.ResourceLimits = .{},
    format: features.FormatKind = .lossless,
    quality: u8 = 75,
    /// Reserved; has no effect today. Metadata attachment on encode is
    /// controlled by `metadata` below — this flag is read by nothing.
    preserve_metadata: bool = true,
    /// Effort level (0..6, `cwebp -m` compatible): higher trades encode time
    /// for quality by widening the rate-distortion search (step 8c-1). The
    /// lossy default 4 matches the step-8b gate's `cwebp -q 75 -m 4`; methods
    /// 5–6 currently clamp to 4 (no extra search above the 8b baseline yet).
    method: u8 = 4,
    /// Target output size in bytes. When set, the encoder runs a bounded
    /// quantizer-index search (up to 8 passes, step 8c-3) and returns the probe
    /// whose byte size is closest to `target_size`. No error is raised if the
    /// target is unattainable or unbracketed by the quantizer grid, so callers
    /// should treat the result as the nearest candidate, not a guaranteed hit.
    /// Mutually exclusive with `target_psnr`; both set ⇒
    /// `error.InvalidEncodeOptions`. Unset → `quality` picks the quantizer in a
    /// single pass.
    target_size: ?u32 = null,
    /// Target reconstructed luma PSNR in dB. When set, the encoder runs a
    /// bounded quantizer-index search (step 8c-3) for the coarsest quantizer
    /// whose BT.601 luma PSNR still meets the request; if no quantizer in the
    /// search grid meets the target, the finest (highest-PSNR) probe reached is
    /// returned, so callers should verify the achieved PSNR rather than assume
    /// the request was met. Mutually exclusive with `target_size`; both set ⇒
    /// `error.InvalidEncodeOptions`.
    target_psnr: ?f32 = null,
    /// Alpha-plane compression effort (0..100) for lossy+alpha (`ALPH`) output
    /// (step 8c-2). 0 emits an uncompressed `ALPH` chunk; 1..100 also tries the
    /// lossless VP8L form and keeps whichever is smaller. Alpha is always
    /// lossless — this knob trades encode work for size, never fidelity.
    alpha_quality: u8 = 100,
    /// Use sharp (iterative) RGB→YUV chroma downsampling instead of the box
    /// average (step 8c-4). The default (false) box-average path is
    /// byte-identical to the pre-8c-4 encoder.
    use_sharp_yuv: bool = false,
    /// Raw metadata payloads (ICCP color profile, EXIF, XMP) to attach to a
    /// still encode (step 9d). Each present payload is written verbatim into its
    /// canonical chunk by the still encoders (`encodeLossless`/`encodeLossy`),
    /// forcing the extended (`VP8X`) container, and round-trips byte-exactly
    /// through `demux`. Default `.{}` (all null) leaves the output identical to
    /// the no-metadata path. The encoders do not parse or validate the payloads;
    /// the caller owns them and they must outlive the encode call.
    metadata: metadata.RawPayloads = .{},
};
