/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Output stage for the TinyVGA PMOD: registers the pixel colour and sync pulses and maps
 * them onto the PMOD's pins.
 *
 * All 8 outputs change on the same clock edge, so colour and sync stay aligned and no
 * glitches from the colour logic reach the monitor; everything is delayed by one clock.
 * Outside the visible area the colour is forced to black, as VGA requires.
 */

`default_nettype none

module tiny_vga_out (
    input  logic             clk,
    input  logic             rst_n,
    input  colour_pkg::rgb_t colour,    // pixel colour
    input  logic             visible,   // beam inside the picture; the colour is ignored otherwise
    input  logic             h_sync_n,  // sync pulses, active low
    input  logic             v_sync_n,
    output logic [7:0]       uo_out     // TinyVGA PMOD pins
);

  // TinyVGA PMOD pin layout, most significant bit first: 2 bits per colour, with each
  // colour's bits on different pins
  typedef struct packed {
    logic h_sync, b0, g0, r0, v_sync, b1, g1, r1;
  } pins_t;

  colour_pkg::rgb_t rgb_q;
  logic             h_sync_q, v_sync_q;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rgb_q    <= 0;
      h_sync_q <= 1;
      v_sync_q <= 1;
    end else begin
      rgb_q    <= visible ? colour : colour_pkg::BLACK;
      h_sync_q <= h_sync_n;
      v_sync_q <= v_sync_n;
    end
  end

  pins_t pins;
  assign pins.h_sync        = h_sync_q;
  assign pins.v_sync        = v_sync_q;
  assign {pins.r1, pins.r0} = rgb_q.r;
  assign {pins.g1, pins.g0} = rgb_q.g;
  assign {pins.b1, pins.b0} = rgb_q.b;
  assign uo_out             = pins;

endmodule
