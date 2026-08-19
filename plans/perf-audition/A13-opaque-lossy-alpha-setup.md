# A13 — Skip redundant alpha setup for opaque lossy input

**Verdict: `not-worthy`.** Independently verified at `a2b7f81`, Zig 0.16.0,
ReleaseFast, single-threaded, quality 75/method 0.

Reusing the gather transparency result and skipping alpha-plane alloc/fill for
opaque input improves meaningful Zig rows by 3.2–7.0% with byte-identical
outputs and no transparent-control regression. It does not establish a C-weak
class: seven RGB inputs finish at **1.198× C geomean** and **1.606× aggregate
time**; the four photos are 1.625×/1.615×. The only existing strong win, 17×17
RGB, changes by +0.42% noise.

All 30 final Zig/C artifacts decode via `dwebp`; `zig build ci` passes 19/19
steps and 517/517 tests. Do not promote the isolated 17-line cleanup under this
campaign because it misses the mandatory 0.67 Zig/C bar by a wide margin.
