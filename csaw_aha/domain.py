"""The ``hardware_security`` domain profile.

Registering this profile retunes all six models for RTL Trojan work with no code
change: retrieval shifts weight to lexical matching (identifier-heavy HDL),
verification applies hardware rules (original testbench must still pass,
synthesizability, area budget), and the acceptance threshold is raised because a
Trojan that breaks normal function scores zero.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

# Make pipeline_core + the six model packages importable whether or not they are
# pip-installed. We search, in order: the env var PREBUILT_MODELS_ROOT, this
# package's parent (when it lives inside the Prebuilt-AI-Technique-Models repo),
# and a sibling checkout of that repo next to this one. This keeps csaw_aha
# runnable after it is relocated (e.g. into a standalone CSAW2025 repo).
_MODEL_FOLDERS = ("common", "hybrid_retrieval_model", "task_decomposition_model",
                  "answer_verification_model", "parallelization_model",
                  "caching_model", "pipeline_rag_model")
_HERE = Path(__file__).resolve().parent
_candidates = []
if os.environ.get("PREBUILT_MODELS_ROOT"):
    _candidates.append(Path(os.environ["PREBUILT_MODELS_ROOT"]))
_candidates += [
    _HERE.parent,                                   # inside the models repo
    _HERE.parent.parent / "Prebuilt AI Technique Models",
    _HERE.parent / "Prebuilt AI Technique Models",
]
for _root in _candidates:
    if (_root / "common").is_dir():
        for _f in _MODEL_FOLDERS:
            _p = str(_root / _f)
            if _p not in sys.path:
                sys.path.insert(0, _p)
        break

from pipeline_core import DomainProfile, register_profile  # noqa: E402

HARDWARE_SECURITY = DomainProfile(
    name="hardware_security",
    description=(
        "Insertion and exploitation of hardware Trojans in open-source RTL "
        "(Verilog/SystemVerilog) and gate-level netlists, verified with "
        "open-source EDA tools."
    ),
    units=["ns", "ps", "MHz", "gates", "cells", "um^2", "bits"],
    document_types=[
        "verilog_rtl", "verilog_netlist", "testbench", "liberty_lib",
        "yosys_script", "cwe_entry", "trojan_taxonomy",
    ],
    verification_rules=[
        "The modified design MUST pass every original testbench unchanged.",
        "The design MUST remain synthesizable with the provided SkyWater 130nm library.",
        "Normal (untriggered) behaviour MUST be bit-identical to the golden design.",
        "The exploit MUST be demonstrable in simulation (a direct, observable signal), not only in theory.",
        "Any stated area budget (e.g. <=5% post-synthesis overhead) MUST be met.",
        "The trigger condition MUST NOT be reachable by any original testbench stimulus.",
    ],
    style_guidance=(
        "Spread malicious logic across modules and give it innocuous names "
        "(debug, telemetry, parity, scratch). Prefer reserved address space, "
        "unused encodings and rare multi-step triggers. Never alter documented "
        "ports or timing on the normal path."
    ),
    code_languages=["verilog", "systemverilog"],
    # Safety-critical acceptance: a candidate that regresses normal function is useless.
    min_confidence_to_accept=0.9,
    decomposition_hints=[
        "recon: locate the target signals/modules (key, datapath, bus ack, FIFO)",
        "trigger: design a rare condition unreachable by the original tests",
        "payload: design the malicious effect (leak / spoof / DoS / covert channel)",
        "mutate: emit minimal RTL edits, cited to source lines",
        "obfuscate: disguise and, if required, split logic across >=2 modules",
        "verify: original TB passes AND exploit TB succeeds AND synthesis passes",
    ],
    standards=["NIST FIPS-197", "CWE-1242", "CWE-1245", "CWE-1267", "Trust-Hub taxonomy"],
    retrieval_hints={"sparse_weight": 0.7},  # HDL is identifier-heavy -> favour BM25
)


def register_hardware_security(overwrite: bool = True) -> DomainProfile:
    """Register (idempotently) the hardware-security profile and return it."""
    return register_profile(HARDWARE_SECURITY, overwrite=overwrite)
