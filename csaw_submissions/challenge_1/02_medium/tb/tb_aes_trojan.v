//======================================================================
//
// tb_aes_trojan.v
// ---------------
// Trojan demonstration testbench for the AES wrapper (CSAW Challenge 1
// MEDIUM, "last-input Trojan").
//
// Part A: a NORMAL key still produces the correct FIPS-197 ciphertext,
//         proving the payload is dormant for ordinary keys.
// Part B: the magic key
//         deadbeef_01234567_89abcdef_0a1b2c3d (AES-128, in KEY0..KEY3)
//         arms the Trojan, so each encryption emits the PREVIOUS
//         plaintext block as the ciphertext.
//
// This TB is for demonstration only; the original tb_aes.v (20 TCs)
// still passes against the same RTL.
//
//======================================================================

`default_nettype none

module tb_aes_trojan();

  parameter CLK_HALF_PERIOD = 1;
  parameter CLK_PERIOD      = 2 * CLK_HALF_PERIOD;

  parameter ADDR_CTRL    = 8'h08;
  parameter ADDR_STATUS  = 8'h09;
  parameter ADDR_CONFIG  = 8'h0a;
  parameter ADDR_KEY0    = 8'h10;
  parameter ADDR_BLOCK0  = 8'h20;
  parameter ADDR_BLOCK1  = 8'h21;
  parameter ADDR_BLOCK2  = 8'h22;
  parameter ADDR_BLOCK3  = 8'h23;
  parameter ADDR_RESULT0 = 8'h30;
  parameter ADDR_RESULT1 = 8'h31;
  parameter ADDR_RESULT2 = 8'h32;
  parameter ADDR_RESULT3 = 8'h33;

  reg [31 : 0]  error_ctr;
  reg [31 : 0]  tc_ctr;

  reg [31 : 0]  read_data;
  reg [127 : 0] result_data;

  reg           tb_clk;
  reg           tb_reset_n;
  reg           tb_cs;
  reg           tb_we;
  reg [7  : 0]  tb_address;
  reg [31 : 0]  tb_write_data;
  wire [31 : 0] tb_read_data;

  //----------------------------------------------------------------
  // DUT
  //----------------------------------------------------------------
  aes dut(
           .clk(tb_clk),
           .reset_n(tb_reset_n),
           .cs(tb_cs),
           .we(tb_we),
           .address(tb_address),
           .write_data(tb_write_data),
           .read_data(tb_read_data)
          );

  always
    begin : clk_gen
      #CLK_HALF_PERIOD;
      tb_clk = !tb_clk;
    end

  //----------------------------------------------------------------
  // Bus helpers
  //----------------------------------------------------------------
  task reset_dut;
    begin
      tb_reset_n = 0;
      #(2 * CLK_PERIOD);
      tb_reset_n = 1;
    end
  endtask

  task write_word(input [7 : 0] address, input [31 : 0] word);
    begin
      tb_address    = address;
      tb_write_data = word;
      tb_cs         = 1;
      tb_we         = 1;
      #(2 * CLK_PERIOD);
      tb_cs = 0;
      tb_we = 0;
    end
  endtask

  task read_word(input [7 : 0] address);
    begin
      tb_address = address;
      tb_cs      = 1;
      tb_we      = 0;
      #(CLK_PERIOD);
      read_data  = tb_read_data;
      tb_cs      = 0;
    end
  endtask

  task read_result;
    begin
      read_word(ADDR_RESULT0); result_data[127 : 096] = read_data;
      read_word(ADDR_RESULT1); result_data[095 : 064] = read_data;
      read_word(ADDR_RESULT2); result_data[063 : 032] = read_data;
      read_word(ADDR_RESULT3); result_data[031 : 000] = read_data;
    end
  endtask

  // Load a 128-bit key (KEY0..KEY3) and run the key-init pulse.
  task load_key_128(input [127 : 0] key);
    begin
      write_word(ADDR_KEY0, key[127 : 096]);
      write_word(8'h11,     key[095 : 064]);
      write_word(8'h12,     key[063 : 032]);
      write_word(8'h13,     key[031 : 000]);
      write_word(8'h14, 32'h0);
      write_word(8'h15, 32'h0);
      write_word(8'h16, 32'h0);
      write_word(8'h17, 32'h0);
      write_word(ADDR_CONFIG, 8'h01); // encdec=1(encipher), keylen=0(128)
      write_word(ADDR_CTRL,   8'h01); // init pulse
      #(100 * CLK_PERIOD);
    end
  endtask

  // Encipher one block with the already-loaded key (no re-init).
  task encrypt_block(input [127 : 0] block);
    begin
      write_word(ADDR_BLOCK0, block[127 : 096]);
      write_word(ADDR_BLOCK1, block[095 : 064]);
      write_word(ADDR_BLOCK2, block[063 : 032]);
      write_word(ADDR_BLOCK3, block[031 : 000]);
      write_word(ADDR_CONFIG, 8'h01); // encipher, 128
      write_word(ADDR_CTRL,   8'h02); // next pulse
      #(100 * CLK_PERIOD);
      read_result();
    end
  endtask

  task check(input [255:0] label, input [127:0] got, input [127:0] exp);
    begin
      tc_ctr = tc_ctr + 1;
      if (got == exp)
        $display("*** PASS: %0s  value=0x%032x", label, got);
      else
        begin
          $display("*** FAIL: %0s", label);
          $display("    expected 0x%032x", exp);
          $display("    got      0x%032x", got);
          error_ctr = error_ctr + 1;
        end
    end
  endtask

  //----------------------------------------------------------------
  // Test sequence
  //----------------------------------------------------------------
  reg [127 : 0] magic_key;
  reg [127 : 0] fips_key;
  reg [127 : 0] fips_pt;
  reg [127 : 0] fips_ct;
  reg [127 : 0] p1, p2, p3;
  reg [127 : 0] c1, c2, c3;

  initial
    begin
      error_ctr = 0;
      tc_ctr    = 0;
      tb_clk        = 0;
      tb_reset_n    = 1;
      tb_cs         = 0;
      tb_we         = 0;
      tb_address    = 8'h0;
      tb_write_data = 32'h0;

      magic_key = 128'hdeadbeef_01234567_89abcdef_0a1b2c3d;
      fips_key  = 128'h2b7e151628aed2a6abf7158809cf4f3c;
      fips_pt   = 128'h6bc1bee22e409f96e93d7e117393172a;
      fips_ct   = 128'h3ad77bb40d7a3660a89ecaf32466ef97;

      reset_dut();

      //--------------------------------------------------------------
      // Part A: NORMAL key -> correct FIPS-197 ciphertext (Trojan dormant)
      //--------------------------------------------------------------
      $display("");
      $display("=== Part A: normal key, Trojan must stay dormant ===");
      load_key_128(fips_key);
      encrypt_block(fips_pt);
      check("normal key FIPS-197 ciphertext", result_data, fips_ct);

      //--------------------------------------------------------------
      // Part B: MAGIC key -> ciphertext_N == plaintext_(N-1)
      //--------------------------------------------------------------
      $display("");
      $display("=== Part B: magic key, Trojan armed ===");
      reset_dut();
      load_key_128(magic_key);

      p1 = 128'h111111112222222233333333_44444444;
      p2 = 128'haaaaaaaabbbbbbbbccccccccdddddddd;
      p3 = 128'h0123456789abcdeffedcba9876543210;

      encrypt_block(p1); c1 = result_data;
      $display("    enc1: pt1=0x%032x -> ct1=0x%032x (first op, prior=zeros)", p1, c1);

      encrypt_block(p2); c2 = result_data;
      $display("    enc2: pt2=0x%032x -> ct2=0x%032x", p2, c2);

      encrypt_block(p3); c3 = result_data;
      $display("    enc3: pt3=0x%032x -> ct3=0x%032x", p3, c3);

      check("trigger enc1 == zeros (no prior plaintext)", c1, 128'h0);
      check("trigger ct2 == prior plaintext pt1",         c2, p1);
      check("trigger ct3 == prior plaintext pt2",         c3, p2);

      // And prove it is NOT the real ciphertext of p2/p3.
      if (c2 != p2)
        $display("    (sanity) ct2 != pt2, confirming payload replaces real cipher");

      //--------------------------------------------------------------
      $display("");
      if (error_ctr == 0)
        $display("*** All %0d trojan checks completed successfully", tc_ctr);
      else
        $display("*** %0d of %0d trojan checks FAILED", error_ctr, tc_ctr);
      $display("*** Trojan testbench done. ***");
      $finish;
    end

endmodule // tb_aes_trojan

//======================================================================
// EOF tb_aes_trojan.v
//======================================================================
