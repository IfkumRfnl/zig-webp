# Releasing

This document makes the `PLAN.MD` release criteria (step 12) operational: each
gate is mapped to a concrete check, with an honest note on whether it runs in
CI or only as a local oracle. It also records the release procedure.

## Release gates

`PLAN.MD` defines two release bars:

- **`0.1.0`** — release only after the **step 5 decode gate** and the **step 7
  validity and size gates** hold.
- **`1.0.0`** — release only after the **8b and 8c** lossy-encode gates,
  animation encode, metadata, hardening (step 11), docs, and compatibility
  testing are all met.

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
