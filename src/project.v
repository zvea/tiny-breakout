/*
 * Copyright (c) 2026 Alexei Zverovitch
 * 
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Breakout: a brick-breaker game in a single Tiny Tapeout tile.
 *
 *   uo_out  : TinyVGA PMOD (640x480 @ 60 Hz, 25.175 MHz clock)
 *   ui_in[4]: Gamepad PMOD latch   (Psychogenic SNES Gamepad PMOD)
 *   ui_in[5]: Gamepad PMOD clock
 *   ui_in[6]: Gamepad PMOD data
 *   ui_in[0]: direct button LEFT   (active high, for simulators / plain buttons)
 *   ui_in[1]: direct button RIGHT
 *   ui_in[2]: direct button FIRE   (launch ball / restart after game over)
 *   ui_in[3]: AUTOPLAY             (paddle tracks the ball, auto-launch)
 *
 * Collisions are detected by pixel overlap while the frame is being drawn:
 * whenever a ball pixel coincides with a wall/brick/paddle pixel a flag is
 * set (and a touched brick is cleared on the spot). All flags are consumed
 * once per frame at the start of vertical blanking, where the ball and
 * paddle are moved.
 */

`default_nettype none

module tt_um_tiny_breakout (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path (active high: 0=input, 1=output)
    input  wire       ena,      // always 1 when the design is powered, so you can ignore it
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // ---------------------------------------------------------------------------
  // VGA timing: 640x480 @ 60 Hz
  // Each line is 800 clocks and each frame 525 lines; beyond the visible area
  // come the front porch, the sync pulse and the back porch (all black).
  // ---------------------------------------------------------------------------
  localparam H_VISIBLE    = 640;
  localparam H_SYNC_START = 656;  // after a 16-clock front porch
  localparam H_SYNC_END   = 752;  // 96-clock sync pulse, then a 48-clock back porch
  localparam H_TOTAL      = 800;

  localparam V_VISIBLE    = 480;
  localparam V_SYNC_START = 490;  // after a 10-line front porch
  localparam V_SYNC_END   = 492;  // 2-line sync pulse, then a 33-line back porch
  localparam V_TOTAL      = 525;

  reg [9:0] hc, vc;
  wire h_end = (hc == H_TOTAL - 1);
  wire v_end = (vc == V_TOTAL - 1);

  always @(posedge clk) begin
    if (!rst_n) begin
      hc <= 0;
      vc <= 0;
    end else if (h_end) begin
      hc <= 0;
      vc <= v_end ? 10'd0 : vc + 10'd1;
    end else begin
      hc <= hc + 10'd1;
    end
  end

  wire visible = (hc < H_VISIBLE) && (vc < V_VISIBLE);
  wire hsync_n = ~((hc >= H_SYNC_START) && (hc < H_SYNC_END));
  wire vsync_n = ~((vc >= V_SYNC_START) && (vc < V_SYNC_END));

  // ---------------------------------------------------------------------------
  // Gamepad PMOD receiver (trimmed version of Psychogenic's gamepad_pmod_driver,
  // single controller, 12 bits: {b,y,select,start,up,down,left,right,a,x,l,r})
  // ---------------------------------------------------------------------------
  // Button positions in gp_shift
  localparam GP_B     = 11;
  localparam GP_START = 8;
  localparam GP_LEFT  = 5;
  localparam GP_RIGHT = 4;
  localparam GP_A     = 3;

  reg [1:0] gp_data_s, gp_clk_s, gp_latch_s;
  reg       gp_clk_prev, gp_latch_prev;
  reg [11:0] gp_shift;
  reg       gp_left, gp_right, gp_fire;

  wire gp_present = ~&gp_shift;  // all ones => no controller

  always @(posedge clk) begin
    if (!rst_n) begin
      gp_data_s     <= 0;
      gp_clk_s      <= 0;
      gp_latch_s    <= 0;
      gp_clk_prev   <= 0;
      gp_latch_prev <= 0;
      gp_shift      <= 12'hfff;
      gp_left       <= 0;
      gp_right      <= 0;
      gp_fire       <= 0;
    end else begin
      gp_data_s     <= {gp_data_s[0], ui_in[6]};
      gp_clk_s      <= {gp_clk_s[0], ui_in[5]};
      gp_latch_s    <= {gp_latch_s[0], ui_in[4]};
      gp_clk_prev   <= gp_clk_s[1];
      gp_latch_prev <= gp_latch_s[1];
      if (gp_clk_s[1] & ~gp_clk_prev) gp_shift <= {gp_shift[10:0], gp_data_s[1]};
      if (gp_latch_s[1] & ~gp_latch_prev) begin
        gp_left  <= gp_present & gp_shift[GP_LEFT];
        gp_right <= gp_present & gp_shift[GP_RIGHT];
        gp_fire  <= gp_present & (gp_shift[GP_B] | gp_shift[GP_START] | gp_shift[GP_A]);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Game state
  // ---------------------------------------------------------------------------
  // The paddle position is stored in 4-px units (pad_q = paddle x / 4).
  localparam PAD_MIN_Q   = 16;   // x = 64, against the left wall
  localparam PAD_MAX_Q   = 128;  // x = 512, against the right wall
  localparam PAD_START_Q = 72;   // x = 288, centred
  localparam SERVE_DX    = 28;   // ball x relative to paddle x when resting on it (centred)
  localparam SERVE_Y     = 440;  // ball y when resting on the paddle (paddle top is 448)
  localparam SPARE_LIVES = 2;

  reg [9:0]  bx, by;        // ball top-left corner
  reg        vx_neg, vx_fast, vy_neg;
  reg [7:0]  pad_q;         // paddle x / 4  (paddle x = 64..512)
  reg [1:0]  lives;         // spare balls
  reg        serve;         // ball resting on the paddle
  reg        gameover;
  reg [47:0] bricks;

  // Per-frame collision flags
  reg hit_l, hit_r, hit_t, hit_b, hit_p;
  reg [1:0] hit_zone;

  wire autoplay = ui_in[3];
  wire [9:0] padx = {pad_q, 2'b00};

  // ---------------------------------------------------------------------------
  // Pixel classification for the current beam position
  // ---------------------------------------------------------------------------
  // Brick field: 8 columns x 64 px (x 64..575), 6 rows x 16 px (y 64..159)
  wire [3:0] hb = hc[9:6];
  wire [5:0] vb = vc[9:4];
  wire [7:0] col_sel = {hb == 4'd8, hb == 4'd7, hb == 4'd6, hb == 4'd5,
                        hb == 4'd4, hb == 4'd3, hb == 4'd2, hb == 4'd1};
  wire [5:0] row_sel = {vb == 6'd9, vb == 6'd8, vb == 6'd7, vb == 6'd6, vb == 6'd5, vb == 6'd4};

  // One-hot select of the brick under the beam (bit = row * 8 + col).
  // Written as whole-vector operations: same gates, much faster to simulate.
  wire [47:0] brick_sel = {{8{row_sel[5]}} & col_sel, {8{row_sel[4]}} & col_sel,
                           {8{row_sel[3]}} & col_sel, {8{row_sel[2]}} & col_sel,
                           {8{row_sel[1]}} & col_sel, {8{row_sel[0]}} & col_sel};

  wire brick_gap = (hc[5:1] == 0) || (vc[3:1] == 0);
  wire brick_px  = (|(brick_sel & bricks)) & ~brick_gap;

  // Walls: left x 56..63, right x 576..583, top y 24..31
  wire wall_l = (hc[9:3] == 7'd7) && (vc[9:3] >= 7'd3);
  wire wall_r = (hc[9:3] == 7'd72) && (vc[9:3] >= 7'd3);
  wire wall_t = (vc[9:3] == 7'd3) && (hc[9:3] >= 7'd7) && (hc[9:3] <= 7'd72);

  // Playfield interior (dark background)
  wire field = (|col_sel) && (vc[9:5] != 0);

  // Paddle: 64 x 8 at y 448..455
  wire [9:0] dpx = hc - padx;
  wire paddle_px = (vc[9:3] == 7'd56) && (dpx[9:6] == 0);

  // Ball: 8 x 8
  wire [9:0] dbx = hc - bx;
  wire [9:0] dby = vc - by;
  wire ball_px = (dbx[9:3] == 0) && (dby[9:3] == 0) && ~gameover;

  // Spare lives: 8x8 squares at y 8..15, x 64, 80
  wire life_px = (vc[9:3] == 7'd1) && ~hc[3] &&
                 (((hc[9:4] == 6'd4) && (lives != 0)) || ((hc[9:4] == 6'd5) && lives[1]));

  // Colours: {R,G,B}, 2 bits each
  localparam [5:0] BLACK     = 6'b00_00_00;
  localparam [5:0] WHITE     = 6'b11_11_11;
  localparam [5:0] PALE_CYAN = 6'b10_11_11;
  localparam [5:0] GREY      = 6'b01_01_01;
  localparam [5:0] NAVY      = 6'b00_00_01;
  localparam [5:0] RED       = 6'b11_00_00;
  localparam [5:0] ORANGE    = 6'b11_10_00;
  localparam [5:0] YELLOW    = 6'b11_11_00;
  localparam [5:0] GREEN     = 6'b00_11_00;
  localparam [5:0] AZURE     = 6'b00_10_11;
  localparam [5:0] VIOLET    = 6'b10_00_11;

  localparam [5:0] BALL_COLOUR   = WHITE;
  localparam [5:0] PADDLE_COLOUR = PALE_CYAN;  // also the spare-life markers
  localparam [5:0] WALL_COLOUR   = GREY;
  localparam [5:0] FIELD_COLOUR  = NAVY;

  // Brick colour by row
  reg [5:0] brick_rgb;
  always @(*) begin
    case (vc[6:4])  // rows 4..9 -> vc[6:4] = 4,5,6,7,0,1
      3'd4:    brick_rgb = RED;
      3'd5:    brick_rgb = ORANGE;
      3'd6:    brick_rgb = YELLOW;
      3'd7:    brick_rgb = GREEN;
      3'd0:    brick_rgb = AZURE;
      default: brick_rgb = VIOLET;
    endcase
  end

  reg [5:0] rgb;
  always @(*) begin
    if (!visible)                      rgb = BLACK;
    else if (ball_px)                  rgb = BALL_COLOUR;
    else if (paddle_px | life_px)      rgb = PADDLE_COLOUR;
    else if (brick_px)                 rgb = brick_rgb;
    else if (wall_l | wall_r | wall_t) rgb = WALL_COLOUR;
    else if (field)                    rgb = FIELD_COLOUR;
    else                               rgb = BLACK;
  end

  // Registered outputs (glitch-free)
  reg [5:0] rgb_q;
  reg hs_q, vs_q;
  always @(posedge clk) begin
    if (!rst_n) begin
      rgb_q <= 0;
      hs_q  <= 1;
      vs_q  <= 1;
    end else begin
      rgb_q <= rgb;
      hs_q  <= hsync_n;
      vs_q  <= vsync_n;
    end
  end

  // TinyVGA PMOD: {hsync, B0, G0, R0, vsync, B1, G1, R1}
  assign uo_out = {hs_q, rgb_q[0], rgb_q[2], rgb_q[4], vs_q, rgb_q[1], rgb_q[3], rgb_q[5]};

  // ---------------------------------------------------------------------------
  // Game logic
  // ---------------------------------------------------------------------------
  wire btn_left  = ui_in[0] | gp_left;
  wire btn_right = ui_in[1] | gp_right;
  wire btn_fire  = ui_in[2] | gp_fire | autoplay;

  // Autoplay: steer the paddle so the ball lands in paddle zone ap_zone (0..3, 16 px each).
  // The zone is re-picked pseudo-randomly after every paddle hit; always aiming at the same
  // spot makes the ball settle into a closed loop that never reaches the remaining bricks.
  // Ball centre (bx + 4) at zone centre (padx + 16 * zone + 8)  <=>  bx / 4 = pad_q + 4 * zone + 1
  reg [4:0] lfsr;     // x^5 + x^3 + 1, advanced every frame
  reg [1:0] ap_zone;
  wire [7:0] pad_aim = pad_q + {4'd0, ap_zone, 2'b01};
  wire ap_right = bx[9:2] > pad_aim;
  wire ap_left  = bx[9:2] < pad_aim;
  wire go_left  = autoplay ? ap_left  : (btn_left & ~btn_right);
  wire go_right = autoplay ? ap_right : (btn_right & ~btn_left);

  wire frame_tick = (vc == V_VISIBLE) && (hc == 0);  // first clock of vertical blanking
  wire ball_lost  = by[9] | (by[8:5] == 4'b1111);  // by >= 480
  wire cleared    = ~|bricks;

  // Next ball direction from this frame's collisions
  wire n_vy_neg  = hit_p ? 1'b1 : hit_t ? 1'b0 : (vy_neg ^ hit_b);
  wire p_vx_neg  = hit_p ? ~hit_zone[1] : vx_neg;
  wire n_vx_neg  = hit_l ? 1'b0 : hit_r ? 1'b1 : p_vx_neg;
  wire n_vx_fast = hit_p ? (hit_zone[1] ~^ hit_zone[0]) : vx_fast;  // outer quarters = steep x
  wire [9:0] vx  = n_vx_neg ? (n_vx_fast ? -10'd2 : -10'd1) : (n_vx_fast ? 10'd2 : 10'd1);
  wire [9:0] vy  = n_vy_neg ? -10'd2 : 10'd2;

  always @(posedge clk) begin
    if (!rst_n) begin
      lfsr    <= 5'b00001;
      ap_zone <= 2'd1;
    end else if (frame_tick) begin
      lfsr <= {lfsr[3:0], lfsr[4] ^ lfsr[2]};
      if (hit_p) ap_zone <= lfsr[1:0];
    end
  end

  always @(posedge clk) begin
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
      bricks   <= {48{1'b1}};
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
      if (go_left && pad_q != PAD_MIN_Q) pad_q <= pad_q - 8'd1;
      else if (go_right && pad_q != PAD_MAX_Q) pad_q <= pad_q + 8'd1;

      if (gameover) begin
        if (btn_fire) begin
          gameover <= 0;
          lives    <= SPARE_LIVES;
          serve    <= 1;
          bricks   <= {48{1'b1}};
        end
      end else if (serve | cleared) begin
        if (cleared) bricks <= {48{1'b1}};
        serve   <= ~btn_fire;
        bx      <= padx + SERVE_DX;
        by      <= SERVE_Y;
        vx_neg  <= 0;
        vx_fast <= 0;
        vy_neg  <= 1;
      end else if (ball_lost) begin
        if (lives == 0) gameover <= 1;
        else begin
          lives <= lives - 2'd1;
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
  wire _unused = &{ena, uio_in, ui_in[7], 1'b0};

endmodule
