// SPDX-FileCopyrightText: 2026 Alexei Zverovitch
// SPDX-License-Identifier: Apache-2.0
//
// Records the demo for tools/movie.sh: the chip from reset with no controller connected, so it
// plays itself, until EXTRA frames into the second level. Writes each frame's picture to stdout
// as 640x480 RGB (3 bytes a pixel) and its sound, as the Audio Pmod plays it, to AUDIO_FILE as
// mono 16-bit samples at 48 kHz (800 a frame). Progress goes to stderr.
//
// Usage: movie AUDIO_FILE EXTRA

#include "sim.h"

#include <cstdio>
#include <cstdlib>
#include <vector>

namespace {

// Bricks standing, read off the picture as the system tests do: 8 x 6 bricks of 64 x 16 px from
// (64, 64), each standing if a pixel inside it differs from the 2-px gap at its left edge (and
// neither is the white ball).
int bricks(const Game &g, const uint8_t (&lut)[256][3]) {
  auto white = [&](uint8_t o) { return lut[o][0] == 255 && lut[o][1] == 255 && lut[o][2] == 255; };
  int n = 0;
  for (int r = 0; r < 6; r++)
    for (int c = 0; c < 8; c++) {
      int x0 = 64 * (c + 1), y = 16 * (r + 4) + 4;
      uint8_t k = g.fb[y * 640 + x0 + 4], gap = g.fb[y * 640 + x0];
      n += (k & 0x77) != (gap & 0x77) && !white(k) && !white(gap);  // colour bits only
    }
  return n;
}

}  // namespace

int main(int argc, char **argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s AUDIO_FILE EXTRA_FRAMES\n", argv[0]);
    return 2;
  }
  FILE *audio = fopen(argv[1], "wb");
  if (!audio) {
    perror(argv[1]);
    return 1;
  }
  const int extra = atoi(argv[2]);

  // TinyVGA PMOD byte {hs, B0, G0, R0, vs, B1, G1, R1} -> RGB, 2 bits a channel
  static const uint8_t level[4] = {0, 85, 170, 255};
  uint8_t lut[256][3];
  for (int o = 0; o < 256; o++) {
    lut[o][0] = level[((o >> 0) & 1) << 1 | ((o >> 4) & 1)];
    lut[o][1] = level[((o >> 1) & 1) << 1 | ((o >> 5) & 1)];
    lut[o][2] = level[((o >> 2) & 1) << 1 | ((o >> 6) & 1)];
  }

  Game g;
  g.pmod_plugged = false;  // no controller: the demo
  g.capture_audio = true;
  g.reset();
  std::vector<uint8_t> rgb(640 * 480 * 3);
  std::vector<int16_t> pcm(Game::AUDIO_PER_FRAME);
  bool seen = false, cleared = false;  // the first wall has come in; it has gone
  int after = -1;  // frames since the second wall came in
  for (int frame = 0; after < extra; frame++) {
    if (frame == 60 * 60 * 15) {  // a quarter of an hour of demo without a second level
      fprintf(stderr, "no second level after %d frames\n", frame);
      return 1;
    }
    g.frame();
    for (int i = 0; i < 640 * 480; i++)
      for (int k = 0; k < 3; k++) rgb[i * 3 + k] = lut[g.fb[i]][k];
    for (int i = 0; i < Game::AUDIO_PER_FRAME; i++) {
      float x = g.audio[i];  // -0.5 .. 0.5 at most (tools/movie.sh normalises it)
      pcm[i] = int16_t(x > 1 ? 32767 : x < -1 ? -32767 : x * 32767);
    }
    if (fwrite(rgb.data(), 1, rgb.size(), stdout) != rgb.size() ||
        fwrite(pcm.data(), 2, pcm.size(), audio) != pcm.size()) {
      fprintf(stderr, "write failed at frame %d\n", frame);
      return 1;
    }
    int n = bricks(g, lut);
    seen |= n > 0;
    if (seen && !cleared && n == 0) cleared = true;
    if (cleared && after < 0 && n > 0) {
      after = 0;
      fprintf(stderr, "frame %d: the second level begins\n", frame);
    }
    if (after >= 0) after++;
    if (frame % 600 == 0) fprintf(stderr, "frame %d (%d s), %d bricks\n", frame, frame / 60, n);
  }
  fclose(audio);
  return 0;
}
