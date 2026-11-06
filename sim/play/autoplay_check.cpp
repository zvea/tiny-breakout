// Runs autoplay for N frames and reports progress: detects the ball getting stuck in a loop.
#include "sim.h"
#include <cstdio>
#include <cstdlib>
int main(int argc, char **argv) {
  int n = argc > 1 ? atoi(argv[1]) : 20000;
  Game g; g.reset(); g.autoplay = true;
  auto *r = g.top.rootp;
  int last_change = 0, prev = 48, levels = 0, lost = 0, prev_lives = 2;
  for (int f = 0; f < n; f++) {
    g.frame();
    int b = __builtin_popcountll(r->tt_um_tiny_breakout__DOT__bricks);
    if (b == 48 && prev < 48) levels++;
    if (r->tt_um_tiny_breakout__DOT__lives != prev_lives) { lost++; prev_lives = r->tt_um_tiny_breakout__DOT__lives; }
    if (b != prev) { last_change = f; prev = b; }
    if (f % 2000 == 0) printf("frame %6d (%5.0f s): bricks %2d, levels cleared %d, lives lost %d, x=%d y=%d\n", f, f / 60.0, b, levels, lost, r->tt_um_tiny_breakout__DOT__bx, r->tt_um_tiny_breakout__DOT__by);
  }
  printf("last brick change at frame %d (%.0f s ago at end)\n", last_change, (n - last_change) / 60.0);
}
