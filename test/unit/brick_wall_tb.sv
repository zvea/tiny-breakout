// SPDX-FileCopyrightText: 2026 Alexei Zverovitch
// SPDX-License-Identifier: Apache-2.0
//
// Test wrapper for brick_wall: the wall needs a beam that scans the screen in order, so
// vga_timing drives it here as in the real design.

`default_nettype none

module brick_wall_tb (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       refill,
    input  logic       full_wall,
    input  logic [1:0] level,
    input  logic [4:0] random,
    input  logic       clear,
    output logic [9:0] h_pos,
    output logic [9:0] v_pos,
    output logic       brick_px,
    output logic [2:0] brick_row,
    output logic       over_columns,
    output logic       empty
);

  logic visible, h_sync_n, v_sync_n, vblank_start;

  vga_timing u_vga_timing (
      .clk         (clk),
      .rst_n       (rst_n),
      .h_pos       (h_pos),
      .v_pos       (v_pos),
      .visible     (visible),
      .h_sync_n    (h_sync_n),
      .v_sync_n    (v_sync_n),
      .vblank_start(vblank_start)
  );

  brick_wall u_brick_wall (
      .clk         (clk),
      .rst_n       (rst_n),
      .h_pos       (h_pos),
      .v_pos       (v_pos),
      .refill      (refill),
      .full_wall   (full_wall),
      .level       (level),
      .random      (random),
      .clear       (clear),
      .brick_px    (brick_px),
      .brick_row   (brick_row),
      .over_columns(over_columns),
      .empty       (empty)
  );

  wire _unused = &{visible, h_sync_n, v_sync_n, vblank_start, 1'b0};

endmodule
