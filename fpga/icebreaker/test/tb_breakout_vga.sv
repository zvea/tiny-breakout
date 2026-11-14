/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Self-checking testbench for breakout_vga (run by run.sh, with Verilator). It holds the
 * PLL's lock low for a while, runs the demo, then plays with the three buttons, and checks:
 *
 *   1. Reset: none of the game runs until the PLL has locked and 256 clocks have passed, and
 *      the reset button (pressed for 20 clocks in frame 5) resets it at once.
 *   2. Pins: on every clock after reset, each VGA Pmod colour channel is the game's 2-bit
 *      level repeated (r1 r0 r1 r0), taken from the game before its pins, so a swapped channel
 *      or reversed level fails; and the sync pins follow 640x480's timing, a clock behind the
 *      beam (as the game registers its pins), written here from the standard, not the game.
 *   3. Buttons: right (from frame 10) ends the demo and moves the paddle right, left moves it
 *      back left, and fire launches the ball.
 *
 * Hierarchical names reach into breakout_vga and the game: a testbench's licence.
 */

`default_nettype none
`timescale 1ns / 1ps

module tb_breakout_vga;

  logic clk = 0;
  always #1 clk = !clk;

  logic locked = 0;  // the PLL's lock, set after 1000 clocks below
  logic reset_button = 0, btn_left = 0, btn_right = 0, btn_fire = 0;
  logic [3:0] vga_r, vga_g, vga_b;
  logic vga_hs_n, vga_vs_n;

  breakout_vga dut (
      .clk         (clk),
      .clk_locked  (locked),
      .reset_button(reset_button),
      .btn_left    (btn_left),
      .btn_right   (btn_right),
      .btn_fire    (btn_fire),
      .vga_r       (vga_r),
      .vga_g       (vga_g),
      .vga_b       (vga_b),
      .vga_hs_n    (vga_hs_n),
      .vga_vs_n    (vga_vs_n)
  );

  wire       game_rst_n = dut.u_game.rst_n;
  wire [9:0] h_pos = dut.u_game.u_vga_timing.h_pos;
  wire [9:0] v_pos = dut.u_game.u_vga_timing.v_pos;

  int frame = 0;  // frames since the first reset, counted at the end of each
  int errors = 0;

  always_ff @(posedge clk) if (game_rst_n && h_pos == 799 && v_pos == 524) frame <= frame + 1;

  // A failed check: the first few are printed
  task automatic fail(input string msg);
    if (errors < 10) $display("FAIL in frame %0d at line %0d, clock %0d: %s", frame, v_pos, h_pos,
                              msg);
    errors++;
  endtask

  // 1. Reset, after configuration: the PLL locks after 1000 clocks, and the game must stay in
  // reset until then and for 256 clocks after
  longint clocks = 0;
  longint locked_at = 0;
  longint released_at = -1;  // the clock the game first left reset (-1: not yet)
  always_ff @(posedge clk) begin
    clocks <= clocks + 1;
    if (clocks == 1000) begin
      locked    <= 1;
      locked_at <= clocks + 1;
    end
    if (game_rst_n && released_at < 0) released_at <= clocks;
  end

  // 2. Pins: the beam a clock ago is the position of what the pins show now
  logic [9:0] h_prev, v_prev;
  logic       running = 0;  // a clock has passed since reset
  always_ff @(posedge clk) begin
    h_prev  <= h_pos;
    v_prev  <= v_pos;
    running <= game_rst_n;
  end

  wire colour_pkg::rgb_t pixel = dut.u_game.u_tiny_vga_out.rgb_q;  // the game's, unmapped
  wire hs_want_n = !(h_prev >= 656 && h_prev < 752);  // 96-clock pulse after a 16-clock porch
  wire vs_want_n = !(v_prev >= 490 && v_prev < 492);  // 2-line pulse after a 10-line porch
  longint lit_pixels = 0;  // pixels not black, so the colour check saw some colour

  always_ff @(posedge clk)
    if (running) begin
      if (vga_r != {2{pixel.r}} || vga_g != {2{pixel.g}} || vga_b != {2{pixel.b}})
        fail($sformatf("pins %h%h%h, game's colour %0d %0d %0d",
                       vga_r, vga_g, vga_b, pixel.r, pixel.g, pixel.b));
      if (vga_hs_n != hs_want_n) fail($sformatf("hsync_n %0d", vga_hs_n));
      if (vga_vs_n != vs_want_n) fail($sformatf("vsync_n %0d", vga_vs_n));
      if (pixel != colour_pkg::BLACK) lit_pixels++;
    end

  // Waits for the start of frame n (the clock its count changes)
  task automatic wait_frame(input int n);
    wait (frame == n);
  endtask

  // A design that never gets there fails, rather than hangs: 200 frames, at 2 time units a clock
  initial begin
    #(longint'(2) * 800 * 525 * 200);
    fail("timed out after 200 frames' time");
    $display("FAIL");
    $finish;
  end

  // 1 and 3, in order
  initial begin
    automatic int paddle_start, paddle_right;

    // 1. Reset after lock
    wait (released_at >= 0);
    if (released_at < locked_at + 256)
      fail($sformatf("game left reset at clock %0d, the PLL locked at %0d", released_at,
                     locked_at));
    if (released_at > locked_at + 300)
      fail($sformatf("game left reset only at clock %0d, the PLL locked at %0d", released_at,
                     locked_at));

    // 1. The reset button, in the middle of frame 5: the game in reset within 3 clocks (the
    // synchroniser, and the register after it), while it is held, and out again after
    wait_frame(5);
    wait (v_pos == 300);
    @(negedge clk) reset_button = 1;
    repeat (3) @(posedge clk);
    repeat (17) begin
      @(negedge clk);
      if (game_rst_n) fail("game not in reset with the button held");
    end
    reset_button = 0;
    repeat (300) @(posedge clk);
    if (!game_rst_n) fail("game still in reset 300 clocks after the button's release");
    $display("Reset pressed in frame 5");

    // 3. Right: the demo ends (a new game, the paddle in the middle), and the paddle moves right
    wait_frame(10);
    if (!dut.u_game.demo) fail("no demo with no buttons pressed");
    @(negedge clk) btn_right = 1;
    wait_frame(12);
    @(negedge clk);
    if (dut.u_game.demo) fail("demo still running with right held");
    paddle_start = int'(dut.u_game.paddle_c4);
    wait_frame(30);
    @(negedge clk) btn_right = 0;
    paddle_right = int'(dut.u_game.paddle_c4);
    if (paddle_right <= paddle_start)
      fail($sformatf("right held: paddle from %0d to %0d", paddle_start, paddle_right));

    // 3. Left: the paddle moves back left
    @(negedge clk) btn_left = 1;
    wait_frame(50);
    @(negedge clk) btn_left = 0;
    if (int'(dut.u_game.paddle_c4) >= paddle_right)
      fail($sformatf("left held: paddle from %0d to %0d", paddle_right, dut.u_game.paddle_c4));
    $display("Paddle %0d at the new game, %0d after right, %0d after left", paddle_start,
             paddle_right, dut.u_game.paddle_c4);

    // 3. Fire: the ball launches. (A new wall is built row by row first, with the ball on the
    // paddle, so allow for that.)
    @(negedge clk) btn_fire = 1;
    while (!dut.u_game.fly && frame < 150) @(negedge clk);
    @(negedge clk) btn_fire = 0;
    if (!dut.u_game.fly) fail("fire held for 100 frames, and the ball never launched");
    else $display("Ball launched in frame %0d", frame);

    wait_frame(frame + 2);
    if (lit_pixels == 0) fail("every pixel black: the colour check proved nothing");
    $display("%0d frames, %0d lit pixels: %0d errors", frame, lit_pixels, errors);
    if (errors == 0) $display("PASS");
    else $display("FAIL");
    $finish;
  end

endmodule
