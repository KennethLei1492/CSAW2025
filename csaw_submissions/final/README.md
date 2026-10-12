# Final Challenge — OpenTitan Root-of-Trust

**Team:** NYU CSAW AI Hardware Attack Challenge 2025
**Target:** OpenTitan (lowRISC) — a silicon root-of-trust
**Deliverable:** AI-driven Trojan design + strategy. Per the challenge rules we
submit only the files we created/modified; the judges graft them into the
OpenTitan tree and run the official DV in the OpenTitan Docker.

> Full OpenTitan DV (UVM/`dvsim`, Verilator `chip_sim`) runs only inside the
> official container, which is not available in our offline build environment.
> The qualifying-round Trojans in this repo are all **simulation-verified end to
> end** (see [`../PIPELINE.md`](../PIPELINE.md)); this final design is built by
> the same pipeline and is written to pass the block-level DV it targets.

---

## 1. How we used AI

The same autonomous pipeline that produced the six qualifying Trojans
([`../../csaw_aha/`](../../csaw_aha/README.md)) is pointed at OpenTitan:

- **Task Decomposition** splits the final into: pick a high-value IP → find a
  signal whose corruption is *severe but DV-invisible* → design a rare trigger →
  design a stealthy payload → emit the minimal RTL patch → assemble a
  block-level exploit → argue DV-pass and detector-evasion.
- **Hybrid Retrieval** indexes the OpenTitan RTL (`hw/ip/*`), the DV testplans
  (`*_testplan.hjson`) and the CWE hardware-weakness list, so the attack targets
  a signal the existing testplan does **not** assert on.
- **Pipeline RAG** writes the patch, cited to the exact OpenTitan source lines.
- **Answer Verification** gates on the block's own DV smoke test + a crafted
  exploit sequence (run in the OT Docker).
- **Caching / Parallelization** make the large-repo recon and multi-IP
  candidate search tractable.

Complete logs: [`ai/`](ai/).

## 2. Target selection and the Trojan

**Chosen IP: `hw/ip/aes` (the OpenTitan AES accelerator).** It is a
root-of-trust crypto primitive, its DV testplan asserts *functional* correctness
(ciphertext vectors, side-load key wiring, protocol) but not the absence of an
*aliased debug read path*, and it is reachable over the standard TL-UL register
interface — the same class of attack we proved in Challenge 1.

**Mechanism — initial-key exfiltration through a reserved CSR alias.**
OpenTitan AES holds the initial key in the `KEY_SHARE0_*` / `KEY_SHARE1_*`
write-only registers (the two shares of the masked key). The Trojan adds a tiny
read decoder on a **reserved offset** in the AES register window that, only when
a rare arming condition holds, returns the reconstructed key share word selected
by a per-operation counter — one word leaked per AES operation, write-only
semantics preserved for every documented offset.

- **Trigger (rare, DV-unreachable):** a specific unlock pattern written to the
  reserved offset (a 32-bit magic constant), which the DV never issues because
  the offset is not in the register model. Optionally gate on a debug/lifecycle
  state so it is inert in the production life-cycle state DV exercises.
- **Payload:** a read of the reserved offset returns `key_share0[idx] ^
  key_share1[idx]` (the unmasked key word), `idx` advancing each time AES
  signals `output_valid`. Eight operations leak a 256-bit key.
- **Stealth:** no documented register changes value or timing; masked datapath
  untouched; the added logic is a handful of flops + a comparator + a read mux
  on an address the register abstraction layer never touches — so block-level
  and chip-level DV pass unchanged.

A higher-severity variant the pipeline also produced (documented in `ai/`)
**biases the entropy** feeding `csrng`/`edn` by forcing a few LFSR state bits
under the same rare trigger: catastrophic for key generation, yet invisible to
protocol-level DV (statistical entropy quality is not a DV assertion). We lead
with the AES key-leak because it is cleanly demonstrable in a block-level
simulation for the presentation.

## 3. Files we modify

```
hw/ip/aes/rtl/aes_reg_top.sv     + reserved-offset read decode + counter (Trojan)
hw/ip/aes/rtl/aes_core.sv        + unmasked-key tap feeding the covert read
```
See [`rtl/aes_trojan_patch.md`](rtl/aes_trojan_patch.md) for the concrete,
line-cited patch the pipeline emitted (kept as a reviewable patch description
because it must be applied against the exact OpenTitan revision the judges use).

## 4. How to test (OpenTitan Docker)

```bash
# Block-level DV smoke (must still pass):
util/dvsim/dvsim.py hw/ip/aes/dv/aes_sim_cfg.hjson -i aes_smoke
# Exploit sequence (our testbench, in tb/):
#   drives the reserved-offset unlock, runs 8 AES ops, reads the covert
#   offset, reconstructs the key, asserts it equals the loaded key.
```
`tb/aes_trojan_exploit.md` describes the exploit transaction sequence and the
expected "recovered key == loaded key" assertion.

## 5. Detection-evasion (presentation emphasis)

- **Structural scanners** (e.g. unused-logic / rare-net flags): the trigger
  comparator is folded into existing address-decode logic and the counter
  resembles the real operation counter, minimising "rare net" signatures.
- **Functional DV:** the attack lives entirely on an address outside the
  register model, so coverage closure never exercises it.
- **Info-flow checks:** the leak path is gated, so a key→output flow only exists
  under the rare trigger; unconditional-flow checkers see nothing on the normal
  path.

## 6. Presentation

20 min + 5 Q&A (10:00 ET, 7 Nov). Narrative: the six-model pipeline, the
qualifying Trojans as a verified track record, the OpenTitan target rationale,
a live block-level demo of the key reconstruction, and the detector-evasion
argument.
