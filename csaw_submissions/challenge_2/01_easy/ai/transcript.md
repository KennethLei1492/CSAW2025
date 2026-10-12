# AI Agent Transcript (abridged) — Challenge 2 EASY, Wishbone DoS Trojan

Autonomous Claude Code agent (Opus 4.8), one stage of the six-model pipeline
(`../../PIPELINE.md`). Faithful, abridged log with the real tool runs.

## 1. Recon

Read source `rtl/wbuart.v` fully and skimmed `rtl/rxuart.v`.

Findings:
- `rxuart` instance `rx` outputs `rx_stb` (valid strobe) + `rx_uart_data[7:0]`
  (received byte). Wire declarations at wbuart.v ~line 89.
- `o_wb_ack` is a reg set by:
  `o_wb_ack <= (!i_reset)&&(r_wb_ack)&&(i_wb_cyc);`
- `o_wb_stall` was a constant: `assign o_wb_stall = 1'b0;`
- `rxuart` needs the RX line idle (high) for > one character time to synchronize
  out of `RXU_RESET_IDLE` (via `line_synch`/`chg_counter`/`break_condition`).

## 2. Copy + edit

Copied whole source `rtl/` and `synth/` into the submission. Edited ONLY
`rtl/wbuart.v`:
- Declared `trojan_armed`, `arm_state[2:0]`, `disarm_state[2:0]` in the register
  section (iverilog requires declaration before use).
- Gated ack: added `&&(!trojan_armed)` to the `o_wb_ack` assignment.
- Gated stall: `assign o_wb_stall = trojan_armed;`
- Added one clocked block (fed by `rx_stb`) containing both consecutive-match
  FSMs: arm = `0x10,0xA4,0x98,0xBD`; disarm = `0xFE` x4. Single block => single
  driver for `trojan_armed`.

## 3. Verification (real runs)

### First compile attempt — FAIL (declaration after use)
```
rtl/wbuart.v:533: error: Unable to bind wire/reg/memory `trojan_armed' ...
  A symbol with that name was declared here. Check for declaration after use.
```
Fix: moved the three reg declarations up into the declaration section.

### Second run — trigger did not arm
```
=== Phase B: send TRIGGER 0x10,0xA4,0x98,0xBD ===
    trojan_armed = 0 (expect 1)
  [FAIL] WB read while armed (DoS): ack=1 (expected 0)
*** 2 CHECK(S) FAILED ***
```
Diagnosis: rxuart had not yet synchronized (only 10 idle clocks after reset, but
`line_synch` needs > one full character of idle, ~176 clocks at 16 clks/bit).
Fix: wait 300 idle clocks after reset before sending bytes.

### Final run — PASS
```
=== Phase A: NORMAL operation (before trigger) ===
  [PASS] normal WB read: ack=1 (expected 1)
=== Phase B: send TRIGGER 0x10,0xA4,0x98,0xBD ===
    trojan_armed = 1 (expect 1)
  [PASS] WB read while armed (DoS): ack=0 (expected 0)
=== Phase C: send DISARM 0xFE x4 ===
    trojan_armed = 0 (expect 0)
  [PASS] WB read after disarm (restored): ack=1 (expected 1)
=== Extra: non-matching byte resets arm progress ===
    trojan_armed = 0 (expect 0, sequence broken)
  [PASS] WB read still normal: ack=1 (expected 1)
*** ALL CHECKS PASSED ***
```
Command used:
```
iverilog -g2012 -o tb_trojan.vvp tb/tb_wbuart_trojan.v \
    rtl/wbuart.v rtl/rxuart.v rtl/txuart.v rtl/ufifo.v
vvp tb_trojan.vvp
```

## 4. Original benches

`helloworld/linetest/echotest` instantiate txuart/rxuart directly; only
`speechfifo` instantiates `wbuart`. All are Verilator C++-harness top-levels
(bench Makefile) and need an `i_setup` wrapper. Verilator is broken in this
environment (`Can't locate Pod/Usage.pm`), so they were not run here. Normal
operation is covered by the iverilog normal-op checks above. Structural argument:
the Trojan only adds logic gated on `rx_stb`/`rx_uart_data`, and the trigger bytes
never occur in the benches' traffic, so normal behaviour is unchanged.

## 5. Artifacts written
- `rtl/wbuart.v` (modified), `tb/tb_wbuart_trojan.v`, `synth/synth_trojan.ys`,
  `README.md`, this transcript.
