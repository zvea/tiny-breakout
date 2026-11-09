/*
 * PROTOTYPE sound, tiers A'..D (TIER = 1..4), each adding to the one before:
 *   1 (A'): a tone voice with real notes and a volume envelope: bricks by row, the paddle,
 *           the lost ball, quiet wall ticks;
 *   2 (B):  + the cleared-wall arpeggio and the game-over scale;
 *   3 (C):  + a noise voice (wall ticks, paddle thump) and a new-game jingle;
 *   4 (D):  + a written 16-note tune at a new game instead of the jingle.
 *
 * Notes: a counter clocked once per line (31.47 kHz) toggles the tone every N lines, so the
 * tone is 31469 / (2 N) Hz. The pentatonic scale on C5 (C D E G A C D E) is N = 30 27 24 20
 * 18 15 13 12, within about 12 cents; twice N is the octave below.
 * Volume: the output is high only for the first `env` of every 8 steps of h_pos[3:1]
 * (1.57 MHz), so after the Audio Pmod's filter a note's loudness follows env (0..7).
 * Two voices take turns clock by clock (h_pos[0]); the filter averages them into a mix.
 */

`default_nettype none

// The tier to build: sim/play/build.sh sets it from SOUND_TIER (default 4)
`ifndef SOUND_TIER
`define SOUND_TIER 4
`endif

module sound #(
    parameter int TIER = `SOUND_TIER
) (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       frame_tick,
    input  logic [9:0] h_pos,
    input  logic [9:0] v_pos,
    input  logic       lost,        // at frame_tick: the ball fell off the bottom
    input  logic       brick,       // at frame_tick: a brick was hit this frame
    input  logic [2:0] brick_row,   // its row, 0 (top) .. 5
    input  logic       paddle,      // at frame_tick: the ball hit the paddle
    input  logic       wall,        // at frame_tick: the ball touched a wall
    input  logic [4:0] speed_level,
    input  logic [1:0] frame_phase,
    input  logic       celebrate,   // the pause after a cleared wall
    input  logic       game_over,
    input  logic       new_game,    // at frame_tick
    output logic       audio
);

  // Half-periods in lines: pentatonic C5 D5 E5 G5 A5 C6 D6 E6
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

  // The cleared-wall arpeggio (C E G C' E' C' G E), one note per step of the pause timer
  function automatic logic [2:0] arp(input logic [2:0] i);
    case (i)
      0: arp = 0; 1: arp = 2; 2: arp = 3; 3: arp = 5;
      4: arp = 7; 5: arp = 5; 6: arp = 3; default: arp = 2;
    endcase
  endfunction

  // Tier D's tune: 16 notes of 4 frames (an original phrase)
  function automatic logic [2:0] tune(input logic [3:0] i);
    case (i)
      0: tune = 0;  1: tune = 2;  2: tune = 3;  3: tune = 5;
      4: tune = 4;  5: tune = 3;  6: tune = 5;  7: tune = 7;
      8: tune = 6;  9: tune = 5;  10: tune = 4; 11: tune = 3;
      12: tune = 1; 13: tune = 2; 14: tune = 0; default: tune = 0;
    endcase
  endfunction

  typedef enum logic [2:0] {NONE, BRICK, PADDLE, LOST, WALL, JINGLE, PHRASE} kind_t;
  (* fsm_encoding = "none" *) kind_t kind;
  logic [6:0] note, count;  // half-period and the line count within it
  logic       square;
  logic [2:0] env;          // tone volume
  logic [5:0] timer;        // frames left of the current sound

  wire line = (h_pos == 0);
  wire [2:0] brick_note = (3'd5 - brick_row) + (speed_level[3] ? 3'd2 : 3'd0);
  wire [2:0] go_step = speed_level[4:2];  // game over: 0..7, 4 frames each
  wire jingle_long = (TIER >= 4);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      count  <= 0;
      square <= 0;
    end else if (line) begin
      if (count >= note - 1) begin
        count  <= 0;
        square <= ~square;
      end else begin
        count <= count + 1;
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      kind  <= NONE;
      note  <= 30;
      env   <= 0;
      timer <= 0;
    end else if (frame_tick) begin
      if (TIER >= 2 && game_over) begin
        // The descending scale C6 .. C5, after the lost-ball glide (steps 2..7 of 4 frames)
        if (go_step >= 2 && speed_level[1:0] == 0 && speed_level != 31) begin
          kind <= PHRASE;
          note <= scale(3'd7 - go_step);
          env  <= 6;
        end else if (kind == PHRASE && env != 0) env <= env - 1;
        else if (kind == LOST) begin
          note <= note + 6;
          if (timer[0] && env != 0) env <= env - 1;
          if (timer != 0) timer <= timer - 1;
        end else env <= 0;
      end else if (TIER >= 2 && celebrate) begin
        kind <= PHRASE;
        note <= scale(arp(speed_level[2:0]));
        if (frame_phase == 0) env <= 6;
        else if (env > 2) env <= env - 1;
      end else if (TIER >= 3 && new_game) begin
        kind  <= JINGLE;
        timer <= jingle_long ? 6'd63 : 6'd11;
        note  <= scale(0);
        env   <= 6;
      end else if (lost) begin
        kind  <= LOST;
        note  <= 15;
        env   <= 7;
        timer <= 12;
      end else if (brick && kind != LOST) begin
        kind  <= BRICK;
        note  <= scale(brick_note);
        env   <= 6;
        timer <= 6;
      end else if (paddle && kind != LOST) begin
        kind  <= PADDLE;
        note  <= 60;
        env   <= 5;
        timer <= 3;
      end else if (TIER <= 2 && wall && kind != LOST && (kind == NONE || timer == 0)) begin
        kind  <= WALL;
        note  <= scale(7);
        env   <= 2;
        timer <= 2;
      end else if (timer != 0) begin
        timer <= timer - 1;
        case (kind)
          LOST: begin
            note <= note + 6;
            if (timer[0] && env != 0) env <= env - 1;
          end
          PADDLE: begin
            note <= note + 6;
            env  <= (env > 2) ? env - 2 : 0;
          end
          JINGLE: begin
            // Tier C: C E G, 4 frames each; tier D: the tune, 16 notes of 4 frames
            if (timer[1:0] == 0) begin
              note <= jingle_long ? scale(tune(4'd15 - timer[5:2])) : scale(timer[3:2] == 2 ? 3'd2 : 3'd3);
              env  <= 6;
            end else if (env != 0) env <= env - 1;
          end
          default: if (env != 0) env <= env - 1;
        endcase
      end else begin
        env  <= 0;
        kind <= NONE;
      end
    end
  end

  // Tier C on: noise from a 9-bit LFSR clocked once per line, with its own fast-decaying volume
  logic [8:0] lfsr;
  logic [2:0] env2;
  always_ff @(posedge clk) begin
    if (!rst_n || TIER < 3) begin
      lfsr <= 1;
      env2 <= 0;
    end else begin
      if (line) lfsr <= {lfsr[7:0], lfsr[8] ^ lfsr[4]};
      if (frame_tick) begin
        if (wall) env2 <= 5;
        else if (paddle) env2 <= 4;
        else env2 <= (env2 > 2) ? env2 - 2 : 0;
      end
    end
  end

  wire [2:0] step = h_pos[3:1];
  wire tone_on  = square & (step < env);
  wire noise_on = lfsr[0] & (step < env2);
  always_ff @(posedge clk) begin
    if (!rst_n) audio <= 0;
    else if (TIER >= 3) audio <= h_pos[0] ? tone_on : noise_on;
    else audio <= tone_on;
  end

  wire _unused = &{v_pos, 1'b0};

endmodule
