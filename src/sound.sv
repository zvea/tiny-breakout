/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Sound effects for the Tiny Tapeout Audio Pmod (mono, on uio[7]).
 *
 * Two voices take turns clock by clock (h_pos[0]), and the Pmod's filter averages them into a
 * mix. Each plays a square wave or noise at a volume of 0..7, set by pulse-width modulation:
 * the output is high only for the first `volume` of every 8 steps of h_pos[3:1] (1.57 MHz).
 *
 * A note is a square wave that flips every N lines of the 31.47 kHz line clock, so its pitch
 * is 31469 / (2 N) Hz: N = 30 is C5, 15 is C6, 60 is C4. Noise is a hash of the line number and
 * the game's random number, which changes every frame: white like an LFSR's, without registers.
 *
 * Each voice keeps only which sound it plays and how many frames it has been playing; the
 * note and the volume are worked out from those, frame by frame:
 *   voice A  start       two chords at a new game, with voice B: C5 with G5, then C6 with E6
 *            brick       a marimba-like note an octave below the row's (pentatonic, red
 *                        highest), two steps higher once the ball is fast, fading over 5 frames
 *            paddle      a low C dropping in pitch over 3 frames (the "thock")
 *            clear       a fanfare in the pause after a cleared wall: C, E, G, a held high C,
 *                        timed by the pause timer
 *            lost        a minor sigh: E-flat, D, then a long C (a ball lost, spares left)
 *            over        a sad trombone: G4, F#4, F4, then a long wobbling E4 (the last ball,
 *                        instead of the lost-ball sound)
 *   voice B  chord       the upper note of the new game's chords
 *            thump       noise stepped every line, under the paddle's thock
 *            rumble      noise stepped every 8 lines (no hiss): a dull thump, for the walls
 * A later sound on a voice replaces the one playing; nothing interrupts a lost ball or game
 * over on voice A. The phrases move in 4-frame steps, so a note and its volume are a small
 * table on the timer's top bits, not comparisons and subtractions: cheaper logic.
 */

`default_nettype none

module sound (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       frame_tick,   // the events below are valid here
    input  logic [9:0] h_pos,
    input  logic [9:0] v_pos,        // the beam's line
    input  logic [3:0] random,       // a new random number every frame (for the noise)
    input  logic       new_game,
    input  logic       paused,       // the pause after a cleared wall
    input  logic       lost,         // the ball fell off the bottom ...
    input  logic       last,         // ... and it was the last one: game over
    input  logic       brick,        // a brick was hit this frame
    input  logic [2:0] brick_row,    // its row, 0 (top) .. 5
    input  logic       fast,         // the ball is fast (2x and up)
    input  logic       paddle,       // the ball hit the paddle
    input  logic       wall,         // the ball touched a wall
    input  logic [3:0] pause_step,   // in the pause: 0..15, one step every 4 frames
    input  logic [1:0] frame_phase,  // frames within a pause step
    output logic       audio
);

  // Half-periods in lines of the pentatonic scale C5 D5 E5 G5 A5 C6 D6 E6
  function automatic logic [6:0] scale(input logic [2:0] i);
    case (i)
      0:       scale = 30;
      1:       scale = 27;
      2:       scale = 24;
      3:       scale = 20;
      4:       scale = 18;
      5:       scale = 15;
      6:       scale = 13;
      default: scale = 12;
    endcase
  endfunction

  // ---- Voice A ----
  typedef enum logic [2:0] {A_NONE, A_BRICK, A_PADDLE, A_LOST, A_OVER, A_CLEAR, A_START} a_kind_t;
  (* fsm_encoding = "none" *) a_kind_t a_kind;  // kept binary, so tools/lec.sh can pair it by name
  logic [5:0] a_t;                          // frames since it started

  // Its note and volume now
  logic [6:0] a_note;
  logic [2:0] a_vol;
  logic       a_done;  // the sound has ended
  wire  [2:0] brick_step = (3'd5 - brick_row) + (fast ? 3'd2 : 3'd0);
  wire  [6:0] brick_n    = scale(brick_step);
  // Phrases in 4-frame steps: the note is a table on the step, the volume falls with the
  // timer's top bits; no comparisons or subtractions on the timer
  wire [3:0] step = a_t[5:2];
  always_comb begin
    a_note = 30;
    a_vol  = 0;
    a_done = 0;
    case (a_kind)
      A_BRICK: begin
        a_note = {brick_n[5:0], 1'b0};
        a_vol  = 3'd5 - a_t[2:0];
        a_done = a_t[2] & a_t[0];  // a_t counts up from 0: the first 5
      end
      A_PADDLE: begin
        a_note = (a_t[1:0] == 0) ? 7'd60 : (a_t[1:0] == 1) ? 7'd66 : 7'd72;
        a_vol  = 3'd5 - {a_t[1:0], 1'b0};
        a_done = &a_t[1:0];
      end
      A_LOST: begin  // E-flat, D: 8 frames each; C: 16
        a_note = step[3:1] == 0 ? 7'd25 : step[3:1] == 1 ? 7'd27 : 7'd30;
        a_vol  = 3'd6 - {1'b0, a_t[4:3]};
        a_done = a_t[5];  // step 8, the first time
      end
      A_OVER: begin  // G4, F#4, F4: 8 frames each; E4 wobbling: 32
        case (step[3:1])
          0:       a_note = 40;
          1:       a_note = 42;
          2:       a_note = 45;
          default: a_note = (a_t[2:1] == 2'd2) ? 7'd50 : a_t[1] ? 7'd49 : 7'd48;
        endcase
        a_vol  = 3'd6 - {1'b0, a_t[5:4]};
        a_done = &a_t[5:3];  // step 14, the first time
      end
      A_CLEAR: begin  // the pause timer's steps: C 0..1, E 2..3, G 4..5, then a held high C
        case (pause_step[3:1])
          0:       a_note = 30;
          1:       a_note = 24;
          2:       a_note = 20;
          default: a_note = 15;
        endcase
        a_vol = 3'd7 - {1'b0, pause_step[3:2]};
      end
      A_START: begin  // C5 for 8 frames, then C6 for 24
        a_note = step[3:1] == 0 ? 7'd30 : 7'd15;
        a_vol  = 3'd6 - {1'b0, a_t[4:3]};
        a_done = a_t[5];
      end
      default: ;
    endcase
    if (a_done) a_vol = 0;  // silent on the frame it ends (the volume steps would wrap or restart)
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      a_kind <= A_NONE;
      a_t    <= 0;
    end else if (frame_tick) begin
      if (new_game) begin
        a_kind <= A_START;
        a_t    <= 0;
      end else if (paused) begin
        a_kind <= A_CLEAR;
      end else if (lost) begin
        if (last) a_kind <= A_OVER;
        else a_kind <= A_LOST;
        a_t <= 0;
      end else if ((brick || paddle) && a_kind != A_LOST && a_kind != A_OVER) begin
        if (brick) a_kind <= A_BRICK;
        else a_kind <= A_PADDLE;
        a_t <= 0;
      end else if (a_done || a_kind == A_CLEAR) begin
        a_kind <= A_NONE;
      end else if (a_t != 63) begin
        a_t <= a_t + 1;
      end
    end
  end

  // ---- Voice B ----
  typedef enum logic [1:0] {B_NONE, B_THUMP, B_RUMBLE, B_CHORD} b_kind_t;
  (* fsm_encoding = "none" *) b_kind_t b_kind;
  logic [2:0] b_t;  // frames since a thump or rumble started, 0..4 (the chord follows voice A's)

  logic [4:0] b_note;
  logic [2:0] b_vol;
  always_comb begin
    b_note = (a_t[5:3] == 0) ? 5'd20 : 5'd12;  // the chord's upper notes: G5, then E6
    case (b_kind)
      B_THUMP:  b_vol = b_t[2] ? 3'd0 : {b_t[1:0] == 0, -b_t[1:0]};  // 4 - b_t
      B_RUMBLE: b_vol = b_t[2] ? 3'd0 : {1'b0, ~b_t[1:0]};           // 3 - b_t, down to 0
      B_CHORD:  b_vol = 3'd6 - {1'b0, a_t[4:3]};
      default:  b_vol = 0;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      b_kind <= B_NONE;
      b_t    <= 0;
    end else if (frame_tick) begin
      if (new_game) b_kind <= B_CHORD;
      else if (paddle) {b_kind, b_t} <= {B_THUMP, 3'd0};
      else if (wall) {b_kind, b_t} <= {B_RUMBLE, 3'd0};
      else if (b_kind == B_CHORD) begin  // as long as voice A plays its lower notes
        if (a_kind != A_START || a_done) b_kind <= B_NONE;
      end else if (b_t[2]) b_kind <= B_NONE;  // b_t is 4
      else b_t <= b_t + 1;
    end
  end

  // ---- The two tones and the noise ----
  // A note: a counter loaded with N counts lines down to 1, then flips the square wave
  wire line = (h_pos == 0);
  logic [6:0] a_count;
  logic [4:0] b_count;  // voice B's notes are short
  logic       a_square, b_square;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      a_count  <= 1;
      b_count  <= 1;
      a_square <= 0;
      b_square <= 0;
    end else if (line) begin
      if (a_count <= 1) {a_count, a_square} <= {a_note, ~a_square};
      else a_count <= a_count - 1;
      if (b_count <= 1) {b_count, b_square} <= {b_note, ~b_square};
      else b_count <= b_count - 1;
    end
  end

  wire [2:0] pwm   = h_pos[3:1];
  wire       a_on  = a_square & (pwm < a_vol);
  // The noise: a hash of the line number, so a new value every line, and of the frame's random
  // number, so each frame's pattern differs (one repeated every frame would buzz at 60 Hz).
  // Products of the line's bits, each against higher bits and the random number, give it a
  // spectrum as flat as an LFSR's. The rumble leaves out the term with the line's low 3 bits,
  // so its noise changes every 8 lines.
  wire fine  = (v_pos[0] & v_pos[7]) ^ (v_pos[1] & v_pos[8]) ^ (v_pos[2] & v_pos[6]);
  wire noise = (v_pos[3] & (v_pos[6] ^ random[0])) ^ (v_pos[4] & (v_pos[7] ^ random[1])) ^
               (v_pos[5] & (v_pos[8] ^ random[2])) ^ random[3] ^ (fine & (b_kind != B_RUMBLE));

  wire       b_src = (b_kind == B_CHORD) ? b_square : noise;
  wire       b_on  = b_src & (pwm < b_vol);
  always_ff @(posedge clk) begin  // registered, so the pin never glitches
    if (!rst_n) audio <= 0;
    else audio <= h_pos[0] ? a_on : b_on;
  end

  // a pause step's last 2 frames; N < 64; the done tests above read the timer's bits directly
  wire _unused = &{frame_phase, pause_step[0], brick_n[6], step[0], v_pos[9], 1'b0};

endmodule
