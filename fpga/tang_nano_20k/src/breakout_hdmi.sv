/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Tiny Breakout with HDMI video and audio: the game (tt_um_tiny_breakout, unchanged) and
 * hdl-util/hdmi, joined. Nothing here is specific to an FPGA: the board's top module supplies
 * the clocks and drives the HDMI pins (tn20k_top.v).
 *
 * The game plays its demo: no controller is connected (all inputs 0).
 *
 * Video: the game's vga_timing and hdl-util's frame counter (cx, cy) both reset to (0, 0) on
 * the same clock, and count the same 800x525 frame with the picture at the top left (CEA-861
 * format 1, 640x480), so they stay equal. The game's pins are registered (tiny_vga_out), a
 * clock behind its counters, and hdl-util takes rgb a clock behind cx: they line up with no
 * delay of their own. hdl-util makes the sync pulses, so the game's aren't used.
 *
 * Audio: the Audio Pmod pin is PWM, which the Pmod's filter averages. Here it is filtered into
 * 48 kHz samples instead, as the simulator's player does: see "Audio" below.
 */

`default_nettype none

module breakout_hdmi #(
    // Picture only, with no sound: plain DVI, for monitors that don't take HDMI's audio (and
    // for simulators that can't evaluate hdl-util's audio parameters)
    parameter bit DVI_ONLY = 1'b0
) (
    input  logic       clk_pixel,     // 25.2 MHz: 640x480 at 60.00 Hz
    input  logic       clk_pixel_x5,  // 126 MHz, for the TMDS serialisers (DDR: 252 Mbit/s)
    input  logic       reset_button,  // high while pressed, asynchronous
    output logic [2:0] tmds,          // TMDS data channels 0..2 (blue, green, red), serial
    output logic       tmds_clock
);

  // ---------------------------------------------------------------------------
  // Reset: for 256 clocks after configuration (the flip-flops' initial values), and while the
  // button is pressed. One register resets both the game and hdl-util, so their frame counters
  // start on the same clock.
  // ---------------------------------------------------------------------------
  logic [1:0] button_s = 0;  // synchroniser
  logic [8:0] por      = 0;  // counts to 256 after configuration
  logic       rst_n    = 0;

  always_ff @(posedge clk_pixel) begin
    button_s <= {button_s[0], reset_button};
    if (!por[8]) por <= por + 1;
    rst_n <= por[8] && !button_s[1];
  end

  // ---------------------------------------------------------------------------
  // The game, as on the Tiny Tapeout board
  // ---------------------------------------------------------------------------
  logic [7:0] uo_out, uio_out, uio_oe;

  tt_um_tiny_breakout u_game (
      .ui_in  (8'b0),  // no buttons and no Gamepad PMOD: the demo
      .uo_out (uo_out),
      .uio_in (8'b0),
      .uio_out(uio_out),
      .uio_oe (uio_oe),
      .ena    (1'b1),
      .clk    (clk_pixel),
      .rst_n  (rst_n)
  );

  // TinyVGA PMOD pins (tiny_vga_out.sv), most significant first: hsync_n, b0, g0, r0, vsync_n,
  // b1, g1, r1. Each 2-bit level is repeated to fill 8 bits: 00, 55, AA, FF.
  wire [1:0] red   = {uo_out[0], uo_out[4]};
  wire [1:0] green = {uo_out[1], uo_out[5]};
  wire [1:0] blue  = {uo_out[2], uo_out[6]};
  wire [23:0] rgb  = {{4{red}}, {4{green}}, {4{blue}}};

  wire audio_pin = uio_out[7];  // Audio Pmod

  // ---------------------------------------------------------------------------
  // Audio: the pin as heard from the Audio Pmod's headphone jack, computed as the simulator's
  // player does it (sim/play/sim.h), so the board sounds like the player. 48 kHz samples, one
  // per 525 clocks exactly (25.2 MHz / 48 kHz):
  //   1. A 3rd-order CIC filter decimating by 525: the fraction of time the pin was high,
  //      smoothed, with nothing left of the PWM or anything else above 24 kHz to alias.
  //   2. A 1st-order high-pass at 50 Hz, standing in for the Pmod's AC coupling: silence is 0
  //      and the sound swings either side of it, with no DC.
  // Nothing here is reset: it runs from configuration, and the pin is low while the game is.
  // ---------------------------------------------------------------------------
  logic [9:0] audio_count = 0;  // 0..524: a sample's clocks

  always_ff @(posedge clk_pixel) audio_count <= (audio_count == 524) ? 10'd0 : audio_count + 1;

  // 1. The CIC: three integrators every clock, three combs every sample. 28 bits hold the
  // largest result, 525^3 (the pin always high), so the integrators may wrap: the combs'
  // differences come out right modulo 2^28, which is all a CIC needs.
  logic [27:0] integ1 = 0, integ2 = 0, integ3 = 0;
  logic [27:0] comb1 = 0, comb2 = 0, comb3 = 0;  // each comb's input a sample ago
  logic [27:0] cic = 0;  // 0 .. 525^3: the pin's time high, out of 525^3

  always_ff @(posedge clk_pixel) begin
    integ1 <= integ1 + 28'(audio_pin);
    integ2 <= integ2 + integ1;
    integ3 <= integ3 + integ2;
    if (audio_count == 0) begin
      comb1 <= integ3;
      comb2 <= integ3 - comb1;
      comb3 <= integ3 - comb1 - comb2;
      cic   <= integ3 - comb1 - comb2 - comb3;
    end
  end

  // 2. The high-pass, a clock later: y = a (y + x - x_prev), with a = 0.99348 as in sim.h
  // (exp(-2 pi 50 Hz / 48 kHz)), and y kept with 4 bits below the CIC's units. Since
  // x is 0 .. 0.875 * 525^3 (the loudest mix is 14 of 16 clocks high), y is within +-x's
  // largest, under 2^31 with those 4 bits, and y + x - x_prev within twice that: 33 bits and a
  // sign hold it, with a bit to spare.
  localparam logic signed [17:0] ONE_MINUS_A = 18'sd109387;  // (1 - a) * 2^24
  logic        [27:0] cic_prev = 0;
  logic signed [33:0] hp = 0;
  wire  signed [28:0] cic_step = signed'({1'b0, cic}) - signed'({1'b0, cic_prev});
  wire  signed [33:0] hp_in = hp + (34'(cic_step) <<< 4);  // y + x - x_prev
  wire  signed [51:0] hp_loss = hp_in * ONE_MINUS_A;       // (1 - a) (y + x - x_prev), * 2^24

  always_ff @(posedge clk_pixel)
    if (audio_count == 1) begin
      hp       <= hp_in - 34'(hp_loss >>> 24);
      cic_prev <= cic;
    end

  // The sample: y / 8192 in CIC units (sim.h's value times 525^3 / 8192), so the loudest
  // possible swing, +-0.875 * 525^3, is +-15456 of 16-bit signed's 32767: half of full
  // scale, as the game's sounds were loud on a screen at full scale
  wire [15:0] sample = hp[32:17];

  // hdl-util takes a sample on each rising edge of clk_audio, at count 262: half a sample
  // from where it changes, so it is steady then
  logic clk_audio = 0;
  always_ff @(posedge clk_pixel) clk_audio <= audio_count >= 262;

  // ---------------------------------------------------------------------------
  // HDMI
  // ---------------------------------------------------------------------------
  hdmi #(
      .VIDEO_ID_CODE     (1),     // 640x480
      .DVI_OUTPUT        (DVI_ONLY),
      .VIDEO_REFRESH_RATE(60.0),  // with the 25.2 MHz clock (59.94 with 25.175)
      .AUDIO_RATE        (48000),
      .AUDIO_BIT_WIDTH   (16)
  ) u_hdmi (
      .clk_pixel_x5     (clk_pixel_x5),
      .clk_pixel        (clk_pixel),
      .clk_audio        (clk_audio),
      .reset            (!rst_n),
      .rgb              (rgb),
      .audio_sample_word('{sample, sample}),  // the same on left and right
      .tmds             (tmds),
      .tmds_clock       (tmds_clock),
      .cx               (),
      .cy               (),
      .frame_width      (),
      .frame_height     (),
      .screen_width     (),
      .screen_height    ()
  );

  wire _unused = &{uo_out[7], uo_out[3], uio_out[6:0], uio_oe, 1'b0};

endmodule
