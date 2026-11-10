/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * VGA timing generator for 640x480 @ 60 Hz (25.175 MHz pixel clock).
 *
 * Each line is 800 clocks and each frame 525 lines; beyond the visible area come the
 * front porch, the sync pulse and the back porch, during which the picture must be black.
 */

`default_nettype none

module vga_timing (
    input  logic       clk,
    input  logic       rst_n,
    output logic [9:0] h_pos,        // clock within the line, 0..799 (pixel x when visible)
    output logic [9:0] v_pos,        // line within the frame, 0..524 (pixel y when visible)
    output logic       visible,      // beam inside the 640x480 picture
    output logic       h_sync_n,     // sync pulses, active low (combinational)
    output logic       v_sync_n,
    output logic       vblank_start  // one clock: the first clock after the last visible line
                                     // (registered)
);

  localparam logic [9:0] H_VISIBLE    = 640;
  localparam logic [9:0] H_SYNC_START = 656;  // after a 16-clock front porch
  localparam logic [9:0] H_SYNC_END   = 752;  // 96-clock sync pulse, then a 48-clock back porch
  localparam logic [9:0] H_TOTAL      = 800;

  localparam logic [9:0] V_VISIBLE    = 480;
  localparam logic [9:0] V_SYNC_START = 490;  // after a 10-line front porch
  localparam logic [9:0] V_SYNC_END   = 492;  // 2-line sync pulse, then a 33-line back porch
  localparam logic [9:0] V_TOTAL      = 525;

  wire h_end = (h_pos == H_TOTAL - 1);
  wire v_end = (v_pos == V_TOTAL - 1);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      h_pos <= 0;
      v_pos <= 0;
    end else if (h_end) begin
      h_pos <= 0;
      v_pos <= v_end ? 0 : v_pos + 1;
    end else begin
      h_pos <= h_pos + 1;
    end
  end

  // vblank_start starts the game's frame update, its widest logic, so it comes from a
  // flip-flop rather than a comparator (the iCE40 FPGA build needs the time). It is decoded a
  // clock early, at the last clock of the last visible line, which the counters make exact.
  always_ff @(posedge clk) begin
    if (!rst_n) vblank_start <= 0;
    else vblank_start <= (v_pos == V_VISIBLE - 1) && h_end;
  end

  assign visible  = (h_pos < H_VISIBLE) && (v_pos < V_VISIBLE);
  assign h_sync_n = !((h_pos >= H_SYNC_START) && (h_pos < H_SYNC_END));
  assign v_sync_n = !((v_pos >= V_SYNC_START) && (v_pos < V_SYNC_END));

endmodule
