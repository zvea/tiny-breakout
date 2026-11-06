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
