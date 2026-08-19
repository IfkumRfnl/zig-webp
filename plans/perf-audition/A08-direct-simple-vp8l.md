# A08 — Direct simple VP8L RIFF write

**Verdict: `already-on-master`; specialist writer rejected.** Verified at
`a2b7f81`, Zig 0.16.0, ReleaseFast, single-threaded, 3 warmups + 15 medians,
libwebp 1.5.0 preset 0 with `exact=1`.

Across six tiny one/low-color fixtures, current Zig totals **228,507 ns**
versus C's **404,646 ns** (**0.565×**) and 554 versus 486 bytes (**1.140×**),
clearing both campaign gates without a change.

The existing generic Zig mux costs only **47–49 ns**, or **0.05–0.24%** of
full encoding. A throwaway hand-written wrapper costs 12–13 ns. Duplicating
container logic could therefore save at most about 36 ns and is not worthy.
All outputs were deterministic and the direct wrapper matched generic file
sizes; no production source changed.
