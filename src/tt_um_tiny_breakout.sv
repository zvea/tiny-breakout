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
 * Pins (see inputs_t and tiny_vga_t below for the exact bit layout):
 *   uo_out     : TinyVGA PMOD (640x480 @ 60 Hz, 25.175 MHz clock)
 *   ui_in[0..2]: direct buttons LEFT, RIGHT, FIRE (active high, for simulators /
 *                plain buttons; FIRE launches the ball / restarts after game over)
 *   ui_in[3]   : AUTOPLAY (paddle tracks the ball, auto-launch)
 *   ui_in[4..6]: Gamepad PMOD latch, clock, data (Psychogenic SNES Gamepad PMOD)
 *
 * Collisions are detected by pixel overlap while the frame is being drawn:
 * whenever a ball pixel coincides with a wall/brick/paddle pixel a flag is
 * set (and a touched brick is cleared on the spot). All flags are consumed
 * once per frame at the start of vertical blanking, where the ball and
 * paddle are moved.
 *
 * Sections: types and pins, video timing, game state, controls, what is under the
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
  // Types and pins. Packed structs list fields most significant bit first.
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

  // TinyVGA PMOD: 2 bits per colour, with each colour's bits on different pins
  typedef struct packed {
    logic h_sync, b0, g0, r0, v_sync, b1, g1, r1;
  } tiny_vga_t;

  // Colours: 2 bits each of red, green and blue
  typedef struct packed {
    logic [1:0] r, g, b;
  } rgb_t;

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

  logic [9:0] ball_x, ball_y;  // top-left of the 8x8 box the round ball is drawn in

  // Ball direction and speed, stored as sign and magnitude because that is how the game
  // changes them: walls set only the horizontal direction, the paddle sets the angle,
  // bricks flip only the vertical direction. (Two's-complement velocities need
  // negations and absolute values instead: ~6% more logic.)
  logic ball_left;   // moving left (else right)
  logic ball_steep;  // 2 px per frame horizontally (else 1)
  logic ball_up;     // moving up (else down); always 2 px per frame vertically

  logic [1:0] lives;      // spare balls
  logic       serving;    // ball resting on the paddle, waiting to be launched
  logic       game_over;

  // Collision flags, gathered during each frame and consumed at frame_tick
  typedef struct packed { logic wall_l, wall_r, wall_t, brick, paddle; } hits_t;
  hits_t      hit;
  logic [1:0] hit_quarter;  // paddle quarter the ball touched (0 = leftmost)

  // ---------------------------------------------------------------------------
  // Controls: gamepad, direct buttons and autoplay
  // ---------------------------------------------------------------------------
  gamepad_pkg::gamepad_t gp;        // gamepad report, all zero without a controller
  logic                  gp_valid;  // gp is complete (one clock per report)
  logic                  gp_left, gp_right, gp_fire;  // game controls from the last report

  gamepad_rx u_gamepad_rx (
      .clk         (clk),
      .rst_n       (rst_n),
      .pmod_latch  (ui.gp_latch),
      .pmod_clk    (ui.gp_clk),
      .pmod_data   (ui.gp_data),
      .report      (gp),
      .report_valid(gp_valid)
  );

  // Keep only the game's controls from each report: fire is B, start or A
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gp_left  <= 0;
      gp_right <= 0;
      gp_fire  <= 0;
    end else if (gp_valid) begin
      gp_left  <= gp.left;
      gp_right <= gp.right;
      gp_fire  <= gp.b | gp.start | gp.a;
    end
  end

  wire btn_left  = ui.left  | gp_left;
  wire btn_right = ui.right | gp_right;
  wire btn_fire  = ui.fire  | gp_fire | ui.autoplay;  // autoplay launches the ball itself

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
  wire go_left  = ui.autoplay ? auto_left  : (btn_left & ~btn_right);
  wire go_right = ui.autoplay ? auto_right : (btn_right & ~btn_left);

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

  // Spare lives: 8-px circles in 16-px slots from x 64; marker i is shown while lives > i
  localparam logic [5:0] FIRST_LIFE_SLOT = 4;  // x 64
  wire [5:0] life_slot = h_pos[9:4] - FIRST_LIFE_SLOT;
  wire life_px = (cell_y == LIVES_CELL_Y) && ~h_pos[3] && in_circle8(h_pos[2:0], v_pos[2:0]) &&
                 (life_slot < 6'(lives));

  // ---------------------------------------------------------------------------
  // Collisions: pixel overlap with the ball during scan-out
  // ---------------------------------------------------------------------------
  // The ball resting on the paddle never collides
  wire touch = ball_px & ~serving;

  assign clear_brick = touch && brick_px;

  // Collision flags: set during scan-out, consumed and cleared at frame_tick
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hit         <= '0;
      hit_quarter <= 0;
    end else if (frame_tick) begin
      hit <= '0;
    end else if (touch) begin
      if (wall_l_px) hit.wall_l <= 1;
      if (wall_r_px) hit.wall_r <= 1;
      if (wall_t_px) hit.wall_t <= 1;
      if (brick_px)  hit.brick  <= 1;
      if (paddle_px) begin
        hit.paddle  <= 1;
        hit_quarter <= paddle_dx[5:4];
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Frame update (at frame_tick)
  // ---------------------------------------------------------------------------
  wire ball_lost = (ball_y >= SCREEN_H);

  // Next ball direction from this frame's collisions. A paddle hit sends the ball up, left
  // from the left half and right from the right half, steeply from the outer quarters.
  wire next_up           = hit.paddle ? 1 : hit.wall_t ? 0 : (ball_up ^ hit.brick);
  wire left_after_paddle = hit.paddle ? ~hit_quarter[1] : ball_left;
  wire next_left         = hit.wall_l ? 0 : hit.wall_r ? 1 : left_after_paddle;
  wire next_steep        = hit.paddle ? (hit_quarter[1] ~^ hit_quarter[0]) : ball_steep;
  wire [9:0] step_x = next_left ? (next_steep ? -2 : -1) : (next_steep ? 2 : 1);
  wire [9:0] step_y = next_up ? -2 : 2;

  // What each frame update does, in priority order
  wire restart   = game_over & btn_fire;                  // new game after game over
  wire on_paddle = ~game_over & (serving | bricks_empty); // ball waits on the paddle
  wire lose_ball = ~game_over & ~on_paddle & ball_lost;   // ball fell off the bottom
  wire fly       = ~game_over & ~on_paddle & ~ball_lost;  // ball in flight

  // Paddle
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      paddle_q <= PADDLE_START_Q;
    end else if (frame_tick) begin
      if (go_left && paddle_q != PADDLE_MIN_Q) paddle_q <= paddle_q - 1;
      else if (go_right && paddle_q != PADDLE_MAX_Q) paddle_q <= paddle_q + 1;
    end
  end

  // Ball position and direction
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      ball_x     <= PADDLE_START_Q * 4 + SERVE_DX;  // resting on the paddle
      ball_y     <= SERVE_Y;
      ball_left  <= 0;
      ball_steep <= 0;
      ball_up    <= 1;
    end else if (frame_tick && on_paddle) begin
      ball_x     <= paddle_x + SERVE_DX;
      ball_y     <= SERVE_Y;
      ball_left  <= 0;
      ball_steep <= 0;
      ball_up    <= 1;
    end else if (frame_tick && fly) begin
      ball_left  <= next_left;
      ball_steep <= next_steep;
      ball_up    <= next_up;
      ball_x     <= ball_x + step_x;
      ball_y     <= ball_y + step_y;
    end
  end

  // Game progress: spare lives, serving, game over
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lives     <= SPARE_LIVES;
      serving   <= 1;
      game_over <= 0;
    end else if (frame_tick) begin
      if (restart) begin
        lives     <= SPARE_LIVES;
        serving   <= 1;
        game_over <= 0;
      end else if (on_paddle) begin
        serving <= ~btn_fire;
      end else if (lose_ball) begin
        if (lives == 0) begin
          game_over <= 1;
        end else begin
          lives   <= lives - 1;
          serving <= 1;
        end
      end
    end
  end

  // Bricks come back for a new game or level
  assign refill_bricks = frame_tick && (restart || (on_paddle && bricks_empty));

  // ---------------------------------------------------------------------------
  // Video output
  // ---------------------------------------------------------------------------
  localparam rgb_t BLACK     = 6'b00_00_00;
  localparam rgb_t WHITE     = 6'b11_11_11;
  localparam rgb_t PALE_CYAN = 6'b10_11_11;
  localparam rgb_t GREY      = 6'b01_01_01;
  localparam rgb_t NAVY      = 6'b00_00_01;
  localparam rgb_t RED       = 6'b11_00_00;
  localparam rgb_t ORANGE    = 6'b11_10_00;
  localparam rgb_t YELLOW    = 6'b11_11_00;
  localparam rgb_t GREEN     = 6'b00_11_00;
  localparam rgb_t AZURE     = 6'b00_10_11;
  localparam rgb_t VIOLET    = 6'b10_00_11;

  localparam rgb_t BALL_COLOUR   = WHITE;      // also the spare-life markers (spare balls)
  localparam rgb_t PADDLE_COLOUR = PALE_CYAN;
  localparam rgb_t WALL_COLOUR   = GREY;
  localparam rgb_t FIELD_COLOUR  = NAVY;

  // Brick colour by row, top to bottom
  rgb_t brick_rgb;
  always_comb begin
    case (brick_row)
      0:       brick_rgb = RED;
      1:       brick_rgb = ORANGE;
      2:       brick_rgb = YELLOW;
      3:       brick_rgb = GREEN;
      4:       brick_rgb = AZURE;
      default: brick_rgb = VIOLET;
    endcase
  end

  // What is drawn where several things overlap: first match wins
  rgb_t rgb;
  always_comb begin
    if (!visible)               rgb = BLACK;
    else if (ball_px | life_px) rgb = BALL_COLOUR;
    else if (paddle_px)         rgb = PADDLE_COLOUR;
    else if (brick_px)          rgb = brick_rgb;
    else if (wall_px)           rgb = WALL_COLOUR;
    else if (field_px)          rgb = FIELD_COLOUR;
    else                        rgb = BLACK;
  end

  // Registered outputs (glitch-free)
  rgb_t rgb_q;
  logic h_sync_q, v_sync_q;
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rgb_q    <= 0;
      h_sync_q <= 1;
      v_sync_q <= 1;
    end else begin
      rgb_q    <= rgb;
      h_sync_q <= h_sync_n;
      v_sync_q <= v_sync_n;
    end
  end

  tiny_vga_t vga;
  assign vga.h_sync       = h_sync_q;
  assign vga.v_sync       = v_sync_q;
  assign {vga.r1, vga.r0} = rgb_q.r;
  assign {vga.g1, vga.g0} = rgb_q.g;
  assign {vga.b1, vga.b0} = rgb_q.b;
  assign uo_out           = vga;

  assign uio_out = 0;
  assign uio_oe  = 0;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, uio_in, ui.unused, paddle_dx[3:0],
                   gp.y, gp.select, gp.up, gp.down, gp.x, gp.l, gp.r, 1'b0};

endmodule
