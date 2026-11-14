/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Breakout for a 12-bit VGA output with three buttons: the game (tt_um_tiny_breakout,
 * unchanged), its reset, and its pins mapped onto a VGA Pmod's 4 bits per colour. Nothing here
 * is specific to an FPGA: the board's top module supplies the clock and the pins
 * (icebreaker_top.v, icebreaker.pcf).
 *
 * Buttons: left, right and fire go to the game's direct button inputs (ui_in[0..2]), as on the
 * Tiny Tapeout board, where the game registers them (direct_q). There is no Gamepad Pmod, so
 * its inputs are 0: the game sees no controller, and plays its demo until a button is pressed.
 * Autoplay (ui_in[3]) is off; the demo returns after a reset.
 *
 * Picture: the game's 2-bit colour levels (TinyVGA pins, see tiny_vga_out.sv), each repeated
 * to fill the VGA Pmod's 4 bits: 0, 5, A, F, evenly spaced from black to full brightness. The
 * sync pins are the game's own, active low, as 640x480 needs.
 */

`default_nettype none

module breakout_vga (
    input  logic       clk,           // the pixel clock, near 25.175 MHz
    input  logic       clk_locked,    // high once the clock is steady (the PLL's lock)
    input  logic       reset_button,  // high while pressed, asynchronous
    input  logic       btn_left,      // high while pressed, asynchronous
    input  logic       btn_right,     // high while pressed, asynchronous
    input  logic       btn_fire,      // high while pressed, asynchronous
    output logic [3:0] vga_r,         // VGA Pmod levels, most significant bit first
    output logic [3:0] vga_g,
    output logic [3:0] vga_b,
    output logic       vga_hs_n,
    output logic       vga_vs_n
);

  // ---------------------------------------------------------------------------
  // Reset: until the clock has been steady for 256 clocks, and while the button is pressed.
  // The lock and the button come through synchronisers; the count restarts if the lock drops.
  // ---------------------------------------------------------------------------
  logic [1:0] locked_s = 0;  // synchroniser
  logic [1:0] button_s = 0;  // synchroniser
  logic [8:0] steady   = 0;  // counts to 256 after the lock
  logic       rst_n    = 0;
  always_ff @(posedge clk) begin
    locked_s <= {locked_s[0], clk_locked};
    button_s <= {button_s[0], reset_button};
    if (!locked_s[1]) steady <= 0;
    else if (!steady[8]) steady <= steady + 1;
    rst_n <= steady[8] && !button_s[1];
  end

  // ---------------------------------------------------------------------------
  // The game, as on the Tiny Tapeout board
  // ---------------------------------------------------------------------------
  logic [7:0] uo_out, uio_out, uio_oe;
  tt_um_tiny_breakout u_game (
      .ui_in  ({4'b0, 1'b0, btn_fire, btn_right, btn_left}),  // no Gamepad Pmod; autoplay off
      .uo_out (uo_out),
      .uio_in (8'b0),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (1'b1),
      .clk    (clk),
      .rst_n  (rst_n)
  );

  // TinyVGA pins (tiny_vga_out.sv), most significant first: hsync_n, b0, g0, r0, vsync_n,
  // b1, g1, r1
  wire [1:0] red   = {uo_out[0], uo_out[4]};
  wire [1:0] green = {uo_out[1], uo_out[5]};
  wire [1:0] blue  = {uo_out[2], uo_out[6]};
  assign vga_r    = {2{red}};
  assign vga_g    = {2{green}};
  assign vga_b    = {2{blue}};
  assign vga_hs_n = uo_out[7];
  assign vga_vs_n = uo_out[3];

  wire _unused = &{uio_out, uio_oe, 1'b0};  // no Audio Pmod

endmodule
