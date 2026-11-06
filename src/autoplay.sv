/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Autoplay: steers the paddle so the ball lands on a chosen quarter ("zone") of it.
 *
 * The zone is re-picked pseudo-randomly after every paddle hit. Always aiming at the same
 * spot makes the ball settle into a closed loop that never reaches the remaining bricks;
 * since the paddle quarter sets the bounce angle, varying it keeps the ball exploring.
 */

`default_nettype none

module autoplay (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       frame_tick,   // once per frame: advance the random sequence
    input  logic       paddle_hit,   // at frame_tick: the ball hit the paddle this frame
    input  logic [9:0] ball_x,       // left edge of the 8-px ball
    input  logic [9:0] paddle_x,     // left edge of the 64-px paddle (a multiple of 4)
    output logic       steer_left,   // move the paddle left / right this frame
    output logic       steer_right
);

  logic [4:0] lfsr;  // x^5 + x^3 + 1: cycles through all 31 non-zero values
  logic [1:0] zone;  // paddle quarter to aim for, 16 px each

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lfsr <= 1;  // any non-zero seed
      zone <= 1;
    end else if (frame_tick) begin
      lfsr <= {lfsr[3:0], lfsr[4] ^ lfsr[2]};
      if (paddle_hit) zone <= lfsr[1:0];
    end
  end

  // Ball centre (ball_x + 4) over zone centre (paddle_x + 16 * zone + 8), compared in
  // 4-px units: ball_x / 4 = paddle_x / 4 + 4 * zone + 1
  wire [7:0] ball_q = ball_x[9:2];
  wire [7:0] aim_q  = paddle_x[9:2] + zone * 4 + 1;

  assign steer_right = ball_q > aim_q;
  assign steer_left  = ball_q < aim_q;

  wire _unused = &{ball_x[1:0], paddle_x[1:0], 1'b0};

endmodule
