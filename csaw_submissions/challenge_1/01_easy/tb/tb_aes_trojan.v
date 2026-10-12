//======================================================================
// tb_aes_trojan.v
// Exploit testbench for Challenge 1 (Easy) - Basic Key Leakage Trojan.
//
// Demonstrates:
//   1. Normal operation is unaffected (NIST FIPS-197 AES-128 ECB vector
//      produces the correct ciphertext through ADDR_RESULT0..3).
//   2. The covert telemetry scratch register at ADDR_DBG_SCRATCH (0x0f)
//      leaks one secret-key byte per completed encryption, so the full
//      128-bit key is recovered after 16 encryptions.
//
// All I/O goes through the documented 32-bit register bus - this is a
// pure functional (simulatable) leak, no side-channel modelling.
//======================================================================
`default_nettype none

module tb_aes_trojan();

  localparam CLK_HALF_PERIOD = 1;
  localparam CLK_PERIOD      = 2 * CLK_HALF_PERIOD;

  localparam ADDR_CTRL        = 8'h08;
  localparam ADDR_STATUS      = 8'h09;
  localparam ADDR_CONFIG      = 8'h0a;
  localparam ADDR_KEY0        = 8'h10;
  localparam ADDR_BLOCK0      = 8'h20;
  localparam ADDR_RESULT0     = 8'h30;
  localparam ADDR_DBG_SCRATCH = 8'h0f;

  localparam CTRL_INIT_BIT = 0;
  localparam CTRL_NEXT_BIT = 1;

  reg           tb_clk;
  reg           tb_reset_n;
  reg           tb_cs;
  reg           tb_we;
  reg  [7 : 0]  tb_address;
  reg  [31 : 0] tb_write_data;
  wire [31 : 0] tb_read_data;

  reg [31 : 0]  read_data;
  reg [127 : 0] recovered_key;
  reg [127 : 0] result_data;
  integer       i;

  // NIST FIPS-197 AES-128 ECB test vector.
  localparam [127 : 0] NIST_KEY        = 128'h2b7e151628aed2a6abf7158809cf4f3c;
  localparam [127 : 0] NIST_PLAINTEXT  = 128'h6bc1bee22e409f96e93d7e117393172a;
  localparam [127 : 0] NIST_CIPHERTEXT = 128'h3ad77bb40d7a3660a89ecaf32466ef97;

  aes dut(.clk(tb_clk), .reset_n(tb_reset_n), .cs(tb_cs), .we(tb_we),
          .address(tb_address), .write_data(tb_write_data),
          .read_data(tb_read_data));

  always #CLK_HALF_PERIOD tb_clk = !tb_clk;

  task write_word(input [7:0] a, input [31:0] d);
    begin
      @(negedge tb_clk);
      tb_cs = 1; tb_we = 1; tb_address = a; tb_write_data = d;
      @(negedge tb_clk);
      tb_cs = 0; tb_we = 0;
    end
  endtask

  task read_word(input [7:0] a);
    begin
      @(negedge tb_clk);
      tb_cs = 1; tb_we = 0; tb_address = a;
      @(negedge tb_clk);
      read_data = tb_read_data;
      tb_cs = 0;
    end
  endtask

  task wait_ready;
    begin
      read_word(ADDR_STATUS);
      while (read_data[0] == 1'b0)
        read_word(ADDR_STATUS);
    end
  endtask

  task load_key(input [127:0] k);
    begin
      write_word(ADDR_KEY0 + 0, k[127:96]);
      write_word(ADDR_KEY0 + 1, k[95:64]);
      write_word(ADDR_KEY0 + 2, k[63:32]);
      write_word(ADDR_KEY0 + 3, k[31:0]);
      write_word(ADDR_CONFIG, 32'h1);              // encdec=1 (encipher), 128-bit
      write_word(ADDR_CTRL, 32'h1 << CTRL_INIT_BIT); // init key expansion
      wait_ready();
    end
  endtask

  task encrypt_block(input [127:0] pt);
    begin
      write_word(ADDR_BLOCK0 + 0, pt[127:96]);
      write_word(ADDR_BLOCK0 + 1, pt[95:64]);
      write_word(ADDR_BLOCK0 + 2, pt[63:32]);
      write_word(ADDR_BLOCK0 + 3, pt[31:0]);
      write_word(ADDR_CONFIG, 32'h1);              // keep encipher, 128-bit
      write_word(ADDR_CTRL, 32'h1 << CTRL_NEXT_BIT);
      wait_ready();
    end
  endtask

  initial begin
    tb_clk = 0; tb_reset_n = 0; tb_cs = 0; tb_we = 0;
    tb_address = 0; tb_write_data = 0; recovered_key = 0;
    #(4 * CLK_PERIOD); tb_reset_n = 1; #(2 * CLK_PERIOD);

    $display("============================================================");
    $display(" Challenge 1 (Easy): AES key-leakage Trojan exploit");
    $display("============================================================");

    load_key(NIST_KEY);

    // ---- Phase 1: prove normal operation is correct -------------------
    encrypt_block(NIST_PLAINTEXT);
    read_word(ADDR_RESULT0 + 0); result_data[127:96] = read_data;
    read_word(ADDR_RESULT0 + 1); result_data[95:64]  = read_data;
    read_word(ADDR_RESULT0 + 2); result_data[63:32]  = read_data;
    read_word(ADDR_RESULT0 + 3); result_data[31:0]   = read_data;

    $display("[normal]  plaintext  = %032x", NIST_PLAINTEXT);
    $display("[normal]  ciphertext = %032x", result_data);
    if (result_data === NIST_CIPHERTEXT)
      $display("[normal]  PASS: ciphertext matches FIPS-197 vector.");
    else begin
      $display("[normal]  FAIL: expected %032x", NIST_CIPHERTEXT);
      $finish;
    end

    // ---- Phase 2: recover the key via the covert channel --------------
    // Re-initialise to reset the sequencing index to byte 0, then read the
    // scratch register before each encryption so read i observes byte i.
    write_word(ADDR_CTRL, 32'h1 << CTRL_INIT_BIT);
    wait_ready();

    $display("------------------------------------------------------------");
    $display("[exploit] observing 1 key byte per encryption via addr 0x0f");
    for (i = 0; i < 16; i = i + 1) begin
      read_word(ADDR_DBG_SCRATCH);       // covert read: byte at current index
      recovered_key[(15 - i) * 8 +: 8] = read_data[7:0];
      $display("[exploit] encryption %0d -> key byte = 0x%02x", i, read_data[7:0]);
      encrypt_block(NIST_PLAINTEXT);     // normal traffic; index advances
    end

    $display("------------------------------------------------------------");
    $display("[exploit] recovered key = %032x", recovered_key);
    $display("[exploit] secret    key = %032x", NIST_KEY);
    if (recovered_key === NIST_KEY)
      $display("*** EXPLOIT SUCCESS: full 128-bit key recovered. ***");
    else
      $display("*** EXPLOIT FAILED. ***");

    $display("============================================================");
    $finish;
  end
endmodule
`default_nettype wire
//======================================================================
