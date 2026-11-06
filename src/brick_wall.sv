/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * The wall of bricks: which bricks are still standing, and what lies under the beam.
 *
 * 8 columns x 6 rows of 64 x 16 px bricks at x 64..575, y 64..159, each with a 2-px gap
 * on its left and top edges. Everything is decided per pixel from the beam position, so
 * the game can draw a brick and detect the ball touching it in the same clock cycle.
 */

`default_nettype none

module brick_wall (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [9:0] h_pos,         // beam position
    input  logic [9:0] v_pos,
    input  logic       refill,        // put every brick back (new game or level)
    input  logic       clear,         // remove the brick under the beam, if any
    output logic       brick_px,      // a standing brick is under the beam
    output logic [2:0] brick_row,     // its row, 0 (top) .. 5: valid while brick_px
    output logic       over_columns,  // the beam is within the wall's x range (64..575)
    output logic       empty          // every brick has been cleared
);

  // Counted in brick-sized steps across the screen, the bricks start at column
  // FIRST_COL (x 64) and row FIRST_ROW (y 64).
  localparam int         COLS       = 8;
  localparam int         ROWS       = 6;
  localparam int         NUM_BRICKS = COLS * ROWS;
  localparam logic [3:0] FIRST_COL  = 1;
  localparam logic [5:0] FIRST_ROW  = 4;

  logic [NUM_BRICKS-1:0] bricks;  // bit = row * COLS + col; 1 = brick standing

  // The 64-px column and 16-px row under the beam
  wire [3:0] col = h_pos[9:6];
  wire [5:0] row = v_pos[9:4];

  // One-hot decode: col_sel[c] / row_sel[r] are set when the beam is over brick column c / row r
  wire [COLS-1:0] col_sel;
  wire [ROWS-1:0] row_sel;
  for (genvar c = 0; c < COLS; c++) begin : g_col_sel
    assign col_sel[c] = (col == FIRST_COL + 4'(c));
  end
  for (genvar r = 0; r < ROWS; r++) begin : g_row_sel
    assign row_sel[r] = (row == FIRST_ROW + 6'(r));
  end

  // One-hot select of the brick under the beam: row r's bits are the column selects
  // gated by row r. Whole-vector operations simulate much faster.
  wire [NUM_BRICKS-1:0] brick_sel;
  for (genvar r = 0; r < ROWS; r++) begin : g_brick_row
    assign brick_sel[r*COLS +: COLS] = {COLS{row_sel[r]}} & col_sel;
  end

  wire gap = (h_pos[5:1] == 0) || (v_pos[3:1] == 0);  // 2-px gap left of / above each brick

  always_ff @(posedge clk) begin
    if (!rst_n || refill) begin
      bricks <= '1;
    end else if (clear) begin
      bricks <= bricks & ~brick_sel;
    end
  end

  // Read the brick under the beam by binary index (row * 8 + col) rather than through
  // the one-hot select; only valid inside the wall, hence in_wall.
  wire       in_wall = (|col_sel) & (|row_sel);
  wire [2:0] col_idx = 3'(col - FIRST_COL);
  wire [2:0] row_idx = {~row[2], row[1:0]};
  wire [5:0] idx     = {row_idx, col_idx};
  assign brick_px     = in_wall & bricks[idx] & ~gap;
  // Rows 4..9 have low bits 4,5,6,7,0,1; flipping the top bit gives 0..5.
  assign brick_row    = {~row[2], row[1:0]};
  assign over_columns = |col_sel;
  assign empty        = ~|bricks;

  wire _unused = &{h_pos[0], v_pos[0], 1'b0};  // gaps are 2 px: bit 0 is never needed

endmodule
