/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Autoplay: steers the paddle so the ball lands on a chosen zone of it.
 *
 * After each paddle hit it picks the target zone (possibly the same one) from the game's
 * LFSR, which steps every frame (lfsr.sv). The zone sets the bounce angle, and a fixed
 * target lets the ball settle into a loop that never reaches the last bricks. Picking from
 * the game's own state (such as the ball's position) was tried and also fell into such
 * loops.
 *
 * Where the ball is over the paddle is read off the beam, as the drawing finds it, rather than
 * worked out from their positions: as the beam crosses the ball's columns, on every line, it
 * samples the paddle zone under it, which the drawing works out for every pixel anyway (from
 * the beam's x alone, so on every line, not just the paddle's). Comparing that with the
 * target takes two 2-bit compares, where subtracting the positions took an adder and two 8-bit
 * compares, and the flip-flops holding the result cost less than those.
 */

`default_nettype none

module autoplay (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       frame_tick,   // once per frame
    input  logic       paddle_hit,   // at frame_tick: the ball hit the paddle this frame
    input  logic [1:0] random,       // pseudo-random bits that change every frame (the LFSR)
    input  logic       in_ball_x,    // the beam is over the columns of the ball's 8x8 box ...
    input  logic [2:0] ball_dx,      // ... at this offset from its left edge (0..7)
    input  logic [1:0] paddle_zone,  // the paddle zone under the beam, 0..3 from the left;
                                     // 0 / 3 also beyond the paddle's left / right end
    input  logic       over_paddle,  // the beam is over the paddle's columns
    output logic       steer_left,   // move the paddle left / right by one 4-px step
    output logic       steer_right
);

  logic [1:0] aim_zone;  // paddle zone to aim for, 0..3 from the left (the angle zones)

  always_ff @(posedge clk) begin
    if (!rst_n) aim_zone <= 1;
    else if (frame_tick && paddle_hit) aim_zone <= random;
  end

  // The zone a bounce takes is the one under the last ball pixel to touch the paddle: the
  // right end of the ball's bottom row, ball x + 5. Steer until that pixel is at least 2 px
  // inside the target zone, that is, until the pixels 2 px either side of it, ball x + 3 and
  // ball x + 7, are both over the zone (and over the paddle, for an outer zone). That leaves
  // 4 px or more to stop in (the inner zones of the narrowest paddle are 8 px), at least the
  // paddle's 4-px step, so it stops on target rather than stepping back and forth. Once it
  // has stopped, the ball moves at most 2 px before the next step is decided, so the pixel
  // stays in the zone. At the left end, steer left also while ball x is off the paddle: that
  // keeps the ball's whole bottom row (ball x + 2 .. ball x + 5) on the paddle, as ball x + 7
  // does at the right.
  //
  // The paddle and the ball move only at the start of a line (move_tick), and this samples on
  // every line, so each step is decided on the positions the step before left, as fresh as
  // working them out from the positions would be. No reset: the first line after a reset sets
  // both, long before the first move.
  wire left_of_paddle  = !over_paddle && !paddle_zone[1];
  wire right_of_paddle = !over_paddle && paddle_zone[1];

  always_ff @(posedge clk) begin
    if (in_ball_x) begin
      case (ball_dx)
        0:       steer_left  <= left_of_paddle;
        3:       steer_left  <= steer_left || (paddle_zone < aim_zone);
        7:       steer_right <= right_of_paddle || (paddle_zone > aim_zone);
        default: ;
      endcase
    end
  end

endmodule
