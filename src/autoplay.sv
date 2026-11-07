/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Autoplay: steers the paddle so the ball lands on a chosen quarter of it.
 *
 * After every paddle hit it aims at another quarter, picked pseudo-randomly: always aiming
 * at the same spot makes the ball settle into a closed loop that never reaches the
 * remaining bricks, and since the paddle quarter sets the bounce angle, varying it keeps
 * the ball exploring. The choice comes from an LFSR that steps every frame, independently
 * of the game: picking from the game's own state (such as the ball's position) was tried,
 * and the game then fell into loops that never cleared the last bricks.
 */

`default_nettype none

module autoplay (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       frame_tick,   // once per frame: the LFSR steps
    input  logic       paddle_hit,   // at frame_tick: the ball hit the paddle this frame
    input  logic [9:0] ball_x,       // left edge of the 8x8 box the round ball is drawn in
    input  logic [9:0] paddle_x,     // left edge of the 64-px paddle (a multiple of 4)
    output logic       steer_left,   // move the paddle left / right by one 4-px step
    output logic       steer_right
);

  logic [4:0] lfsr;         // x^5 + x^3 + 1: cycles through all 31 non-zero values
  logic [1:0] aim_quarter;  // paddle quarter to aim for, 16 px each (0 = leftmost)

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lfsr        <= 1;  // any non-zero seed
      aim_quarter <= 1;
    end else if (frame_tick) begin
      lfsr <= {lfsr[3:0], lfsr[4] ^ lfsr[2]};
      if (paddle_hit) aim_quarter <= lfsr[1:0];
    end
  end

  // Ball centre (ball_x + 4) over the quarter's centre (paddle_x + 16 * aim_quarter + 8),
  // compared in 4-px units: ball_x / 4 = paddle_x / 4 + 4 * aim_quarter + 1. The paddle
  // moves one 4-px step at a time and this is re-evaluated before each step, so it stops
  // exactly on target.
  wire [7:0] ball_q = ball_x[9:2];
  wire [7:0] aim_q  = paddle_x[9:2] + aim_quarter * 4 + 1;

  assign steer_right = ball_q > aim_q;
  assign steer_left  = ball_q < aim_q;

  wire _unused = &{ball_x[1:0], paddle_x[1:0], 1'b0};

endmodule
