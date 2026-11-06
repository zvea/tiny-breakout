// CXXRTL harness: runs the game, emulates the Gamepad PMOD, dumps frames as PPM.
#include "breakout.cpp"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>
using namespace std;

static cxxrtl_design::p_tt__um__tiny__breakout top;
static uint8_t ui = 0;
// Gamepad PMOD emulation state: 12 bits {b,y,sel,start,up,down,left,right,a,x,l,r}
static uint16_t pad_bits = 0;
static bool pad_connected = false;
static long cyc = 0;

static void pmod_drive() {
  // Report every 40000 cycles (~630 Hz): 24 bits, 40-cycle clock period, then latch pulse.
  long t = cyc % 40000;
  int clk = 0, latch = 0, data = 0;
  if (pad_connected && t < 24 * 40) {
    int bit = t / 40;
    // first 12 bits: second controller (absent -> zeros), last 12: our controller, MSB first
    data = bit < 12 ? 0 : (pad_bits >> (11 - (bit - 12))) & 1;
    clk = (t % 40) >= 20;
  } else if (pad_connected && t >= 24 * 40 + 20 && t < 24 * 40 + 60) {
    latch = 1;
  }
  ui = (ui & 0x8f) | (latch << 4) | (clk << 5) | (data << 6);
}

static void step() {
  pmod_drive();
  top.p_ui__in.set<uint8_t>(ui);
  top.p_clk.set<bool>(false); top.step();
  top.p_clk.set<bool>(true);  top.step();
  cyc++;
}

static void frame(const char *ppm) {
  // Frame starts at hc=vc=0; outputs are registered (1 cycle latency).
  vector<uint8_t> img(640 * 480 * 3);
  for (int y = 0; y < 525; y++)
    for (int x = 0; x < 800; x++) {
      step();
      if (ppm && y < 480 && x < 640) {
        uint8_t o = top.p_uo__out.get<uint8_t>();
        int r = ((o >> 0) & 1) << 1 | ((o >> 4) & 1);
        int g = ((o >> 1) & 1) << 1 | ((o >> 5) & 1);
        int b = ((o >> 2) & 1) << 1 | ((o >> 6) & 1);
        uint8_t *p = &img[(y * 640 + x) * 3];
        p[0] = r * 85; p[1] = g * 85; p[2] = b * 85;
      }
    }
  if (ppm) {
    FILE *f = fopen(ppm, "wb");
    fprintf(f, "P6 640 480 255\n");
    fwrite(img.data(), 1, img.size(), f);
    fclose(f);
  }
}

static int sig(const char *what) {
  if (!strcmp(what, "pad")) return top.p_pad__q.get<int>();
  if (!strcmp(what, "bricks")) { int n = 0; for (int i = 0; i < 48; i++) n += (top.p_bricks.get<uint64_t>() >> i) & 1; return n; }
  if (!strcmp(what, "lives")) return top.p_lives.get<int>();
  if (!strcmp(what, "gameover")) return top.p_gameover.get<int>();
  if (!strcmp(what, "serve")) return top.p_serve.get<int>();
  return -1;
}

int main(int argc, char **argv) {
  string mode = argc > 1 ? argv[1] : "auto";
  int nframes = argc > 2 ? atoi(argv[2]) : 600;
  top.p_ena.set<bool>(true);
  top.p_rst__n.set<bool>(false);
  for (int i = 0; i < 10; i++) step();
  top.p_rst__n.set<bool>(true);
  // Align to frame start: reset puts hc=vc=0 on the cycle after release.
  cyc = 0;

  if (mode == "auto") {
    ui = 0x08;  // autoplay
    for (int f = 0; f < nframes; f++) {
      char name[64]; snprintf(name, sizeof name, "frame_%04d.ppm", f);
      bool dump = (f % 100 == 0) || f == nframes - 1;
      frame(dump ? name : nullptr);
      if (f % 100 == 0)
        printf("frame %4d: bricks=%2d lives=%d serve=%d gameover=%d pad=%d\n", f, sig("bricks"),
               sig("lives"), sig("serve"), sig("gameover"), sig("pad"));
    }
  } else if (mode == "lose") {
    // Launch, never move: the ball must eventually be lost 3 times -> game over -> restart.
    int fail = 0, prev_lives = sig("lives"), seen_gameover = 0;
    for (int f = 0; f < nframes && !seen_gameover; f++) {
      ui = sig("serve") ? 0x04 : 0x00;  // tap fire only while serving
      frame(f == 0 ? "lose_0000.ppm" : nullptr);
      if (sig("lives") != prev_lives) { printf("frame %d: lives %d -> %d\n", f, prev_lives, sig("lives")); prev_lives = sig("lives"); }
      if (sig("gameover")) { printf("frame %d: game over (bricks left %d)\n", f, sig("bricks")); seen_gameover = 1; frame("lose_gameover.ppm"); }
    }
    if (!seen_gameover) fail = 1;
    ui = 0x04; frame(nullptr); ui = 0; frame(nullptr);
    printf("after fire: gameover=%d lives=%d bricks=%d serve=%d\n", sig("gameover"), sig("lives"), sig("bricks"), sig("serve"));
    if (sig("gameover") || sig("lives") != 2 || sig("bricks") != 48) fail = 1;
    printf(fail ? "FAIL\n" : "PASS\n");
    return fail;
  } else if (mode == "gamepad") {
    pad_connected = true;
    int fail = 0;
    frame(nullptr); frame(nullptr);
    int p0 = sig("pad");
    pad_bits = 1 << 4;  // right
    for (int i = 0; i < 10; i++) frame(nullptr);
    int p1 = sig("pad");
    pad_bits = 1 << 5;  // left
    for (int i = 0; i < 20; i++) frame(nullptr);
    int p2 = sig("pad");
    printf("gamepad: pad %d -> (right) %d -> (left) %d\n", p0, p1, p2);
    if (!(p1 > p0 && p2 < p1)) fail = 1;
    pad_bits = 0; frame(nullptr);
    printf("serve before fire: %d\n", sig("serve"));
    pad_bits = 1 << 11;  // B = fire
    frame(nullptr); frame(nullptr);
    pad_bits = 0;
    printf("serve after fire:  %d\n", sig("serve"));
    if (sig("serve") != 0) fail = 1;
    // direct pins
    int q0 = sig("pad"); ui = 0x02; for (int i = 0; i < 5; i++) frame(nullptr); ui = 0;
    printf("direct right pin: pad %d -> %d\n", q0, sig("pad"));
    if (sig("pad") <= q0) fail = 1;
    printf(fail ? "FAIL\n" : "PASS\n");
    return fail;
  }
  return 0;
}
