# A19 — Still decode without full demux lists

**Isolated verdict: `worthy`, narrowly. Integration verdict: `hold`.** Independently
recovered and verified from worktree `01a01980-e480-7f71-89db-580e327975e6`
at `a2b7f81`, Zig 0.16.0, ReleaseFast, caller-owned RGBA, 3 warmups + 15
medians.

The isolated change makes result-list storage optional in the existing strict
demux state machine and routes `decodeStatic*` through an allocation-free
summary cursor. Full demux behavior remains intact.

On the 25-file tiny batch, baseline is **252,154 ns** Zig versus **371,198 ns**
C (**0.679298×**). After is **246,189 ns** (**0.663228× C**, 2.37% faster
than baseline). Three paired after/C ratios are 0.6662, 0.6523, and 0.6655.
The Bryce control improves 1.63%.

Target RGBA matches libwebp byte-for-byte. Mutation tests enforce identical
summary/error behavior; `zig build ci` passes 19/19 steps and 517/517 tests.

The margin is only 0.0068 below the 0.67 gate and the diff is roughly 180 lines
across demux/decode, so independently repeat the paired benchmark and audit
strict-error/resource-limit parity before considering promotion.

## Integration follow-up

After applying A17, A02, A07, and A19 together, a fresh three-run
back-to-back comparison used the A17-only decode binary as the control for the
same 25-file target. Median invocation times were 254,955 ns without A19 and
257,850 ns with A19 (1.011×). Both trees remained faster than libwebp, but the
large demux refactor did not reproduce an incremental win, so A19 was removed
from the prepared integration stack. The isolated evidence above remains the
experiment record.
