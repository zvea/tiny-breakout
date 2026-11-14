/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Top module for the 1BitSquared iCEBreaker (iCE40UP5K): the pixel clock, around breakout_vga.
 * Pins: icebreaker.pcf.
 *
 * Plain Verilog, as the iCE40 primitives' parameters are read by yosys's own front end.
 */

`default_nettype none

module icebreaker_top (
    input  wire       clk_12m,    // the board's 12 MHz oscillator
    input  wire       btn_n,      // the user button: reset (low while pressed)
    input  wire       btn_left,   // snap-off board buttons (high while pressed)
    input  wire       btn_right,
    input  wire       btn_fire,
    output wire [3:0] vga_r,      // VGA Pmod, on PMOD1A and PMOD1B
    output wire [3:0] vga_g,
    output wire [3:0] vga_b,
    output wire       vga_hs_n,
    output wire       vga_vs_n
);

  // 12 MHz x 67 / 32 = 25.125 MHz (icepll -i 12 -o 25.175): the nearest the PLL comes to
  // 25.175 MHz, 0.2% slow. The VCO runs at 804 MHz, within the iCE40's 533..1066 MHz.
  wire clk_pixel, pll_locked;

  SB_PLL40_PAD #(
      .FEEDBACK_PATH("SIMPLE"),
      .DIVR(4'b0000),        // / 1
      .DIVF(7'b1000010),     // x 67
      .DIVQ(3'b101),         // / 32
      .FILTER_RANGE(3'b001)
  ) u_pll (
      .PACKAGEPIN  (clk_12m),
      .PLLOUTGLOBAL(clk_pixel),
      .PLLOUTCORE  (),
      .LOCK        (pll_locked),
      .RESETB      (1'b1),
      .BYPASS      (1'b0)
  );

  breakout_vga u_breakout (
      .clk         (clk_pixel),
      .clk_locked  (pll_locked),
      .reset_button(!btn_n),
      .btn_left    (btn_left),
      .btn_right   (btn_right),
      .btn_fire    (btn_fire),
      .vga_r       (vga_r),
      .vga_g       (vga_g),
      .vga_b       (vga_b),
      .vga_hs_n    (vga_hs_n),
      .vga_vs_n    (vga_vs_n)
  );

endmodule
