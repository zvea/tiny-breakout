/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Sound effects: a short square-wave beep for each event, for the Tiny Tapeout Audio Pmod
 * (mono, on uio[7]). The tones need no counter of their own: they are bits of the beam's line
 * counter, which advances at 31.47 kHz, so v_pos[k] is a square wave at 31.47 kHz / 2^(k+1).
 * (A frame is 525 lines, not a power of two, so each wave skips a little at the frame
 * boundary: a faint 60 Hz roughness.) Events are sampled at frame_tick and a beep lasts whole
 * frames; a later event replaces a beep still playing if it ranks at least as high.
 */

`default_nettype none

module sound (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       frame_tick,  // events are valid here; the beep timer counts frames
    input  logic       lost,        // the ball fell off the bottom
    input  logic       brick,       // a brick was hit
    input  logic       paddle,      // the ball hit the paddle
    input  logic       wall,        // the ball touched a wall
    input  logic       mute,        // no sound (the demo)
    input  logic [9:0] v_pos,       // beam line: its bits are the tones
    output logic       audio
);

  // Beeps, highest rank first: tone (v_pos bit) and length in frames (16.7 ms each)
  localparam int LOST_BIT = 6, LOST_FRAMES = 7;  // 246 Hz, 117 ms
  localparam int BRICK_BIT = 3, BRICK_FRAMES = 2;  // 1967 Hz, 33 ms
  localparam int PADDLE_BIT = 5, PADDLE_FRAMES = 2;  // 492 Hz, 33 ms
  localparam int WALL_BIT = 4, WALL_FRAMES = 1;  // 983 Hz, 17 ms

  // Kept binary: synthesis would recode it one-hot (4 flip-flops), and tools/lec.sh pairs
  // registers by name, so it could not check a recoded state register
  (* fsm_encoding = "none" *)
  logic [1:0] beep;    // which beep: 3 lost, 2 brick, 1 paddle, 0 wall
  logic [2:0] frames;  // frames left to play; 0 = silent

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      frames <= 0;
      beep   <= 0;
    end else if (frame_tick) begin
      if (mute) frames <= 0;
      else if (lost) {beep, frames} <= {2'd3, 3'(LOST_FRAMES)};
      else if (brick && (frames == 0 || beep <= 2)) {beep, frames} <= {2'd2, 3'(BRICK_FRAMES)};
      else if (paddle && (frames == 0 || beep <= 1)) {beep, frames} <= {2'd1, 3'(PADDLE_FRAMES)};
      else if (wall && frames == 0) {beep, frames} <= {2'd0, 3'(WALL_FRAMES)};
      else if (frames != 0) frames <= frames - 1;
    end
  end

  logic tone;
  always_comb begin
    case (beep)
      3:       tone = v_pos[LOST_BIT];
      2:       tone = v_pos[BRICK_BIT];
      1:       tone = v_pos[PADDLE_BIT];
      default: tone = v_pos[WALL_BIT];
    endcase
  end

  // Registered, so the pin never glitches
  always_ff @(posedge clk) begin
    if (!rst_n) audio <= 0;
    else audio <= (frames != 0) & tone;
  end

endmodule
