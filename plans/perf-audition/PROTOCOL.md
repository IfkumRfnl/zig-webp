# Isolated experiment protocol

Follow this exactly. You own **one** idea in **this** worktree.

## Hard constraints

- Zig 0.16.0. Run `zig version` once.
- Zero package dependencies. Do not add C, system libraries, or vendored
  codecs to `build.zig` / `build.zig.zon`.
- `references/libwebp`, system `libwebp` headers, `dwebp`, `cwebp`, and a
  generated adapter under `.zig-cache/` are allowed for **local** benches
  only.
- Do not copy libwebp source. Reimplement from specs.
- Do not update `PLAN.MD`, `PROGRESS.MD`, `README.MD`, or
  `plans/perf-audition/README.md`. Main session owns the campaign record.
- Do not commit unless useful for your own worktree history. Do not push.
- Keep public API in `src/root.zig`. Keep modules separate.
- Scalar correctness first. SIMD only if the one idea *is* SIMD.

## Protocol

1. **Confirm the C weakness.** Measure current `main` (this worktree, no
   edits yet) against libwebp C on the target class. If Zig/C is already
   **≤ 0.50×**, stop implementing: write the report as `already-on-master`.
   If Zig/C is **≥ 0.90×** and there is no cheap structural reason C should
   lose, stop: C is not weak here; report `not-worthy` with the baseline.
2. **Implement only the named idea.** No drive-by refactors, no second
   optimization, no docs-of-record updates.
3. **Re-measure** with the same protocol as step 1, plus a **control class**
   that must not regress >5% vs baseline Zig.
4. **Correctness.** At minimum: `zig fmt .`, `zig build test` (or a
   documented focused subset plus `zig build test` if time allows). Lossless
   must round-trip pixel-exactly through this decoder and `dwebp`. Lossy
   must remain valid (`dwebp` decodes) and keep encoder/decoder
   self-consistency tests green.
5. **Write `EXPERIMENT.md` at the worktree root** with the sections below.

## Timing protocol

- `ReleaseFast`, single thread, this machine.
- Warmups ≥ 3, timed samples ≥ 15, report the median. Tiny inputs may be
  batched like `tools/webp-fast-lossless-bench.sh` (batch up to 262144
  pixels, max 256 encodes/decodes).
- Encode: identical prepared RGBA (or the format the idea cares about).
  libwebp: `WebPConfigLosslessPreset(..., 0)` or the matching lossy
  config; `exact=1`; `thread_level=0`. Include gather/import, encode,
  output alloc, cleanup. Exclude source I/O.
- Decode: caller-owned output (`decodeStaticInto`) vs C decode into a
  reused buffer. Do **not** compare against `dwebp` wall clock as the
  primary number (`dwebp -v` internal time is secondary).
- Record absolute times and the Zig/C ratio. Lower ratio is faster Zig.

Reuse `tools/webp-fast-lossless-bench.sh` when the class fits. Otherwise
write a throwaway adapter under `.zig-cache/` modeled on that script.

## `EXPERIMENT.md` template

```markdown
# Axx title

- worktree:
- HEAD:
- idea: (one sentence)
- C weakness: (one sentence)
- verdict recommendation: worthy | already-on-master | not-worthy

## Baseline (unmodified)

protocol, machine, times, sizes, Zig/C ratio

## Change

files and the single idea. empty if no code change.

## After

same protocol, times, sizes, Zig/C ratio

## Control class

which class, baseline vs after Zig time

## Correctness

commands and results

## Why this verdict
```
