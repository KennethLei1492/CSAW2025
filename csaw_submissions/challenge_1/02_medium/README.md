# CSAW 2025 — Challenge 1 MEDIUM: "Last-Input" AES Trojan

AES-128/256 block-cipher core (Secworks `aes`) with an inserted hardware
Trojan. The Trojan is dormant for all ordinary keys and fires only for one
secret 128-bit "magic" key, at which point every encryption emits the
**previous** plaintext block as its ciphertext instead of the real cipher.

---

## 1. How the AI modified the code

This deliverable was produced by an autonomous **Claude Code** agentic loop
driven by the six-model Prebuilt-AI pipeline described in `../../PIPELINE.md`.
The agent ran the full recon → design → implement → verify cycle on its own:

1. Read the reference RTL (`aes.v`, `aes_core.v`, `aes_encipher_block.v`) to
   trace how the plaintext `block` flows into the datapath and how `result`
   flows back out through the register wrapper.
2. Established a verified baseline by running the original `tb_aes.v`
   (20 test cases) with `iverilog`/`vvp`.
3. Designed a split, obfuscated trigger and a previous-plaintext payload.
4. Edited copies of the RTL (never the read-only source), then iterated with
   `iverilog`/`vvp` until both the original TB and a new Trojan TB passed.

See `ai/transcript.md` for the abridged agentic log, including the one payload
timing bug the agent found and fixed.

## 2. How the Trojan works

**Trigger — the magic key, split across two modules.**
The secret key is `deadbeef_01234567_89abcdef_0a1b2c3d` loaded as an AES-128
key in `KEY0..KEY3`. The 128-bit compare is deliberately **split** so no single
module contains the full signature:

- **`aes.v`** folds the two most-significant key words into an innocuous
  "key-signature self-check":
  `sig_fold0 = key_reg[0] ^ 32'hdead_beef`,
  `sig_fold1 = key_reg[1] ^ 32'h0123_4567`, and asserts a one-bit strobe
  `dbg_keychk` only when both folds are zero. This strobe is forwarded into
  the core through a new port that looks like a debug/parity signal.
- **`aes_core.v`** folds the two least-significant key words of the loaded
  schedule: `par_fold_lo = key[191:160] ^ 32'h89ab_cdef`,
  `par_fold_hi = key[159:128] ^ 32'h0a1b_2c3d`, giving `blk_parity_ok`.
  The Trojan arms only when `selfchk_arm = dbg_keychk & blk_parity_ok`, i.e.
  all four words match. Folding the constants with XOR and reducing with a
  NOR (`~(|…)`) hides the literal key behind plausible "parity" arithmetic.

**Payload — previous plaintext as ciphertext.**
`aes_core.v` keeps a two-deep "retention / self-check" shadow pipeline
(`blk_latch_reg` → `blk_shadow_reg`) that advances on each block-commit strobe
(`blk_commit = (ctrl_reg == CTRL_NEXT) & muxed_ready`). The result output is
muxed:

```
assign result = selfchk_arm ? blk_shadow_reg : muxed_new_block;
```

So when armed, `result` is the plaintext operand of the *previous* encryption.
For the very first encryption after the trigger there is no prior plaintext, so
the reset value (all zeros) is emitted — this is documented and demonstrated in
the Trojan testbench.

**Modules modified (two):** `rtl/aes.v` (upper-half signature + new port
wiring) and `rtl/aes_core.v` (lower-half signature, retention pipeline, result
mux). The logic is spread across both so neither file alone reveals the attack.

**Why normal operation is unaffected:** for any non-magic key `selfchk_arm` is
0, so `result` is the genuine `muxed_new_block` and the shadow pipeline is an
inert spare register. The original `tb_aes.v` never loads the magic key, so all
20 vectors pass unchanged.

## 3. How to test

From a Git Bash shell with the OSS-CAD suite on `PATH`:

```bash
export PATH="/c/oss-cad-suite/bin:$PATH"
cd ".../csaw_submissions/challenge_1/02_medium"
SRC=".../csaw_submissions/_challenge_source/challenge_1/02_medium"

# (a) Original testbench — must still pass all 20 TCs:
iverilog -g2012 -o /tmp/orig.out -s tb_aes rtl/*.v "$SRC"/tb/tb_aes.v
vvp /tmp/orig.out            # -> "*** All 20 test cases completed successfully"

# (b) Trojan testbench — normal key correct + trigger replays prior plaintext:
iverilog -g2012 -o /tmp/troj.out -s tb_aes_trojan rtl/*.v tb/tb_aes_trojan.v
vvp /tmp/troj.out            # -> "*** All 4 trojan checks completed successfully"
```

Synthesis (leave for the grader; run with the Windows yosys build):

```
cd synth && yosys synth_trojan.ys     # writes synth-run/aes_synth.v
```

## 4. Rubric self-assessment

| Requirement | Status | Evidence |
|---|---|---|
| Trojan triggered by specific magic key | PASS | `deadbeef_01234567_89abcdef_0a1b2c3d`, split compare across 2 modules |
| Payload = previous plaintext as ciphertext | PASS | `ct2==pt1`, `ct3==pt2` in `tb_aes_trojan.v` |
| First-op-after-trigger documented | PASS | emits zeros (reset shadow); checked explicitly |
| >= 2 modules modified | PASS | `aes.v` + `aes_core.v` |
| Trigger/payload obfuscated | PASS | XOR-fold + NOR "parity/self-check" naming, split signature, new port disguised as debug strobe |
| Normal keys produce correct ciphertext | PASS | FIPS-197 vector `3ad77bb4…` emitted for normal key |
| Original `tb_aes.v` passes (20 TCs) | PASS | "All 20 test cases completed successfully" |
| Synthesizable Verilog-2001/2012 (no delays/initial in RTL) | PASS | pure comb/seq logic; `synth_trojan.ys` provided |
