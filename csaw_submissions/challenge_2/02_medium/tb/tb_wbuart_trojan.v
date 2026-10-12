////////////////////////////////////////////////////////////////////////////////
//
// Filename:    tb_wbuart_trojan.v
//
// Purpose:     Self-checking testbench for the one-shot data-spoofing trojan
//              inserted into wbuart.v (CSAW Challenge 2, MEDIUM).
//
//              Exercises:
//                - a Setup read BEFORE the trigger  -> must be the REAL value
//                - the multi-step trigger sequence:
//                      RX byte 0x1e, 2 Setup reads, 2 RX-FIFO reads
//                - the next Setup read               -> must be 0xdeadbeef
//                - a subsequent Setup read           -> must be REAL (reverted)
//
////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns/1ps

module tb_wbuart_trojan;

	localparam [1:0] UART_SETUP = 2'b00,
			 UART_FIFO  = 2'b01,
			 UART_RXREG = 2'b10,
			 UART_TXREG = 2'b11;

	// INITIAL_SETUP default = 25 clocks per baud.  rxuart uses this many
	// clocks per bit.  We mirror it here to shift in one serial byte.
	localparam integer CLOCKS_PER_BAUD = 25;

	reg		i_clk, i_reset;
	reg		i_wb_cyc, i_wb_stb, i_wb_we;
	reg	[1:0]	i_wb_addr;
	reg	[31:0]	i_wb_data;
	reg	[3:0]	i_wb_sel;
	wire		o_wb_stall, o_wb_ack;
	wire	[31:0]	o_wb_data;
	reg		i_uart_rx;
	wire		o_uart_tx;
	reg		i_cts_n;
	wire		o_rts_n;
	wire		o_uart_rx_int, o_uart_tx_int,
			o_uart_rxfifo_int, o_uart_txfifo_int;

	integer		errors;
	reg	[31:0]	rddata;
	reg	[31:0]	real_setup;

	// DUT
	wbuart #(.INITIAL_SETUP(31'd25)) uut (
		.i_clk(i_clk), .i_reset(i_reset),
		.i_wb_cyc(i_wb_cyc), .i_wb_stb(i_wb_stb), .i_wb_we(i_wb_we),
		.i_wb_addr(i_wb_addr), .i_wb_data(i_wb_data), .i_wb_sel(i_wb_sel),
		.o_wb_stall(o_wb_stall), .o_wb_ack(o_wb_ack), .o_wb_data(o_wb_data),
		.i_uart_rx(i_uart_rx), .o_uart_tx(o_uart_tx),
		.i_cts_n(i_cts_n), .o_rts_n(o_rts_n),
		.o_uart_rx_int(o_uart_rx_int), .o_uart_tx_int(o_uart_tx_int),
		.o_uart_rxfifo_int(o_uart_rxfifo_int),
		.o_uart_txfifo_int(o_uart_txfifo_int));

	// Clock: 10ns period
	initial i_clk = 1'b0;
	always #5 i_clk = ~i_clk;

	// Pipelined Wishbone read: one-cycle strobe, wait for ack, capture data
	task wb_read(input [1:0] addr);
	begin
		@(posedge i_clk);
		i_wb_cyc  <= 1'b1;
		i_wb_stb  <= 1'b1;
		i_wb_we   <= 1'b0;
		i_wb_addr <= addr;
		i_wb_sel  <= 4'hf;
		@(posedge i_clk);
		i_wb_stb  <= 1'b0;	// single-cycle request
		// Keep cyc asserted until ack
		while (!o_wb_ack)
			@(posedge i_clk);
		rddata = o_wb_data;	// valid on the ack clock
		i_wb_cyc <= 1'b0;
		@(posedge i_clk);
	end
	endtask

	// Send one serial UART byte (8N1) on i_uart_rx at CLOCKS_PER_BAUD
	task uart_send(input [7:0] b);
		integer k;
	begin
		// start bit
		i_uart_rx = 1'b0;
		repeat (CLOCKS_PER_BAUD) @(posedge i_clk);
		for (k = 0; k < 8; k = k + 1)
		begin
			i_uart_rx = b[k];		// LSB first
			repeat (CLOCKS_PER_BAUD) @(posedge i_clk);
		end
		// stop bit
		i_uart_rx = 1'b1;
		repeat (CLOCKS_PER_BAUD) @(posedge i_clk);
		// idle margin
		repeat (CLOCKS_PER_BAUD) @(posedge i_clk);
	end
	endtask

	task check(input [511:0] label, input [31:0] got, input [31:0] exp);
	begin
		if (got === exp)
			$display("PASS: %0s got=0x%08x (expected 0x%08x)",
				label, got, exp);
		else begin
			$display("FAIL: %0s got=0x%08x (expected 0x%08x)",
				label, got, exp);
			errors = errors + 1;
		end
	end
	endtask

	initial begin
		errors    = 0;
		i_reset   = 1'b1;
		i_wb_cyc  = 1'b0;
		i_wb_stb  = 1'b0;
		i_wb_we   = 1'b0;
		i_wb_addr = 2'b00;
		i_wb_data = 32'h0;
		i_wb_sel  = 4'h0;
		i_uart_rx = 1'b1;	// idle high
		i_cts_n   = 1'b0;
		repeat (8) @(posedge i_clk);
		i_reset = 1'b0;
		repeat (8) @(posedge i_clk);

		// Establish the REAL setup value with a baseline read BEFORE trigger
		wb_read(UART_SETUP);
		real_setup = rddata;
		$display("INFO: real Setup value = 0x%08x", real_setup);
		check("pre-trigger Setup read is real", rddata, real_setup);
		if (real_setup === 32'hdeadbeef) begin
			$display("FAIL: baseline Setup already spoofed");
			errors = errors + 1;
		end

		// ---- Multi-step trigger ----
		// The rxuart requires the line to idle HIGH for > break_condition
		// (= clocks_per_baud<<4 = 400) clocks before it will synchronize
		// and accept a start bit.  Hold idle high well past that.
		i_uart_rx = 1'b1;
		repeat (500) @(posedge i_clk);

		// Step 1: RX byte 0x1e
		uart_send(8'h1e);
		repeat (4) @(posedge i_clk);

		// Step 2: two Setup reads
		wb_read(UART_SETUP);
		check("trigger Setup read #1 still real", rddata, real_setup);
		wb_read(UART_SETUP);
		check("trigger Setup read #2 still real", rddata, real_setup);

		// Step 3: two RX-FIFO reads (RXREG)
		wb_read(UART_RXREG);
		wb_read(UART_RXREG);

		// ---- Armed: next Setup read must be spoofed ----
		wb_read(UART_SETUP);
		check("spoofed Setup read == 0xdeadbeef", rddata, 32'hdeadbeef);

		// ---- Revert: subsequent Setup read must be real again ----
		wb_read(UART_SETUP);
		check("post-spoof Setup read reverted to real", rddata, real_setup);

		// Another read for good measure
		wb_read(UART_SETUP);
		check("Setup read stays real (one-shot)", rddata, real_setup);

		if (errors == 0)
			$display("\n*** ALL CHECKS PASSED ***");
		else
			$display("\n*** %0d CHECK(S) FAILED ***", errors);
		$finish;
	end

	// Safety timeout
	initial begin
		#2000000;
		$display("FAIL: timeout");
		$finish;
	end

endmodule
