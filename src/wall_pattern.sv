/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * The layout of the walls after the first: which bricks each row of a new wall has. This is
 * the place to try different levels; brick_wall builds a wall from it one row at a time.
 *
 * How brick_wall uses it:
 *   - It asks for the rows in the order the ring fills, one per brick row as the beam passes
 *     the wall: row 5 (the bottom one) first, then rows 0 .. 4. With each it gives the row it
 *     got just before (prev); for row 5 that is the ring's own last row, which is empty after
 *     a cleared wall.
 *   - The inputs hold still while a wall is built (one frame): `level` and `random` change
 *     only between frames.
 *   - The first wall of a game is always full: brick_wall makes it so whatever this module
 *     returns (a new game can start with bricks left, which only the full wall covers), so a
 *     layout here only has to work for level 1 and up.
 *   - A layout must never be empty for any input: the level would never end.
 *
 * The current layout ("Aliens") grows each wall from one row: row 5 is a seed of 4 bricks
 * from `random`, mirrored into 8 columns, and each later row is grown from the one before by
 * a one-dimensional cellular automaton: a brick goes where an odd number of the three bricks
 * above it (left, centre, right) stand, Wolfram's rule 150; with random[4] set, also where
 * both neighbours stand, rule 182. The rows stay mirror-symmetric: column 3's right neighbour
 * is column 4, which mirrors column 3, and column 0's left neighbour is column 7, which
 * mirrors column 0. The 31 values of `random` give 21 different walls of 20 to 48 bricks.
 */

`default_nettype none

module wall_pattern (
    input  logic [2:0] r,       // the row asked for: 0 (top) .. 5 (bottom)
    input  logic [7:0] prev,    // the row given just before (bit c: column c, 0 = leftmost)
    input  logic [1:0] level,   // 1 .. 3: the 2nd, 3rd and 4th-onwards walls of a game
    input  logic [4:0] random,  // never 0; the game's LFSR
    output logic [7:0] row      // the row's bricks (bit c: column c)
);

  wire [3:0] half  = prev[3:0];               // columns 0 .. 3; columns 4 .. 7 mirror them
  wire [3:0] left  = {half[2:0], half[0]};    // each column's left neighbour (column 0's: 7)
  wire [3:0] right = {half[3], half[3:1]};    // each column's right neighbour (column 3's: 4)
  wire [3:0] seed  = {random[3:1], random[0] | random[4]};  // never 0, as random is never 0
  wire [3:0] grown = (left ^ half ^ right) | (left & right & {4{random[4]}});
  wire [3:0] q     = (r == 5) ? seed : grown;  // row 5 comes first: the seed

  assign row = {q[0], q[1], q[2], q[3], q};

  wire _unused = &{prev[7:4], level, 1'b0};  // this layout doesn't use them

endmodule
