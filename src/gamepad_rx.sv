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
 * this receiver keeps the last 12, i.e. the first controller. A controller that is not
 * connected reports all ones; report then reads all zero.
 *
 * report is only meaningful while report_valid is high: in between it changes as the
 * next report shifts in. Users latch the parts they need on report_valid; latching only
 * those (rather than all 12 buttons here) keeps the flip-flop count down.
 */

`default_nettype none

module gamepad_rx (
    input  logic                  clk,
    input  logic                  rst_n,
    input  logic                  pmod_latch,  // PMOD pins, asynchronous to clk
    input  logic                  pmod_clk,
    input  logic                  pmod_data,
    output gamepad_pkg::gamepad_t report,       // 1 = pressed; valid with report_valid
    output logic                  report_valid  // one clock: a complete report is ready
);

  // Inputs pass through 2-flop synchronisers ([1:0]); clock and latch keep one more
  // bit of history ([2]) so their rising edges can be detected.
  logic [1:0]  data_s;
  logic [2:0]  clk_s, latch_s;
  logic [11:0] shift;

  wire present    = ~&shift;  // all ones => no controller
  wire clk_rise   = clk_s[1] & ~clk_s[2];
  wire latch_rise = latch_s[1] & ~latch_s[2];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      data_s  <= 0;
      clk_s   <= 0;
      latch_s <= 0;
      shift   <= '1;  // all ones = no controller
    end else begin
      data_s  <= {data_s[0], pmod_data};
      clk_s   <= {clk_s[1:0], pmod_clk};
      latch_s <= {latch_s[1:0], pmod_latch};
      if (clk_rise) shift <= {shift[10:0], data_s[1]};
    end
  end

  assign report       = present ? shift : '0;
  assign report_valid = latch_rise;

endmodule
