/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * The wall of bricks: which bricks are still standing, and what lies under the beam.
 *
 * 8 columns x 6 rows of 64 x 16-px cells at x 64..575, y 64..159; each brick fills its cell
 * but for a 2-px gap on the left and top.
 *
 * The bricks are kept as a ring that turns with the beam, so the brick under the beam is
 * always bit 0. That needs no 48-way read multiplexer or write decoder, and halves the wall's
 * logic. It relies on the beam scanning the screen in order (vga_timing). The ring holds the
 * rows one after another, the head row (the one under the beam) in bits 0..7, and turns by
 * one bit at the start of each brick column, 8 times a line:
 *   - On most lines only the head row turns, so it is back in place for the next line.
 *   - On the first line of each brick row the whole ring turns (a row turn), so by the end of
 *     the line it has moved on by a row: 6 row turns per frame. That line is in the 2-px gap
 *     above the bricks, so no brick shows while the rows are half moved, and none is cleared.
 *     Turning the rows one bit at a time, as the head row turns anyway, saves a multiplexer
 *     on each head row bit over moving them a whole row at once.
 * Bricks keep their order around the ring, so which bit holds which brick at reset does not
 * matter.
 *
 * Refill shifts a new wall in with the row turns of the next frame, and the bricks stay
 * hidden until the end of the wall (line 160), after the last turn: the frame after reset and
 * after each refill shows no bricks, rather than the half-built ring's bottom row. Hiding them
 * also keeps the unreset bits from showing as X in simulation.
 *
 * The first wall of a game is full; every later one comes from wall_pattern, which gives the
 * wall's rows one at a time: each row turn of the fill loads one row, the one leaving the head
 * for the tail. The fill's first turn loads row 5 (the bottom one), then rows 0 .. 4, and each
 * time wall_pattern also gets the row loaded just before, the one ahead of it in the ring, so
 * a layout can grow each row from the last. A row is loaded at its turn's last step, when it
 * and the row before are both whole. The fill ORs the new rows into what is left in the ring:
 * empty after a cleared wall. A new game can start with bricks left, so the first wall is
 * forced full, whatever the layout.
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
    input  logic       refill,        // build a new wall (new game or level)
    input  logic       full_wall,     // while filling: build the full wall, not a pattern
    input  logic [1:0] level,         // while filling, for wall_pattern: the level, 1 .. 3
    input  logic [4:0] random,        // while filling, for wall_pattern: never 0, steady
    input  logic       clear,         // remove the brick under the beam, if any
    output logic       brick_px,      // a standing brick is under the beam
    output logic [2:0] brick_row,     // its row, 0 (top) .. 5: valid while brick_px
    output logic       over_columns,  // the beam is within the wall's x range (64..575)
    output logic       empty          // no brick standing: valid below the wall (y >= 160)
);

  localparam int COLS = 8;
  localparam int ROWS = 6;
  localparam int RING = ROWS * COLS;
  localparam logic [3:0] FIRST_COL = 1;  // in 64-px columns: x 64
  localparam logic [5:0] FIRST_ROW = 4;  // in 16-px rows: y 64

  // The 64-px column and 16-px row under the beam: the wall is columns 1..8, rows 4..9
  wire [3:0] col     = h_pos[9:6];
  wire [5:0] row     = v_pos[9:4];
  wire       in_cols = (col >= FIRST_COL) && (col < FIRST_COL + 4'(COLS));
  wire       in_rows = (row >= FIRST_ROW) && (row < FIRST_ROW + 6'(ROWS));
  wire       gap     = (h_pos[5:1] == 0) || (v_pos[3:1] == 0);  // 2-px gap left of / above each brick

  logic [RING-1:0] ring;     // 1 = standing; ring row r in bits 8r .. 8r + 7; bit 0 under the beam
  logic            filling;  // refill in progress: 1s come in with the row turns

  // Turns happen in the gaps, where no brick is cleared
  wire col_turn  = (h_pos[5:0] == 0) && in_cols;      // start of each brick column
  wire row_line  = (v_pos[3:0] == 0) && in_rows;      // first line of each brick row: a row turn
  wire last_step = col_turn && row_line && h_pos[9];  // a row turn's last step (column 7)

  // The row the fill loads at this row turn (see the top). The turn on the first line of brick
  // row k (0..5 from the top) loads row k - 1, the first one row 5. Bit c + 1 of a ring row is
  // under wall column c, as the head row has turned once at the start of column 0, so rows
  // are turned by one bit out of and into column order. At the last step, before it is taken,
  // the loaded row is in bits 41..47 and 0, and the row before it in bits 33..40.
  wire [2:0]      turn     = 3'(row - FIRST_ROW);
  wire [2:0]      fill_r   = (turn == 0) ? 3'd5 : turn - 3'd1;
  wire [COLS-1:0] last_row = {ring[RING-15], ring[RING-8:RING-14]};  // bit c: column c
  wire [COLS-1:0] pattern_row;
  wall_pattern u_wall_pattern (
      .r     (fill_r),
      .prev  (last_row),
      .level (level),
      .random(random),
      .row   (pattern_row)
  );
  wire [COLS-1:0] fill_row = full_wall ? '1 : pattern_row;  // bit c: column c
  wire [COLS-1:0] fill     = {fill_row[COLS-2:0], fill_row[COLS-1]} & {COLS{filling && last_step}};

  // No reset: refill (which reset starts) fills the wall
  always_ff @(posedge clk) begin
    if (col_turn && row_line) begin
      ring <= {ring[0], ring[RING-1:1]} | {fill, (RING - COLS)'(0)};
    end else if (col_turn) begin
      ring[COLS-1:0] <= {ring[0], ring[COLS-1:1]};
    end else if (clear && brick_px) begin
      ring[0] <= 0;
    end
  end

  // Filling ends at the end of the wall (line 160) of the next frame, after its last row turn
  // (line 144); refill must come after line 160, as it does at frame_tick (line 480)
  always_ff @(posedge clk) begin
    if (!rst_n || refill) filling <= 1;
    else if (row == FIRST_ROW + 6'(ROWS)) filling <= 0;
  end

  assign brick_px = in_cols && in_rows && !gap && ring[0] && !filling;

  // Whether a brick was drawn this frame, from the wall's top row on (a filling wall counts)
  logic seen;
  always_ff @(posedge clk) begin
    if (!rst_n || v_pos[9:6] == 0) seen <= 0;  // above the wall (y < 64)
    else if (brick_px || filling) seen <= 1;
  end

  assign brick_row    = {~row[2], row[1:0]};  // rows 4..9 have low bits 4,5,6,7,0,1: flip bit 2
  assign over_columns = in_cols;
  assign empty        = !seen;

  wire _unused = &{h_pos[0], v_pos[0], 1'b0};  // gaps are 2 px: bit 0 is never needed

endmodule
