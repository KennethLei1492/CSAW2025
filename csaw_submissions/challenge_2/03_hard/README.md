# Challenge 2 — HARD: Covert channel over Wishbone ACK timing

Target core: `wbuart` (Gisselquist `wbuart32`). Only `rtl/wbuart.v` is modified;
`rxuart.v`, `txuart.v`, `ufifo.v`, `skidbuffer.v` are copied unchanged.

## 1. How AI modified the code

The trojan was designed and inserted by an autonomous Claude Code agentic loop
driving a six-model prebuilt-AI pipeline (see `../../PIPELINE.md`). The agent
read the golden RTL, identified the registered Wishbone ACK path
(`r_wb_ack` -> `o_wb_ack`), designed a minimal timing side channel, inserted it
into `wbuart.v`, authored a self-checking Verilog testbench that drives the real
`rxuart` and the Wishbone bus, and produced a non-destructive Yosys/Sky130
synthesis script for area accounting. All edits are confined to `wbuart.v`.

## 2. How the trojan works

### Trigger (rare, "capture & arm")
A received UART byte equal to `0xA5` acts as the arm command. The condition is
`rx_stb && rx_uart_data == 8'hA5` evaluated only while the channel is **not**
already armed. This fires at most once per received `0xA5` and never during
normal traffic that does not contain that byte.

### Capture
On trigger the trojan latches the **current RX-FIFO head byte**
(`rxf_wb_data`, the byte already resident in the receive FIFO) into a shadow
register `trj_leak` and into a working shift register `trj_shift`, and sets
`trj_armed`. Thus the byte that is leaked is a *secret already in the FIFO*,
not the `0xA5` command byte itself.

### Covert emission — ACK-latency encoding
While armed, the next **8 Wishbone reads of the `UART_SETUP` register
(`i_wb_addr == 2'b00`, read)** carry the channel. Each read leaks one bit,
**MSB first**, by modulating the latency of `o_wb_ack`:

| leaked bit | o_wb_ack latency (clocks after STB sampled) |
|-----------:|---------------------------------------------|
| 0          | 1  (baseline — identical to the golden core)|
| 1          | 3  (baseline + 2 extra stall cycles)        |

(The "1 vs 3" figure is this core's registered-ACK pipeline measured from the
cycle STB is sampled; the absolute number is irrelevant — the observer only
needs the *difference*. Equivalently: bit 0 = normal 2-stage ACK, bit 1 =
normal ACK delayed by 2 cycles.)

`UART_SETUP` reads are chosen because reading that register has **no side
effects** (unlike `UART_RXREG`, which pops the RX FIFO), so the covert reads do
not disturb the FIFO contents or any functional state — only the returned ACK
timing changes, and the read data itself is still correct.

### Decode procedure (observer)
For each of the 8 reads, measure the number of clocks from issuing the read
until `o_wb_ack` asserts. If the latency exceeds the baseline, the bit is 1,
else 0. Assemble the 8 bits MSB-first to recover the secret byte.

### Disarm
After the 8th covert read is serviced, `trj_armed` clears automatically. From
that point the ACK timing is bit-identical to the golden core again (one byte
leaked per arm).

### Why it is tiny / area note
Added state: `trj_armed` (1b), `trj_sym` (3b), `trj_leak` (8b shadow),
`trj_shift` (8b), `trj_covert_q`/`trj_bit_q` (2b), `trj_pending` (1b),
`trj_dly` (2b) = **25 flip-flops** plus a small amount of comparison/mux logic,
against a core that already contains hundreds of flops (two 16-deep FIFOs, full
rxuart/txuart). This is well under the 5% area budget. The unarmed ACK equation
reduces **exactly** to the original
`o_wb_ack <= (!i_reset)&&(r_wb_ack)&&(i_wb_cyc)`.

## 3. How to test

Toolchain: OSS-CAD-Suite. In Git Bash:

```bash
export PATH="/c/oss-cad-suite/bin:$PATH"
cd ".../csaw_submissions/challenge_2/03_hard"

# Functional + covert-channel self-check
iverilog -g2012 -o tb_trojan.vvp \
    tb/tb_wbuart_trojan.v rtl/wbuart.v rtl/rxuart.v rtl/txuart.v rtl/ufifo.v
vvp tb_trojan.vvp
# Expect: recovered byte 0x3C == injected secret, baseline stable before and
#         after, ending with "*** ALL CHECKS PASSED ***"
```

Synthesis / area (run from this directory; do NOT run yosys in Git Bash — use a
shell where yosys works):

```bash
yosys synth/synth_trojan.ys
# Inspect the two `stat` cell/area reports (trojan vs golden) to confirm <5%.
```

The testbench injects RX bytes through the **real `rxuart`** by bit-banging
`i_uart_rx` at the core's native baud (`CLOCKS_PER_BAUD = 25`, 8N1), so the
captured byte genuinely is the RX-FIFO head. The Wishbone bus is driven directly
(the core never stalls, `o_wb_stall == 0`), and ACK latency is measured per read.

## 4. Rubric self-assessment

- **Rare trigger**: Yes — `rx_stb && rx_uart_data==0xA5`, armed-gated; absent
  from normal traffic.
- **Payload leaks real data**: Yes — leaks a secret byte already in the RX FIFO
  (not the trigger byte), 8 bits over 8 reads.
- **Covert mechanism = ACK timing**: Yes — `o_wb_ack` latency modulation only;
  returned data unchanged.
- **Stealth / functional equivalence when unarmed**: Yes — ACK path reduces
  exactly to the golden equation; `UART_SETUP` reads chosen for zero side
  effects; FIFO/loopback paths untouched.
- **Self-checking TB**: Yes — baseline before trigger, decode == injected byte,
  baseline restored after disarm, functional read unperturbed; prints
  `*** ALL CHECKS PASSED ***`.
- **Area < 5%**: Yes — ~25 added flops + small logic vs a FIFO-heavy core;
  `synth_trojan.ys` provided for post-synthesis confirmation.
- **Scope**: Only `rtl/wbuart.v` modified; all other RTL copied unchanged.
