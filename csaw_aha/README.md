# `csaw_aha` — agentic hardware-Trojan pipeline

The reusable framework behind the CSAW 2025 submissions. It composes the six
*Prebuilt AI Technique* models into one self-verifying loop whose acceptance gate
is a real EDA toolchain (Icarus Verilog + Yosys). Design rationale:
[`../csaw_submissions/PIPELINE.md`](../csaw_submissions/PIPELINE.md).

## Layout

| File | What it is |
|---|---|
| `domain.py` | registers the `hardware_security` `DomainProfile` (retunes all six models) |
| `challenges.py` | the seven CSAW challenges as structured specs → `TaskRequest`s |
| `verifier.py` | `ToolVerifier`: a `pipeline_core.Verifier` backed by `iverilog`/`vvp`/`yosys` |
| `pipeline.py` | `TrojanPipeline`: wires the six models; `plan()` and `verify_submission()` |
| `cli.py` | `python -m csaw_aha {list,plan,verify}` |

## Use

```bash
# from the repo root
python -m csaw_aha list
python -m csaw_aha plan c2_hard
python -m csaw_aha verify c1_medium --submissions csaw_submissions \
       --source csaw_submissions/_challenge_source --synth
```

`TrojanPipeline(offline=True)` constructs against the deterministic `MockLLM`, so
planning and the tool-backed verification run with no credentials. Set
`ANTHROPIC_API_KEY` (and `offline=False`) to drive generation with Claude.

`OSS_CAD_BIN` (default `C:\oss-cad-suite\bin`) points the verifier at the
toolchain; the verifier injects it onto `PATH` for each spawned tool.

## Why the verifier is the point

LLM self-correction only helps with an **external** signal (Huang et al., 2024).
For hardware that signal is the toolchain: `gate1` the original testbench still
passes, `gate2` the exploit testbench succeeds, `gate3` synthesis produces a
netlist. A candidate is accepted only when all three are green; otherwise the
failing log is fed back for a re-plan.
