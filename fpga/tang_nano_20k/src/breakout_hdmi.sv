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
 * Audio: the Audio Pmod pin is PWM, which the Pmod's filter averages. Here it is turned into
 * 48 kHz samples instead: see "Audio" below.
 */

`default_nettype none

module breakout_hdmi (
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
  // Audio. The pin carries two voices taking turns clock by clock, each at a volume of 0..7
  // out of 8 steps (sound.sv): a pattern that repeats every 16 clocks, aligned to the line, and
  // changes only between lines, or a clock into line 480 at the frame update. So the ones in
  // each 16-clock block are the mix exactly, 0..14, with no filter, except that the first block
  // of line 480 may mix the old sound and the new: inaudibly. The pin is registered, a clock
  // behind the beam, so a block ends where cx[3:0] is 0.
  // ---------------------------------------------------------------------------
  logic [9:0] cx;     // hdl-util's beam position: equal to the game's
  logic [3:0] ones;   // in the block so far
  logic [3:0] level;  // in the last whole block

  always_ff @(posedge clk_pixel) begin
    if (cx[3:0] == 0) begin
      level <= ones + 4'(audio_pin);
      ones  <= 0;
    end else begin
      ones <= ones + 4'(audio_pin);
    end
  end

  // 48 kHz samples: 25.2 MHz / 48 kHz is 525 clocks exactly. hdl-util takes a sample on each
  // rising edge of clk_audio (count 0); the sample changes half a period before, so it is
  // steady then. The level is scaled to 0..28672 of the 16-bit signed range: silence is 0.
  logic [9:0]  audio_count = 0;
  logic        clk_audio   = 0;
  logic [15:0] sample      = 0;

  always_ff @(posedge clk_pixel) begin
    audio_count <= (audio_count == 524) ? 10'd0 : audio_count + 1;
    clk_audio   <= audio_count < 262;
    if (audio_count == 262) sample <= {1'b0, level, 11'b0};
  end

  // ---------------------------------------------------------------------------
  // HDMI
  // ---------------------------------------------------------------------------
  hdmi #(
      .VIDEO_ID_CODE     (1),     // 640x480
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
      .cx               (cx),
      .cy               (),
      .frame_width      (),
      .frame_height     (),
      .screen_width     (),
      .screen_height    ()
  );

  wire _unused = &{uo_out[7], uo_out[3], uio_out[6:0], uio_oe, 1'b0};

endmodule
