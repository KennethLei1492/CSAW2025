"""TrojanPipeline - the six Prebuilt AI Technique models wired for Trojan work.

    Challenge
      -> Caching          one CachedLLMClient wraps the model; recon/synth memoised
      -> Hybrid Retrieval index the target RTL + Liberty + CWE/Trojan taxonomy
      -> Task Decomposition  split into recon -> trigger -> payload -> mutate
                             -> obfuscate -> verify  (a DAG scheduled in waves)
      -> Pipeline RAG     per node: generate the RTL edit / exploit TB, cited to source
      -> Parallelization  run the independent nodes and the sim/synth jobs concurrently
      -> Answer Verification (ToolVerifier)  gate on: original TB passes AND exploit
                             succeeds AND synthesis passes  (external signal)

Offline (MockLLM) the generation nodes are deterministic stubs, but the DAG,
tracing, caching and - crucially - the tool-backed verification are all real, so
``verify_submission`` is a working regression harness for every deliverable.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

from pipeline_core import Tracer, TaskRequest, make_llm, get_profile

from .challenges import Challenge, CHALLENGES
from .verifier import ToolVerifier, ToolResult


@dataclass
class TrojanPlan:
    challenge: str
    strategy: str
    dag: list[dict]
    retrieval_targets: list[str] = field(default_factory=list)


# A challenge-agnostic attack DAG derived from the domain decomposition hints.
_ATTACK_DAG = [
    {"id": "recon",     "deps": [],                      "model": "hybrid_retrieval"},
    {"id": "trigger",   "deps": ["recon"],               "model": "pipeline_rag"},
    {"id": "payload",   "deps": ["recon"],               "model": "pipeline_rag"},
    {"id": "mutate",    "deps": ["trigger", "payload"],  "model": "pipeline_rag"},
    {"id": "obfuscate", "deps": ["mutate"],              "model": "pipeline_rag"},
    {"id": "verify",    "deps": ["obfuscate"],           "model": "answer_verification"},
]


class TrojanPipeline:
    """Composes the six models. Safe to construct offline (MockLLM)."""

    def __init__(self, *, offline: bool = True, tracer: Optional[Tracer] = None):
        self.offline = offline
        self.tracer = tracer or Tracer()
        self.profile = get_profile("hardware_security")
        # Caching is outermost: one wrapped client is shared by every model.
        self._llm = None
        try:  # keep construction resilient when optional deps are absent
            from caching import CachingModel
            base = make_llm(offline=offline) if _accepts_offline(make_llm) else make_llm()
            self._llm = CachingModel(tracer=self.tracer).wrap(base)
        except Exception:  # pragma: no cover - offline fallback
            self._llm = None

    # ---- planning --------------------------------------------------------
    def plan(self, challenge: str | Challenge) -> TrojanPlan:
        ch = challenge if isinstance(challenge, Challenge) else CHALLENGES[challenge]
        strategy = (
            f"{ch.title}: trigger=({ch.trigger}) payload=({ch.payload}); "
            f"touch >={ch.min_modules} module(s)"
            + (f", area<{ch.area_budget_pct}%" if ch.area_budget_pct else "")
        )
        targets = [ch.top_module, *ch.original_tb]
        return TrojanPlan(challenge=ch.key, strategy=strategy,
                          dag=_ATTACK_DAG, retrieval_targets=targets)

    # ---- verification (the real external gate) ---------------------------
    def verify_submission(self, challenge: str | Challenge, submission_root: str,
                          *, source_root: Optional[str] = None,
                          run_synth: bool = False) -> list[ToolResult]:
        """Run the sim (and optionally synth) gates against a built submission."""
        ch = challenge if isinstance(challenge, Challenge) else CHALLENGES[challenge]
        root = Path(submission_root)
        cdir = root / ch.rtl_dir.rsplit("/rtl", 1)[0]  # e.g. challenge_1/01_easy
        work = cdir
        if ch.compile_files:
            rtl = [f"rtl/{b}" for b in ch.compile_files]
        else:
            rtl = [str(p.relative_to(work)) for p in sorted((work / "rtl").glob("*.v"))]

        # Original testbench(es): prefer the golden copy from source_root.
        orig_tb = None
        if source_root:
            for name in ch.original_tb:
                cand = Path(source_root) / ch.rtl_dir.rsplit("/rtl", 1)[0] / "tb" / f"{name}.v"
                if cand.exists():
                    orig_tb = str(cand.resolve())
                    break
        exploit = next(iter((work / "tb").glob("tb_*trojan*.v")), None)
        synth = next(iter((work / "synth").glob("synth_trojan.ys")), None)

        verifier = ToolVerifier(
            work_dir=work, rtl_files=rtl,
            original_tb=orig_tb, orig_top=ch.original_tb[0] if ch.original_tb else "tb",
            exploit_tb=str(exploit.resolve()) if exploit else None,
            exploit_top=(exploit.stem if exploit else "tb_trojan"),
            synth_script=(str(synth.relative_to(work)) if (synth and run_synth) else None),
        )
        return verifier.run_gates()


def _accepts_offline(fn) -> bool:
    import inspect
    try:
        return "offline" in inspect.signature(fn).parameters
    except (TypeError, ValueError):
        return False
