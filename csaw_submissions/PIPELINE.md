# The Trojan-Insertion Pipeline (`csaw_aha`)

Every submission in this repository was produced by one system: an autonomous,
self-verifying hardware-Trojan pipeline built on the six *Prebuilt AI Technique*
models. This document is the architecture; the runnable code is in
[`../csaw_aha/`](../csaw_aha/README.md).

> **AI usage (per competition rules).** All RTL and testbench edits are
> generative-AI output — no Verilog was hand-written by a human. The generator
> is Anthropic **Claude `claude-opus-4-8`**, driven through the **Claude Code**
> agentic harness (tool use: file edit, `iverilog`/`vvp`, `yosys`). The six
> models form the framework *around* the model. Complete interaction logs are
> in each challenge's `ai/` directory.

---

## 1. Why a pipeline, not a single prompt

A hardware Trojan has to satisfy three hard constraints at once: the normal
function must stay **bit-identical** (pass every original testbench), the
exploit must be **demonstrable in simulation**, and the design must remain
**synthesizable**. A one-shot prompt cannot guarantee any of these. The research
behind these models is explicit that LLM self-correction only improves results
when the correction signal is **external** (Huang et al., 2024) — so the loop is
closed around a *real EDA toolchain*, not the model's own judgement.

## 2. The six models, mapped to the attack

```
Challenge spec ─▶ Caching ─▶ Hybrid Retrieval ─▶ Task Decomposition ─▶ (DAG)
                   (memoise)   (index the RTL)      recon→trigger→payload
                                                    →mutate→obfuscate→verify
                                                          │ waves
                                                          ▼
                                   Parallelization ◀─ Pipeline RAG (generate
                                   (fan out sim/synth   RTL edits + exploit TB,
                                    and variants)        cited to source lines)
                                                          │
                                                          ▼
                              Answer Verification = ToolVerifier
                              gate1 original TB passes
                              gate2 exploit TB succeeds   ── all green? accept
                              gate3 yosys synthesis OK     ── else re-plan
```

| Model | Role in the pipeline | Key decisions it makes |
|---|---|---|
| **Task Decomposition** | Turns a challenge into the DAG `recon → trigger → payload → mutate → obfuscate → verify`, schedules independent nodes in waves, and **re-plans** when a verification gate fails. | difficulty routing; which nodes can run in parallel; when to recurse (e.g. medium's "split across ≥2 modules"). |
| **Hybrid Retrieval** | Indexes the target RTL, the Liberty cell library and a CWE / Trust-Hub Trojan taxonomy; BM25-weighted (HDL is identifier-heavy, `sparse_weight=0.7`). | *where* to attack — e.g. the `aes.v` register mux, the `wbuart.v` ack path, the `rx_stb`/`rx_uart_data` RX stream. |
| **Pipeline RAG** | The sub-task solver: generates the concrete RTL mutation and the exploit testbench, grounded in and cited to the retrieved source lines. | the exact edit; trigger encoding; payload wiring. |
| **Parallelization** | Bounded-concurrency executor running the DAG waves and the sim/synth jobs; retries and a circuit breaker around flaky tool calls. | run easy/medium/hard and their verification jobs concurrently. |
| **Answer Verification** | Implemented as [`ToolVerifier`](../csaw_aha/verifier.py): the acceptance gate. Score = fraction of gates passed; a candidate is accepted only at score 1.0 (profile `min_confidence_to_accept = 0.9`). | accept / reject / feed failures back to decomposition for a re-plan. |
| **Caching** | One `CachedLLMClient` wraps the model for every component; recon and synthesis results are memoised and tagged by corpus version, so the agentic loop's repeated calls are cheap. | what to reuse across iterations and difficulties. |

The `hardware_security` **domain profile**
([`csaw_aha/domain.py`](../csaw_aha/domain.py)) retunes all six at once:
retrieval weighting, the verification rule-set (original TB must pass,
synthesizable, untriggered path identical, area budget, trigger unreachable by
tests), and a raised acceptance threshold.

## 3. The verification gate (the important part)

`ToolVerifier` satisfies the `pipeline_core.Verifier` protocol but runs the
open-source toolchain the judges use:

1. **gate 1 — functionality:** compile the *modified* RTL against the **original**
   testbench; require the golden pass banner (e.g. "All 20 test cases completed
   successfully"). A Trojan that regresses normal behaviour scores zero.
2. **gate 2 — exploit:** compile the RTL against the exploit testbench; require
   the success banner (key recovered / spoof observed / DoS then restored / byte
   leaked). This proves the Trojan actually works in simulation.
3. **gate 3 — synthesis:** run the Yosys sky130 flow; require a gate-level
   netlist (and, where a budget applies, an area check).

Only when all three are green is the candidate accepted; otherwise the failing
gate's log is handed back to Task Decomposition, which re-plans the failing node
(this is exactly how the medium AES Trojan's first "replay current-instead-of-
previous plaintext" bug and the UART RX-synchronisation timing bug were caught
and fixed — see the `ai/` logs).

## 4. Running it

```bash
python -m csaw_aha list                     # the seven challenge specs
python -m csaw_aha plan c1_easy             # the attack DAG + strategy
# Regression-verify a built submission with the real toolchain:
python -m csaw_aha verify c1_easy  --submissions csaw_submissions \
        --source csaw_submissions/_challenge_source --synth
```

`verify` is the same gate the pipeline uses internally, so it doubles as a
one-command regression harness over every deliverable in this repo.

## 5. Status of the deliverables

| Challenge | Trojan | gate1 func | gate2 exploit | gate3 synth |
|---|---|:--:|:--:|:--:|
| C1 easy | key-leak via reserved register | ✅ 20/20 | ✅ full key | ✅ |
| C1 medium | magic-key previous-plaintext replay | ✅ 20/20 | ✅ | ✅ |
| C1 hard | netlist LSB key-leak | see its README | — | — |
| C2 easy | Wishbone DoS (armed/disarm) | n/a* | ✅ DoS+restore | ✅ |
| C2 medium | one-shot Setup-register spoof | n/a* | ✅ | ✅ |
| C2 hard | ACK-timing covert channel | n/a* | ✅ | ✅ |
| Final | OpenTitan | see `final/README.md` | | |

\* The wbuart32 original benches use a Verilator C++ harness (broken in this
offline environment); normal operation is instead proven by in-bench normal-op
checks and the structural argument that the trigger is unreachable by ordinary
traffic. Each README documents this. Run them under Verilator in the official
Docker to reproduce the golden pass.
