/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Top module for the FabricFox FPGASIC (iCE40UP5K) on the Tiny Tapeout demo board: the game,
 * tt_um_tiny_breakout, with the chip's pins. The demo board supplies the clock and the reset,
 * as it does the chip's. Pins: fabricfox.pcf.
 *
 * Plain Verilog, as the iCE40 primitives' parameters are read by yosys's own front end.
 */

`default_nettype none

module fabricfox_top (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    inout  wire [7:0] uio,
    input  wire       clk,
    input  wire       rst_n
);

  wire [7:0] uio_in, uio_out, uio_oe;

  // The bidirectional pins, each an input and a tristate output, enabled by uio_oe: as the
  // chip's are. PIN_TYPE 1010_01: the output and its enable straight from the fabric, the input
  // unregistered.
  SB_IO #(
      .PIN_TYPE(6'b1010_01)
  ) u_uio[7:0] (
      .PACKAGE_PIN  (uio),
      .OUTPUT_ENABLE(uio_oe),
      .D_OUT_0      (uio_out),
      .D_IN_0       (uio_in)
  );

  tt_um_tiny_breakout u_game (
      .ui_in  (ui_in),
      .uo_out (uo_out),
      .uio_in (uio_in),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (1'b1),
      .clk    (clk),
      .rst_n  (rst_n)
  );

endmodule
