# libwebp C weaknesses (parent-session notes)

Inspected 2026-08-19 against `references/libwebp` 1.5.0 while wave-1
experiments run. This is a structural reading, not a timing claim.
Research agents may refine it.

## Encoder

### Always-copy import

`WebPEncodeRGBA` / `WebPEncodeBGRA` / lossless variants go through
`WebPPictureImport*` (`picture_enc.c`, `picture_csp_enc.c`). The picture
object owns a separate ARGB buffer. There is no public "encode these
packed pixels in place" path.

Targeted by **A01**.

### Palette scan + generic lossless even at preset 0

`EncoderAnalyze` (`vp8l_enc.c`) always calls `GetColorPalette`. At
`method == 0` it skips `AnalyzeEntropy` (comment: "somewhat slow") and
forces `kPalette` or `kSpatialSubGreen`, but still allocates the picture,
builds histograms, and runs generic backward references.

Constant / 2-color / small-palette / repeated-row images still pay that
generic tax. Targeted by **A02, A03, A10, A11**.

### Alpha plane is a full VP8L encode

`alpha_enc.c` allocates a `WebPPicture`, copies alpha into the green
channel (`WebPDispatchAlphaToGreen`), forces `exact=1`, and calls
`VP8LEncodeStream`. Binary 0/255 alpha still goes through that machinery.
Targeted by **A07**.

### Lossy method 0 still transforms every macroblock

Method 0 shrinks mode search but still runs the per-MB forward
transform/quant path (`quant_enc.c`, `frame_enc.c`). Uniform UI blocks
do not get a "constant MB, skip FDCT" specialist. Targeted by **A06,
A14**.

### RGB import still becomes ARGB

`WebPEncodeRGB` imports through the picture path (`picture_enc.c`).
Targeted by **A13**.

### Mux / picture object for the simplest file

Even a one-color lossless file constructs a picture, encoder state, and
container writer. Targeted by **A08**.

### Color-transform analysis on gray

Non-`low_effort` paths run `AnalyzeEntropy` across subtract-green / color
/ spatial combinations. Grayscale palette-miss images still pay color
analysis at higher methods; at method 0 they take `kSpatialSubGreen`
without checking that subtract-green is a no-op. Targeted by **A09**.

## Decoder / container

### Feature probe is full header parse

`WebPGetInfo` calls `GetFeatures` (`webp_dec.c`), which is
`ParseHeadersInternal` (RIFF + VP8X + optional extra chunks). ABI
version check + feature struct zeroing on every call. Targeted by
**A04**.

### Per-call decoder object

`WebPDecode` / `WebPDecodeRGBAInto` init decoder state, output buffers,
and CPU/DSP dispatch (`vp8_dec.c` `VP8GetCPUInfo`, `vp8l_dec.c` Huffman
setup) even for 1x1 and tiny icons. Targeted by **A05, A12**.

### Animation decoder is a mux object

`WebPAnimDecoderNew` builds a demuxer and full animation state to
produce frame 0. Targeted by **A15**.

### Demuxer heap object

`WebPDemuxInternal` allocates a demuxer and chunk list to walk a RIFF.
Targeted by **A16**.

## Not treated as C-weak here

- Fancy YUV upsampling (we match `dwebp` byte-exactly; skipping it is a
  quality/API change).
- Photo lossless at preset 0 (`kSpatialSubGreen` + hash-chain): C is
  **strong**. Our palette-miss class is 16× slower; that is our weakness,
  not a campaign target.
- `exact=0` (C may smash RGB of transparent pixels): faster, but not
  lossless-exact. We do not "beat" C by dropping exactness.

## Already-on-master candidates (to confirm with numbers)

Default low-color VP8L encode vs preset 0 is already **0.729×** time and
**0.803×** bytes on the pinned primary UI corpus (`PROGRESS.MD`
2026-07-29). That is a real C-weak win already on `main`, below the
campaign's "much better" prefer-0.50 bar but above the 0.67 floor.
Wave-1 asks whether we can push selected subclasses further.

## Decode-research addenda (agent `01a01971-2536-7e43-9be7-52cafac9c625`)

High-confidence extras not fully covered by A01–A16:

- Paletted UI inverse transform: C `ColorIndexInverseTransform_C` + 16-row
  `argb_cache`; Zig grouped lookup is gated at 100k pixels (**A17**).
- Solid/trivial Huffman still runs `DecodeImageData` + row emit (**A18**).
- Zig still decode pays a full `demux.parse` `ArrayList`; C still path is a
  header cursor (**A19**).
- `WebPGetInfo` zeros a full features struct and, on VP8X stills, still
  walks optional chunks then re-parses VP8/VP8L (A04).
- VP8L Huffman arena is worst-case sized even for one-symbol trees (A05).
