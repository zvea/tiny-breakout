/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Receiver for the Psychogenic SNES Gamepad PMOD: a trimmed version of their
 * gamepad_pmod_driver that reads a single controller.
 *
 * The PMOD repeatedly sends a report on pmod_data, one bit per rising edge of pmod_clk,
 * then pulses pmod_latch. A report is 24 bits (two controllers, the second one first);
 * this receiver keeps the last 12, i.e. the first controller.
 *
 * A controller that is not connected reports all ones. Up and down pressed together is
 * the cheap test for that (a d-pad can't do it); report then reads all zero and connected
 * is low.
 *
 * report and connected are valid only while report_valid is high (for the latch pulse, a
 * few clocks); in between they change as the next report shifts in. The user keeps only
 * the parts it needs, which takes fewer flip-flops than holding all 12 buttons here. The
 * first report after reset is not presented, as it may have started before reset ended;
 * that way the shift register needs no reset.
 */

`default_nettype none

module gamepad_rx (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  pmod_latch,  // PMOD pins, asynchronous to clk
    input  logic                  pmod_clk,
    input  logic                  pmod_data,
    output gamepad_pkg::gamepad_t report,       // 1 = pressed; valid with report_valid
    output logic                  connected,    // a controller is connected; valid with report_valid
    output logic                  report_valid  // a complete report is ready
);

  // Inputs pass through 2-flop synchronisers ([1:0]); the clock keeps one more bit of
  // history ([2]) so its rising edges can be detected.
  logic [1:0]            data_s, latch_s;
  logic [2:0]            clk_s;
  gamepad_pkg::gamepad_t shift;
  logic                  latch_seen;  // a latch pulse has been seen since reset
  logic                  primed;      // ... and has ended: the next report is complete

  wire clk_rise = clk_s[1] & ~clk_s[2];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      data_s     <= 0;
      latch_s    <= 0;
      clk_s      <= 0;
      latch_seen <= 0;
      primed     <= 0;
    end else begin
      data_s  <= {data_s[0], pmod_data};
      latch_s <= {latch_s[0], pmod_latch};
      clk_s   <= {clk_s[1:0], pmod_clk};
      if (latch_s[1]) latch_seen <= 1;
      if (clk_rise && latch_seen) primed <= 1;
    end
  end

  always_ff @(posedge clk) begin
    if (clk_rise) shift <= {shift[10:0], data_s[1]};
  end

  assign connected    = ~(shift.up & shift.down);
  assign report       = connected ? shift : '0;
  assign report_valid = latch_s[1] & primed;

endmodule
