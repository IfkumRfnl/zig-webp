# Performance audition summary

Campaign completed 2026-08-19 against `origin/main` at `a2b7f81`, Zig 0.16.0,
and libwebp 1.5.0. Nineteen isolated worktrees each tested one idea under the
protocol in [`PROTOCOL.md`](PROTOCOL.md). No candidate source was merged or
committed. Three independently verified changes are now applied together in
the main worktree as an integration candidate.

## Outcome

| Verdict | Count | Experiments |
|---|---:|---|
| `integration-ready` | 3 | A02, A07, A17 |
| `already-on-master` | 7 | A01, A05, A08, A10, A15, A16, A18 |
| `hold` | 1 | A19 |
| `not-worthy` | 8 | A03, A04, A06, A09, A11, A12, A13, A14 |

## Integration-ready candidates

| Priority | ID | Isolated change | Final evidence | Risk / recommendation |
|---:|---|---|---|---|
| 1 | A17 | One threshold line in `vp8l/inverse_transform.zig` | 65.50% faster Zig; **0.386885× C**; +0.42% control; byte-exact; 517/517 | Best first candidate: tiny diff, largest decode win, low integration risk. |
| 2 | A02 | 56-line constant VP8L emitter in `vp8l/encoder.zig` | 18.82% faster Zig; **0.467937× C**; 2 bytes smaller per target; controls unchanged; 517/517 | Strong encoder candidate; audit single-symbol stream invariants, then promote independently. |
| 3 | A07 | 66-line small binary-alpha branch in `alpha.zig` | 2.34× faster Zig; **0.451476× C**; 0.972× C bytes; bitstream unchanged; +3.63% control; 518/518 | Good narrow win; discuss whether the 4096-pixel policy cutoff belongs in production. |

Worktrees:

- A02: `/home/hayk/.grok/worktrees/hayk-zig-webp/subagent-01a01971-2537-73e1-a1aa-6426e8a2d4c9`
- A07: `/home/hayk/.grok/worktrees/hayk-zig-webp/subagent-01a01971-2556-7351-8e1e-b64cfdd00b82`
- A17: `/home/hayk/.grok/worktrees/hayk-zig-webp/subagent-01a01980-e46d-73a2-a74d-6c57c9d3455f`

The three changes have been applied together and freshly remeasured. See
[`INTEGRATION.md`](INTEGRATION.md) for the combined-tree numbers and held
changes.

## Existing narrow wins confirmed

- A01: tiny packed-BGRA lossless encode **0.380× C** aggregate.
- A05: tiny VP8L caller-output decode **0.438× C** aggregate.
- A08: tiny low-color lossless encode **0.565× C**; mux itself is <0.25%.
- A10: repeated-row UI **0.411–0.494× C**, with smaller files.
- A15: first frame of tiny lossless animations **0.424× C**.
- A16: broad full demux scan **0.990× C**; narrow margin, no source change.
- A18: solid/trivial-Huffman VP8L fill **0.165668× C** aggregate.

These require no campaign source change. Claims must remain scoped to the
measured class; none implies general codec superiority.

## Rejected experiments worth remembering

- A06's uniform-block reuse improved Zig 30.55% but still ended at 1.247× C.
- A12's 128 KiB stack-first tiny decode saved only 2.27% and ended at 0.679× C.
- A13's opaque-alpha cleanup saved 3.2–7.0% but its RGB class remained 1.198× C geomean.
- A14 established that `mb_skip_coeff` does not make loop-filter omission safe.
- A04 feature probing is a Zig weakness today (about 6.7–7.0× C), not a C-weak niche.
- A09 large grayscale lossless encode is also a Zig weakness (9.32× C aggregate).

## Held after combined recheck

- A19's allocation-free static demux cursor ended below C in isolation, but
  unmodified Zig already beat C and the roughly 180-line refactor did not
  reproduce an incremental win in a fresh back-to-back combined-tree run.
  Its preserved worktree is
  `/home/hayk/.grok/worktrees/hayk-zig-webp/subagent-01a01980-e480-7f71-89db-580e327975e6`.

Full numbers, controls, and correctness gates are in the individual
`Axx-*.md` reports in this directory.
