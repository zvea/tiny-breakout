// SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
// SPDX-License-Identifier: Apache-2.0
//
// Black-box scenario tests for Tiny Breakout.
//
// Each scenario drives only the chip's input pins (direct buttons, autoplay, the emulated
// Gamepad PMOD) and judges only from its video output: every frame is decoded and the game
// state is read off the picture (life markers, ball, paddle, bricks). Nothing here depends
// on the design's internal signal names, so refactoring the RTL cannot break these tests;
// the per-module unit tests cover the internals.
//
// Usage: scenarios <name>   (exit status 0 = pass)
//        scenarios list
// Normally built and run by test_scenarios.py (pytest).

#include "sim.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>

namespace {

// ---- Inputs ------------------------------------------------------------------------------

constexpr uint8_t LEFT = 1, RIGHT = 2, FIRE = 4;  // direct button pins ui_in[2:0]

// Gamepad report bits {b,y,select,start,up,down,left,right,a,x,l,r}, b most significant
constexpr uint16_t GP_B = 1 << 11, GP_LEFT = 1 << 5, GP_RIGHT = 1 << 4;

// ---- Reading the picture -----------------------------------------------------------------

// Colour of one pixel as 6 bits {r, g, b}, decoded from the TinyVGA PMOD byte
// {hsync, B0, G0, R0, vsync, B1, G1, R1}.
int colour(uint8_t o) {
  int r = ((o >> 0) & 1) << 1 | ((o >> 4) & 1);
  int g = ((o >> 1) & 1) << 1 | ((o >> 5) & 1);
  int b = ((o >> 2) & 1) << 1 | ((o >> 6) & 1);
  return r << 4 | g << 2 | b;
}

constexpr int BLACK = 0x00, WHITE = 0x3f, PADDLE = 0x2f, FIELD = 0x01;

struct View {
  int lives = 0;        // spare-life markers shown
  bool ball = false;    // ball visible below the top wall
  int ball_x = -1;      // top-left of the ball's bounding box
  int ball_y = -1;
  int paddle_x = -1;    // left edge of the paddle
  int bricks = 0;       // standing bricks
  int row_bricks[6] = {};  // standing bricks per row, 0 = top
};

// find_ball: the ball search scans the whole playfield, the slowest part; skip it when
// only bricks and markers matter.
View look(const Game &g, bool find_ball = true) {
  auto at = [&](int x, int y) { return colour(g.fb[y * 640 + x]); };
  View v;
  // Life markers: white circles on the status line above the playfield
  for (int x = 48, prev = BLACK; x < 128; x++) {
    int c = at(x, 12);
    if (c == WHITE && prev != WHITE) v.lives++;
    prev = c;
  }
  // Ball: the white pixels below the top wall
  for (int y = 32; find_ball && y < 480; y++)
    for (int x = 0; x < 640; x++)
      if (at(x, y) == WHITE) {
        if (!v.ball || x < v.ball_x) v.ball_x = x;
        if (!v.ball) v.ball_y = y;
        v.ball = true;
      }
  // Paddle: first paddle-coloured pixel on its row
  for (int x = 0; x < 640 && v.paddle_x < 0; x++)
    if (at(x, 450) == PADDLE) v.paddle_x = x;
  // Bricks: 8 x 6 bricks of 64 x 16 px from (64, 64). A brick counts as standing if either
  // of two pixels inside it has a brick colour (two, in case the ball covers one).
  for (int r = 0; r < 6; r++)
    for (int c = 0; c < 8; c++) {
      int x0 = 64 * (c + 1), y0 = 16 * (r + 4);
      auto is_brick = [&](int x, int y) {
        int k = at(x, y);
        return k != FIELD && k != WHITE && k != BLACK;
      };
      if (is_brick(x0 + 4, y0 + 4) || is_brick(x0 + 60, y0 + 13)) {
        v.bricks++;
        v.row_bricks[r]++;
      }
    }
  return v;
}

// A ball resting on the paddle sits at y 440, centred on it.
bool resting(const View &v) {
  return v.ball && v.ball_y == 440 && v.paddle_x >= 0 && v.ball_x == v.paddle_x + 28;
}

// ---- Checks ------------------------------------------------------------------------------

int failures = 0;

#define CHECK(cond, ...)                                     \
  do {                                                       \
    if (!(cond)) {                                           \
      printf("FAIL line %d: %s: ", __LINE__, #cond);         \
      printf(__VA_ARGS__);                                   \
      printf("\n");                                          \
      failures++;                                            \
    }                                                        \
  } while (0)

View run(Game &g, int frames, bool find_ball = true) {
  for (int i = 0; i < frames; i++) g.frame();
  return look(g, find_ball);
}

// ---- Scenarios ---------------------------------------------------------------------------

// A new game shows the full wall, two spare balls and the ball resting on the paddle; it
// stays there until FIRE launches it upwards.
void launch() {
  Game g;
  g.reset();
  View v = run(g, 2);
  CHECK(v.bricks == 48, "bricks %d", v.bricks);
  CHECK(v.lives == 2, "life markers %d", v.lives);
  CHECK(resting(v), "ball at (%d, %d), paddle at %d", v.ball_x, v.ball_y, v.paddle_x);
  v = run(g, 60);
  CHECK(resting(v), "ball left the paddle without FIRE: (%d, %d)", v.ball_x, v.ball_y);
  g.buttons = FIRE;
  run(g, 1);
  g.buttons = 0;
  v = run(g, 10);
  CHECK(v.ball && v.ball_y < 440 - 10, "ball not launched upwards: y %d", v.ball_y);
}

// The paddle moves 4 px per frame while LEFT or RIGHT is held, from either the direct pins
// or the gamepad; both together cancel out. The resting ball moves with it.
void steering() {
  for (int source = 0; source < 2; source++) {
    const char *name = source ? "gamepad" : "direct pins";
    auto press = [&](Game &g, bool l, bool r) {
      if (source) g.pad_bits = (l ? GP_LEFT : 0) | (r ? GP_RIGHT : 0);
      else g.buttons = (l ? LEFT : 0) | (r ? RIGHT : 0);
    };
    Game g;
    g.reset();
    int x0 = run(g, 2).paddle_x;
    press(g, false, true);
    int x1 = run(g, 10).paddle_x;
    CHECK(x1 >= x0 + 32 && x1 <= x0 + 40, "%s: right moved the paddle %d -> %d", name, x0, x1);
    press(g, true, false);
    int x2 = run(g, 10).paddle_x;
    CHECK(x2 <= x1 - 32 && x2 >= x1 - 40, "%s: left moved the paddle %d -> %d", name, x1, x2);
    press(g, true, true);
    int x3 = run(g, 2).paddle_x;
    int x4 = run(g, 10).paddle_x;
    CHECK(x4 == x3, "%s: left + right moved the paddle %d -> %d", name, x3, x4);
    press(g, false, false);
    CHECK(resting(run(g, 2)), "%s: the resting ball did not follow the paddle", name);
  }
}

// The paddle stops at the walls: x 64 on the left, 512 on the right.
void paddle_limits() {
  Game g;
  g.reset();
  g.buttons = LEFT;
  View v = run(g, 100);
  CHECK(v.paddle_x == 64, "left limit %d", v.paddle_x);
  g.buttons = RIGHT;
  v = run(g, 150);
  CHECK(v.paddle_x == 512, "right limit %d", v.paddle_x);
}

// Letting the ball fall uses up the spare balls one by one, then the game is over: no
// ball and no markers. FIRE starts a new game with a full wall and two spare balls.
void game_over_and_restart() {
  Game g;
  g.reset();
  int expected_lives = 2, frame = 0, missing = 0, since_launch = 1000, prev_y = -1;
  View v = run(g, 1);
  for (; frame < 20000; frame++) {
    // Keep the paddle against the left wall, and launch whenever the ball is resting.
    bool launch = resting(v);
    g.buttons = LEFT | (launch ? FIRE : 0);
    since_launch = launch ? 0 : since_launch + 1;
    v = run(g, 1);
    // Every new ball starts at the base speed, 2 px per frame, however fast the last one was.
    if (since_launch >= 2 && since_launch < 12)
      CHECK(v.ball && std::abs(v.ball_y - prev_y) == 2, "frame %d: new ball moved %d px",
            frame, std::abs(v.ball_y - prev_y));
    prev_y = v.ball_y;
    if (v.lives != expected_lives) {
      CHECK(v.lives == expected_lives - 1, "frame %d: life markers %d -> %d", frame,
            expected_lives, v.lives);
      printf("frame %5d: %d spare balls left\n", frame, v.lives);
      expected_lives = v.lives;
    }
    missing = v.ball ? 0 : missing + 1;
    if (missing == 3) break;  // the ball is never hidden for more than a frame in play
  }
  CHECK(missing == 3, "no game over within %d frames", frame);
  CHECK(v.lives == 0, "game over with %d markers left", v.lives);
  printf("frame %5d: game over with %d bricks standing\n", frame, v.bricks);

  g.buttons = 0;
  v = run(g, 30);
  CHECK(!v.ball, "ball reappeared without FIRE");
  g.buttons = FIRE;
  run(g, 1);
  g.buttons = 0;
  v = run(g, 2);
  CHECK(v.lives == 2, "after restart: life markers %d", v.lives);
  CHECK(v.bricks == 48, "after restart: bricks %d", v.bricks);
  CHECK(resting(v), "after restart: ball at (%d, %d)", v.ball_x, v.ball_y);
}

// Autoplay keeps the ball in play and clears a whole level (the wall comes back) without
// settling into a loop that never reaches the last bricks.
void autoplay_clears_a_level() {
  Game g;
  g.reset();
  g.autoplay = true;
  int fewest = 48, frame = 0, lives_lost = 0, lives = 2;
  bool cleared = false;
  for (; frame < 40000 && !cleared; frame++) {
    View v = run(g, 1, false);
    if (v.lives < lives) lives_lost += lives - v.lives;
    lives = v.lives;
    if (v.bricks < fewest) fewest = v.bricks;
    cleared = fewest <= 1 && v.bricks == 48;  // the last brick vanishes mid-frame
    if (frame % 2000 == 0) printf("frame %5d: %2d bricks, %d lost\n", frame, v.bricks, lives_lost);
  }
  printf("frame %5d: %s, %d spare balls lost\n", frame, cleared ? "level cleared" : "stuck",
         lives_lost);
  CHECK(cleared, "level not cleared in %d frames (fewest bricks %d)", frame, fewest);
}

// The ball moves 2 px per frame vertically until it clears its first brick, and averages
// 1.75 times that (3.5 px) once it has reached the top two rows.
void ball_speeds_up() {
  Game g;
  g.reset();
  g.autoplay = true;
  View v = run(g, 1);
  int prev_y = v.ball_y, lives = v.lives, frame = 0, samples = 0, sum = 0;
  for (; frame < 20000 && samples < 400; frame++) {
    v = run(g, 1);
    int dy = std::abs(v.ball_y - prev_y);
    prev_y = v.ball_y;
    if (v.lives != lives) {  // a lost ball starts again at the base speed: restart the count
      lives = v.lives;
      samples = sum = 0;
    }
    if (!v.ball || dy == 0 || dy > 4) continue;  // resting on the paddle, or a new ball
    if (v.bricks == 48) CHECK(dy == 2, "frame %d: %d px per frame before any brick", frame, dy);
    if (v.row_bricks[0] + v.row_bricks[1] < 16) {  // the top rows have been reached
      samples++;
      sum += dy;
    }
  }
  CHECK(samples == 400, "top rows not reached and held for 400 frames by frame %d", frame);
  double average = samples ? double(sum) / samples : 0;
  printf("frame %5d: average %.2f px per frame at the top rows\n", frame, average);
  CHECK(average > 3.3 && average < 3.7, "average step %.2f px, expected about 3.5", average);
}

struct Scenario {
  const char *name;
  void (*run)();
};

const Scenario scenarios[] = {
    {"launch", launch},
    {"steering", steering},
    {"paddle_limits", paddle_limits},
    {"game_over_and_restart", game_over_and_restart},
    {"ball_speeds_up", ball_speeds_up},
    {"autoplay_clears_a_level", autoplay_clears_a_level},
};

}  // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <scenario> | list\n", argv[0]);
    return 2;
  }
  for (const Scenario &s : scenarios) {
    if (!strcmp(argv[1], "list")) {
      printf("%s\n", s.name);
    } else if (!strcmp(argv[1], s.name)) {
      s.run();
      printf("%s: %s\n", s.name, failures ? "FAIL" : "PASS");
      return failures ? 1 : 0;
    }
  }
  if (!strcmp(argv[1], "list")) return 0;
  fprintf(stderr, "unknown scenario %s\n", argv[1]);
  return 2;
}
