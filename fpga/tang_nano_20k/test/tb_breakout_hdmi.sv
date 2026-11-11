/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Self-checking testbench for breakout_hdmi (run by run.sh, with Verilator). It runs the demo
 * for +frames=N frames (default 400: the first sound is in frame 350, as the reset in frame 5
 * restarts the demo) and checks what breakout_hdmi's design rests on:
 *
 *   1. Lockstep: hdl-util's frame counter (cx, cy) equals the game's beam (h_pos, v_pos) on
 *      every clock after reset.
 *   2. Video: the pixels hdl-util sends (its video_data, in video periods) are the game's
 *      visible pixels, in order, none missing or extra: so the picture is neither shifted nor
 *      cropped. The game's pixel for a position is its own colour as tiny_vga_out registers
 *      it, a clock after the beam is there, taken before any pin mapping: so a colour channel
 *      swapped or a level reversed, in the game's pins or in breakout_hdmi's reading of them,
 *      fails too.
 *   3. Audio: breakout_hdmi's samples are those of the simulator's player (sim/play/sim.h),
 *      whose code is copied here: its CIC filter's exactly, and its high-pass's to within
 *      rounding. The demo must make some sound, or the check would prove nothing.
 *   4. Reset: the button is pressed for 20 clocks in the middle of frame 5, and checks 1 to 3
 *      hold after it as before (pixels queued before it are dropped).
 *
 * Hierarchical names reach into breakout_hdmi, the game and hdl-util: a testbench's licence.
 */

`default_nettype none
`timescale 1ns / 1ps

module tb_breakout_hdmi;

  logic clk = 0;
  always #1 clk = !clk;

  // DVI only (no sound in hdl-util): Verilator can't evaluate hdl-util's audio clock packet's
  // parameters (a real cast to int in a localparam). The picture path is the same code with or
  // without sound, and the audio checks below are on breakout_hdmi's side, before hdl-util.
  breakout_hdmi #(
      .DVI_ONLY(1'b1)
  ) dut (
      .clk_pixel   (clk),
      .clk_pixel_x5(1'b0),  // the serialisers aren't simulated (hdl-util leaves them out)
      .reset_button(button),
      .tmds        (),
      .tmds_clock  ()
  );

  wire [9:0] h_pos = dut.u_game.u_vga_timing.h_pos;
  wire [9:0] v_pos = dut.u_game.u_vga_timing.v_pos;

  logic button = 0;  // the board's reset button (S1), pressed once below
  int frames = 400;
  int frame = 0;  // frames since the first reset, counted at the end of each
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
  wire colour_pkg::rgb_t pixel = dut.u_game.u_tiny_vga_out.rgb_q;  // the game's, unmapped
  always_ff @(posedge clk) begin
    if (!dut.rst_n) expected.delete();  // a reset drops what was on its way
    if (running && h_prev < 640 && v_prev < 480)
      expected.push_back({{4{pixel.r}}, {4{pixel.g}}, {4{pixel.b}}});
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

  // 3. Audio: sim.h's audio_clock(), on the pin every clock. Its integrators add as they go
  // (each takes the one before's new value), where breakout_hdmi's are registers, each a clock
  // behind the one before: so breakout_hdmi's third integrator, at its combs (count 0), is
  // sim.h's from 3 clocks before, and sim.h's combs run at count 522.
  localparam real HP_A = 0.99348;  // sim.h's
  longint unsigned cic_i[3] = '{0, 0, 0}, cic_c[3] = '{0, 0, 0};
  longint unsigned cic_d = 0;      // sim.h's last CIC result
  real             hp_x = 0, hp_y = 0;
  int              loud_samples = 0, loudest = 0;

  always @(posedge clk) begin
    automatic longint unsigned d;
    cic_i[0] += 64'(dut.audio_pin);
    cic_i[1] += cic_i[0];
    cic_i[2] += cic_i[1];
    if (dut.audio_count == 522) begin
      d = cic_i[2];
      for (int k = 0; k < 3; k++) begin  // the combs
        automatic longint unsigned prev = cic_c[k];
        cic_c[k] = d;
        d -= prev;
      end
      cic_d = d;
      hp_y  = HP_A * (hp_y + real'(d) - hp_x);  // in the CIC's units: sim.h's times 525^3
      hp_x  = real'(d);
    end
    // breakout_hdmi's sample is ready at count 2 (its combs at 0, its high-pass at 1). Its
    // sample is the high-pass / 8192, rounded down: so expect within a step or two of that.
    if (dut.audio_count == 2) begin
      automatic real want = hp_y / 8192.0;
      automatic int  got = int'($signed(dut.sample));
      if (64'(dut.cic) != cic_d) fail($sformatf("CIC %0d, sim.h's %0d", dut.cic, cic_d));
      if (real'(got) < want - 2.0 || real'(got) > want + 2.0)
        fail($sformatf("audio sample %0d, sim.h's %.1f", got, want));
      if (got > 1000 || got < -1000) begin
        if (loud_samples == 0) $display("First sound in frame %0d", frame);
        loud_samples++;
      end
      if (got > loudest) loudest = got;
      if (-got > loudest) loudest = -got;
    end
  end

  // 4. Reset: the button pressed for 20 clocks at line 300 of frame 5
  initial begin
    wait (dut.rst_n && frame == 5 && v_pos == 300);
    button = 1;
    repeat (20) @(posedge clk);
    button = 0;
    $display("Reset pressed in frame 5");
  end

  initial begin
    void'($value$plusargs("frames=%d", frames));
    wait (dut.rst_n);
    repeat (frames * 800 * 525) @(posedge clk);
    // The pixels still in the queue are hdl-util's latency: a few clocks' worth, no more
    if (expected.size() > 4) fail($sformatf("%0d pixels never sent", expected.size()));
    if (pixels_sent < longint'(frames - 1) * 640 * 480)
      fail($sformatf("only %0d pixels sent in %0d frames", pixels_sent, frames));
    if (loud_samples == 0) fail("no sound in the demo: the audio check saw only silence");
    $display("%0d frames, %0d pixels, %0d audio samples with sound (loudest %0d): %0d errors",
             frames, pixels_sent, loud_samples, loudest, errors);
    if (errors == 0) $display("PASS");
    else $display("FAIL");
    $finish;
  end

endmodule
