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
  // Pin layout. Packed structs list fields most significant bit first.
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

  inputs_t ui;
  assign ui = ui_in;

  // ---------------------------------------------------------------------------
  // Video timing and gamepad input
  // ---------------------------------------------------------------------------
  localparam logic [9:0] SCREEN_H = 480;  // visible lines in vga_timing's 640x480 mode

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

  gamepad_pkg::gamepad_t gp;  // latest gamepad report, all zero without a controller

  gamepad_rx u_gamepad_rx (
      .clk       (clk),
      .rst_n     (rst_n),
      .pmod_latch(ui.gp_latch),
      .pmod_clk  (ui.gp_clk),
      .pmod_data (ui.gp_data),
      .buttons   (gp)
  );

  // ---------------------------------------------------------------------------
  // Game state
  // ---------------------------------------------------------------------------
  // The paddle position is stored in 4-px units (pad_q = paddle x / 4).
  localparam logic [7:0] PAD_MIN_Q   = 16;   // x = 64, against the left wall
  localparam logic [7:0] PAD_MAX_Q   = 128;  // x = 512, against the right wall
  localparam logic [7:0] PAD_START_Q = 72;   // x = 288, centred
  localparam logic [9:0] SERVE_DX    = 28;   // ball x relative to paddle x when resting on it (centred)
  localparam logic [9:0] SERVE_Y     = 440;  // ball y when resting on the paddle (paddle top is 448)
  localparam logic [1:0] SPARE_LIVES = 2;

  logic [9:0]  bx, by;        // ball top-left corner
  // Ball direction and speed, stored as sign and magnitude because that is how the game
  // changes them: walls set only the horizontal direction, the paddle sets the angle,
  // bricks flip only the vertical direction. (Two's-complement velocities need
  // negations and absolute values instead: ~6% more logic.)
  logic        ball_left;   // moving left (else right)
  logic        ball_steep;  // 2 px per frame horizontally (else 1)
  logic        ball_up;     // moving up (else down); always 2 px per frame vertically
  logic [7:0]  pad_q;         // paddle x / 4  (paddle x = 64..512)
  logic [1:0]  lives;         // spare balls
  logic        serve;         // ball resting on the paddle
  logic        gameover;

  // Brick field: BRICK_COLS x BRICK_ROWS bricks of 64 x 16 px. Counted in brick-sized
  // steps across the screen, the bricks start at column FIRST_BRICK_COL (x 64) and
  // row FIRST_BRICK_ROW (y 64).
  localparam int         BRICK_COLS      = 8;
  localparam int         BRICK_ROWS      = 6;
  localparam int         NUM_BRICKS      = BRICK_COLS * BRICK_ROWS;
  localparam logic [3:0] FIRST_BRICK_COL = 1;
  localparam logic [5:0] FIRST_BRICK_ROW = 4;

  logic [NUM_BRICKS-1:0] bricks;  // bit = row * BRICK_COLS + col; 1 = brick present
  localparam logic [NUM_BRICKS-1:0] ALL_BRICKS = '1;

  // Per-frame collision flags: walls left/right/top, brick, paddle
  typedef struct packed { logic l, r, t, b, p; } hits_t;
  hits_t      hit;
  logic [1:0] hit_zone;   // paddle quarter the ball touched

  wire [9:0] padx = pad_q * 4;

  // ---------------------------------------------------------------------------
  // Pixel classification for the current beam position
  // ---------------------------------------------------------------------------
  // The 64-px column and 16-px row under the beam (x 64..575 = columns 1..8,
  // y 64..159 = rows 4..9 hold bricks)
  wire [3:0] brick_col = h_pos[9:6];
  wire [5:0] brick_row = v_pos[9:4];

  // One-hot decode: col_sel[c] / row_sel[r] are set when the beam is over brick column c / row r
  wire [BRICK_COLS-1:0] col_sel;
  wire [BRICK_ROWS-1:0] row_sel;
  for (genvar c = 0; c < BRICK_COLS; c++) begin : g_col_sel
    assign col_sel[c] = (brick_col == FIRST_BRICK_COL + 4'(c));
  end
  for (genvar r = 0; r < BRICK_ROWS; r++) begin : g_row_sel
    assign row_sel[r] = (brick_row == FIRST_BRICK_ROW + 6'(r));
  end

  // One-hot select of the brick under the beam: row r's bits are the column selects
  // gated by row r. Whole-vector operations simulate much faster.
  wire [NUM_BRICKS-1:0] brick_sel;
  for (genvar r = 0; r < BRICK_ROWS; r++) begin : g_brick_row
    assign brick_sel[r*BRICK_COLS +: BRICK_COLS] = {BRICK_COLS{row_sel[r]}} & col_sel;
  end

  wire brick_gap = (h_pos[5:1] == 0) || (v_pos[3:1] == 0);
  wire brick_px  = (|(brick_sel & bricks)) & ~brick_gap;

  // Walls, paddle and life markers are aligned to a grid of 8x8-px cells
  wire [6:0] cell_x = h_pos[9:3];
  wire [6:0] cell_y = v_pos[9:3];
  localparam logic [6:0] WALL_L_CELL   = 7;   // x 56..63
  localparam logic [6:0] WALL_R_CELL   = 72;  // x 576..583
  localparam logic [6:0] WALL_T_CELL   = 3;   // y 24..31
  localparam logic [6:0] PADDLE_CELL_Y = 56;  // y 448..455
  localparam logic [6:0] LIVES_CELL_Y  = 1;   // y 8..15

  wire wall_l = (cell_x == WALL_L_CELL) && (cell_y >= WALL_T_CELL);
  wire wall_r = (cell_x == WALL_R_CELL) && (cell_y >= WALL_T_CELL);
  wire wall_t = (cell_y == WALL_T_CELL) && (cell_x >= WALL_L_CELL) && (cell_x <= WALL_R_CELL);

  // Playfield interior (dark background)
  wire field = (|col_sel) && (v_pos[9:5] != 0);

  // Paddle: 64 x 8, one cell row high
  wire [9:0] dpx = h_pos - padx;
  wire paddle_px = (cell_y == PADDLE_CELL_Y) && (dpx[9:6] == 0);

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
  wire [9:0] dbx = h_pos - bx;
  wire [9:0] dby = v_pos - by;
  wire ball_px = (dbx[9:3] == 0) && (dby[9:3] == 0) && in_circle8(dbx[2:0], dby[2:0]) &&
                 ~gameover;

  // Spare lives: 8-px circles in 16-px slots from x 64; marker i is shown while lives > i
  localparam logic [5:0] FIRST_LIFE_SLOT = 4;  // x 64
  wire [5:0] life_slot = h_pos[9:4] - FIRST_LIFE_SLOT;
  wire life_px = (cell_y == LIVES_CELL_Y) && ~h_pos[3] && in_circle8(h_pos[2:0], v_pos[2:0]) &&
                 (life_slot < 6'(lives));

  // Colours: 2 bits each of red, green and blue
  typedef struct packed {
    logic [1:0] r, g, b;
  } rgb_t;

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

  localparam rgb_t BALL_COLOUR   = WHITE;
  localparam rgb_t PADDLE_COLOUR = PALE_CYAN;  // also the spare-life markers
  localparam rgb_t WALL_COLOUR   = GREY;
  localparam rgb_t FIELD_COLOUR  = NAVY;

  // Brick colour by row. Brick rows 4..9 have low 3 bits 4,5,6,7,0,1.
  // (Sliced outside the always_comb: Icarus can't make a process sensitive to a part-select.)
  wire [2:0] brick_row_low = brick_row[2:0];
  rgb_t brick_rgb;
  always_comb begin
    case (brick_row_low)
      4:       brick_rgb = RED;
      5:       brick_rgb = ORANGE;
      6:       brick_rgb = YELLOW;
      7:       brick_rgb = GREEN;
      0:       brick_rgb = AZURE;
      default: brick_rgb = VIOLET;
    endcase
  end

  rgb_t rgb;
  always_comb begin
    if (!visible)                      rgb = BLACK;
    else if (ball_px)                  rgb = BALL_COLOUR;
    else if (paddle_px | life_px)      rgb = PADDLE_COLOUR;
    else if (brick_px)                 rgb = brick_rgb;
    else if (wall_l | wall_r | wall_t) rgb = WALL_COLOUR;
    else if (field)                    rgb = FIELD_COLOUR;
    else                               rgb = BLACK;
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

  // ---------------------------------------------------------------------------
  // Game logic
  // ---------------------------------------------------------------------------
  wire btn_left  = ui.left  | gp.left;
  wire btn_right = ui.right | gp.right;
  wire btn_fire  = ui.fire  | gp.b | gp.start | gp.a | ui.autoplay;

  // Autoplay: steer the paddle so the ball lands in paddle zone ap_zone (0..3, 16 px each).
  // The zone is re-picked pseudo-randomly after every paddle hit; always aiming at the same
  // spot makes the ball settle into a closed loop that never reaches the remaining bricks.
  // Ball centre (bx + 4) at zone centre (padx + 16 * zone + 8)  <=>  bx / 4 = pad_q + 4 * zone + 1
  logic [4:0] lfsr;     // x^5 + x^3 + 1, advanced every frame
  logic [1:0] ap_zone;
  wire [7:0] pad_aim = pad_q + ap_zone * 4 + 1;
  wire ap_right = bx[9:2] > pad_aim;
  wire ap_left  = bx[9:2] < pad_aim;
  wire go_left  = ui.autoplay ? ap_left  : (btn_left & ~btn_right);
  wire go_right = ui.autoplay ? ap_right : (btn_right & ~btn_left);

  wire ball_lost  = (by >= SCREEN_H);
  wire cleared    = ~|bricks;

  // Next ball direction from this frame's collisions. A paddle hit sends the ball up, left
  // from the left half and right from the right half, steeply from the outer quarters.
  wire next_up     = hit.p ? 1 : hit.t ? 0 : (ball_up ^ hit.b);
  wire paddle_left = hit.p ? ~hit_zone[1] : ball_left;
  wire next_left   = hit.l ? 0 : hit.r ? 1 : paddle_left;
  wire next_steep  = hit.p ? (hit_zone[1] ~^ hit_zone[0]) : ball_steep;
  wire [9:0] step_x = next_left ? (next_steep ? -2 : -1) : (next_steep ? 2 : 1);
  wire [9:0] step_y = next_up ? -2 : 2;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lfsr    <= 1;  // any non-zero seed
      ap_zone <= 1;
    end else if (frame_tick) begin
      lfsr <= {lfsr[3:0], lfsr[4] ^ lfsr[2]};
      if (hit.p) ap_zone <= lfsr[1:0];
    end
  end

  // What each frame update (at frame_tick) does, in priority order
  wire restart   = gameover & btn_fire;                  // new game after game over
  wire on_paddle = ~gameover & (serve | cleared);        // ball waits on the paddle
  wire lose_ball = ~gameover & ~on_paddle & ball_lost;   // ball fell off the bottom
  wire fly       = ~gameover & ~on_paddle & ~ball_lost;  // ball in flight

  // Ball contact during scan-out (the ball resting on the paddle never collides)
  wire touch = ball_px & ~serve;

  // Paddle
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      pad_q <= PAD_START_Q;
    end else if (frame_tick) begin
      if (go_left && pad_q != PAD_MIN_Q) pad_q <= pad_q - 1;
      else if (go_right && pad_q != PAD_MAX_Q) pad_q <= pad_q + 1;
    end
  end

  // Ball position and direction
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bx         <= PAD_START_Q * 4 + SERVE_DX;  // resting on the paddle
      by         <= SERVE_Y;
      ball_left  <= 0;
      ball_steep <= 0;
      ball_up    <= 1;
    end else if (frame_tick && on_paddle) begin
      bx         <= padx + SERVE_DX;
      by         <= SERVE_Y;
      ball_left  <= 0;
      ball_steep <= 0;
      ball_up    <= 1;
    end else if (frame_tick && fly) begin
      ball_left  <= next_left;
      ball_steep <= next_steep;
      ball_up    <= next_up;
      bx         <= bx + step_x;
      by         <= by + step_y;
    end
  end

  // Game progress: spare lives, serving, game over
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lives    <= SPARE_LIVES;
      serve    <= 1;
      gameover <= 0;
    end else if (frame_tick) begin
      if (restart) begin
        lives    <= SPARE_LIVES;
        serve    <= 1;
        gameover <= 0;
      end else if (on_paddle) begin
        serve <= ~btn_fire;
      end else if (lose_ball) begin
        if (lives == 0) begin
          gameover <= 1;
        end else begin
          lives <= lives - 1;
          serve <= 1;
        end
      end
    end
  end

  // Bricks: refilled for a new game or level, cleared when the ball touches them
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bricks <= ALL_BRICKS;
    end else if (frame_tick) begin
      if (restart || (on_paddle && cleared)) bricks <= ALL_BRICKS;
    end else if (touch && brick_px) begin
      bricks <= bricks & ~brick_sel;
    end
  end

  // Collision flags: set by pixel overlap during scan-out, consumed and cleared at frame_tick
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      hit      <= '0;
      hit_zone <= 0;
    end else if (frame_tick) begin
      hit <= '0;
    end else if (touch) begin
      if (wall_l)   hit.l <= 1;
      if (wall_r)   hit.r <= 1;
      if (wall_t)   hit.t <= 1;
      if (brick_px) hit.b <= 1;
      if (paddle_px) begin
        hit.p    <= 1;
        hit_zone <= dpx[5:4];
      end
    end
  end

  assign uio_out = 0;
  assign uio_oe  = 0;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, uio_in, ui.unused, dpx[3:0],
                   gp.y, gp.select, gp.up, gp.down, gp.x, gp.l, gp.r, 1'b0};

endmodule
