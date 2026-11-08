/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Autoplay: steers the paddle so the ball lands on a chosen quarter of it.
 *
 * After each paddle hit it picks the target quarter (possibly the same one) from the game's
 * LFSR, which steps every frame (lfsr.sv). The quarter sets the bounce angle, and a fixed
 * target lets the ball settle into a loop that never reaches the last bricks. Picking from
 * the game's own state (such as the ball's position) was tried and also fell into such
 * loops.
 */

`default_nettype none

module autoplay (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       frame_tick,   // once per frame
    input  logic       paddle_hit,   // at frame_tick: the ball hit the paddle this frame
    input  logic [1:0] random,       // pseudo-random bits that change every frame (the LFSR)
    input  logic [9:0] ball_x,       // left edge of the 8x8 box the round ball is drawn in
    input  logic [9:0] paddle_x,     // left edge of the 64-px paddle (a multiple of 4)
    output logic       steer_left,   // move the paddle left / right by one 4-px step
    output logic       steer_right
);

  logic [1:0] aim_quarter;  // paddle quarter to aim for, 16 px each (0 = leftmost)

  always_ff @(posedge clk) begin
    if (!rst_n) aim_quarter <= 1;
    else if (frame_tick && paddle_hit) aim_quarter <= random;
  end

  // Ball centre (ball_x + 4) over the quarter's centre (paddle_x + 16 * aim_quarter + 8),
  // compared in 4-px units: ball_x / 4 = paddle_x / 4 + 4 * aim_quarter + 1. The paddle
  // moves one 4-px step at a time and this is re-evaluated before each step, so it stops
  // on target (to within 4 px).
  wire [7:0] ball_x4 = ball_x[9:2];
  wire [7:0] aim_x4  = paddle_x[9:2] + aim_quarter * 4 + 1;

  assign steer_right = ball_x4 > aim_x4;
  assign steer_left  = ball_x4 < aim_x4;

  wire _unused = &{ball_x[1:0], paddle_x[1:0], 1'b0};

endmodule
