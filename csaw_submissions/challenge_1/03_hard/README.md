# Challenge 1 — Hard: Netlist-level Key-Leakage Trojan (AES)

**Target:** the provided **flattened Verilog netlist** `rtl/aes_flattened.v`.
**Objective:** leak `key[7:0]` (the low byte of the key), one bit per encryption,
via the **LSB of the ciphertext** — while producing correct ciphertext when not
leaking.

---

## 1. How we used AI

Produced by the autonomous Claude Code pipeline (see
[`../../PIPELINE.md`](../../PIPELINE.md)). Hybrid Retrieval located the three
nets the attack needs inside the 48k-line netlist — the key word
`\key_reg[7]` (whose low byte is `key[7:0]`), the ciphertext-LSB flop
`result_reg[0]`, and the completion strobe `core_valid` — and Pipeline RAG
emitted a minimal, self-contained logic block. The tool-verifier caught a
one-cycle index/latch race on the first attempt (the read, which happens after
`ready`, observed `key[idx+1]`); the fix latches the emitted bit into a
dedicated `trj_emit` register at the completion edge. Logs in [`ai/`](ai/).

## 2. How the Trojan works

Only `aes_flattened.v` is modified (per the rules). Added logic:

- **Trigger (rare):** a write of `0xA5A5A5A5` to reserved address `0x0b` sets
  `trj_armed`. Nothing in the original testbench writes this, so the design is
  inert under normal test.
- **Index:** `trj_idx` (3 bits) advances on each rising edge of `core_valid`
  (once per completed block).
- **Payload:** at each completion while armed, `trj_emit <= \key_reg[7][trj_idx]`
  — the next bit of `key[7:0]`. The ciphertext-LSB flop is driven by
  `trj_lsb = trj_armed ? trj_emit : \core.result[0]`, so **while armed the
  ciphertext LSB carries one key bit per encryption**; after 8 encryptions the
  Trojan disarms (one full key byte leaked). When disarmed, `result_reg[0]`
  reduces exactly to the original `\core.result[0]` → correct ciphertext.

An observer reads the low ciphertext word (`RESULT3`, bit 0) after each of 8
encryptions and reassembles `key[7:0]`.

## 3. How to test

```bash
export PATH=/path/to/oss-cad-suite/bin:$PATH   # iverilog/vvp
cd challenge_1/03_hard
# Exploit: normal AES-256 ciphertext correct, then key[7:0] recovered via LSB
iverilog -g2012 -o sim_x.out -s tb_aes_synth_trojan rtl/aes_flattened.v tb/tb_aes_synth_trojan.v
vvp sim_x.out
# Synthesis (sky130):
yosys -q synth/synth_trojan.ys        # writes synth-run/aes_synth.v
```

The exploit bench uses the NIST SP800-38A **AES-256** vector (so `key_reg[7]` is
non-zero): key `603deb…0914dff4`, `key[7:0] = 0xf4`.

> **Timing note (from the challenge):** the *original* post-synthesis testbench
> `tb_aes_synth` exercises many AES-128/256 operations and takes a long time to
> run; our exploit bench runs a single normal encryption plus 8 armed
> encryptions, which is far shorter but still a full gate-accurate run. Allow a
> few minutes.

## 4. Files

```
rtl/aes_flattened.v            modified flattened netlist (Trojan ~8 lines of logic)
tb/tb_aes_synth_trojan.v       exploit (normal AES-256 vector + key[7:0] recovery)
synth/synth_trojan.ys          Yosys sky130 script
synth-run/aes_synth.v          synthesized netlist
ai/transcript.md               AI interaction log
```

## 5. Rubric self-assessment

| Category | Level | Pts |
|---|---|---|
| Trojan Effectiveness | Fully leaks `key[7:0]` as specified (1 bit/encryption via ciphertext LSB) | 5 |
| Stealth & Subtlety | No deviation when disarmed; correct ciphertext on the normal path | 5 |
| Creativity & Design | Netlist-level edit tapping named nets of a flattened design; rare arm + per-block index | 3–5 |
| Documentation | Trigger, payload, observation explained | 3 |
| Demonstration | Sim shows correct ciphertext and bit-by-bit key recovery | 3 |
| AI Interaction | Autonomous agentic pipeline with tool-backed self-correction | 5 |
