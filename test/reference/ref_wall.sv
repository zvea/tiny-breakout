/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Reference model of src/brick_wall.sv, written to be read rather than built: the same
 * behaviour on every clock, with none of the tricks that make the chip's version small.
 */

`default_nettype none

module ref_wall (
    input  logic       clk,
    input  logic       rst_n,
    input  logic [9:0] x,
    input  logic [9:0] y,
    input  logic       refill,
    input  logic       full_wall,
    input  logic [1:0] level,
    input  logic [4:0] random,
    input  logic       clear,
    output logic       brick_px,
    output logic [2:0] brick_row,
    output logic       over_columns,
    output logic       empty
);

  localparam int COLUMNS      = 8;
  localparam int ROWS         = 6;
  localparam int BRICK_WIDTH  = 64;
  localparam int BRICK_HEIGHT = 16;
  localparam int GAP          = 2;
  localparam int WALL_LEFT    = 64;
  localparam int WALL_TOP     = 64;
  localparam int WALL_RIGHT   = WALL_LEFT + COLUMNS * BRICK_WIDTH;
  localparam int WALL_BOTTOM  = WALL_TOP + ROWS * BRICK_HEIGHT;

  typedef logic [COLUMNS-1:0] row_t;  // one bit per column: 1 = the brick is standing

  row_t [ROWS-1:0] bricks;
  logic new_wall_due;     // asked for and not yet in place: no bricks are shown meanwhile
  logic drawn_since_top;  // a brick was drawn (or a new wall was due) since the beam was above the wall

  // ---- Where the beam is ----

  wire       in_columns     = (x >= WALL_LEFT) && (x < WALL_RIGHT);
  wire       in_rows        = (y >= WALL_TOP) && (y < WALL_BOTTOM);
  wire [2:0] column         = 3'((x - WALL_LEFT) / BRICK_WIDTH);
  wire [2:0] row            = 3'((y - WALL_TOP) / BRICK_HEIGHT);
  wire       in_left_gap    = ((x - WALL_LEFT) % BRICK_WIDTH) < GAP;
  wire       in_top_gap     = ((y - WALL_TOP) % BRICK_HEIGHT) < GAP;
  wire       above_wall     = y < WALL_TOP;
  wire       beam_past_wall = y == WALL_BOTTOM;

  // ---- The next wall ----

  // The layout grows its rows in the order 5, 0, 1, 2, 3, 4, each from the one before: the
  // bottom row from nothing, the top row from the bottom one, then each row from the one above

  row_t [ROWS-1:0] pattern;

  wall_pattern bottom_row (
      .r     (3'(ROWS - 1)),
      .prev  (row_t'(0)),
      .level (level),
      .random(random),
      .row   (pattern[ROWS-1])
  );

  wall_pattern top_row (
      .r     (3'd0),
      .prev  (pattern[ROWS-1]),
      .level (level),
      .random(random),
      .row   (pattern[0])
  );

  for (genvar r = 1; r < ROWS - 1; r++) begin : grown_rows
    wall_pattern grown_row (
        .r     (3'(r)),
        .prev  (pattern[r-1]),
        .level (level),
        .random(random),
        .row   (pattern[r])
    );
  end

  // ---- The wall ----

  always_ff @(posedge clk) begin
    if (!rst_n || refill) new_wall_due <= 1;
    else if (beam_past_wall) new_wall_due <= 0;
  end

  always_ff @(posedge clk) begin
    if (new_wall_due && beam_past_wall) bricks <= full_wall ? '1 : pattern;
    else if (clear && brick_px) bricks[row][column] <= 0;
  end

  always_ff @(posedge clk) begin
    if (!rst_n || above_wall) drawn_since_top <= 0;
    else if (brick_px || new_wall_due) drawn_since_top <= 1;
  end

  // ---- What the beam sees ----

  assign over_columns = in_columns;
  assign brick_px     = in_columns && in_rows && !in_left_gap && !in_top_gap
                        && bricks[row][column] && !new_wall_due;
  assign brick_row    = row;
  assign empty        = !drawn_since_top;

endmodule
