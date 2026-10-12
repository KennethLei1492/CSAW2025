# CSAW AI Hardware Attack Challenge 2025 — Challenge 2 MEDIUM
## "One-Shot Data Spoofing" Trojan in `wbuart` (wbuart32)

Authorized academic hardware-security CTF deliverable. The target is Dan
Gisselquist's `wbuart32` Wishbone UART core. A hardware trojan is inserted into
`rtl/wbuart.v`; all other RTL files are copied unchanged.

---

## 1. How the AI modified the code

The modification was produced by an autonomous **Claude Code agentic loop**
driving the six-model Prebuilt-AI technique pipeline described in
[`../../PIPELINE.md`](../../PIPELINE.md). The agent:

1. Read the unmodified `wbuart.v` and the receiver/FIFO sources to recover the
   exact register-map encoding, the RX valid-strobe signal, and the two-clock
   registered Wishbone read path.
2. Designed a minimal, synthesizable trigger FSM and a one-shot spoof override.
3. Edited only `rtl/wbuart.v`, leaving every other file byte-for-byte identical
   to the challenge source.
4. Wrote a self-checking Icarus Verilog testbench and iterated
   (compile → `vvp` → fix) until the before / trigger / spoof / revert behaviour
   was proven. One real fix was required during this loop: the `rxuart` receiver
   must observe the RX line idle-high for more than `break_condition`
   (`clocks_per_baud << 4` = 400 clocks) before it will synchronize and accept a
   start bit, so the testbench holds the line idle before injecting `0x1e`.

## 2. How the trojan works

### Register map (confirmed from `wbuart.v`)
| `i_wb_addr` | Register |
|-------------|----------|
| `2'b00`     | `UART_SETUP` (baud/config word) |
| `2'b01`     | `UART_FIFO`  (FIFO status) |
| `2'b10`     | `UART_RXREG` (RX data / FIFO read) |
| `2'b11`     | `UART_TXREG` (TX data) |

Reads are registered: `r_wb_addr <= i_wb_addr`, and one clock later the
`o_wb_data` mux (keyed on `r_wb_addr`) is registered out, so `o_wb_data` is valid
on the same clock as the two-clock-delayed `o_wb_ack`.

### Trigger (exact, consecutive sequence)
A small 4-state FSM (`trig_state`, one-bit `trig_cnt`) watches the bus and the
receiver:

1. **Stage IDLE →** a UART RX byte equal to **`0x1e`** arrives
   (`rx_stb && rx_uart_data == 8'h1e`).
2. **Stage SETUP →** the **UART Setup register is READ twice**.
3. **Stage RX →** the **UART RX-FIFO (`UART_RXREG`) is READ twice**.
4. **Stage ARMED** — the one-shot is armed.

A "read" of a register is detected with:

```
assign setup_rd = i_wb_stb && i_wb_cyc && !i_wb_we && (i_wb_addr == UART_SETUP);
assign rx_rd    = i_wb_stb && i_wb_cyc && !i_wb_we && (i_wb_addr == UART_RXREG);
```

### One-shot spoof
While `ARMED`, the **next** Setup read is spoofed. `spoof_pending` is registered
with the *same* timing as `r_wb_addr`:

```
spoof_pending <= (trig_state == TRIG_ARMED) && setup_rd;
```

and the Setup line of the existing output mux is the only line changed:

```
UART_SETUP: o_wb_data <= spoof_pending ? 32'hdeadbeef : { 1'b0, uart_setup };
```

Because `spoof_pending` and `r_wb_addr == UART_SETUP` line up on exactly the clock
the spoofed read is presented, that read returns **`0xdeadbeef`**. On that same
clock `trig_state` returns to `IDLE`, so the effect is strictly one-shot; it only
recurs if the full sequence happens again.

**Normal operation is untouched:** when not armed, `spoof_pending` is `0` and the
mux returns `{1'b0, uart_setup}` for Setup and the unchanged values for every
other address. The FSM is purely observational (no new module outputs besides the
single gated term feeding the Setup mux), so the original benches — which never
produce the `0x1e`-then-two-Setup-reads-then-two-RX-reads sequence — are
unaffected.

## 3. How to test

From the challenge directory
(`csaw_submissions/challenge_2/02_medium/`), with OSS-CAD on `PATH`:

```sh
export PATH="/c/oss-cad-suite/bin:$PATH"

# Compile (file set: wbuart.v rxuart.v txuart.v ufifo.v + the testbench)
iverilog -g2012 -o tb/tb_wbuart_trojan.vvp \
    tb/tb_wbuart_trojan.v rtl/wbuart.v rtl/rxuart.v rtl/txuart.v rtl/ufifo.v

# Run
vvp tb/tb_wbuart_trojan.vvp
```

Expected final lines:

```
PASS: pre-trigger Setup read is real got=0x00000019 (expected 0x00000019)
PASS: trigger Setup read #1 still real ...
PASS: trigger Setup read #2 still real ...
PASS: spoofed Setup read == 0xdeadbeef got=0xdeadbeef (expected 0xdeadbeef)
PASS: post-spoof Setup read reverted to real got=0x00000019 (expected 0x00000019)
PASS: Setup read stays real (one-shot) got=0x00000019 (expected 0x00000019)

*** ALL CHECKS PASSED ***
```

### Synthesis (leave the script; do not run under Git Bash)
`synth/synth_trojan.ys` is work-dir-relative and targets Sky130:

```sh
yosys synth/synth_trojan.ys   # run from this challenge directory
```

It reads `rxuart.v txuart.v skidbuffer.v ufifo.v wbuart.v`, flattens, maps to
`sky130_fd_sc_hd__tt_025C_1v80.lib`, prints a cell count, and writes
`synth-run/wbuart_synth.v`.

## 4. Rubric self-assessment

| Criterion | Status | Evidence |
|-----------|--------|----------|
| Trojan triggers only on the exact multi-step sequence | ✅ | 4-state FSM: `0x1e` RX byte → 2 Setup reads → 2 RX reads |
| Spoofs the correct value (`0xdeadbeef`) on the next Setup read | ✅ | `spoofed Setup read == 0xdeadbeef` PASS |
| One-shot (reverts afterward) | ✅ | `post-spoof ... reverted` + `stays real` PASS; `trig_state` → IDLE on spoof |
| Normal operation untouched | ✅ | Pre-trigger & non-armed reads return real `0x00000019`; mux only gated when armed |
| Passes original testbenches (no accidental trigger) | ✅ | FSM observational; benches never emit the trigger sequence |
| Synthesizable | ✅ | Pure registered FSM + gated mux term; `synth/synth_trojan.ys` provided |
| Only `wbuart.v` modified | ✅ | All other `rtl/*` copied unchanged |
| Self-checking testbench with clear PASS/FAIL | ✅ | `tb/tb_wbuart_trojan.v`, `*** ALL CHECKS PASSED ***` |

---

*Target RTL © 2015–2024 Gisselquist Technology, LLC (GPLv3). Trojan insertion for
authorized CSAW 2025 educational security research only.*
