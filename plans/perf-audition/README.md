# Performance audition: libwebp C weak cases

Campaign started 2026-08-19 against `origin/main` (`a2b7f81`).
This folder is the main-session record. Isolated worktrees implement **one
idea each**; this session verifies numbers and writes the verdict.

The goal is **not** blanket superiority over `libwebp`. It is to find asset
classes and API shapes where the C implementation pays avoidable tax, then
make zig-webp faster on those cases while staying pixel-exact (lossless) and
modular. The maintainer's target threshold is final Zig time below matched C
time; the size, correctness, control, and engineering-risk gates still apply.

## Rules

- One idea per worktree. No stacking. No merge from the worktree.
- Zero-dependency policy: benches may call installed `libwebp` / `dwebp` as
  a local oracle. Generated C adapters stay under `.zig-cache/`.
- Fair timing: in-memory, identical pixels, `ReleaseFast`, single thread,
  warmups + median. Encode: `exact=1`, `thread_level=0` (same protocol as
  `tools/webp-fast-lossless-bench.sh`). Decode: caller-owned output buffer
  vs `WebPDecode*` into a reused buffer; `dwebp -v` `decode_int_ms` is
  secondary only.
- Lossless output must round-trip bit-exactly through this decoder and
  `dwebp`. Lossy must stay valid and self-consistent.
- Main session copies a verdict here after independent verification.
  Worktree `EXPERIMENT.md` is evidence, not the record of record.

## Verdict labels

| Label | Meaning |
|---|---|
| `worthy` | Independent numbers show a large win on a real C-weak class, no serious regression, small modular change. Candidate to discuss for `main`. |
| `already-on-master` | Current `main` already beats C on this class. Claim-worthy at the measured scope; no extra code. |
| `not-worthy` | Missed the bar, C was not actually weak, regressions, or the idea is too invasive. |
| `hold` | Beats C, but a production change is not justified or did not reproduce an incremental combined-tree win. |
| `in-flight` | Worktree still running or unverified. |

## Bar for `worthy`

All of:

1. Target-class Zig/C time ratio **< 1.00** (prefer a wide margin).
2. Lossless size vs libwebp preset-0 aggregate **≤ 1.15×** (or smaller).
3. Correctness gates above hold.
4. Control class (existing UI corpus or photos) not **> 1.05×** slower than
   baseline Zig on the same machine.
5. The diff is one idea, keeps modules separate, and does not add
   dependencies.

A numerically faster result can still be `not-worthy` or `hold` when current
main already wins and the patch's incremental gain does not justify its cost.

## Experiments

| ID | Idea | C weakness targeted | Verdict |
|---|---|---|---|
| A01 | Zero-copy encode from packed native pixels | `WebPPictureImport*` always copies into ARGB | already-on-master |
| A02 | Solid-color VP8L emit without palette/index machinery | One-color images still run VP8L analysis | worthy |
| A03 | Two-color horizontal RLE on the index image | Hash-chain LZ77 for 2-color UI | not-worthy |
| A04 | Feature probe vs `WebPGetInfo`/`WebPGetFeatures` | C feature probe walks more container than needed | not-worthy |
| A05 | Tiny VP8L decode setup | Huffman/CPU-dispatch tax on tiny lossless stills | already-on-master |
| A06 | Uniform-block lossy method-0 skip | Method 0 still FDCT/quant every macroblock | not-worthy |
| A07 | Binary (0/255) alpha `ALPH` fast path | Alpha always goes through full VP8L | worthy |
| A08 | Direct simple `VP8L` RIFF write | Generic muxer/picture object overhead | already-on-master |
| A09 | Grayscale skip color-transform search | Color analysis on R=G=B images | not-worthy |
| A10 | Identical-row copy tokens | Row-repeat UI still matched pixel-by-pixel | already-on-master |
| A11 | Small-palette direct Huffman | Histogram/trial emission for tiny alphabets | not-worthy |
| A12 | Batch tiny decode-into | Per-call alloc/setup vs reused caller buffer | not-worthy |
| A13 | RGB lossy skip alpha work | Opaque RGB still pays alpha-adjacent setup | not-worthy |
| A14 | All-skip lossy frames skip loop filter | Filter runs even when every MB skipped | not-worthy |
| A15 | Animation first-frame-only decode | Full anim decoder setup to read frame 0 | already-on-master |
| A16 | Demux/chunk scan vs `WebPDemux` | Heavy mux object to list chunks | already-on-master (narrow) |
| A17 | Paletted UI color-index inverse | C stages 16 BGRA rows + per-pixel map; Zig grouped lookup only ≥100k px | worthy |
| A18 | Solid-color VP8L decode fill | Trivial Huffman still runs LZ77 + 16-row cache | already-on-master |
| A19 | Still decode without full demux list | Zig `decodeStatic*` materializes chunk `ArrayList`s; C still path does not | hold after combined recheck |

## After the wave

Main session verifies each worktree, writes `Axx-<slug>.md` here, then a
`SUMMARY.md` listing every `worthy` / `already-on-master` candidate for a
merge discussion. Nothing lands on `main` from this campaign until that
discussion.

All 19 experiments are complete. See [`SUMMARY.md`](SUMMARY.md) and the
combined-tree [`INTEGRATION.md`](INTEGRATION.md). Three candidate source
changes are prepared in the main worktree; nothing has been committed or
pushed.
