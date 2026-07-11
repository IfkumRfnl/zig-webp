# Plan 021: Give the VP8L bit reader a bulk 64-bit refill and an unchecked fast path, byte-exact

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 29be0df..HEAD -- src/bit_reader.zig src/vp8l/huffman.zig PROGRESS.MD`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (touches the hottest decode loop; mitigated by the byte-exact corpus gate)
- **Depends on**: plans/020-bench-libwebp-internal-decode-timing.md (soft — only for the recorded ratio)
- **Category**: perf
- **Planned at**: commit `29be0df`, 2026-07-09

## Why this matters

Lossless (VP8L) decode is this library's biggest recorded speed gap vs
libwebp: 1.8×–5.6× slower per the 2026-06-26 baseline in `PROGRESS.MD`.
libwebp's VP8L entropy loop is scalar C — the gap is not SIMD maturity, it is
per-symbol overhead in our bit reader. Today **every Huffman symbol pays two
`ensureBits` bounds checks (peek, then drop) and refills one byte at a time
in a loop**. libwebp refills with a single 64-bit load and defers bounds
checking. This plan replaces the refill with a bulk unaligned little-endian
64-bit load and gives `huffman.SymbolTable.decode` a fill-once/read-unchecked
fast path. Alpha (`ALPH`) decode uses the same reader via the VP8L modules,
so it benefits too. Output must remain byte-for-byte identical — the SHA-256
corpus gate inside `zig build test` enforces that.

## Current state

- `src/bit_reader.zig` — `BitReader`: LSB-first reader over a borrowed byte
  slice; `bytes` + `byte_offset` + 64-bit `bit_buffer` + `bit_count: u6`.
  All VP8L entropy decode goes through it (`src/vp8l/*.zig`), as does
  VP8L-compressed alpha. Re-exported at `src/root.zig:149` (`BitReader`) —
  a **Tier 2** name (module-internal tier, no stability promise; renames
  allowed but unnecessary here).
- `src/vp8l/huffman.zig` — two-level table decode; the per-symbol hot path.

The refill as it exists today (`src/bit_reader.zig:180-194`):

```zig
fn ensureBits(self: *BitReader, count: u6) Error!void {
    assert(count <= 32);
    if (self.bit_count >= count) return;

    const missing_bits = @as(u6, count - self.bit_count);
    const bytes_needed = (@as(usize, missing_bits) + bits_per_byte - 1) / bits_per_byte;
    if (bytes_needed > self.bytes.len - self.byte_offset) return error.TruncatedBitstream;

    var bytes_loaded: usize = 0;
    while (bytes_loaded < bytes_needed) : (bytes_loaded += 1) {
        self.bit_buffer |= @as(u64, self.bytes[self.byte_offset]) << self.bit_count;
        self.byte_offset += 1;
        self.bit_count += bits_per_byte;
    }
}
```

`peekBits` and `dropBits` **each** call `ensureBits`
(`src/bit_reader.zig:150-170`), so the common `peek+drop` pair double-checks.

The symbol decode hot path (`src/vp8l/huffman.zig:219-257`, abridged):

```zig
pub fn decode(self: Self, reader: *bit_reader.BitReader) Error!u16 {
    if (self.single_symbol) |symbol| return symbol;
    ...
    if (reader.remainingBits() < root_bits) {
        return self.decodeSlow(reader);
    }
    const root_value = try reader.peekBits(root_bits_u6);
    const root_index: usize = @intCast(root_value & root_mask_u32);
    const root_entry = self.entries[root_index];
    switch (root_entry.op) {
        .invalid => return error.InvalidHuffmanCode,
        .symbol => {
            try reader.dropBits(@intCast(root_entry.bits));
            return root_entry.symbol;
        },
        .table => {
            const subtable_bits: u6 = @intCast(root_entry.bits);
            const total_bits = root_bits_u6 + subtable_bits;
            if (reader.remainingBits() < total_bits) {
                return self.decodeSlow(reader);
            }
            const value = try reader.peekBits(total_bits);
            ...
            try reader.dropBits(root_bits_u6 + @as(u6, @intCast(subtable_entry.bits)));
            return subtable_entry.symbol;
        },
    }
}
```

Table geometry (`src/vp8l/huffman.zig:44-51`): `root_bits_default = 8`,
`max_code_bits = 15`, so a root+subtable read needs at most 23 bits — always
satisfiable from a ≥ 57-bit-full buffer except near end of stream, where
`decodeSlow` already exists and stays authoritative.

Semantics that MUST be preserved exactly:

- Logical LSB-first bit order; `readBits`/`peekBits`/`dropBits` results and
  their `error.TruncatedBitstream` / `error.InvalidBitCount` behavior.
- `remainingBits()` = buffered + unloaded bits (`src/bit_reader.zig:129-137`)
  — `decodeSlow` and truncation tests depend on it.
- `alignToByte()` drops only the sub-byte remainder of `bit_count`
  (`src/bit_reader.zig:172-178`); with bulk prefetch it must still leave
  whole buffered bytes intact (the existing
  "byte alignment preserves prefetched bytes" test pins this).

Semantics that MAY change (implementation detail, pinned only by this file's
own unit tests, which you will update): how many bytes are prefetched into
the buffer at a given moment. `loadedBytes()`/`bufferedBits()` are asserted
only in `src/bit_reader.zig` tests and one `src/vp8l/huffman.zig:466-469`
test that uses an **empty** reader (unaffected). Verified at planning time:
no production code reads them.

Repo conventions that apply:

- Assertions on invariants, bounded loops, explicit integer widths; comptime
  asserts at the bottom of the module (see `src/bit_reader.zig:197-203` —
  extend, don't delete).
- **32-bit portability (plan-014 lesson)**: never write a hardcoded `u6`
  shift amount for a `usize` shift. Shifting the `u64` `bit_buffer` by a
  `u6` is fine on every target (`Log2Int(u64) == u6` everywhere). Use
  `std.mem.readInt(u64, ..., .little)` for the bulk load — it is
  endian-correct on the big-endian CI target (powerpc64 under QEMU) and
  alignment-safe.
- The precedent for this exact kind of change is slice 10c (VP8 bool-reader
  renormalization, `PROGRESS.MD` "Oracle Results" 2026-06-26 row): arithmetic
  unchanged, loop overhead removed, byte-exact gate + interleaved A/B bench.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Full local gate | `zig build ci` | exit 0 (fmt check, compile, 464+ tests incl. SHA-256 corpus gate) |
| Tests only | `zig build test` | exit 0 |
| 32-bit/wasm gate | `zig build wasm-check` | exit 0 (compiles unit tests for wasm32) |
| Bench (ReleaseFast) | `zig build bench -Doptimize=ReleaseFast` | TSV to stdout |
| libwebp side | `tools/webp-bench.sh` | table (or SKIP if dwebp absent) |
| Format | `zig fmt .` | rewrites; run before `zig build ci` |

## Scope

**In scope** (the only files you should modify):
- `src/bit_reader.zig`
- `src/vp8l/huffman.zig`
- `PROGRESS.MD` (dated result row + short entry; append-only)

**Out of scope** (do NOT touch, even though they look related):
- `src/vp8/bool_reader.zig` — different codec, already optimized (slice 10c).
- `src/vp8l/entropy.zig`, `src/vp8l/image_data.zig` — their `readBits` calls
  benefit automatically; restructuring that loop is plan 022.
- `src/bit_writer.zig`, all encoder files.
- `src/root.zig` — the `BitReader` re-export keeps working unchanged.

## Git workflow

- Branch: `vp8l-bitreader-fast-path`
- Commit per step; message style: imperative summary line, e.g.
  `Bulk-refill the VP8L bit reader with a 64-bit load`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Record the baseline

`zig build bench -Doptimize=ReleaseFast` on the current `main` (or the
branch point). Save the output to `/tmp/plan021-bench-before.tsv`. Note the
lossless-decode rows (the harness labels asset classes; lossless files
include `lossless*` and `photo_*` lossless entries).

**Verify**: file exists and contains lossless decode rows.

### Step 2: Bulk refill in `ensureBits` + a public `fill`

In `src/bit_reader.zig`:

1. Add a non-failing top-up used by both the checked and fast paths:

```zig
/// Tops the buffer up from `bytes` without failing: loads as many whole
/// bytes as fit in the 64-bit buffer (single unaligned little-endian load
/// when 8+ bytes remain, byte loop on the short tail).
pub fn fill(self: *BitReader) void {
    const remaining = self.bytes.len - self.byte_offset;
    if (remaining >= 8) {
        const word = std.mem.readInt(u64, self.bytes[self.byte_offset..][0..8], .little);
        self.bit_buffer |= word << self.bit_count;
        const usable_bytes: usize = (64 - @as(usize, self.bit_count)) / 8;
        self.byte_offset += usable_bytes;
        self.bit_count += @intCast(usable_bytes * 8);
    } else {
        while (self.bit_count <= 64 - 8 and self.byte_offset < self.bytes.len) {
            self.bit_buffer |= @as(u64, self.bytes[self.byte_offset]) << self.bit_count;
            self.byte_offset += 1;
            self.bit_count += bits_per_byte;
        }
    }
}
```

   Correctness argument to keep as a comment: when `bit_count = c`, the
   shifted word contributes bits `c..64`; only `floor((64-c)/8)` whole bytes
   land entirely below bit 64, and exactly those are consumed — bytes whose
   bits would be truncated are neither credited to `bit_count` nor skipped
   in `byte_offset`. (`bit_count ≤ 63` always, so `64 - c ≥ 1`.) Note when
   `bit_count ≥ 57`, `usable_bytes == 0` and the call is a no-op — fine.

2. Rewrite `ensureBits` to: return early if satisfied; else `self.fill()`;
   then `if (self.bit_count < count) return error.TruncatedBitstream;`.
   The truncation condition is equivalent to the old byte-count check
   because `count ≤ 32` and `fill` loads everything available up to ≥ 57
   bits. Keep the `assert(count <= 32)`.

3. Add the unchecked pair for callers that have already filled:

```zig
/// Requires `bit_count >= count` (call `fill` first). `count` in 1..32.
pub fn peekBitsUnchecked(self: *const BitReader, count: u6) u32 { ... }
pub fn dropBitsUnchecked(self: *BitReader, count: u6) void { ... }
```

   Both `assert(count >= 1 and count <= read_bits_max)` and
   `assert(self.bit_count >= count)`, then do exactly the mask/shift the
   checked versions do (`src/bit_reader.zig:156-169`) without `ensureBits`.
   Have `peekBits`/`dropBits` keep their current signatures and error
   behavior (they are used by header/transform parsing and by tests).

4. Update this file's unit tests for the new prefetch amounts: the tests at
   `src/bit_reader.zig:246-307` assert exact `loadedBytes()` values after
   partial reads (e.g. `loadedBytes() == 1` after `peekBits(1)` on a 2-byte
   input). With bulk fill on a <8-byte input the byte loop fills everything,
   so expected values become the full input length. Update expectations —
   do NOT weaken the logical-bit-order or truncation assertions. Add one new
   test: a 16+-byte input where a single `peekBits(1)` prefetches exactly 8
   bytes (the u64 path), then 32-bit reads proceed correctly across the
   bulk/tail boundary and end in `error.TruncatedBitstream` at the right
   spot.

**Verify**: `zig build test` → exit 0 (the corpus SHA-256 gate proves decode
is byte-exact); `zig build wasm-check` → exit 0.

### Step 3: Fill-once fast path in `huffman.SymbolTable.decode`

In `src/vp8l/huffman.zig` `decode` (`:219-257`):

1. Replace the `remainingBits() < root_bits` pre-check with:
   `reader.fill();` then `if (reader.bufferedBits() < root_bits_u6) return self.decodeSlow(reader);`
   (`bufferedBits()` is existing API; after `fill`, buffered < root_bits
   implies the stream genuinely has fewer bits left, which is exactly the
   old `remainingBits()` condition given root_bits ≤ 8.)
2. Root hit: `reader.peekBitsUnchecked(root_bits_u6)` and
   `reader.dropBitsUnchecked(@intCast(root_entry.bits))` — a `.symbol` root
   entry has `bits ≤ root_bits ≤ bufferedBits`, so the unchecked drop is
   safe; keep an `assert(root_entry.bits <= root_bits)` beside it.
3. Subtable: `total_bits ≤ 23 < 57`, so after one `fill` the only failure
   mode is a genuinely short stream: replace the second `remainingBits()`
   check with `if (reader.bufferedBits() < total_bits) return self.decodeSlow(reader);`
   then use the unchecked peek/drop pair. Keep `decodeSlow` byte-identical
   in behavior (it is the end-of-stream authority and the `.invalid` /
   error paths must not change).

Do not touch `build`, `fillRoot`, `fillSubtable`, or `decodeSlow` logic.

**Verify**: `zig build test` → exit 0. Then `zig fmt .` and
`zig build ci` → exit 0.

### Step 4: Measure and record

1. Interleaved A/B, both ReleaseFast, single thread: alternate
   `git stash`-free runs by checking out the branch point and the branch tip
   (or two worktrees), ≥3 runs each, medians. Compare lossless-decode rows
   vs `/tmp/plan021-bench-before.tsv`.
2. If `dwebp` is present, run `tools/webp-bench.sh` and compute the new
   lossless ratios (use `decode_int_ms` if plan 020 has landed).
3. Append to `PROGRESS.MD`: a dated row in "Oracle Results" (corpus =
   lossless decode set, gate = byte-exact suite + measured speedup, machine
   + build mode stated) and a short "Recently Completed" entry, following
   the slice-10c entry's format. State the honest dimension: scalar
   lossless-decode speed; no general claims.

**Verify**: aggregate lossless decode is ≥ 1.15× faster (median). If it is
< 1.05× — the change is not earning its complexity — see STOP conditions.

## Test plan

- Updated expectations in `src/bit_reader.zig` tests (Step 2.4) plus the new
  bulk/tail-boundary test. Model after the existing
  `test "bit reader peeks and drops without changing logical bit order"`.
- No new tests in `src/vp8l/huffman.zig` needed beyond the existing suite:
  its tables/EOS behavior is pinned by `:466-564` tests, and byte-exactness
  by the corpus gate. Do add asserts as instructed.
- Verification: `zig build test` → all pass; the SHA-256 corpus regression
  (part of the suite) is the authoritative byte-exactness oracle.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `zig build ci` exits 0
- [ ] `zig build wasm-check` exits 0
- [ ] `grep -n "fn fill" src/bit_reader.zig` shows the new function;
      `grep -n "peekBitsUnchecked\|dropBitsUnchecked" src/vp8l/huffman.zig`
      shows the fast path in use
- [ ] Bench medians recorded in `PROGRESS.MD` with date, machine, build mode
- [ ] Aggregate lossless decode ≥ 1.15× vs baseline (else STOP outcome
      recorded instead)
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any corpus-hash test fails after Step 2 or 3 — the refactor changed decode
  behavior; do not "fix" hashes, find the logic difference or report.
- `zig build test -Dtarget=powerpc64-linux -fqemu` (if runnable locally) or
  the wasm/BE reasoning above is contradicted by a failing `wasm-check`.
- Speedup < 1.05× aggregate lossless decode after correct implementation:
  record the measured numbers in your report and leave the branch unmerged —
  the maintainer decides whether complexity is worth it.
- The excerpts in "Current state" no longer match the live code.

## Maintenance notes

- Plan 022 (specialized VP8L pixel loop) builds directly on `fill` +
  `peekBitsUnchecked`/`dropBitsUnchecked`; land this first.
- Reviewer should scrutinize: the `usable_bytes` accounting comment in
  `fill` (the truncated-high-bits argument), the updated `loadedBytes()`
  test expectations (must reflect prefetch, not paper over bit-order bugs),
  and that `decodeSlow` still owns every end-of-stream path.
- The `BitReader` root re-export is Tier 2; its checked API is unchanged
  anyway.
