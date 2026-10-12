# Challenge 1 — Easy: Basic Key-Leakage Trojan (AES-128)

**Team:** NYU CSAW AI Hardware Attack Challenge 2025
**Target:** `secworks/aes` core, top-level wrapper `aes.v`
**Status:** Verified — passes all 20 original test cases, recovers the full
128-bit key in simulation, and synthesizes to the SkyWater 130 nm library.

---

## 1. How we used AI to modify the code

All RTL and testbench modifications were produced by a generative-AI pipeline
— no Verilog was hand-written by a human. See [`../../PIPELINE.md`](../../PIPELINE.md)
for the full architecture. In short:

- **Interaction method:** autonomous agentic loop driving Anthropic Claude
  (`claude-opus-4-8`) through the Claude Code harness. The model reads the
  design, proposes the Trojan, writes the RTL + exploit testbench, and runs the
  open-source toolchain itself (`iverilog`/`vvp`, `yosys`) to verify each
  candidate, iterating on failures.
- **Supporting framework:** the six-model *Prebuilt AI Technique* pipeline
  (`csaw_aha/`). Task Decomposition split the challenge into
  recon → trigger → payload → mutation → verify; Hybrid Retrieval located the
  register-decode logic in `aes.v`; Pipeline RAG generated the edits cited to
  source lines; Answer Verification gated the result on "original TB passes AND
  exploit succeeds AND synthesizes"; Parallelization ran the sim/synth jobs.
- **Full transcript:** [`ai/`](ai/).

## 2. How the Trojan works

**Mechanism:** a covert read-only exfiltration register in the memory-mapped
register interface of `aes.v`.

- The documented register map leaves address `0x0f` unused. The Trojan decodes
  a read at `0x0f` (named `ADDR_DBG_SCRATCH`, disguised as a bring-up/telemetry
  scratch register) and returns one byte of the secret key:
  `core_key[255 - dbg_idx*8 -: 8]`.
- A 4-bit index `dbg_idx_reg` advances by one on every completed block
  (rising edge of `result_valid`), so successive reads walk the entire 128-bit
  key, **one key byte leaked per encryption**. A key re-initialisation
  (`init`) resets the index to byte 0 so the phase is always known.

**Why it passes the original testbenches and leaks ≥8 bits/encryption:**

- The normal datapath is completely untouched — ciphertext at
  `RESULT0..3` is bit-exact (all 20 original test cases pass, plus the
  FIPS-197 vector in our exploit bench).
- The leak uses a *direct, simulatable* output (a normal bus read of an
  otherwise-ignored address), so it needs no side-channel. It leaks 8 bits
  (one key byte) per encryption; 16 encryptions recover the full AES-128 key.

**Stealth:** no functional or timing deviation on any documented address;
the only change is that a previously reserved address now returns data. A
reviewer who never reads `0x0f` sees a bit-identical core.

## 3. How to test the Trojan

From this directory, with `iverilog`/`vvp` on `PATH`:

```bash
# 1. Prove normal functionality is intact (original testbench, 20 TCs)
iverilog -g2012 -o sim_orig.out -s tb_aes rtl/*.v ../../_challenge_source/challenge_1/01_easy/tb/tb_aes.v
vvp sim_orig.out            # -> "*** All 20 test cases completed successfully"

# 2. Demonstrate the exploit (normal ciphertext correct + full key recovered)
iverilog -g2012 -o sim_exploit.out -s tb_aes_trojan rtl/*.v tb/tb_aes_trojan.v
vvp sim_exploit.out         # -> "*** EXPLOIT SUCCESS: full 128-bit key recovered. ***"
```

Synthesis (SkyWater 130 nm), via the provided Yosys flow:

```bash
yosys -q synth/synth_trojan.ys   # writes synth-run/aes_synth.v
```

### Expected exploit output (abridged)

```
[normal]  ciphertext = 3ad77bb40d7a3660a89ecaf32466ef97
[normal]  PASS: ciphertext matches FIPS-197 vector.
[exploit] encryption 0 -> key byte = 0x2b
...
[exploit] recovered key = 2b7e151628aed2a6abf7158809cf4f3c
*** EXPLOIT SUCCESS: full 128-bit key recovered. ***
```

## 4. Files

```
rtl/aes.v                 modified top-level (Trojan here); other RTL unchanged
tb/tb_aes_trojan.v        exploit testbench (normal-op check + key recovery)
synth/synth_trojan.ys     Yosys sky130 synthesis script
synth-run/aes_synth.v     synthesized gate-level netlist
ai/                       complete AI interaction logs
```

## 5. Rubric self-assessment

| Category | Level | Pts |
|---|---|---|
| Trojan Effectiveness | Fully leaks the targeted data (full key over 16 encryptions) | 5 |
| Stealth & Subtlety | No functional/timing deviation under normal use | 5 |
| Creativity & Design | Encryption-indexed shadow exfil register on a reserved address | 3–5 |
| Documentation | Trigger, payload, observation all explained | 3 |
| Demonstration | Sim shows both normal and triggered behavior | 3 |
| AI Interaction | Fully-autonomous agentic framework with self-verification | 5 |
