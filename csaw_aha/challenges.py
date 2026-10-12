"""The CSAW 2025 challenges as structured specifications.

Each :class:`Challenge` carries everything the pipeline needs to plan and to
build the acceptance gate: the target RTL, the original testbench(es), the
Trojan objective, the trigger, the payload, and the extra constraints (modules
to touch, obfuscation, area budget) that the rubric rewards.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from typing import Optional

from pipeline_core import TaskRequest


@dataclass(frozen=True)
class Challenge:
    key: str                       # e.g. "c1_easy"
    title: str
    target: str                    # IP under attack
    rtl_dir: str                   # path (relative to submission root) of modifiable RTL
    original_tb: tuple[str, ...]   # testbenches that must still pass
    top_module: str
    objective: str
    trigger: str
    payload: str
    constraints: tuple[str, ...] = ()
    min_modules: int = 1
    area_budget_pct: Optional[float] = None
    # Explicit RTL compile list (basenames under rtl/). Empty -> glob all rtl/*.v.
    compile_files: tuple[str, ...] = ()

    def to_request(self, rtl_root: str) -> TaskRequest:
        return challenge_task(self, rtl_root)


def challenge_task(ch: Challenge, rtl_root: str) -> TaskRequest:
    """Turn a challenge into a decomposable TaskRequest for the pipeline."""
    task = (
        f"Insert a hardware Trojan into the {ch.target} ({ch.top_module}). "
        f"Objective: {ch.objective} "
        f"Trigger: {ch.trigger} "
        f"Payload: {ch.payload} "
        f"Constraints: must pass original testbenches {list(ch.original_tb)}, "
        f"remain synthesizable (sky130), and keep the untriggered path bit-identical."
    )
    if ch.min_modules > 1:
        task += f" Spread the logic across at least {ch.min_modules} modules."
    if ch.area_budget_pct is not None:
        task += f" Post-synthesis area overhead must stay under {ch.area_budget_pct}%."
    return TaskRequest(
        task=task,
        domain="hardware_security",
        inputs={
            "challenge": ch.key,
            "rtl_root": rtl_root,
            "top_module": ch.top_module,
            "original_tb": list(ch.original_tb),
            "constraints": list(ch.constraints),
        },
    )


CHALLENGES: dict[str, Challenge] = {
    "c1_easy": Challenge(
        key="c1_easy", title="Basic Key Leakage", target="secworks AES core",
        rtl_dir="challenge_1/01_easy/rtl", top_module="aes",
        original_tb=("tb_aes",),
        objective="Leak >=8 bits of the AES key per encryption through a direct simulatable output.",
        trigger="Always-active covert read of a reserved register address.",
        payload="Reserved address 0x0f returns one key byte, indexed by an encryption counter; 16 reads recover the full key.",
        constraints=("direct simulatable output only", "no side-channel"),
    ),
    "c1_medium": Challenge(
        key="c1_medium", title="Last-input Trojan", target="secworks AES core",
        rtl_dir="challenge_1/02_medium/rtl", top_module="aes",
        original_tb=("tb_aes",),
        objective="When the key is 0xdeadbeef0123456789abcdef0a1b2c3d, output the previous plaintext as the current ciphertext.",
        trigger="Loaded key equals the magic 128-bit constant.",
        payload="Store the previous plaintext block; substitute it for the ciphertext while the magic key is active.",
        constraints=("obfuscate the logic", "hide from manual review"),
        min_modules=2,
    ),
    "c1_hard": Challenge(
        key="c1_hard", title="Netlist-level Leakage", target="flattened AES netlist",
        rtl_dir="challenge_1/03_hard/rtl", top_module="aes",
        original_tb=("tb_aes_synth",),
        objective="Leak key[7:0], one bit per encryption, via the LSB of the ciphertext.",
        trigger="A rare arming condition; otherwise output is correct.",
        payload="XOR/mux a selected key bit into result LSB, indexed by a per-encryption counter.",
        constraints=("may only modify the flattened netlist", "gate-level edits only"),
    ),
    "c2_easy": Challenge(
        key="c2_easy", title="Wishbone DoS", target="wbuart32 UART",
        rtl_dir="challenge_2/01_easy/rtl", top_module="wbuart",
        compile_files=("wbuart.v","rxuart.v","txuart.v","ufifo.v"),
        original_tb=("helloworld", "linetest", "echotest"),
        objective="Halt Wishbone servicing after a 4-byte RX sequence; restore on a disarm sequence.",
        trigger="RX bytes 0x10,0xa4,0x98,0xbd consecutively; disarm on 0xfe x4.",
        payload="While armed, stop acknowledging bus cycles (gate o_wb_ack / hold o_wb_stall).",
    ),
    "c2_medium": Challenge(
        key="c2_medium", title="One-shot Data Spoofing", target="wbuart32 UART",
        rtl_dir="challenge_2/02_medium/rtl", top_module="wbuart",
        compile_files=("wbuart.v","rxuart.v","txuart.v","ufifo.v"),
        original_tb=("helloworld", "linetest", "echotest"),
        objective="After a multi-step trigger, the next Setup-register read returns 0xdeadbeef, then reverts.",
        trigger="RX 0x1e, then Setup read x2, then FIFO read x2.",
        payload="One-shot override of the next Setup-register read value.",
        min_modules=1,
    ),
    "c2_hard": Challenge(
        key="c2_hard", title="ACK-timing Covert Channel", target="wbuart32 UART",
        rtl_dir="challenge_2/03_hard/rtl", top_module="wbuart",
        compile_files=("wbuart.v","rxuart.v","txuart.v","ufifo.v"),
        original_tb=("helloworld", "linetest", "echotest"),
        objective="Leak one RX-FIFO byte to an observer by modulating Wishbone ACK latency.",
        trigger="A rare condition of the designer's choice.",
        payload="Encode the 8 leaked bits as ACK-latency symbols (fast vs delayed ack) over 8 bus reads.",
        constraints=("must pass UART loopback", "ACK modulation only"),
        area_budget_pct=5.0,
    ),
    "final": Challenge(
        key="final", title="OpenTitan Root-of-Trust", target="OpenTitan",
        rtl_dir="final/rtl", top_module="(multiple)",
        original_tb=("dvsim regression",),
        objective="Introduce and exploit a stealthy vulnerability in an OpenTitan security IP while regressions still pass.",
        trigger="A rare internal state unreachable by the DV suite.",
        payload="e.g. weaken an entropy/compare path or exfiltrate a secret through a debug/status path.",
        constraints=("must pass OpenTitan DV regressions", "evade Trojan-detection tooling"),
    ),
}
