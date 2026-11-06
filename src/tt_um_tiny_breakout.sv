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
  // VGA timing: 640x480 @ 60 Hz
  // Each line is 800 clocks and each frame 525 lines; beyond the visible area
  // come the front porch, the sync pulse and the back porch (all black).
  // ---------------------------------------------------------------------------
  localparam logic [9:0] H_VISIBLE    = 640;
  localparam logic [9:0] H_SYNC_START = 656;  // after a 16-clock front porch
  localparam logic [9:0] H_SYNC_END   = 752;  // 96-clock sync pulse, then a 48-clock back porch
  localparam logic [9:0] H_TOTAL      = 800;

  localparam logic [9:0] V_VISIBLE    = 480;
  localparam logic [9:0] V_SYNC_START = 490;  // after a 10-line front porch
  localparam logic [9:0] V_SYNC_END   = 492;  // 2-line sync pulse, then a 33-line back porch
  localparam logic [9:0] V_TOTAL      = 525;

  logic [9:0] h_pos, v_pos;  // beam position
  wire h_end = (h_pos == H_TOTAL - 1);
  wire v_end = (v_pos == V_TOTAL - 1);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      h_pos <= 0;
      v_pos <= 0;
    end else if (h_end) begin
      h_pos <= 0;
      v_pos <= v_end ? 0 : v_pos + 1;
    end else begin
      h_pos <= h_pos + 1;
    end
  end

  wire visible = (h_pos < H_VISIBLE) && (v_pos < V_VISIBLE);
  wire h_sync_n = ~((h_pos >= H_SYNC_START) && (h_pos < H_SYNC_END));
  wire v_sync_n = ~((v_pos >= V_SYNC_START) && (v_pos < V_SYNC_END));

  // ---------------------------------------------------------------------------
  // Gamepad PMOD receiver (trimmed version of Psychogenic's gamepad_pmod_driver,
  // single controller)
  // ---------------------------------------------------------------------------
  // One controller's buttons, in the order the PMOD sends them. B arrives first,
  // so after 12 shifts it ends up in the most significant bit.
  typedef struct packed {
    logic b, y, select, start, up, down, left, right, a, x, l, r;
  } gamepad_t;

  // Inputs pass through 2-flop synchronisers ([1:0]); clock and latch keep one more
  // bit of history ([2]) so their rising edges can be detected.
  logic [1:0]  gp_data_s;
  logic [2:0]  gp_clk_s, gp_latch_s;
  logic [11:0] gp_shift;
  gamepad_t    gp_buttons;  // gp_shift viewed as named buttons
  logic        gp_left, gp_right, gp_fire;

  assign gp_buttons = gp_shift;

  wire gp_present    = ~&gp_shift;  // all ones => no controller
  wire gp_clk_rise   = gp_clk_s[1]   & ~gp_clk_s[2];
  wire gp_latch_rise = gp_latch_s[1] & ~gp_latch_s[2];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      gp_data_s     <= 0;
      gp_clk_s      <= 0;
      gp_latch_s    <= 0;
      gp_shift      <= '1;  // all ones = no controller
      gp_left       <= 0;
      gp_right      <= 0;
      gp_fire       <= 0;
    end else begin
      gp_data_s     <= {gp_data_s[0], ui.gp_data};
      gp_clk_s      <= {gp_clk_s[1:0], ui.gp_clk};
      gp_latch_s    <= {gp_latch_s[1:0], ui.gp_latch};
      if (gp_clk_rise) gp_shift <= {gp_shift[10:0], gp_data_s[1]};
      if (gp_latch_rise) begin
        gp_left  <= gp_present & gp_buttons.left;
        gp_right <= gp_present & gp_buttons.right;
        gp_fire  <= gp_present & (gp_buttons.b | gp_buttons.start | gp_buttons.a);
      end
    end
  end

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
  logic        vx_neg, vx_fast, vy_neg;
  logic [7:0]  pad_q;         // paddle x / 4  (paddle x = 64..512)
  logic [1:0]  lives;         // spare balls
  logic        serve;         // ball resting on the paddle
  logic        gameover;
  logic [47:0] bricks;
  // Not '1: yosys's built-in frontend sizes '1 in a parameter as a single bit (= 48'h1).
  localparam logic [47:0] ALL_BRICKS = {48{1'b1}};

  // Per-frame collision flags
  logic hit_l, hit_r, hit_t, hit_b, hit_p;
  logic [1:0] hit_zone;

  wire autoplay = ui.autoplay;
  wire [9:0] padx = pad_q * 4;

  // ---------------------------------------------------------------------------
  // Pixel classification for the current beam position
  // ---------------------------------------------------------------------------
  // Brick field: 8 columns x 64 px (x 64..575), 6 rows x 16 px (y 64..159)
  wire [3:0] hb = h_pos[9:6];
  wire [5:0] vb = v_pos[9:4];
  wire [7:0] col_sel = {hb == 8, hb == 7, hb == 6, hb == 5, hb == 4, hb == 3, hb == 2, hb == 1};
  wire [5:0] row_sel = {vb == 9, vb == 8, vb == 7, vb == 6, vb == 5, vb == 4};

  // One-hot select of the brick under the beam (bit = row * 8 + col).
  // Written as whole-vector operations: same gates, much faster to simulate.
  wire [47:0] brick_sel = {{8{row_sel[5]}} & col_sel, {8{row_sel[4]}} & col_sel,
                           {8{row_sel[3]}} & col_sel, {8{row_sel[2]}} & col_sel,
                           {8{row_sel[1]}} & col_sel, {8{row_sel[0]}} & col_sel};

  wire brick_gap = (h_pos[5:1] == 0) || (v_pos[3:1] == 0);
  wire brick_px  = (|(brick_sel & bricks)) & ~brick_gap;

  // Walls: left x 56..63, right x 576..583, top y 24..31
  wire wall_l = (h_pos[9:3] == 7) && (v_pos[9:3] >= 3);
  wire wall_r = (h_pos[9:3] == 72) && (v_pos[9:3] >= 3);
  wire wall_t = (v_pos[9:3] == 3) && (h_pos[9:3] >= 7) && (h_pos[9:3] <= 72);

  // Playfield interior (dark background)
  wire field = (|col_sel) && (v_pos[9:5] != 0);

  // Paddle: 64 x 8 at y 448..455
  wire [9:0] dpx = h_pos - padx;
  wire paddle_px = (v_pos[9:3] == 56) && (dpx[9:6] == 0);

  // Ball: 8 x 8
  wire [9:0] dbx = h_pos - bx;
  wire [9:0] dby = v_pos - by;
  wire ball_px = (dbx[9:3] == 0) && (dby[9:3] == 0) && ~gameover;

  // Spare lives: 8x8 squares at y 8..15, x 64, 80
  wire life_px = (v_pos[9:3] == 1) && ~h_pos[3] &&
                 (((h_pos[9:4] == 4) && (lives != 0)) || ((h_pos[9:4] == 5) && lives[1]));

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

  // Brick colour by row. Brick rows are vb = 4..9, whose low 3 bits are 4,5,6,7,0,1.
  // (Sliced outside the always_comb: Icarus can't make a process sensitive to a part-select.)
  wire [2:0] vb_low = vb[2:0];
  rgb_t brick_rgb;
  always_comb begin
    case (vb_low)
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
  wire btn_left  = ui.left  | gp_left;
  wire btn_right = ui.right | gp_right;
  wire btn_fire  = ui.fire  | gp_fire | autoplay;

  // Autoplay: steer the paddle so the ball lands in paddle zone ap_zone (0..3, 16 px each).
  // The zone is re-picked pseudo-randomly after every paddle hit; always aiming at the same
  // spot makes the ball settle into a closed loop that never reaches the remaining bricks.
  // Ball centre (bx + 4) at zone centre (padx + 16 * zone + 8)  <=>  bx / 4 = pad_q + 4 * zone + 1
  logic [4:0] lfsr;     // x^5 + x^3 + 1, advanced every frame
  logic [1:0] ap_zone;
  wire [7:0] pad_aim = pad_q + ap_zone * 4 + 1;
  wire ap_right = bx[9:2] > pad_aim;
  wire ap_left  = bx[9:2] < pad_aim;
  wire go_left  = autoplay ? ap_left  : (btn_left & ~btn_right);
  wire go_right = autoplay ? ap_right : (btn_right & ~btn_left);

  wire frame_tick = (v_pos == V_VISIBLE) && (h_pos == 0);  // first clock of vertical blanking
  wire ball_lost  = (by >= V_VISIBLE);
  wire cleared    = ~|bricks;

  // Next ball direction from this frame's collisions
  wire n_vy_neg  = hit_p ? 1 : hit_t ? 0 : (vy_neg ^ hit_b);
  wire p_vx_neg  = hit_p ? ~hit_zone[1] : vx_neg;
  wire n_vx_neg  = hit_l ? 0 : hit_r ? 1 : p_vx_neg;
  wire n_vx_fast = hit_p ? (hit_zone[1] ~^ hit_zone[0]) : vx_fast;  // outer quarters = steep x
  wire [9:0] vx  = n_vx_neg ? (n_vx_fast ? -2 : -1) : (n_vx_fast ? 2 : 1);
  wire [9:0] vy  = n_vy_neg ? -2 : 2;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lfsr    <= 1;  // any non-zero seed
      ap_zone <= 1;
    end else if (frame_tick) begin
      lfsr <= {lfsr[3:0], lfsr[4] ^ lfsr[2]};
      if (hit_p) ap_zone <= lfsr[1:0];
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      bx       <= PAD_START_Q * 4 + SERVE_DX;  // resting on the paddle
      by       <= SERVE_Y;
      vx_neg   <= 0;
      vx_fast  <= 0;
      vy_neg   <= 1;
      pad_q    <= PAD_START_Q;
      lives    <= SPARE_LIVES;
      serve    <= 1;
      gameover <= 0;
      bricks   <= ALL_BRICKS;
      hit_l    <= 0;
      hit_r    <= 0;
      hit_t    <= 0;
      hit_b    <= 0;
      hit_p    <= 0;
      hit_zone <= 0;
    end else if (frame_tick) begin
      hit_l <= 0;
      hit_r <= 0;
      hit_t <= 0;
      hit_b <= 0;
      hit_p <= 0;

      // Paddle
      if (go_left && pad_q != PAD_MIN_Q) pad_q <= pad_q - 1;
      else if (go_right && pad_q != PAD_MAX_Q) pad_q <= pad_q + 1;

      if (gameover) begin
        if (btn_fire) begin
          gameover <= 0;
          lives    <= SPARE_LIVES;
          serve    <= 1;
          bricks   <= ALL_BRICKS;
        end
      end else if (serve | cleared) begin
        if (cleared) bricks <= ALL_BRICKS;
        serve   <= ~btn_fire;
        bx      <= padx + SERVE_DX;
        by      <= SERVE_Y;
        vx_neg  <= 0;
        vx_fast <= 0;
        vy_neg  <= 1;
      end else if (ball_lost) begin
        if (lives == 0) gameover <= 1;
        else begin
          lives <= lives - 1;
          serve <= 1;
        end
      end else begin
        vx_neg  <= n_vx_neg;
        vx_fast <= n_vx_fast;
        vy_neg  <= n_vy_neg;
        bx      <= bx + vx;
        by      <= by + vy;
      end
    end else if (ball_px & ~serve) begin
      // Collision detection by pixel overlap during scan-out
      if (wall_l) hit_l <= 1;
      if (wall_r) hit_r <= 1;
      if (wall_t) hit_t <= 1;
      if (paddle_px) begin
        hit_p    <= 1;
        hit_zone <= dpx[5:4];
      end
      if (brick_px) begin
        hit_b  <= 1;
        bricks <= bricks & ~brick_sel;
      end
    end
  end

  assign uio_out = 0;
  assign uio_oe  = 0;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, uio_in, ui.unused, dpx[3:0], dbx[2:0], dby[2:0],
                   gp_buttons.y, gp_buttons.select, gp_buttons.up, gp_buttons.down,
                   gp_buttons.x, gp_buttons.l, gp_buttons.r, 1'b0};

endmodule
