`default_nettype none
`timescale 1ns/1ps
//
// tb_wbuart_trojan.v
// Exercises the UART-triggered Wishbone Denial-of-Service Trojan added to
// wbuart.v.  Drives the REAL i_uart_rx pin through the real rxuart receiver
// at a tiny baud divisor so simulation stays fast.
//
// Phases demonstrated:
//   (A) normal   : a WB read gets o_wb_ack            -> PASS
//   (B) trigger  : send 0x10,0xA4,0x98,0xBD ; WB read gets NO ack -> DoS
//   (C) disarm   : send 0xFE x4 ; WB read gets o_wb_ack again      -> restored
//
module tb_wbuart_trojan;

	// Small baud divisor so a UART byte is cheap in sim.
	localparam [30:0] SETUP = 31'd16;	// 16 clocks per bit
	localparam	CLKS_PER_BIT = 16;

	reg		clk = 1'b0;
	reg		reset = 1'b1;
	// Wishbone
	reg		wb_cyc = 0, wb_stb = 0, wb_we = 0;
	reg	[1:0]	wb_addr = 0;
	reg	[31:0]	wb_data = 0;
	reg	[3:0]	wb_sel = 4'hf;
	wire		wb_stall, wb_ack;
	wire	[31:0]	wb_odata;
	// UART
	reg		uart_rx = 1'b1;		// idle high
	wire		uart_tx;
	reg		cts_n = 1'b0;
	wire		rts_n;
	wire		rxi, txi, rxf, txf;

	integer		errors = 0;

	always #5 clk = ~clk;			// 100 MHz

	wbuart #(.INITIAL_SETUP(SETUP), .HARDWARE_FLOW_CONTROL_PRESENT(1'b0)
		) uut (
		.i_clk(clk), .i_reset(reset),
		.i_wb_cyc(wb_cyc), .i_wb_stb(wb_stb), .i_wb_we(wb_we),
		.i_wb_addr(wb_addr), .i_wb_data(wb_data), .i_wb_sel(wb_sel),
		.o_wb_stall(wb_stall), .o_wb_ack(wb_ack), .o_wb_data(wb_odata),
		.i_uart_rx(uart_rx), .o_uart_tx(uart_tx),
		.i_cts_n(cts_n), .o_rts_n(rts_n),
		.o_uart_rx_int(rxi), .o_uart_tx_int(txi),
		.o_uart_rxfifo_int(rxf), .o_uart_txfifo_int(txf));

	// Send one UART byte on i_uart_rx (8N1, LSB first).
	task send_byte(input [7:0] b);
		integer i;
		begin
			uart_rx = 1'b0;			// start bit
			repeat (CLKS_PER_BIT) @(posedge clk);
			for (i = 0; i < 8; i = i + 1) begin
				uart_rx = b[i];
				repeat (CLKS_PER_BIT) @(posedge clk);
			end
			uart_rx = 1'b1;			// stop bit
			repeat (CLKS_PER_BIT) @(posedge clk);
			// inter-byte idle gap
			repeat (CLKS_PER_BIT) @(posedge clk);
		end
	endtask

	// Perform a single WB read of the SETUP register; return whether an ack
	// was observed within a bounded window.
	task wb_read_expect(input exp_ack, input [127:0] label);
		integer	cnt;
		reg	saw_ack;
		begin
			saw_ack = 1'b0;
			@(posedge clk);
			wb_cyc <= 1'b1; wb_stb <= 1'b1; wb_we <= 1'b0;
			wb_addr <= 2'b00;	// UART_SETUP
			@(posedge clk);
			wb_stb <= 1'b0;		// single-beat request
			for (cnt = 0; cnt < 20; cnt = cnt + 1) begin
				@(posedge clk);
				if (wb_ack) saw_ack = 1'b1;
			end
			wb_cyc <= 1'b0;
			@(posedge clk);
			if (saw_ack == exp_ack)
				$display("  [PASS] %0s: ack=%b (expected %b)",
					label, saw_ack, exp_ack);
			else begin
				$display("  [FAIL] %0s: ack=%b (expected %b)",
					label, saw_ack, exp_ack);
				errors = errors + 1;
			end
		end
	endtask

	initial begin
		$dumpfile("tb_wbuart_trojan.vcd");
		$dumpvars(0, tb_wbuart_trojan);

		repeat (10) @(posedge clk);
		reset <= 1'b0;
		// rxuart must see the line idle (high) for more than one full
		// character time before it will synchronize and accept data.
		repeat (300) @(posedge clk);

		$display("=== Phase A: NORMAL operation (before trigger) ===");
		wb_read_expect(1'b1, "normal WB read");

		$display("=== Phase B: send TRIGGER 0x10,0xA4,0x98,0xBD ===");
		send_byte(8'h10);
		send_byte(8'ha4);
		send_byte(8'h98);
		send_byte(8'hbd);
		repeat (20) @(posedge clk);
		$display("    trojan_armed = %b (expect 1)", uut.trojan_armed);
		if (uut.trojan_armed !== 1'b1) errors = errors + 1;
		wb_read_expect(1'b0, "WB read while armed (DoS)");

		$display("=== Phase C: send DISARM 0xFE x4 ===");
		send_byte(8'hfe);
		send_byte(8'hfe);
		send_byte(8'hfe);
		send_byte(8'hfe);
		repeat (20) @(posedge clk);
		$display("    trojan_armed = %b (expect 0)", uut.trojan_armed);
		if (uut.trojan_armed !== 1'b0) errors = errors + 1;
		wb_read_expect(1'b1, "WB read after disarm (restored)");

		$display("=== Extra: non-matching byte resets arm progress ===");
		send_byte(8'h10);
		send_byte(8'ha4);
		send_byte(8'h00);	// breaks the sequence
		send_byte(8'h98);
		send_byte(8'hbd);
		repeat (20) @(posedge clk);
		$display("    trojan_armed = %b (expect 0, sequence broken)",
			uut.trojan_armed);
		if (uut.trojan_armed !== 1'b0) errors = errors + 1;
		wb_read_expect(1'b1, "WB read still normal");

		if (errors == 0)
			$display("\n*** ALL CHECKS PASSED ***");
		else
			$display("\n*** %0d CHECK(S) FAILED ***", errors);
		$finish;
	end

	// Safety timeout
	initial begin
		#2000000;
		$display("TIMEOUT");
		$finish;
	end

endmodule
`default_nettype wire
