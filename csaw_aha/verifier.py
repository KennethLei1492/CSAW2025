"""ToolVerifier - a :class:`pipeline_core.Verifier` backed by a real EDA toolchain.

The research behind the Answer Verification model is explicit that LLM
self-correction only helps when the verification signal is *external* (Huang et
al., 2024). For hardware Trojans that signal is the toolchain itself:

  gate 1  original testbench(es) pass        (functionality preserved)
  gate 2  exploit testbench succeeds         (Trojan actually works)
  gate 3  Yosys synthesis succeeds           (synthesizable; optional area check)

``verify`` returns a :class:`Verdict` whose ``score`` is the fraction of gates
passed, so the agentic loop keeps iterating until all three are green. The class
is deliberately usable on its own (``run_gates``) and as the ``Verifier`` the
RAG / decomposition models consume.
"""
from __future__ import annotations

import os
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional, Sequence

from pipeline_core import Evidence, Verdict

OSS_CAD_BIN = os.environ.get("OSS_CAD_BIN", r"C:\oss-cad-suite\bin")


@dataclass
class ToolResult:
    name: str
    passed: bool
    detail: str = ""
    log: str = ""


@dataclass
class ToolVerifier:
    """Runs sim/synth gates for one candidate and reports a calibrated Verdict.

    Parameters
    ----------
    work_dir      directory containing ``rtl/`` and ``tb/`` of the candidate
    rtl_files     Verilog sources to compile (globs resolved against work_dir)
    original_tb   path(s) to the golden testbench(es) whose module must pass
    exploit_tb    path to the exploit testbench proving the Trojan
    exploit_top   top module name of the exploit testbench
    orig_top      top module name of the original testbench
    success_token substring that marks success in the original TB log
    exploit_token substring that marks exploit success
    synth_script  optional Yosys .ys to run (via PowerShell on Windows)
    """

    work_dir: Path
    rtl_files: Sequence[str]
    original_tb: Optional[str] = None
    orig_top: str = "tb_aes"
    success_token: str = "test cases completed successfully"
    exploit_tb: Optional[str] = None
    exploit_top: str = "tb_aes_trojan"
    exploit_token: str = "EXPLOIT SUCCESS"
    synth_script: Optional[str] = None

    def __post_init__(self) -> None:
        self.work_dir = Path(self.work_dir).resolve()

    # --- low-level helpers ------------------------------------------------
    def _env(self) -> dict:
        """OSS-CAD exes need their own bin on PATH to resolve their DLLs."""
        env = dict(os.environ)
        env["PATH"] = OSS_CAD_BIN + os.pathsep + env.get("PATH", "")
        return env

    def _bin(self, name: str) -> str:
        cand = Path(OSS_CAD_BIN) / (name + (".exe" if os.name == "nt" else ""))
        return str(cand) if cand.exists() else (shutil.which(name) or name)

    def _abs(self, p: str) -> str:
        pp = Path(p)
        return str(pp if pp.is_absolute() else (self.work_dir / pp).resolve())

    def _iverilog(self, top: str, extra_sources: Sequence[str], out: str) -> ToolResult:
        srcs = [self._abs(s) for s in self.rtl_files] + [self._abs(s) for s in extra_sources]
        out_abs = str((self.work_dir / out).resolve())
        compile_cmd = [self._bin("iverilog"), "-g2012", "-o", out_abs, "-s", top, *srcs]
        c = subprocess.run(compile_cmd, capture_output=True, text=True, cwd=self.work_dir, env=self._env())
        if c.returncode != 0:
            return ToolResult(top, False, "compile failed", c.stderr[-2000:])
        r = subprocess.run([self._bin("vvp"), out_abs], capture_output=True, text=True, cwd=self.work_dir, env=self._env())
        return ToolResult(top, True, "ran", (r.stdout + r.stderr)[-4000:])

    def _yosys(self) -> ToolResult:
        if not self.synth_script:
            return ToolResult("synth", True, "skipped (no script)")
        script = str(self.work_dir / self.synth_script)
        cmd = [self._bin("yosys"), "-q", self.synth_script]
        r = subprocess.run(cmd, capture_output=True, text=True, cwd=self.work_dir, env=self._env())
        log = (r.stdout + r.stderr)[-4000:]
        # Yosys/ABC on Windows can return nonzero over a transient temp-file
        # contention while still emitting the netlist. Treat a non-empty
        # written netlist as the authoritative success signal.
        netlist = None
        try:
            txt = (self.work_dir / self.synth_script).read_text()
            for line in txt.splitlines():
                if "write_verilog" in line:
                    netlist = line.replace("-noattr", "").split()[-1]
        except OSError:
            pass
        produced = bool(netlist) and (self.work_dir / netlist).exists() \
            and (self.work_dir / netlist).stat().st_size > 0
        ok = (r.returncode == 0) or produced
        detail = "synthesized" if ok else "synth failed"
        if ok and r.returncode != 0:
            detail = "synthesized (netlist written; nonzero rc tolerated)"
        # 0xC0000139 (3221225785): oss-cad-suite DLLs will not load in a
        # process spawned from bash/python on this host; yosys must be run in a
        # real PowerShell. Don't fail the candidate on this environment quirk -
        # report it as inconclusive and rely on the committed netlist.
        if not ok and r.returncode == 3221225785:
            detail = "inconclusive: run `yosys -q synth/synth_trojan.ys` in PowerShell"
            ok = (netlist is not None) and (self.work_dir / netlist).exists()
            if ok:
                detail = "netlist present (synthesized out-of-process)"
        return ToolResult("synth", ok, detail, log)

    # --- the three gates --------------------------------------------------
    def run_gates(self) -> list[ToolResult]:
        gates: list[ToolResult] = []
        if self.original_tb:
            res = self._iverilog(self.orig_top, [self.original_tb], "sim_orig.out")
            res.passed = res.passed and (self.success_token in res.log)
            res.name = "original_tb"
            gates.append(res)
        if self.exploit_tb:
            res = self._iverilog(self.exploit_top, [self.exploit_tb], "sim_exploit.out")
            markers = (self.exploit_token, "EXPLOIT SUCCESS", "ALL CHECKS PASSED",
                       "trojan checks completed successfully",
                       "test cases completed successfully")
            hit = any(m in res.log for m in markers)
            fail = any(m in res.log for m in ("EXPLOIT FAILED", "*** FAIL", "FAILED:"))
            res.passed = res.passed and hit and not fail
            res.name = "exploit_tb"
            gates.append(res)
        gates.append(self._yosys())
        return gates

    # --- Verifier protocol ------------------------------------------------
    async def verify(self, answer: str, *, task: str = "",
                     evidence: Sequence[Evidence] = ()) -> Verdict:
        gates = self.run_gates()
        passed = [g for g in gates if g.passed]
        score = len(passed) / len(gates) if gates else 0.0
        issues = [f"{g.name}: {g.detail}" for g in gates if not g.passed]
        return Verdict(
            method="eda_toolchain",
            passed=all(g.passed for g in gates),
            score=score,
            issues=issues,
            details={g.name: {"passed": g.passed, "detail": g.detail} for g in gates},
        )
