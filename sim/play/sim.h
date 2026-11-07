// Verilator model wrapper: runs one VGA frame at a time, emulating the Gamepad PMOD.
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
  bool autoplay = false;
  uint8_t buttons = 0;  // direct button pins ui_in[2:0]: bit 0 LEFT, 1 RIGHT, 2 FIRE
  std::vector<uint8_t> fb = std::vector<uint8_t>(640 * 480);  // raw uo_out per pixel

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
    // Gamepad PMOD report once per frame, in its first 1040 clocks:
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
    int cyc = 0;
    for (int y = 0; y < 525; y++)
      for (int x = 0; x < 800; x++, cyc++) {
        tick(cyc < (int)sizeof pmod ? pmod[cyc] : base);
        if (y < 480 && x < 640) *p++ = top.uo_out;
      }
  }
};
