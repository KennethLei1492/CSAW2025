"""csaw_aha - an agentic hardware-Trojan insertion pipeline for the CSAW AI
Hardware Attack Challenge, built on the six Prebuilt AI Technique models.

The package is the reusable *framework*: it registers a ``hardware_security``
domain profile, models each challenge as a decomposition DAG, and wires the six
models into one traced, budgeted, self-verifying loop whose acceptance gate is a
*real* EDA toolchain (Icarus Verilog + Yosys), not the model's own opinion.

See ``csaw_aha/README.md`` and ``csaw_submissions/PIPELINE.md`` for the design.
"""
from __future__ import annotations

from .domain import HARDWARE_SECURITY, register_hardware_security
from .challenges import CHALLENGES, Challenge, challenge_task
from .verifier import ToolVerifier, ToolResult
from .pipeline import TrojanPipeline, TrojanPlan

register_hardware_security()

__all__ = [
    "HARDWARE_SECURITY",
    "register_hardware_security",
    "CHALLENGES",
    "Challenge",
    "challenge_task",
    "ToolVerifier",
    "ToolResult",
    "TrojanPipeline",
    "TrojanPlan",
]
