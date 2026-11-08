/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Breakout: a brick-breaker game in a single Tiny Tapeout tile.
 *
 * Style: `logic` for variables, always_ff for flip-flops, always_comb for combinational
 * blocks, and `wire x = expr;` for continuous definitions (`logic x = expr;` would only
 * initialise x).
 *
 * Pins (see inputs_t below and tiny_vga_out.sv for the exact bit layout):
 *   uo_out     : TinyVGA PMOD (640x480 @ 60 Hz, 25.175 MHz clock)
 *   ui_in[0..2]: direct buttons LEFT, RIGHT, FIRE (active high, for simulators /
 *                plain buttons; FIRE launches the ball / restarts after game over;
 *                on the gamepad, fire is A, X, L or R)
 *   ui_in[3]   : AUTOPLAY (paddle steers itself, auto-launch); on the gamepad, SELECT
 *                switches autoplay on and left, right or fire switches it off
 *   ui_in[4..6]: Gamepad PMOD latch, clock, data (Psychogenic SNES Gamepad PMOD)
 * With no controller connected the game plays itself (demo); see "Demo" below.
 *
 * Known risk: ui_in[0..3] are used without synchronisers (2 flip-flops each would cost 8).
 * A pin changing at a frame update could reach some flip-flops and not others, e.g. a
 * restart could reset the lives but not refill the wall. The gamepad pins are synchronised.
 *
 * Collisions with bricks and the paddle are found by pixel overlap during scan-out: a ball
 * pixel on a brick or paddle pixel sets a flag (and clears the brick at once). The flags
 * are used and cleared at frame_tick, the first of the frame's moves; wall contacts are
 * worked out there from the ball's position.
 *
 * Sections: pins, video timing, game state, controls, what is under the
 * beam, collisions, frame update, video output.
 */

`default_nettype none

module tt_um_tiny_breakout (
    input  logic [7:0] ui_in,    // Dedicated inputs
    output logic [7:0] uo_out,   // Dedicated outputs
    input  logic [7:0] uio_in,   // IOs: Input path
    output logic [7:0] uio_out,  // IOs: Output path
    output logic [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  logic       ena,      // always 1 when the design is powered, so you can ignore it
    input  logic       clk,      // clock
    input  logic       rst_n     // reset_n - low to reset
);

  // ---------------------------------------------------------------------------
  // Pins. Packed structs list fields most significant bit first.
  // ---------------------------------------------------------------------------
  // Bits 4..6 are fixed by the Gamepad PMOD's default pinout (PMOD IO5..IO7), see
  // https://github.com/psychogenic/gamepad-pmod. Bits 0..3 are this design's own choice:
  // direct controls for simulators such as tiny_explorer (https://znah.net/tiny_explorer/),
  // which can toggle input pins but can't generate the gamepad's serial stream.
  typedef struct packed {
    logic unused;    // [7]
    logic gp_data;   // [6] Gamepad PMOD
    logic gp_clk;    // [5]
    logic gp_latch;  // [4]
    logic autoplay;  // [3]
    logic fire;      // [2] direct buttons, active high
    logic right;     // [1]
    logic left;      // [0]
  } inputs_t;

  inputs_t ui;
  assign ui = ui_in;

  // ---------------------------------------------------------------------------
  // Video timing
  // ---------------------------------------------------------------------------
  logic [9:0] h_pos, v_pos;  // beam position
  logic       visible, h_sync_n, v_sync_n;
  logic       frame_tick;    // game update: first clock of vertical blanking

  vga_timing u_vga_timing (
      .clk         (clk),
      .rst_n       (rst_n),
      .h_pos       (h_pos),
      .v_pos       (v_pos),
      .visible     (visible),
      .h_sync_n    (h_sync_n),
      .v_sync_n    (v_sync_n),
      .vblank_start(frame_tick)
  );

  // ---------------------------------------------------------------------------
  // Game state
  // ---------------------------------------------------------------------------
  localparam logic [9:0] SCREEN_HEIGHT = 480;  // visible lines in vga_timing's 640x480 mode

  // The paddle is stored by its centre, in 4-px units: paddle_c4 = centre x / 4. Its width
  // depends on the level (paddle_w16, below), and keeping the centre lets it narrow evenly
  // from both ends, with the resting ball and the angle zones fixed relative to the centre.
  localparam logic [7:0] PADDLE_START_C4 = 80;  // x = 320, the middle of the field

  logic [7:0] paddle_c4;
  wire  [9:0] paddle_c = paddle_c4 * 4;  // the paddle's centre

  // Ball x relative to the paddle's centre when resting on it: the ball's 8-px box, centred
  localparam logic [9:0] SERVE_DX    = -10'd4;
  localparam logic [9:0] SERVE_Y     = 440;  // ball y when resting on the paddle (paddle top is 448)
  localparam logic [1:0] SPARE_LIVES = 2;

  // Top-left of the 8x8 box the round ball is drawn in. It moves in 2-px steps vertically
  // and stops at y 480 once lost, so only y / 2 is stored.
  logic [9:0] ball_x;
  logic [7:0] ball_y_half;
  wire  [9:0] ball_y = {1'b0, ball_y_half, 1'b0};

  // Ball direction and speed, stored as sign and magnitude because that is how the game
  // changes them: a wall sets one direction (the side walls the horizontal one, the top wall
  // the vertical one), a brick flips one (by the edge it was hit on), and the paddle sets
  // both and the angle. (Two's-complement velocities need negations and absolute values
  // instead: ~6% more logic.)
  logic ball_left;   // moving left (else right)
  logic ball_flat;   // 2 px per move horizontally (else 1): 45 degrees, else about 63
  logic ball_up;     // moving up (else down); 2 px per move vertically

  // Speed: the ball and paddle make 0, 1 or 2 moves per frame (see move_tick), each by
  // their usual step, averaging 2, 3, 4, 5 or 6 moves per 4 frames: 1x, 1.5x, 2x, 2.5x, 3x
  // (1x is a move every other frame: 1 px per frame vertically). speed_level counts the
  // bricks the current ball clears, and the speed rises a half step every 4, up to 3x from
  // 16. Every ball starts at 1x; the levels get harder through a narrower paddle instead.
  //
  // In the pause after a cleared wall, speed_level is the timer: 16..31, one step every 4
  // frames (about a second). After game over it is the curtain's line: 0..31, one per frame.
  logic [4:0] speed_level;
  logic [1:0] frame_phase;  // counts frames: the pattern of moves over 4 frames
  wire        odd_frame = frame_phase[0];

  logic [1:0] lives;      // spare balls; losing a ball with none left wraps to 3: game over
  logic       serving;    // ball resting on the paddle, waiting to be launched
  wire        game_over = (lives == 3);
  logic [1:0] level;      // 0 .. 3: from the 4th level on it stays at 3
  wire  [1:0] level_next = (level == 3) ? 2'd3 : level + 1;
  // The paddle's width in 16 px, by level: 96, 80, 64, then 48 px from the 4th level. It is
  // also the paddle's half-width in 8 px, which is how the drawing and the angle zones use it.
  wire  [2:0] paddle_w16 = 3'd6 - 3'(level);
  logic       new_game;   // decided in the frame update below

  // Collision flags, gathered during each frame and consumed at frame_tick
  // (brick_top_bottom / brick_side: a brick was hit on its top or bottom / on a side edge).
  // The walls need no flags: whether the ball touches one follows from its position.
  typedef struct packed {
    logic brick_top_bottom, brick_side, paddle;
  } hits_t;
  hits_t      hit;
  logic [1:0] hit_zone;  // paddle zone (0..3 from the left, see paddle_px) under the last ball
                         // pixel to touch the paddle: the right end of the ball's bottom row

  // ---------------------------------------------------------------------------
  // Controls: gamepad, direct buttons and autoplay
  // ---------------------------------------------------------------------------
  logic gp_connected;                             // a controller is connected (last report)
  logic gp_left_raw, gp_right_raw, gp_fire_raw;  // pressed in the last report, unmasked
  logic gp_autoplay_raw;                          // switched on with SELECT, unmasked

  gamepad_rx u_gamepad_rx (
      .clk            (clk),
      .rst_n          (rst_n),
      .pmod_latch     (ui.gp_latch),
      .pmod_clk       (ui.gp_clk),
      .pmod_data      (ui.gp_data),
      .connected      (gp_connected),
      .left           (gp_left_raw),
      .right          (gp_right_raw),
      .fire           (gp_fire_raw),
      .select_autoplay(gp_autoplay_raw)
  );

  wire gp_left  = gp_left_raw  & gp_connected;
  wire gp_right = gp_right_raw & gp_connected;
  wire gp_fire  = gp_fire_raw  & gp_connected;
  wire gp_autoplay = gp_autoplay_raw & gp_connected;

  // Demo: autoplay while no controller is connected, until a direct button is pressed
  // (held at a frame update; for simulators that only toggle pins). Ending the demo starts
  // a new game. Unplugging the controller later resumes the demo in the current game.
  logic demo_allowed;  // no direct button pressed since power-up
  logic demo_was;      // the demo ran in the previous frame
  wire  demo     = demo_allowed & ~gp_connected;
  wire  end_demo = demo_was & ~demo;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      demo_allowed <= 1;
      demo_was     <= 0;
    end else if (frame_tick) begin
      if (ui.left || ui.right || ui.fire) demo_allowed <= 0;
      demo_was <= demo;
    end
  end

  wire autoplay  = ui.autoplay | gp_autoplay | demo;
  wire btn_left  = ui.left  | gp_left;
  wire btn_right = ui.right | gp_right;
  wire btn_fire  = ui.fire  | gp_fire | autoplay;  // autoplay launches the ball itself

  // Chance: an LFSR that steps every frame, for autoplay's aim and the shape of each wall
  logic [4:0] random;

  lfsr u_lfsr (
      .clk       (clk),
      .rst_n     (rst_n),
      .frame_tick(frame_tick),
      .value     (random)
  );

  logic auto_left, auto_right;

  autoplay u_autoplay (
      .clk        (clk),
      .rst_n      (rst_n),
      .frame_tick (frame_tick),
      .paddle_hit (hit.paddle),
      .random     (random[1:0]),
      .ball_x     (ball_x),
      .paddle_c   (paddle_c),
      .paddle_w16 (paddle_w16),
      .steer_left (auto_left),
      .steer_right(auto_right)
  );

  // Paddle steering: from autoplay, or from the buttons (left and right together cancel)
  wire go_left  = autoplay ? auto_left  : (btn_left & ~btn_right);
  wire go_right = autoplay ? auto_right : (btn_right & ~btn_left);

  // ---------------------------------------------------------------------------
  // What is under the beam
  // ---------------------------------------------------------------------------
  // Bricks: the wall reports whether a standing brick is under the beam
  logic       brick_px;
  logic [2:0] brick_row;      // 0 (top) .. 5, while brick_px
  logic       over_columns;   // beam within the wall's x range
  logic       bricks_empty;
  logic       refill_bricks;  // decided by the frame update below
  logic       clear_brick;    // decided by the collision logic below

  brick_wall u_brick_wall (
      .clk         (clk),
      .rst_n       (rst_n),
      .h_pos       (h_pos),
      .v_pos       (v_pos),
      .refill      (refill_bricks),
      .full_wall   (level == 0),  // the first wall of a game; later ones are patterns
      .random      (random),
      .clear       (clear_brick),
      .brick_px    (brick_px),
      .brick_row   (brick_row),
      .over_columns(over_columns),
      .empty       (bricks_empty)
  );

  // Score: 10 per brick (shown with a fixed last 0), back to 0000 for a new game; top right
  logic score_px;

  score u_score (
      .clk     (clk),
      .rst_n   (rst_n),
      .clear   (frame_tick && new_game),
      .add     (clear_brick),
      .h_pos   (h_pos),
      .v_pos   (v_pos),
      .score_px(score_px)
  );

  // Walls, paddle and life markers are aligned to a grid of 8x8-px cells
  wire [6:0] cell_x = h_pos[9:3];
  wire [6:0] cell_y = v_pos[9:3];
  localparam logic [6:0] WALL_L_CELL   = 7;   // x 56..63
  localparam logic [6:0] WALL_R_CELL   = 72;  // x 576..583
  localparam logic [6:0] WALL_T_CELL   = 3;   // y 24..31
  localparam logic [6:0] PADDLE_CELL_Y = 56;  // y 448..455
  localparam logic [6:0] LIVES_CELL_Y  = 1;   // y 8..15

  wire wall_l_col = (cell_x == WALL_L_CELL);
  wire wall_r_col = (cell_x == WALL_R_CELL);
  wire wall_l_px  = wall_l_col && (cell_y >= WALL_T_CELL);
  wire wall_r_px  = wall_r_col && (cell_y >= WALL_T_CELL);
  // The top wall spans the left wall, the brick columns and the right wall
  wire wall_t_px  = (cell_y == WALL_T_CELL) && (wall_l_col || over_columns || wall_r_col);
  wire wall_px    = wall_l_px | wall_r_px | wall_t_px;

  // Playfield interior (dark background): the wall's columns, below the top wall (y >= 32)
  wire field_px = over_columns && (v_pos[9:5] != 0);

  // Paddle: 8 px high, one cell row, and 16 x paddle_w16 px wide around its centre: the beam
  // offset from the centre, paddle_dx, runs from -8 x paddle_w16 to 8 x paddle_w16 - 1. Folded
  // to a distance in 8-px units (inverting the negative side, as ~d = -d - 1), both halves
  // are 0 .. paddle_w16 - 1 exactly.
  wire [9:0] paddle_dx = h_pos - paddle_c;
  wire [6:0] paddle_d8 = paddle_dx[9:3] ^ {7{paddle_dx[9]}};
  wire       paddle_px = (cell_y == PADDLE_CELL_Y) && (paddle_d8 < 7'(paddle_w16));
  // Angle zones, 0..3 from the left: the outer 16 px at each end (0 and 3) send the ball off
  // at the flatter angle, the rest (1 and 2) at the steeper one; the half sets the direction.
  wire       paddle_right = !paddle_dx[9];
  wire       paddle_outer = paddle_d8 >= 7'(paddle_w16) - 2;
  wire [1:0] paddle_zone  = {paddle_right, paddle_right ^ !paddle_outer};

  // True for pixels inside an 8-px circle, given the offset (0..7, 0..7) within its 8x8 box.
  // Folds each offset to its distance from the nearest edge (0..3), then cuts the corners,
  // giving rows 4, 6, 8, 8, 8, 8, 6, 4 pixels wide.
  function automatic logic in_circle8(input logic [2:0] x, input logic [2:0] y);
    logic [1:0] ex, ey;
    ex = x[2] ? ~x[1:0] : x[1:0];
    ey = y[2] ? ~y[1:0] : y[1:0];
    in_circle8 = (ex + ey) >= 2;  // not "return": the flow's yosys (0.62) lacks it
  endfunction

  // Ball: 8-px circle, which collisions use too. Its 8x8 box is found by racing the beam
  // rather than by subtracting: it starts where the beam meets the box's corner and lasts
  // until the 3-bit offset wraps to 0 (8 px / 8 lines). The flip-flops hold the previous
  // clock's state.
  wire [2:0] ball_dx = h_pos[2:0] - ball_x[2:0];  // beam offset within the ball's box
  wire [2:0] ball_dy = v_pos[2:0] - ball_y[2:0];
  logic in_ball_x_q, in_ball_y_q;
  wire  in_ball_x = (h_pos == ball_x) | (in_ball_x_q & (ball_dx != 0));
  wire  in_ball_y = (v_pos == ball_y) | (in_ball_y_q & (ball_dy != 0));

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      in_ball_x_q <= 0;
      in_ball_y_q <= 0;
    end else begin
      in_ball_x_q <= in_ball_x;
      in_ball_y_q <= in_ball_y;
    end
  end

  wire ball_px = in_ball_x && in_ball_y &&
                 in_circle8(ball_dx, ball_dy) && ~game_over;

  // Spare lives: 8-px circles at x 64 (with 1 or 2 spare balls) and x 80 (with 2), y 8..15
  wire life_slot_1 = (h_pos[9:4] == 4) && (lives >= 1) && (lives <= SPARE_LIVES);
  wire life_slot_2 = (h_pos[9:4] == 5) && (lives >= 2) && (lives <= SPARE_LIVES);
  wire life_px = (cell_y == LIVES_CELL_Y) && ~h_pos[3] && in_circle8(h_pos[2:0], v_pos[2:0]) &&
                 (life_slot_1 || life_slot_2);

  // ---------------------------------------------------------------------------
  // Collisions: pixel overlap with the ball during scan-out
  // ---------------------------------------------------------------------------
  // The ball resting on the paddle never collides
  wire touch = ball_px & ~serving;

  assign clear_brick = touch && brick_px;

  // Which edge of a brick the ball came through: of the two its direction allows (a side,
  // and the top or bottom), the one its 8x8 box is less far past; ties go to top/bottom.
  // Measured in the brick's 64x16 cell (brick at x 2..63, y 2..15) at the first touched
  // pixel, where the brick vanishes.
  wire signed [7:0] box_x = 8'(h_pos[5:0]) - 8'(ball_dx);  // may be negative
  wire signed [7:0] box_y = 8'(v_pos[3:0]) - 8'(ball_dy);
  wire signed [7:0] past_side = ball_left ? 64 - box_x : box_x + 6;  // right / left edge
  wire signed [7:0] past_flat = ball_up   ? 16 - box_y : box_y + 6;  // bottom / top edge
  wire              side_hit  = past_side < past_flat;

  // Collision flags: set during scan-out, consumed and cleared at frame_tick
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hit         <= '0;
      hit_zone    <= 0;
    end else if (frame_tick) begin
      hit <= '0;
    end else if (touch) begin
      if (brick_px && !side_hit) hit.brick_top_bottom <= 1;
      if (brick_px && side_hit)  hit.brick_side       <= 1;
      if (paddle_px) begin
        hit.paddle  <= 1;
        hit_zone    <= paddle_zone;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Frame update (at frame_tick; ball and paddle moves at move_tick)
  // ---------------------------------------------------------------------------
  wire ball_lost = (ball_y >= SCREEN_HEIGHT);

  // The walls the ball touched in this frame, as the pixel overlap would find them: its
  // round shape reaches its box's left, right and top edges, so it touches the left wall
  // (x 56..63) when x <= 63, the right wall when x + 7 reaches it, and the top wall
  // (y 24..31) when y <= 31. Only at frame_tick, as for the flags: the extra moves of a
  // faster ball keep the direction.
  localparam logic [9:0] WALL_R_X = 10'(WALL_R_CELL) * 8;  // x 576
  wire touch_wall_l = frame_tick && (ball_x[9:6] == 0);
  wire touch_wall_r = frame_tick && (ball_x >= WALL_R_X - 7);
  wire touch_wall_t = frame_tick && (ball_y[9:5] == 0);

  // Next ball direction from this frame's collisions. A paddle hit sends the ball up, left
  // from the left half and right from the right half, at a flatter angle from the outer
  // zones. A brick turns it back vertically or horizontally, by the edge it hit.
  wire next_up           = hit.paddle ? 1 : touch_wall_t ? 0 : (ball_up ^ hit.brick_top_bottom);
  wire left_after_bounce = hit.paddle ? ~hit_zone[1] : (ball_left ^ hit.brick_side);
  wire next_left         = touch_wall_l ? 0 : touch_wall_r ? 1 : left_after_bounce;
  wire next_flat         = hit.paddle ? (hit_zone[1] ~^ hit_zone[0]) : ball_flat;
  // One move's step: x by -2, -1, 1 or 2 (left or right, flat or steep); y by 2 px up or down,
  // which is -1 or 1 in ball_y_half.
  wire [9:0] step_x = next_left ? (next_flat ? -2 : -1) : (next_flat ? 2 : 1);

  // The moved ball_y_half. This means ball_y_half + (next_up ? -1 : 1), written as an
  // incrementer between two sets of XOR gates: moving up, the XORs invert the value before
  // and after adding 1, and in two's complement ~(~y + 1) = y - 1 (as ~y = -y - 1). Synthesis
  // builds this smaller than an adder whose step changes sign, so keep this form.
  wire [7:0] ball_y_half_moved = ((ball_y_half ^ {8{next_up}}) + 1) ^ {8{next_up}};

  // Moves per frame over the 4-frame phase 0, 1, 2, 3: one on even frames; one on odd frames
  // too if speed_level[3] (2x); one more in phase 1 if speed_level[2] (a half step); and
  // from speed_level 16 (and in the pause) 1, 2, 1, 2. Line 480 + k moves if k < moves (line
  // 480 is frame_tick).
  wire [1:0] moves = speed_level[4] ? 2'd1 + 2'(odd_frame)
                   : 2'(!odd_frame) + 2'(speed_level[3] & odd_frame) +
                     2'(speed_level[2] & (frame_phase == 1));
  wire move_tick = (h_pos == 0) && (v_pos[9:2] == SCREEN_HEIGHT[9:2]) && (v_pos[1:0] < moves);

  // What the frame update does. restart needs game over; otherwise exactly one of on_paddle,
  // lose_ball and fly holds. new_game (end_demo) can coincide with any of them and wins.
  wire restart    = game_over & btn_fire;                  // new game after game over
  assign new_game = restart | end_demo;                    // ... or when the demo ends
  wire on_paddle  = ~game_over & (serving | bricks_empty); // ball waits on the paddle
  wire lose_ball  = ~game_over & ~on_paddle & ball_lost;   // ball fell off the bottom
  wire fly        = ~game_over & ~on_paddle & ~ball_lost;  // ball in flight
  wire paused     = on_paddle & bricks_empty;              // the wall was cleared ...
  wire level_done = paused & (speed_level == 31);          // ... and the pause is over

  // Paddle: one 4-px step per move, stopping at the walls, where its centre is half a width
  // from x 64 or x 576: centre / 4 = 16 + 2 x paddle_w16 or 144 - 2 x paddle_w16. A narrower
  // paddle only moves its stops outwards; a new game widens it again, so it starts centred.
  //
  // A new game puts the paddle, the ball and its speed back as reset does (below): the paddle
  // centred, the ball resting on it, 1x. Doing it in the same clock for all three keeps the
  // ball on the paddle, and no state from the last game (such as speed_level at 31, after the
  // curtain) carries into the first frame of the new one.
  wire [7:0] paddle_half4   = {4'b0, paddle_w16, 1'b0};  // half the width, in 4 px
  wire [7:0] paddle_c4_next = (go_left  && paddle_c4 != 8'd16 + paddle_half4)  ? paddle_c4 - 1 :
                              (go_right && paddle_c4 != 8'd144 - paddle_half4) ? paddle_c4 + 1 :
                              paddle_c4;

  always_ff @(posedge clk) begin
    if (!rst_n || (frame_tick && new_game)) paddle_c4 <= PADDLE_START_C4;
    else if (move_tick) paddle_c4 <= paddle_c4_next;
  end

  // The ball's next x. Both ways it moves are a base plus an offset: resting on the paddle it
  // is placed at the paddle's centre + SERVE_DX, and in flight it steps from its own x by step_x.
  // Choosing the operands and adding once, instead of writing the two sums in their branches
  // below, leaves a single 10-bit adder and a plain load in front of ball_x; yosys does not
  // merge the two sums by itself, and the separate adders cost noticeably more area.
  wire [9:0] ball_x_next = (on_paddle ? 10'(paddle_c4_next) * 4 : ball_x) +
                           (on_paddle ? SERVE_DX : step_x);

  // Ball position and direction. On the paddle it is placed at every move, after that
  // move's paddle step, so it stays centred while the paddle moves. Both the placing and the
  // moving load ball_x_next (above).
  always_ff @(posedge clk) begin
    if (!rst_n || (frame_tick && new_game)) begin
      ball_x      <= PADDLE_START_C4 * 4 + SERVE_DX;  // resting on the paddle
      ball_y_half <= SERVE_Y[8:1];
      ball_left   <= 0;
      ball_flat   <= 0;
      ball_up     <= 1;
    end else if (move_tick && on_paddle) begin
      ball_x      <= ball_x_next;
      ball_y_half <= SERVE_Y[8:1];
      ball_left   <= 0;
      ball_flat   <= 0;
      ball_up     <= 1;
    end else if (fly && (frame_tick || move_tick)) begin
      // The direction takes in the frame's collisions at frame_tick, also in a frame with no
      // move (at 1x every other frame has none): the flags are cleared then, and a cleared
      // brick would not be hit again. Later moves keep it, as the flags are clear by then.
      ball_left <= next_left;
      ball_flat <= next_flat;
      ball_up   <= next_up;
      if (move_tick) begin
        ball_x      <= ball_x_next;
        ball_y_half <= ball_y_half_moved;
      end
    end
  end

  // Game progress: spare lives (and game over), serving
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lives   <= SPARE_LIVES;
      serving <= 1;
    end else if (frame_tick) begin
      if (new_game) begin
        lives   <= SPARE_LIVES;
        serving <= 1;
      end else if (on_paddle) begin
        serving <= ~btn_fire;
        if (level_done && lives != SPARE_LIVES) lives <= lives + 1;  // a spare ball for the level
      end else if (lose_ball) begin
        lives   <= lives - 1;  // from 0 to 3: game over
        serving <= 1;
      end
    end
  end

  // Level: 0 for a new game, +1 (up to 3) when the pause after a cleared wall ends
  always_ff @(posedge clk) begin
    if (!rst_n) level <= 0;
    else if (frame_tick && new_game) level <= 0;
    else if (frame_tick && level_done) level <= level_next;
  end

  // Bricks come back for a new game, or after the pause for the next level
  assign refill_bricks = frame_tick && (new_game || level_done);

  // speed_level: 0 while the ball is on the paddle and from a lost ball, +1 per brick while
  // it flies (up to 16); in the pause, 16..31, a step every 4th frame; after game over, +1 per
  // frame up to 31
  always_ff @(posedge clk) begin
    if (!rst_n || (frame_tick && new_game)) begin
      speed_level <= 0;
    end else if (frame_tick && paused) begin
      // Set here: with FIRE held the ball launches next frame, skipping the on_paddle branch
      if (level_done) speed_level <= 0;
      else if (!speed_level[4]) speed_level <= 16;
      else if (frame_phase == 3) speed_level <= speed_level + 1;
    end else if (frame_tick && (on_paddle || lose_ball)) begin
      speed_level <= 0;
    end else if (frame_tick && game_over && speed_level != 31) begin
      speed_level <= speed_level + 1;
    end else if (clear_brick && !speed_level[4]) begin  // stops at 16
      speed_level <= speed_level + 1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) frame_phase <= 0;
    else if (frame_tick) frame_phase <= frame_phase + 1;
  end

  // ---------------------------------------------------------------------------
  // Video output
  // ---------------------------------------------------------------------------
  // What each thing looks like (the named colours are in colour_pkg)
  localparam colour_pkg::rgb_t BALL_COLOUR   = colour_pkg::WHITE;  // also the spare-life markers and score
  localparam colour_pkg::rgb_t PADDLE_COLOUR = colour_pkg::PALE_CYAN;
  localparam colour_pkg::rgb_t WALL_COLOUR   = colour_pkg::GREY;
  localparam colour_pkg::rgb_t FIELD_COLOUR  = colour_pkg::NAVY;

  // A ball wholly below the paddle (y >= 456) can no longer touch it, or anything else that
  // would send it up: it is lost. The black border shows it until the ball leaves the screen
  // (a ball at rest on the paddle is at y 440; after game over it stays below the screen). Not
  // from fly: that is valid only at frame_tick, as the wall's emptiness is read off the picture.
  wire ball_doomed = (ball_y[9:3] > PADDLE_CELL_Y) && !ball_lost;

  // Game over: a black curtain comes down from the top, 16 px a frame (half a second to the
  // bottom), leaving only the score. speed_level is its line.
  wire curtain = game_over && (v_pos[9:4] < {1'b0, speed_level});
  // Red that brightens as it falls: ball_y[4:3] is 1, 2, 3 for y 456, 464, 472 (maroon, dark
  // red, red), so the pulse keeps pace with the ball
  colour_pkg::rgb_t lost_rgb;
  assign lost_rgb = {ball_y[4:3], 4'b0000};  // {r, g, b}

  // Celebration, in the pause after a cleared wall: rainbow bands rise behind the ball and
  // paddle, over the field and the border. The pause is while speed_level counts 17..31 (in
  // play it stops at 16). The bands are 64 px tall and rise 2 px per frame: the band under the
  // beam is its line in 2-px units plus a count of the pause's frames, in 32s.
  wire       celebrate = !game_over && speed_level[4] && (speed_level[3:0] != 0);
  wire [7:0] band_y    = v_pos[8:1] + 8'({speed_level[3:0], frame_phase});

  // Brick colour by row, top to bottom; in the celebration, the colour of the band, which
  // goes on past violet through magenta and rose, back to red
  wire [2:0] colour_row = celebrate ? band_y[7:5] : brick_row;
  colour_pkg::rgb_t brick_rgb;
  always_comb begin
    case (colour_row)
      0:       brick_rgb = colour_pkg::RED;
      1:       brick_rgb = colour_pkg::ORANGE;
      2:       brick_rgb = colour_pkg::YELLOW;
      3:       brick_rgb = colour_pkg::GREEN;
      4:       brick_rgb = colour_pkg::AZURE;
      5:       brick_rgb = colour_pkg::VIOLET;
      6:       brick_rgb = colour_pkg::MAGENTA;
      default: brick_rgb = colour_pkg::ROSE;
    endcase
  end

  // What is drawn where several things overlap: first match wins. (Outside the visible
  // area, tiny_vga_out blanks the output.)
  colour_pkg::rgb_t rgb;
  always_comb begin
    if (curtain && !score_px)              rgb = colour_pkg::BLACK;
    else if (ball_px | life_px | score_px) rgb = BALL_COLOUR;
    else if (paddle_px)                    rgb = PADDLE_COLOUR;
    else if (brick_px)                     rgb = brick_rgb;
    else if (wall_px)                      rgb = WALL_COLOUR;
    else if (celebrate)                    rgb = brick_rgb;  // the band's colour
    else if (field_px)                     rgb = FIELD_COLOUR;
    else if (ball_doomed)                  rgb = lost_rgb;
    else                                   rgb = colour_pkg::BLACK;
  end

  tiny_vga_out u_tiny_vga_out (
      .clk     (clk),
      .rst_n   (rst_n),
      .colour  (rgb),
      .visible (visible),
      .h_sync_n(h_sync_n),
      .v_sync_n(v_sync_n),
      .uo_out  (uo_out)
  );

  assign uio_out = 0;
  assign uio_oe  = 0;

  // Unused inputs and signal bits, listed to silence lint warnings
  wire _unused = &{ena, uio_in, ui.unused, paddle_dx[2:0], band_y[4:0], 1'b0};

endmodule
