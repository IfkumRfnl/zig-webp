# Releasing

This document makes the `PLAN.MD` release criteria (step 12) operational: each
gate is mapped to a concrete check, with an honest note on whether it runs in
CI or only as a local oracle. It also records the release procedure.

## Release gates

`PLAN.MD` defines two release bars:

- **`0.1.0`** — release only after the **step 5 decode gate** and the **step 7
  validity and size gates** hold.
- **`1.0.0`** — release only after the **8b and 8c** lossy-encode gates,
  animation encode, metadata, hardening (step 11), docs, and the
  [compatibility matrix](#compatibility-matrix-10-gate) below are all met.

### Gate → check mapping

| Gate | Concrete check | Where it runs | Pass condition |
|---|---|---|---|
| `zig fmt` | `zig fmt --check .` | CI (`ci.yml`) | exit 0 |
| Build | `zig build check` (library + 4 CLI tools) | CI (`ci.yml`) | exit 0 |
| **Step 5 — static decode** | `zig build test` (includes the SHA-256 corpus regression over `testdata/`) | **CI** (`ci.yml`) | exit 0; planes/frames match committed hashes |
| **Step 7 — lossless validity** | synthetic round-trips in `zig build test`, plus corpus-wide `zig build encode-report` | unit half in **CI**; corpus half **local** | `0 round-trip mismatches` |
| **Step 7 — lossless size** | `zig build encode-report -- --with-corpus R.tsv` then `tools/webp-oracle.sh compare-encode-corpus R.tsv` | **local oracle** (needs `cwebp`) | median ratio ≤ 1.10× |
| Step 8b — lossy PSNR | `zig build encode-lossy-report` + matched-size PSNR vs `cwebp -q 75 -m 4` | local oracle (needs `cwebp`) | mean luma PSNR within 1.0 dB |
| Step 8c — target-size | target-size mode oracle run | local oracle | within 5% of requested size |
| Animation — `anim_dump` parity | `tools/webp-oracle.sh compare-anim` | local oracle (needs `anim_dump`) | byte-for-byte (lossless) |

**Honesty note.** Only the format, build, and step-5 decode gates run in CI
today (CI deliberately avoids requiring `dwebp`/`cwebp` — it uses committed
hashes instead). The encoder size/PSNR/target-size gates are **local oracle
measurements** that require `libwebp`'s `cwebp`/`dwebp`/`anim_dump` on `PATH`;
their latest results are recorded with dates in `PROGRESS.MD`. Re-run them
locally before tagging.

### 1.0.0 gate status

Verified at the `1.0.0` release commit (2026-07-08):

- `zig build ci` — exit 0 (`zig fmt --check .`, `zig build check`,
  `zig build test`; 464/464 tests, corpus regression / step-5 decode gate).
- `zig build encode-report` — 77 sources, **0 round-trip mismatches** (step-7
  validity).
- `compare-encode-corpus` — **median ratio 1.0368×**, aggregate 1.0460×
  (step-7 size gate, ≤ 1.10×; unchanged from `0.2.0`).
- Step 8b — matched-size photo-corpus mean luma PSNR within 1.0 dB of
  `cwebp -q 75 -m 4` (recorded **+0.08 dB**, 2026-06-21; method-4 output
  asserted byte-identical since).
- Step 8c — target-size mode **0.32–2.83%** off requested size (≤ 5% gate);
  target-PSNR 38.01–38.08 dB achieved (reproduced in `zig build ci` metrics).
- `compare-anim-corpus` — 10/10 committed animations byte-exact against
  `anim_dump`.
- Compatibility matrix — Linux x86_64, macOS aarch64, and big-endian
  powerpc64 CI jobs green; browser check passed 2026-07-08 (Firefox +
  Chromium); Windows deferred with reason below.

### 0.2.0 gate status

Verified at the `0.2.0` release commit (2026-07-07):

- `zig build ci` — exit 0 (`zig fmt --check .`, `zig build check`,
  `zig build test`; 452/452 tests, corpus regression / step-5 decode gate).
- `zig build encode-report` — 77 sources, **0 round-trip mismatches** (step-7
  validity).
- `compare-encode-corpus` — **median ratio 1.0368×**, aggregate 1.0460×
  (step-7 size gate, ≤ 1.10×; unchanged from `0.1.0`).
- `compare-anim-corpus` — 10/10 committed animations byte-exact against
  `anim_dump` (animation parity, re-run because decode hot paths changed in
  step 10).

### 0.1.0 gate status

Verified at the `0.1.0` commit:

- `zig fmt --check .` — clean.
- `zig build check` — exit 0.
- `zig build test` — exit 0 (corpus regression / step-5 decode gate).
- `zig build encode-report` — 34 sources, **0 round-trip mismatches** (step-7
  validity).
- `compare-encode-corpus` — **median ratio 1.0368×**, aggregate 1.0460×
  (step-7 size gate, ≤ 1.10×).

## Compatibility matrix (1.0 gate)

`PLAN.MD`'s 1.0.0 bar requires "compatibility testing"; this matrix defines
that phrase. All rows must hold before tagging 1.0.0.

| Dimension | Check | Where | Pass |
|---|---|---|---|
| Linux x86_64 (LE, 64-bit) | `zig build ci` | CI (`ci.yml` `test` job), every PR | exit 0 |
| macOS aarch64 (LE, 64-bit) | `zig build check` + `zig build test` | CI (`ci.yml` `macos` job), every PR | exit 0 |
| Big-endian (powerpc64) | `zig build test -Dtest-shards=4 -Dtarget=powerpc64-linux -Doptimize=ReleaseSafe -fqemu` | CI (`ci.yml` `big-endian` job), every PR | exit 0 |
| Browsers (≥2) | manual render of the two `testdata/animation/anim_minimized_*.webp` samples | manual, recorded in `PROGRESS.MD` before tagging 1.0 | moving region animates correctly in both |
| Windows | deferred | — | recorded as deferred with reason (the `setup-zig` composite action resolves `uname -m`/`uname -s` keys against tar.xz archives; `x86_64-windows` ships as `.zip` and Git-bash `uname -s` reports `MINGW64_NT-...`) |

The big-endian row is the substantive one: it runs the full test suite —
including the byte-exact SHA-256 corpus regression — on a BE host under
user-mode QEMU, so decoded planes must be identical regardless of host
endianness. The run is ReleaseSafe (runtime safety checks and assertions
stay enabled; decoded bytes and the SHA-256 corpus comparison are
optimize-mode-independent) and sharded 4-way for speed; Debug coverage
remains on the native jobs.

### Browser check procedure

Manual pre-tag gate (not CI). In each of at least two browsers (e.g. Firefox
and Chromium):

1. Open `testdata/animation/anim_minimized_lossless.webp`.
2. Open `testdata/animation/anim_minimized_lossy.webp`.
3. Pass condition: each file displays as an animation whose moving region
   animates correctly (no stuck first frame, no corrupted or misplaced
   rectangles, no wrong background bleed-through).

Record the browsers, versions, date, and result in `PROGRESS.MD`. Re-run
whenever animation encode output changes.

## Release procedure

1. Confirm the gate table above holds at the release commit. Run the local
   oracle checks (`cwebp`/`dwebp` must be installed) and the CI checks.
2. Bump `version` in `build.zig.zon`.
3. Add a dated `CHANGELOG.MD` entry describing the release scope.
4. Update the `README.MD` status / version note if needed.
5. Open a `claude/release-X.Y.Z` PR; let CI pass; merge to `main`.
6. After merge, tag the merge commit and push the tag:

   ```sh
   git checkout main && git pull
   git tag -a vX.Y.Z -m "zig-webp vX.Y.Z"
   git push origin vX.Y.Z
   ```

7. Create the GitHub release from the tag, using the `CHANGELOG.MD` entry as the
   body (`gh release create vX.Y.Z --notes-from-tag` or paste the changelog).
