// Measures how fast sim.h simulates frames (autoplay running), to compare Verilator
// versions and options. Build like build.sh, with this file in place of serve.cpp; run as
// ./Vtt_um_tiny_breakout [frames] (default 300). The printed sum only keeps the frame
// buffer reads from being optimised away.
#include "sim.h"
#include <chrono>
#include <cstdio>
int main(int argc, char **argv) {
  Game g; g.reset(); g.autoplay = true;
  int n = argc > 1 ? atoi(argv[1]) : 300;
  auto t0 = std::chrono::steady_clock::now();
  unsigned acc = 0;
  for (int i = 0; i < n; i++) { g.frame(); for (auto v : g.fb) acc += v; }
  double s = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
  printf("frame(): %.1f fps [%u]\n", n / s, acc);
}
