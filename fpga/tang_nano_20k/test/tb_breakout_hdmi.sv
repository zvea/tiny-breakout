/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Self-checking testbench for breakout_hdmi (run by run.sh, with Verilator). It runs the demo
 * for +frames=N frames (default 400: the first sound is in frame 283) and checks what
 * breakout_hdmi's design rests on:
 *
 *   1. Lockstep: hdl-util's frame counter (cx, cy) equals the game's beam (h_pos, v_pos) on
 *      every clock after reset.
 *   2. Video: the pixels hdl-util sends (its video_data, in video periods) are the game's
 *      visible pixels, in order, none missing or extra: so the picture is neither shifted nor
 *      cropped. The game's pixel for a position is read from its pins a clock after its beam
 *      is there, as tiny_vga_out registers them.
 *   3. Audio blocks: in every 16-clock block of the audio pin, each voice's 8 PWM steps are some
 *      ones, then zeros (a volume), so the block's count is the mix; and breakout_hdmi's level
 *      is that count. The exception is the first block of line 480: the frame update changes
 *      the sound a clock into it (frame_tick is registered), so it may mix the old sound and
 *      the new. The demo must make some sound, or the check would prove nothing.
 *
 * Hierarchical names reach into breakout_hdmi, the game and hdl-util: a testbench's licence.
 */

`default_nettype none
`timescale 1ns / 1ps

module tb_breakout_hdmi;

  logic clk = 0;
  always #1 clk = !clk;

  breakout_hdmi dut (
      .clk_pixel   (clk),
      .clk_pixel_x5(1'b0),  // the serialisers aren't simulated (hdl-util leaves them out)
      .reset_button(1'b0),
      .tmds        (),
      .tmds_clock  ()
  );

  // hdl-util as DVI (video only): Verilator can't evaluate its audio clock packet's parameters
  // (a real cast to int in a localparam). The video path is the same code with or without
  // audio, and the audio checks below are on breakout_hdmi's side, before hdl-util.
  defparam dut.u_hdmi.DVI_OUTPUT = 1'b1;

  wire [9:0] h_pos = dut.u_game.u_vga_timing.h_pos;
  wire [9:0] v_pos = dut.u_game.u_vga_timing.v_pos;

  int frames = 400;
  int frame = 0;  // frames since reset, counted at the end of each
  int errors = 0;

  always_ff @(posedge clk) if (dut.rst_n && h_pos == 799 && v_pos == 524) frame <= frame + 1;

  // A failed check: the first few are printed
  task automatic fail(input string msg);
    if (errors < 10) $display("FAIL at line %0d, clock %0d: %s", v_pos, h_pos, msg);
    errors++;
  endtask

  // The beam a clock ago: the position of what the game's pins show now
  logic [9:0] h_prev, v_prev;
  logic       running = 0;  // a clock has passed since reset
  always_ff @(posedge clk) begin
    h_prev  <= h_pos;
    v_prev  <= v_pos;
    running <= dut.rst_n;
  end

  // 1. Lockstep
  always_ff @(posedge clk)
    if (dut.rst_n && (dut.u_hdmi.cx != h_pos || dut.u_hdmi.cy != v_pos))
      fail($sformatf("hdl-util at (%0d, %0d)", dut.u_hdmi.cx, dut.u_hdmi.cy));

  // 2. Video: the game's visible pixels go into a queue; hdl-util's video pixels come out of it
  logic [23:0] expected[$];
  longint      pixels_sent = 0;
  always_ff @(posedge clk) begin
    if (running && h_prev < 640 && v_prev < 480) expected.push_back(dut.rgb);
    // (Only after reset: hdl-util's mode starts as video, for the clock before its reset.)
    if (running && dut.u_hdmi.mode == 3'd1) begin
      if (expected.size() == 0) fail("hdl-util sent a pixel the game didn't show");
      else begin
        if (dut.u_hdmi.video_data != expected[0])
          fail($sformatf("pixel %06x, expected %06x", dut.u_hdmi.video_data, expected[0]));
        void'(expected.pop_front());
        pixels_sent++;
      end
    end
  end

  // 3. Audio blocks. The pin shows the beam a clock ago: h_prev[0] picks the voice (1: A,
  // 0: B, as sound.sv), h_prev[3:1] the PWM step, and a block ends at h_prev[3:0] == 15.
  logic [7:0] a_bits, b_bits;
  logic [3:0] count;
  logic       check_level = 0;  // compare breakout_hdmi's level on the next clock
  int         loud_blocks = 0;

  function automatic logic is_volume(input logic [7:0] bits);  // ones from step 0, then zeros
    return (bits & (bits + 8'd1)) == 0;
  endfunction

  always_ff @(posedge clk) begin
    logic [7:0] a, b;
    a = a_bits;
    b = b_bits;
    if (h_prev[0]) a[h_prev[3:1]] = dut.audio_pin;
    else b[h_prev[3:1]] = dut.audio_pin;
    check_level <= 0;
    if (running && h_prev[3:0] == 15) begin
      if (!(v_prev == 480 && h_prev[9:4] == 0) && (!is_volume(a) || !is_volume(b)))
        fail($sformatf("audio block: voice A %08b, voice B %08b (step 0 on the right)", a, b));
      count       <= 4'($countones(a) + $countones(b));
      check_level <= 1;
      if (a != 0 || b != 0) begin
        if (loud_blocks == 0) $display("First sound in frame %0d", frame);
        loud_blocks++;
      end
      a = 0;
      b = 0;
    end
    a_bits <= a;
    b_bits <= b;
    if (check_level && dut.level != count)
      fail($sformatf("audio level %0d, the block had %0d", dut.level, count));
  end

  initial begin
    void'($value$plusargs("frames=%d", frames));
    a_bits = 0;
    b_bits = 0;
    wait (dut.rst_n);
    repeat (frames * 800 * 525) @(posedge clk);
    // The pixels still in the queue are hdl-util's latency: a few clocks' worth, no more
    if (expected.size() > 4) fail($sformatf("%0d pixels never sent", expected.size()));
    if (pixels_sent < longint'(frames - 1) * 640 * 480)
      fail($sformatf("only %0d pixels sent in %0d frames", pixels_sent, frames));
    if (loud_blocks == 0) fail("no sound in the demo: the audio check saw only silence");
    $display("%0d frames, %0d pixels, %0d audio blocks with sound: %0d errors", frames,
             pixels_sent, loud_blocks, errors);
    if (errors == 0) $display("PASS");
    else $display("FAIL");
    $finish;
  end

endmodule
