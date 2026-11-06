/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Breakout: a brick-breaker game in a single Tiny Tapeout tile.
 *
 * Style: SystemVerilog. `logic` for all variables, always_ff for flip-flops,
 * always_comb for combinational blocks, and `wire x = ...` only for one-line
 * continuous definitions (a `logic x = ...` declaration would be a one-time
 * initialiser, not a continuous assignment).
 *
 * Pins (see inputs_t below and tiny_vga_out.sv for the exact bit layout):
 *   uo_out     : TinyVGA PMOD (640x480 @ 60 Hz, 25.175 MHz clock)
 *   ui_in[0..2]: direct buttons LEFT, RIGHT, FIRE (active high, for simulators /
 *                plain buttons; FIRE launches the ball / restarts after game over)
 *   ui_in[3]   : AUTOPLAY (paddle tracks the ball, auto-launch); on the gamepad,
 *                SELECT switches autoplay on and off
 *   ui_in[4..6]: Gamepad PMOD latch, clock, data (Psychogenic SNES Gamepad PMOD)
 *
 * Collisions with bricks and the paddle are detected by pixel overlap while
 * the frame is being drawn: whenever a ball pixel coincides with one a flag
 * is set (and a touched brick is cleared on the spot). The flags are consumed
 * once per frame at the start of vertical blanking, where the ball and
 * paddle are moved; the walls are checked there too, from the ball's
 * position.
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
  // direct controls for simulators such as tiny_explorer, which can toggle input pins
  // but can't generate the gamepad's serial stream.
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
  localparam logic [9:0] SCREEN_H = 480;  // visible lines in vga_timing's 640x480 mode

  // The paddle position is stored in 4-px units: paddle_q = paddle x / 4.
  localparam logic [7:0] PADDLE_MIN_Q   = 16;   // x = 64, against the left wall
  localparam logic [7:0] PADDLE_MAX_Q   = 128;  // x = 512, against the right wall
  localparam logic [7:0] PADDLE_START_Q = 72;   // x = 288, centred

  logic [7:0] paddle_q;
  wire  [9:0] paddle_x = paddle_q * 4;  // left edge of the 64-px paddle

  localparam logic [9:0] SERVE_DX    = 28;   // ball x relative to paddle x when resting on it (centred)
  localparam logic [9:0] SERVE_Y     = 440;  // ball y when resting on the paddle (paddle top is 448)
  localparam logic [1:0] SPARE_LIVES = 2;

  // Top-left of the 8x8 box the round ball is drawn in. The ball moves 2 px at a time
  // vertically and stays above y 512, so only y / 2 is stored.
  logic [9:0] ball_x;
  logic [7:0] ball_y_half;
  wire  [9:0] ball_y = {1'b0, ball_y_half, 1'b0};

  // Ball direction and speed, stored as sign and magnitude because that is how the game
  // changes them: walls set only the horizontal direction, the paddle sets the angle,
  // bricks flip only the vertical direction. (Two's-complement velocities need
  // negations and absolute values instead: ~6% more logic.)
  logic ball_left;   // moving left (else right)
  logic ball_steep;  // 2 px per frame horizontally (else 1)
  logic ball_up;     // moving up (else down); 2 px per frame vertically

  // Speed: the ball and the paddle move 1, 2 or 3 times per frame, on the first lines of
  // vertical blanking (480, 481, 482), each time by their usual step. Twice per frame after
  // the current ball has cleared 4 bricks, three times after 8. Back on the paddle (new
  // ball, level or game), the speed starts again at once per frame.
  logic [3:0] speed_level;  // bricks cleared by the current ball, up to 8

  logic [1:0] lives;      // spare balls; losing a ball with none left wraps to 3: game over
  logic       serving;    // ball resting on the paddle, waiting to be launched
  wire        game_over = (lives == 3);

  // Collision flags, gathered during each frame and consumed at frame_tick
  // (brick_top_bottom / brick_side: a brick was hit on its top or bottom / on a side edge).
  // The walls need no flags: whether the ball touches one follows from its position.
  typedef struct packed {
    logic brick_top_bottom, brick_side, paddle;
  } hits_t;
  hits_t      hit;
  logic [1:0] hit_quarter;  // paddle quarter the ball touched (0 = leftmost)

  // ---------------------------------------------------------------------------
  // Controls: gamepad, direct buttons and autoplay
  // ---------------------------------------------------------------------------
  gamepad_pkg::gamepad_t gp;        // gamepad report, all zero without a controller
  logic                  gp_valid;  // gp is complete (a few clocks per report)
  logic                  gp_left, gp_right, gp_fire;  // game controls from the last report
  logic                  gp_select;    // SELECT in the last report
  logic                  gp_autoplay;  // autoplay switched on with SELECT

  gamepad_rx u_gamepad_rx (
      .clk         (clk),
      .rst_n       (rst_n),
      .pmod_latch  (ui.gp_latch),
      .pmod_clk    (ui.gp_clk),
      .pmod_data   (ui.gp_data),
      .report      (gp),
      .report_valid(gp_valid)
  );

  // Keep only the game's controls from each report: fire is B, start or A. Each press of
  // SELECT (released in the previous report, pressed in this one) switches autoplay.
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gp_left     <= 0;
      gp_right    <= 0;
      gp_fire     <= 0;
      gp_select   <= 0;
      gp_autoplay <= 0;
    end else if (gp_valid) begin
      gp_left   <= gp.left;
      gp_right  <= gp.right;
      gp_fire   <= gp.b | gp.start | gp.a;
      gp_select <= gp.select;
      if (gp.select && !gp_select) gp_autoplay <= ~gp_autoplay;
    end
  end

  wire autoplay  = ui.autoplay | gp_autoplay;
  wire btn_left  = ui.left  | gp_left;
  wire btn_right = ui.right | gp_right;
  wire btn_fire  = ui.fire  | gp_fire | autoplay;  // autoplay launches the ball itself

  logic auto_left, auto_right;

  autoplay u_autoplay (
      .clk        (clk),
      .rst_n      (rst_n),
      .frame_tick (frame_tick),
      .paddle_hit (hit.paddle),
      .ball_x     (ball_x),
      .paddle_x   (paddle_x),
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
      .clear       (clear_brick),
      .brick_px    (brick_px),
      .brick_row   (brick_row),
      .over_columns(over_columns),
      .empty       (bricks_empty)
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

  // Playfield interior (dark background)
  wire field_px = over_columns && (v_pos[9:5] != 0);

  // Paddle: 64 x 8, one cell row high
  wire [9:0] paddle_dx = h_pos - paddle_x;  // beam offset from the paddle's left edge
  wire paddle_px = (cell_y == PADDLE_CELL_Y) && (paddle_dx[9:6] == 0);

  // True for pixels inside an 8-px circle, given the offset (0..7, 0..7) within its 8x8 box.
  // Folds each offset to its distance from the nearest edge (0..3), then cuts the corners,
  // giving rows 4, 6, 8, 8, 8, 8, 6, 4 pixels wide.
  function automatic logic in_circle8(input logic [2:0] x, input logic [2:0] y);
    logic [1:0] ex, ey;
    ex = x[2] ? ~x[1:0] : x[1:0];
    ey = y[2] ? ~y[1:0] : y[1:0];
    in_circle8 = (ex + ey) >= 2;  // not "return": the flow's yosys (0.62) lacks it
  endfunction

  // Ball: 8-px circle. Collisions use this shape too.
  wire [9:0] ball_dx = h_pos - ball_x;  // beam offset from the ball's box
  wire [9:0] ball_dy = v_pos - ball_y;
  wire ball_px = (ball_dx[9:3] == 0) && (ball_dy[9:3] == 0) &&
                 in_circle8(ball_dx[2:0], ball_dy[2:0]) && ~game_over;

  // Spare lives: 8-px circles in the 16-px slots at x 64 and x 80, shown for 1 and 2 spare
  // balls (none in game over, lives 3)
  wire life_slot_1 = (h_pos[9:4] == 4) && (lives == 1 || lives == 2);
  wire life_slot_2 = (h_pos[9:4] == 5) && (lives == 2);
  wire life_px = (cell_y == LIVES_CELL_Y) && ~h_pos[3] && in_circle8(h_pos[2:0], v_pos[2:0]) &&
                 (life_slot_1 || life_slot_2);

  // ---------------------------------------------------------------------------
  // Collisions: pixel overlap with the ball during scan-out
  // ---------------------------------------------------------------------------
  // The ball resting on the paddle never collides
  wire touch = ball_px & ~serving;

  assign clear_brick = touch && brick_px;

  // Which edge of a brick the ball came through. Its direction leaves two candidates, a side
  // edge and the top or bottom edge; it came through the one its 8x8 box is less far past.
  // Measured within the brick's 64x16 cell (brick at x 2..63, y 2..15), where the ball's box
  // starts at the contact pixel minus its offset in the box. A brick vanishes at its first
  // touched pixel, so this is decided there; ties (exact corners) count as top or bottom.
  wire signed [7:0] box_x = 8'(h_pos[5:0]) - 8'(ball_dx[2:0]);  // may be negative
  wire signed [7:0] box_y = 8'(v_pos[3:0]) - 8'(ball_dy[2:0]);
  wire signed [7:0] past_side = ball_left ? 64 - box_x : box_x + 6;  // right / left edge
  wire signed [7:0] past_flat = ball_up   ? 16 - box_y : box_y + 6;  // bottom / top edge
  wire              side_hit  = past_side < past_flat;

  // Collision flags: set during scan-out, consumed and cleared at frame_tick
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hit         <= '0;
      hit_quarter <= 0;
    end else if (frame_tick) begin
      hit <= '0;
    end else if (touch) begin
      if (brick_px && !side_hit) hit.brick_top_bottom <= 1;
      if (brick_px && side_hit)  hit.brick_side       <= 1;
      if (paddle_px) begin
        hit.paddle  <= 1;
        hit_quarter <= paddle_dx[5:4];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Frame update (at frame_tick; ball and paddle moves at move_tick)
  // ---------------------------------------------------------------------------
  wire ball_lost = (ball_y >= SCREEN_H);

  // The walls the ball touched in this frame, as the pixel overlap would find them: its
  // round shape reaches its box's left and right edges, and its top edge, so it touches
  // the left wall (x 56..63) when x <= 63, the right wall (x 576..583) when x + 7 >= 576,
  // the top wall (y 24..31) when y <= 31. Only at frame_tick, as for the flags: the extra
  // moves of a faster ball keep the direction.
  wire touch_wall_l = frame_tick && (ball_x[9:6] == 0);
  wire touch_wall_r = frame_tick && (ball_x >= 569);
  wire touch_wall_t = frame_tick && (ball_y[9:5] == 0);

  // Next ball direction from this frame's collisions. A paddle hit sends the ball up, left
  // from the left half and right from the right half, steeply from the outer quarters.
  // A brick turns it back vertically or horizontally, by the edge it hit.
  wire next_up           = hit.paddle ? 1 : touch_wall_t ? 0 : (ball_up ^ hit.brick_top_bottom);
  wire left_after_bounce = hit.paddle ? ~hit_quarter[1] : (ball_left ^ hit.brick_side);
  wire next_left         = touch_wall_l ? 0 : touch_wall_r ? 1 : left_after_bounce;
  wire next_steep        = hit.paddle ? (hit_quarter[1] ~^ hit_quarter[0]) : ball_steep;
  wire [9:0] step_x = next_left ? (next_steep ? -2 : -1) : (next_steep ? 2 : 1);
  wire [7:0] step_y_half = next_up ? -1 : 1;

  // Moves per frame: 1 + speed_level / 4, i.e. 1, 2 or 3. They happen at the start of lines
  // 480, 481 and 482 (the first is frame_tick): line 480 + k moves if k < moves. Collision
  // flags are cleared at frame_tick, so the extra moves keep the new direction.
  wire [1:0] moves     = 2'd1 + speed_level[3:2];
  wire       move_tick = (h_pos == 0) && (v_pos[9:2] == SCREEN_H[9:2]) && (v_pos[1:0] < moves);

  // What each frame update does, in priority order
  wire restart   = game_over & btn_fire;                  // new game after game over
  wire on_paddle = ~game_over & (serving | bricks_empty); // ball waits on the paddle
  wire lose_ball = ~game_over & ~on_paddle & ball_lost;   // ball fell off the bottom
  wire fly       = ~game_over & ~on_paddle & ~ball_lost;  // ball in flight

  // Paddle
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      paddle_q <= PADDLE_START_Q;
    end else if (move_tick) begin
      if (go_left && paddle_q != PADDLE_MIN_Q) paddle_q <= paddle_q - 1;
      else if (go_right && paddle_q != PADDLE_MAX_Q) paddle_q <= paddle_q + 1;
    end
  end

  // Ball position and direction
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ball_x      <= PADDLE_START_Q * 4 + SERVE_DX;  // resting on the paddle
      ball_y_half <= SERVE_Y[8:1];
      ball_left  <= 0;
      ball_steep <= 0;
      ball_up    <= 1;
    end else if (frame_tick && on_paddle) begin
      ball_x      <= paddle_x + SERVE_DX;
      ball_y_half <= SERVE_Y[8:1];
      ball_left  <= 0;
      ball_steep <= 0;
      ball_up    <= 1;
    end else if (move_tick && fly) begin
      ball_left  <= next_left;
      ball_steep <= next_steep;
      ball_up    <= next_up;
      ball_x      <= ball_x + step_x;
      ball_y_half <= ball_y_half + step_y_half;
    end
  end

  // Game progress: spare lives (and game over), serving
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lives   <= SPARE_LIVES;
      serving <= 1;
    end else if (frame_tick) begin
      if (restart) begin
        lives   <= SPARE_LIVES;
        serving <= 1;
      end else if (on_paddle) begin
        serving <= ~btn_fire;
      end else if (lose_ball) begin
        lives   <= lives - 1;  // from 0 to 3: game over
        serving <= 1;
      end
    end
  end

  // Bricks come back for a new game or level
  assign refill_bricks = frame_tick && (restart || (on_paddle && bricks_empty));

  // Speed: count the current ball's bricks, from 0 again whenever the ball is on the paddle
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      speed_level <= 0;
    end else if (frame_tick && on_paddle) begin
      speed_level <= 0;
    end else if (clear_brick && !speed_level[3]) begin  // stops at 8
      speed_level <= speed_level + 1;
    end
  end

  // ---------------------------------------------------------------------------
  // Video output
  // ---------------------------------------------------------------------------
  // What each thing looks like (the named colours are in colour_pkg)
  localparam colour_pkg::rgb_t BALL_COLOUR   = colour_pkg::WHITE;  // also the spare-life markers
  localparam colour_pkg::rgb_t PADDLE_COLOUR = colour_pkg::PALE_CYAN;
  localparam colour_pkg::rgb_t WALL_COLOUR   = colour_pkg::GREY;
  localparam colour_pkg::rgb_t FIELD_COLOUR  = colour_pkg::NAVY;

  // Brick colour by row, top to bottom
  colour_pkg::rgb_t brick_rgb;
  always_comb begin
    case (brick_row)
      0:       brick_rgb = colour_pkg::RED;
      1:       brick_rgb = colour_pkg::ORANGE;
      2:       brick_rgb = colour_pkg::YELLOW;
      3:       brick_rgb = colour_pkg::GREEN;
      4:       brick_rgb = colour_pkg::AZURE;
      default: brick_rgb = colour_pkg::VIOLET;
    endcase
  end

  // What is drawn where several things overlap: first match wins. (Outside the visible
  // area, tiny_vga_out blanks the output.)
  colour_pkg::rgb_t rgb;
  always_comb begin
    if (ball_px | life_px)      rgb = BALL_COLOUR;
    else if (paddle_px)         rgb = PADDLE_COLOUR;
    else if (brick_px)          rgb = brick_rgb;
    else if (wall_px)           rgb = WALL_COLOUR;
    else if (field_px)          rgb = FIELD_COLOUR;
    else                        rgb = colour_pkg::BLACK;
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

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, uio_in, ui.unused, paddle_dx[3:0],
                   gp.y, gp.up, gp.down, gp.x, gp.l, gp.r, 1'b0};

endmodule
