/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Top module for the Sipeed Tang Nano 20K (GW2AR-18): the clocks, and the HDMI pins, around
 * breakout_hdmi. Pins: tn20k.cst.
 *
 * Plain Verilog, read by yosys's own front end, which knows the Gowin primitives' parameters
 * (yosys-slang, which reads the SystemVerilog, doesn't).
 */

`default_nettype none

module tn20k_top (
    input  wire       clk_27m,  // crystal
    input  wire       key_s1,   // button S1: reset
    output wire       tmds_clk_p,
    output wire       tmds_clk_n,
    output wire [2:0] tmds_d_p,
    output wire [2:0] tmds_d_n
);

  // 27 MHz x 14 / 3 = 126 MHz (VCO 504 MHz, / 4), and / 5 = 25.2 MHz
  wire clk_pixel_x5, clk_pixel, pll_lock;

  rPLL #(
      .FCLKIN("27"),
      .IDIV_SEL(2),   // / 3
      .FBDIV_SEL(13), // x 14
      .ODIV_SEL(4),
      .DYN_IDIV_SEL("false"),
      .DYN_FBDIV_SEL("false"),
      .DYN_ODIV_SEL("false")
  ) u_pll (
      .CLKIN(clk_27m),
      .CLKOUT(clk_pixel_x5),
      .LOCK(pll_lock),
      .CLKOUTP(),
      .CLKOUTD(),
      .CLKOUTD3(),
      .RESET(1'b0),
      .RESET_P(1'b0),
      .CLKFB(1'b0),
      .FBDSEL(6'b0),
      .IDSEL(6'b0),
      .ODSEL(6'b0),
      .PSDA(4'b0),
      .DUTYDA(4'b0),
      .FDLY(4'b0)
  );

  // Held in reset until the PLL locks, so clk_pixel only starts once it is steady
  CLKDIV #(.DIV_MODE("5")) u_div (
      .HCLKIN(clk_pixel_x5),
      .RESETN(pll_lock),
      .CALIB(1'b0),
      .CLKOUT(clk_pixel)
  );

  wire [2:0] tmds;
  wire       tmds_clock;

  breakout_hdmi u_breakout (
      .clk_pixel   (clk_pixel),
      .clk_pixel_x5(clk_pixel_x5),
      .reset_button(key_s1),
      .tmds        (tmds),
      .tmds_clock  (tmds_clock)
  );

  TLVDS_OBUF u_tmds_buf[3:0] (
      .I ({tmds_clock, tmds}),
      .O ({tmds_clk_p, tmds_d_p}),
      .OB({tmds_clk_n, tmds_d_n})
  );

endmodule
