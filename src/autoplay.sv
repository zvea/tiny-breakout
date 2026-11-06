/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Autoplay: steers the paddle so the ball lands on a chosen quarter of it.
 *
 * The quarter is re-picked at random after every paddle hit. Always aiming at the same
 * spot makes the ball settle into a closed loop that never reaches the remaining bricks;
 * since the paddle quarter sets the bounce angle, varying it keeps the ball exploring.
 */

`default_nettype none

module autoplay (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       frame_tick,   // once per frame
    input  logic       paddle_hit,   // at frame_tick: the ball hit the paddle this frame
    input  logic [1:0] random,       // random bits, new every frame
    input  logic [9:0] ball_x,       // left edge of the 8x8 box the round ball is drawn in
    input  logic [9:0] paddle_x,     // left edge of the 64-px paddle (a multiple of 4)
    output logic       steer_left,   // move the paddle left / right this frame
    output logic       steer_right
);

  logic [1:0] aim_quarter;  // paddle quarter to aim for, 16 px each (0 = leftmost)

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      aim_quarter <= 1;
    end else if (frame_tick && paddle_hit) begin
      aim_quarter <= random;
    end
  end

  // Ball centre (ball_x + 4) over the quarter's centre (paddle_x + 16 * aim_quarter + 8),
  // compared in 4-px units: ball_x / 4 = paddle_x / 4 + 4 * aim_quarter + 1
  wire [7:0] ball_q = ball_x[9:2];
  wire [7:0] aim_q  = paddle_x[9:2] + aim_quarter * 4 + 1;

  assign steer_right = ball_q > aim_q;
  assign steer_left  = ball_q < aim_q;

  wire _unused = &{ball_x[1:0], paddle_x[1:0], 1'b0};

endmodule
