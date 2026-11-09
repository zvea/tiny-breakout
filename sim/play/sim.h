// SPDX-FileCopyrightText: 2026 Alexei Zverovitch
// SPDX-License-Identifier: Apache-2.0
//
// Verilator model wrapper: runs one VGA frame at a time, emulating the Gamepad PMOD and
// listening to the Audio Pmod (as audio for the player, and as pin counts for the tests).
// Needs Verilator 4.x: tick() relies on its internals (__Vclklast); 5.x is also ~2x slower here.
#pragma once
#include "Vtt_um_tiny_breakout.h"
#include "Vtt_um_tiny_breakout___024root.h"
#include <cstdint>
#include <vector>

struct Game {
  Vtt_um_tiny_breakout top;
  uint16_t pad_bits = 0;  // {b,y,sel,start,up,down,left,right,a,x,l,r}
  bool pmod_plugged = true;  // Gamepad PMOD plugged in (false: its pins stay low, no reports)
  int pmod_start = 0;  // clock within the frame at which each report starts (0 .. 418960)
  bool autoplay = false;
  uint8_t buttons = 0;  // direct button pins ui_in[2:0]: bit 0 LEFT, 1 RIGHT, 2 FIRE
  std::vector<uint8_t> fb = std::vector<uint8_t>(640 * 480);  // raw uo_out per pixel

  // Audio Pmod on uio[7], as heard from its headphone jack, when capture_audio is set (the
  // player sets it; the tests don't need it): 800 samples per frame (48 kHz at 60 fps; one
  // sample per 525 clocks). The pin is sampled every clock and decimated with a 3rd-order CIC
  // filter (unsigned wrap-around is how a CIC works); then a 1st-order high-pass at ~50 Hz
  // stands in for the Pmod's AC coupling into headphones. The Pmod's 400 kHz LC filter only
  // shapes ultrasonic content, which the decimation removes anyway. Samples run from about
  // -0.5 to 0.5 (a full-scale square wave).
  static constexpr int AUDIO_PER_FRAME = 800, CLOCKS_PER_SAMPLE = 525;
  bool capture_audio = false;
  std::vector<float> audio = std::vector<float>(AUDIO_PER_FRAME);
  uint64_t cic_i[3] = {}, cic_c[3] = {};
  int cic_n = 0;
  float hp_x = 0, hp_y = 0;
  inline void audio_clock(float *&out) {
    uint64_t pin = (top.uio_oe & top.uio_out) >> 7 & 1;
    cic_i[0] += pin;
    cic_i[1] += cic_i[0];
    cic_i[2] += cic_i[1];
    if (++cic_n < CLOCKS_PER_SAMPLE) return;
    cic_n = 0;
    uint64_t d = cic_i[2];
    for (uint64_t &c : cic_c) {  // combs
      uint64_t prev = c;
      c = d;
      d -= prev;
    }
    constexpr float GAIN = 1.0f / (float(CLOCKS_PER_SAMPLE) * CLOCKS_PER_SAMPLE * CLOCKS_PER_SAMPLE);
    constexpr float HP_A = 0.99348f;  // exp(-2 pi 50 Hz / 48 kHz)
    float x = float(int64_t(d)) * GAIN;  // 0 .. 1: fraction of time the pin was high
    hp_y = HP_A * (hp_y + x - hp_x);
    hp_x = x;
    *out++ = hp_y;
  }

  // The Audio Pmod pin, as the tests read it: for each line of the last frame, the clocks it
  // was high at odd and at even h. The two voices take turns clock by clock (sound.sv), and
  // the pin is registered, so after the clock at h it holds the voice that h chose: [1] is
  // voice A, [0] voice B. A sounding voice is high for 50 x its volume clocks of a line.
  uint16_t audio_high[2][525] = {};

  // One eval per clock: present a rising edge by resetting Verilator's last-seen clock.
  inline void tick(uint8_t ui) {
    top.ui_in = ui;
    top.clk = 1;
    top.rootp->__Vclklast__TOP__clk = 0;
    top.eval();
  }
  void reset() {
    top.ena = 1;
    top.rst_n = 0;
    for (int i = 0; i < 10; i++) tick(0);
    top.rst_n = 1;
  }
  // Simulates exactly one frame (800 x 525 clocks), starting at h_pos = v_pos = 0.
  void frame() {
    const uint8_t base = (buttons & 7) | (autoplay << 3);
    // Gamepad PMOD report once per frame, in the 1040 clocks from pmod_start:
    // 24 bits (2nd controller first, all zeros), 40-cycle clock (data stable while clk high),
    // then a latch pulse.
    uint8_t pmod[24 * 40 + 80];
    for (int bit = 0; bit < 24; bit++) {
      uint8_t d = bit < 12 ? 0 : (pad_bits >> (23 - bit)) & 1;
      for (int i = 0; i < 40; i++) pmod[bit * 40 + i] = base | (d << 6) | ((i >= 20) << 5);
    }
    for (int i = 0; i < 80; i++) pmod[960 + i] = base | ((i >= 20 && i < 60) << 4);
    if (!pmod_plugged) for (uint8_t &b : pmod) b = base;
    // Capture visible pixels (outputs are registered: 1-cycle latency, same as the RTL tests).
    uint8_t *p = fb.data();
    float *a = audio.data();
    int cyc = 0;
    for (int y = 0; y < 525; y++) {
      uint16_t high[2] = {};
      for (int x = 0; x < 800; x++, cyc++) {
        int r = cyc - pmod_start;
        tick(r >= 0 && r < (int)sizeof pmod ? pmod[r] : base);
        if (y < 480 && x < 640) *p++ = top.uo_out;
        high[x & 1] += (top.uio_oe & top.uio_out) >> 7 & 1;
        if (capture_audio) audio_clock(a);
      }
      audio_high[0][y] = high[0];
      audio_high[1][y] = high[1];
    }
  }
};
