/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * The wall of bricks: which bricks are still standing, and what lies under the beam.
 *
 * 8 columns x 6 rows of 64 x 16 px bricks at x 64..575, y 64..159, each with a 2-px gap
 * on its left and top edges.
 *
 * The bricks are kept as a ring that turns with the beam, so the brick under the beam is
 * always bricks[0][0]. That needs no 48-way read multiplexer or write decoder, and halves
 * the wall's logic. It relies on the beam scanning the screen in order (vga_timing):
 *   - The head row, bricks[0], turns by one brick at the start of each brick column:
 *     8 turns per line, so it is back in place for the next line.
 *   - All rows turn by one row at the start of each brick row: 6 turns per frame.
 * Bricks keep their order around the ring, so which bit holds which brick at reset does
 * not matter.
 *
 * Refill shifts in 1s with the row turns of the next frame, and the bricks stay hidden
 * until the last turn: for one frame after reset and after each refill, only the bottom
 * row shows. Hiding them also keeps the unreset bits from showing as X in simulation.
 *
 * Empty is read off the picture: no brick was drawn in the wall's rows. It is valid from
 * the end of the wall (y 160) until the next frame starts.
 */

`default_nettype none

module brick_wall (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [9:0] h_pos,         // beam position, scanning in order
    input  logic [9:0] v_pos,
    input  logic       refill,        // put every brick back (new game or level)
    input  logic       clear,         // remove the brick under the beam, if any
    output logic       brick_px,      // a standing brick is under the beam
    output logic [2:0] brick_row,     // its row, 0 (top) .. 5: valid while brick_px
    output logic       over_columns,  // the beam is within the wall's x range (64..575)
    output logic       empty          // no brick standing: valid below the wall (y >= 160)
);

  localparam int COLS = 8;
  localparam int ROWS = 6;

  // The 64-px column and 16-px row under the beam: the wall is columns 1..8, rows 4..9
  wire [3:0] col     = h_pos[9:6];
  wire [5:0] row     = v_pos[9:4];
  wire       in_cols = (col >= 1) && (col <= 8);
  wire       in_rows = (row >= 4) && (row <= 9);
  wire       gap     = (h_pos[5:1] == 0) || (v_pos[3:1] == 0);  // 2-px gap left of / above each brick

  logic [ROWS-1:0][COLS-1:0] bricks;  // 1 = standing; bricks[0][0] is under the beam
  logic                      filling;  // refill in progress: 1s come in with the row turns

  // Turns happen in the gaps, where no brick is cleared
  wire row_turn = (h_pos == 0) && (v_pos[3:0] == 0) && in_rows;  // start of each brick row
  wire col_turn = (h_pos[5:0] == 0) && in_cols;                  // start of each brick column

  // No reset: refill (which reset starts) fills the wall
  always_ff @(posedge clk) begin
    if (row_turn) begin
      for (int r = 0; r < ROWS - 1; r++) bricks[r] <= bricks[r+1];
      bricks[ROWS-1] <= bricks[0] | {COLS{filling}};
    end else if (col_turn) begin
      bricks[0] <= {bricks[0][0], bricks[0][COLS-1:1]};
    end else if (clear && brick_px) begin
      bricks[0][0] <= 0;
    end
  end

  // Filling lasts until the last row turn of the frame after the refill
  always_ff @(posedge clk) begin
    if (!rst_n || refill) filling <= 1;
    else if (row_turn && row == 9) filling <= 0;
  end

  assign brick_px = in_cols & in_rows & ~gap & bricks[0][0] & ~filling;

  // Whether a brick was drawn this frame, from the wall's top row on (a filling wall counts)
  logic seen;
  always_ff @(posedge clk) begin
    if (!rst_n || v_pos[9:6] == 0) seen <= 0;  // above the wall (y < 64)
    else if (brick_px || filling) seen <= 1;
  end

  assign brick_row    = {~row[2], row[1:0]};  // rows 4..9 have low bits 4,5,6,7,0,1: flip bit 2
  assign over_columns = in_cols;
  assign empty        = ~seen;

  wire _unused = &{h_pos[0], v_pos[0], 1'b0};  // gaps are 2 px: bit 0 is never needed

endmodule
