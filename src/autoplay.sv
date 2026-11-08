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
 */

`default_nettype none

module autoplay (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       frame_tick,   // once per frame
    input  logic       paddle_hit,   // at frame_tick: the ball hit the paddle this frame
    input  logic [1:0] random,       // pseudo-random bits that change every frame (the LFSR)
    input  logic [9:0] ball_x,       // left edge of the 8x8 box the round ball is drawn in
    input  logic [9:0] paddle_c,     // centre of the paddle (a multiple of 4)
    input  logic [2:0] paddle_w16,   // width of the paddle in 16 px
    output logic       steer_left,   // move the paddle left / right by one 4-px step
    output logic       steer_right
);

  logic [1:0] aim_zone;  // paddle zone to aim for, 0..3 from the left (the angle zones)

  always_ff @(posedge clk) begin
    if (!rst_n) aim_zone <= 1;
    else if (frame_tick && paddle_hit) aim_zone <= random;
  end

  // Ball centre (ball_x + 4) over the middle of the zone. The outer zones are the paddle's
  // last 16 px, so their middle is 8 px in from the end: half a width (8 x paddle_w16) - 8 from
  // the centre. The inner ones fill the rest, 8 x paddle_w16 - 16 px each side of the centre,
  // so their middle is 4 x paddle_w16 - 8 from it. Compared in 4-px units, relative to the
  // centre: ball_x / 4 = paddle_c / 4 + aim_dx4, where the - 1 is the ball's 4 px to its centre.
  // The paddle moves one 4-px step at a time and this is re-evaluated before each step, so it
  // stops on target (to within 4 px).
  wire [7:0] w16 = {5'b0, paddle_w16};
  logic [7:0] aim_dx4;
  always_comb begin
    case (aim_zone)
      0:       aim_dx4 = -(2 * w16 - 2) - 1;
      1:       aim_dx4 = -(w16 - 2) - 1;
      2:       aim_dx4 = (w16 - 2) - 1;
      default: aim_dx4 = (2 * w16 - 2) - 1;
    endcase
  end
  wire [7:0] ball_x4 = ball_x[9:2];
  wire [7:0] aim_x4  = paddle_c[9:2] + aim_dx4;

  assign steer_right = ball_x4 > aim_x4;
  assign steer_left  = ball_x4 < aim_x4;

  wire _unused = &{ball_x[1:0], paddle_c[1:0], 1'b0};

endmodule
