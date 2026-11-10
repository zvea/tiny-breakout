// SPDX-FileCopyrightText: 2026 Alexei Zverovitch
// SPDX-License-Identifier: Apache-2.0
//
// Black-box scenario tests for Tiny Breakout.
//
// Each scenario drives only the chip's input pins (direct buttons, autoplay, the emulated
// Gamepad PMOD) and judges only from its outputs: every frame is decoded and the game state
// is read off the picture (life markers, ball, paddle, bricks), and the sound off the audio
// pin (each voice's volume and note). Nothing here depends on the design's internal signal
// names, so refactoring the RTL cannot break these tests; the per-module unit tests cover
// the internals.
//
// Each expensive stretch of play is simulated once and carries every check that needs it, in
// two tiers (the table at the end): the cheap scenarios run all the time; long_game plays a game
// from a new game to the third wall, at milestones.
// The comment before each scenario lists its parts and what each checks; every failure names
// its part and frame.
//
// Usage: scenarios <name>   (exit status 0 = pass)
//        scenarios list
// Normally built and run by test_scenarios.py (pytest).

#include "sim.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

namespace {

// ---- Inputs ------------------------------------------------------------------------------

constexpr uint8_t LEFT = 1, RIGHT = 2, FIRE = 4;  // direct button pins ui_in[2:0]

// Gamepad report bits {b,y,select,start,up,down,left,right,a,x,l,r}, b most significant
constexpr uint16_t GP_SELECT = 1 << 9, GP_LEFT = 1 << 5, GP_RIGHT = 1 << 4, GP_A = 1 << 3;
constexpr uint16_t GP_NONE = 0x0fff;  // the report of a PMOD with no controller: all ones

// ---- Reading the picture -----------------------------------------------------------------

// Colour of one pixel as 6 bits {r, g, b}, decoded from the TinyVGA PMOD byte
// {hsync, B0, G0, R0, vsync, B1, G1, R1}.
int colour(uint8_t o) {
  int r = ((o >> 0) & 1) << 1 | ((o >> 4) & 1);
  int g = ((o >> 1) & 1) << 1 | ((o >> 5) & 1);
  int b = ((o >> 2) & 1) << 1 | ((o >> 6) & 1);
  return r << 4 | g << 2 | b;
}

constexpr int BLACK = 0x00, WHITE = 0x3f, PADDLE = 0x2f, GREY = 0x15, NAVY = 0x01;
// The bricks by row, top to bottom: red, orange, yellow, green, azure, violet
constexpr int ROW_COLOURS[6] = {0x30, 0x38, 0x3c, 0x0c, 0x0b, 0x23};

struct View {
  int lives = 0;        // spare-life markers shown
  bool ball = false;    // ball visible below the top wall
  int ball_x = -1;      // top-left of the ball's bounding box
  int ball_y = -1;
  int paddle_x = -1;    // left edge of the paddle
  int paddle_w = 0;     // its width
  int bricks = 0;       // standing bricks
  uint64_t standing = 0;   // bit r * 8 + c: brick in row r (0 = top), column c
  int score = -1;       // as displayed (-1: not readable as digits)
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
  // Paddle: first paddle-coloured pixel on its bottom line, 455, which only a ball already
  // lost can cover (a bouncing ball reaches line 451)
  for (int x = 0; x < 640 && v.paddle_x < 0; x++)
    if (at(x, 455) == PADDLE) v.paddle_x = x;
  while (v.paddle_x >= 0 && v.paddle_x + v.paddle_w < 640 &&
         at(v.paddle_x + v.paddle_w, 455) == PADDLE)
    v.paddle_w++;
  // Score: 4 seven-segment digits in 16-px slots from x 512, read from the middle of each
  // segment (a..g)
  static const int seg_x[7] = {7, 10, 10, 7, 4, 4, 7}, seg_y[7] = {5, 8, 15, 17, 15, 8, 11};
  static const int digit_segments[10] = {0x7e, 0x30, 0x6d, 0x79, 0x33,
                                         0x5b, 0x5f, 0x70, 0x7f, 0x7b};
  v.score = 0;
  for (int slot = 0; slot < 4 && v.score >= 0; slot++) {
    int segments = 0, digit = -1;
    for (int i = 0; i < 7; i++)
      if (at(512 + 16 * slot + seg_x[i], seg_y[i]) == WHITE) segments |= 0x40 >> i;
    for (int d = 0; d < 10; d++)
      if (digit_segments[d] == segments) digit = d;
    v.score = digit < 0 ? -1 : v.score * 10 + digit;
  }
  // Bricks: 8 x 6 bricks of 64 x 16 px from (64, 64). A brick counts as standing if either
  // of two pixels inside it differs from the 2-px gap at the brick's left edge on the same
  // line (two, in case the ball covers one). Comparing with the gap, not with the field's
  // colour, also holds while rainbow bands fill the field after a cleared wall.
  for (int r = 0; r < 6; r++)
    for (int c = 0; c < 8; c++) {
      int x0 = 64 * (c + 1), y0 = 16 * (r + 4);
      auto is_brick = [&](int x, int y) {
        int k = at(x, y), gap = at(x0, y);
        return k != gap && gap != WHITE && k != WHITE && k != BLACK;
      };
      if (is_brick(x0 + 4, y0 + 4) || is_brick(x0 + 60, y0 + 13)) {
        v.bricks++;
        v.standing |= uint64_t{1} << (r * 8 + c);
      }
    }
  return v;
}

// A ball resting on the paddle sits at y 440, centred on it.
bool resting(const View &v) {
  return v.ball && v.ball_y == 440 && v.paddle_x >= 0 &&
         v.ball_x == v.paddle_x + v.paddle_w / 2 - 4;
}

// The black border (the status line and the strips beside the walls) as one colour, from
// three spots; -1 if they differ.
int border_colour(const Game &g) {
  auto at = [&](int x, int y) { return colour(g.fb[y * 640 + x]); };
  int top = at(300, 8), left = at(20, 300), right = at(620, 470);
  return top == left && left == right ? top : -1;
}

// Lines from the top that are black at x 300, a column the top wall, bricks, field and paddle
// all cross (none of them black) and the score does not: 24 (the status line) when nothing
// else is black there.
int black_from_top(const Game &g) {
  int y = 0;
  while (y < 480 && colour(g.fb[y * 640 + 300]) == BLACK) y++;
  return y;
}

// The walls after the first are grown from a seed row chosen by the LFSR (wall_pattern.sv):
// the bottom row is the seed, 4 bits mirrored into 8 columns, and each row from the top down is
// grown from the one before it by rule 150, or rule 182 when bit 4 is set. As `standing`.
uint64_t pattern_wall(int value) {
  int rule_182 = value >> 4 & 1;
  // Bit c: column c, for c = 0..3. Column 0 from bit 0 or bit 4, but never all four columns:
  // from 1111 every row grows full, which would repeat the first wall
  int high = value & 0b1110;
  int half = high | (((value & 1) | rule_182) & (high != 0b1110));
  auto row_bits = [](int h) {
    uint64_t row = 0;
    for (int c = 0; c < 8; c++) row |= uint64_t((h >> (c < 4 ? c : 7 - c)) & 1) << c;
    return row;
  };
  uint64_t wall = row_bits(half) << (5 * 8);
  for (int r = 0; r < 5; r++) {
    int left = ((half << 1) | (half & 1)) & 0xF, right = (half >> 1) | (half & 8);
    half = (left ^ half ^ right) | (left & right & -rule_182);
    wall |= row_bits(half & 0xF) << (r * 8);
  }
  return wall;
}

bool is_pattern_wall(uint64_t standing) {
  for (int value = 1; value < 32; value++)
    if (pattern_wall(value) == standing) return true;
  return false;
}

// ---- Checks ------------------------------------------------------------------------------

// A failed check is reported and counted, and the scenario goes on, so that one failure does
// not hide others (but rounds that each take a minute or more to simulate stop at the first
// failure, so that a broken design fails fast). Each message names the part of the scenario it
// comes from (`part`, set as the scenario goes) and the frame since power-up; past 100 failures
// they are only counted.
int failures = 0, frame_no = 0;
const char *part = "";

#define CHECK(cond, ...)                                                   \
  do {                                                                     \
    if (!(cond)) {                                                         \
      if (failures < 100) {                                                \
        printf("FAIL line %d, frame %d, %s: ", __LINE__, frame_no, part);  \
        printf(__VA_ARGS__);                                               \
        printf("  [%s]\n", #cond);                                         \
      }                                                                    \
      failures++;                                                          \
    }                                                                      \
  } while (0)

int shown_bricks = 0;  // in the last frame

// Reset through the pin, as at power-up
void power_up(Game &g) {
  g.reset();
  frame_no = 0;
  shown_bricks = 0;
}

// Checked on every frame played, in every scenario:
// - the ball never gets into the outer half of a wall: one touching a wall turns at the next
//   frame update, by then at most two moves (4 px) into it, so nothing white in x 56..59 or
//   580..583 below y 24, or in y 24..27 (the walls are 8 px thick: x 56..63, 576..583, y 24..31)
// - a new wall comes in whole: when the brick count rises, the frame before showed no bricks.
//   The frame in which a wall fills shows none (it once showed the bottom row).
void watch(const Game &g) {
  auto white = [&](int x, int y) { return colour(g.fb[y * 640 + x]) == WHITE; };
  int in_walls = 0;
  for (int y = 24; y < 480; y++)
    for (int x : {56, 57, 58, 59, 580, 581, 582, 583}) in_walls += white(x, y);
  for (int y = 24; y < 28; y++)
    for (int x = 60; x < 580; x++) in_walls += white(x, y);
  CHECK(in_walls == 0, "the ball is in a wall: %d white pixels in the walls' outer half", in_walls);
  int bricks = look(g, false).bricks;
  CHECK(bricks <= shown_bricks || shown_bricks == 0,
        "a wall of %d bricks came in after a frame that showed %d", bricks, shown_bricks);
  shown_bricks = bricks;
}

View run(Game &g, int frames, bool find_ball = true) {
  for (int i = 0; i < frames; i++) {
    g.frame();
    frame_no++;
    watch(g);
  }
  return look(g, find_ball);
}

// With no controller connected the game plays itself (demo). The emulated controller is
// recognised from its second report, which ends the demo and starts a new game; returns
// the view once that game's wall is in (frame 3) and its ball rests on the paddle.
View start_game(Game &g) {
  View v = run(g, 4);
  for (int i = 0; i < 6 && !(v.bricks == 48 && resting(v)); i++) v = run(g, 1);
  CHECK(v.bricks == 48 && resting(v), "no new game: %d bricks, ball at (%d, %d)", v.bricks,
        v.ball_x, v.ball_y);
  return v;
}

// A new ball goes onto the paddle at the next move, and at 1x every other frame has none:
// runs up to 2 more frames for it to come to rest.
View settle(Game &g, View v) {
  for (int i = 0; i < 2 && !resting(v); i++) v = run(g, 1);
  return v;
}

// ---- Listening ---------------------------------------------------------------------------

struct Voice {
  int vol = 0;          // 0..7
  int half = 0;         // its square wave's half-period in lines (the median run); 0 if silent
  bool noise = false;   // its runs differ in length (a tone's are all its half-period)
  bool coarse = false;  // every run a multiple of 8 lines: with noise, the rumble's
};
struct Sound {
  Voice a, b;
};

// One voice of the audio pin (1: A, 0: B), in the lines before the frame's update at line
// 480: they play the sound as the previous frame's update left it. A line counts as high if
// the voice was high for over a quarter of its loudest line's clocks (the pin is registered,
// so a line can start with one clock of the line before).
Voice hear(const Game &g, int voice) {
  const uint16_t *h = g.audio_high[voice];
  Voice v;
  int peak = 0;
  for (int y = 0; y < 480; y++) peak = std::max(peak, int(h[y]));
  v.vol = (peak + 25) / 50;
  if (!v.vol) return v;
  std::vector<int> runs;  // the runs of high lines and of low lines, but the first and last
  for (int y = 1, start = 0; y < 480; y++)
    if ((h[y] > peak / 4) != (h[y - 1] > peak / 4)) {
      if (start > 0) runs.push_back(y - start);
      start = y;
    }
  if (runs.empty()) return v;
  v.coarse = std::all_of(runs.begin(), runs.end(), [](int r) { return r % 8 == 0; });
  std::sort(runs.begin(), runs.end());
  v.half = runs[runs.size() / 2];
  v.noise = runs.back() - runs.front() > 1;
  return v;
}

Sound listen(const Game &g) { return {hear(g, 1), hear(g, 0)}; }

// Voice B playing voice A an octave below, at its volume: the new game's call
bool bass(const Sound &s) { return s.a.vol && s.b.vol == s.a.vol && s.b.half == 2 * s.a.half; }

// ---- Scenarios ---------------------------------------------------------------------------

// With no controller connected the game plays itself (demo): with no Gamepad PMOD at all,
// or with the PMOD reporting no controller (all ones). The demo ends, starting a new game,
// when a direct button is pressed or a controller is connected; after that nothing moves
// without input. Three runs, one for each way of ending it:
// - no PMOD, then a button: the demo plays, launching the ball and clearing a brick
// - PMOD without controller, then one connected: the demo launches the ball. Then the
//   controller's fire (A here; X, L and R are the same to the game) launches the new game's
//   ball, and unplugging the controller resumes the demo in that game: the ball flies on, and
//   the paddle, with the PMOD still in but no controller on it, steers itself.
// - PMOD without controller, reports across the frame update, then a button: the demo
//   launches the ball. A report with no controller is all ones, so the receiver sees SELECT
//   (bit 14) pressed until LEFT (bit 18) comes in; here the frame update falls in between.
void demo() {
  const char *names[] = {"no PMOD, then a button", "PMOD without controller, then one connected",
                         "PMOD without controller, reports across the frame update, then a button"};
  for (int how = 0; how < 3; how++) {
    part = names[how];
    Game g;
    power_up(g);
    if (how) g.pad_bits = GP_NONE;
    else g.pmod_plugged = false;
    if (how == 2) g.pmod_start = 480 * 800 - 16 * 40;  // the frame update is at clock 480 x 800
    View v = run(g, 4);
    int bricks0 = v.bricks;
    if (how == 0) {  // its first brick goes at about frame 280
      for (int i = 0; i < 900 && v.bricks >= bricks0; i++) v = run(g, 1, false);
      CHECK(v.bricks < bricks0, "demo cleared no bricks in 900 frames (%d left)", v.bricks);
      v = look(g);
      CHECK(!resting(v), "in the demo the ball is resting on the paddle");
    } else {
      v = run(g, 20);
      CHECK(v.ball && v.ball_y < 440 - 10, "the demo did not launch the ball: y %d", v.ball_y);
    }
    if (how == 1) {
      g.pad_bits = 0;  // a controller is connected, nothing pressed
      v = settle(g, run(g, 3));
    } else {
      g.buttons = LEFT;
      run(g, 1);
      g.buttons = 0;
      v = settle(g, run(g, 3));  // a new game at the next frame update, then its wall fills
    }
    CHECK(v.bricks == 48 && v.lives == 2, "then %d bricks, %d spare balls", v.bricks, v.lives);
    CHECK(resting(v), "then the ball is at (%d, %d), paddle %d", v.ball_x, v.ball_y, v.paddle_x);
    int x0 = v.paddle_x;
    v = run(g, 60);
    CHECK(resting(v) && v.paddle_x == x0, "without input, ball (%d, %d), paddle %d -> %d",
          v.ball_x, v.ball_y, x0, v.paddle_x);
    if (how != 1) continue;

    part = "controller's fire, then unplugged";
    g.pad_bits = GP_A;
    run(g, 1);
    g.pad_bits = 0;
    v = run(g, 20);
    CHECK(v.ball && v.ball_y < 440 - 10, "A did not launch the ball: y %d", v.ball_y);
    CHECK(v.paddle_x == x0, "the paddle moved from %d to %d without input", x0, v.paddle_x);
    // A new game would put the ball back on the paddle; the demo carries on with it
    g.pad_bits = GP_NONE;
    int y0 = v.ball_y, moved_after = -1;
    for (int i = 0; i < 30 && moved_after < 0; i++) {
      v = run(g, 1);
      CHECK(v.ball && !resting(v) && std::abs(v.ball_y - y0) <= 4 * (i + 1),
            "%d frames after unplugging: ball at (%d, %d), was at y %d", i + 1, v.ball_x, v.ball_y,
            y0);
      CHECK(v.bricks == 48 && v.lives == 2, "%d frames after unplugging: %d bricks, %d markers",
            i + 1, v.bricks, v.lives);
      if (v.paddle_x != x0) moved_after = i + 1;
    }
    CHECK(moved_after > 0, "the demo did not steer the paddle in 30 frames (still at %d)", x0);
  }
}

// The colours of one frame of a new game: each row of bricks in its colour (red at the top,
// then orange, yellow, green, azure and violet), the walls grey, the field navy, the paddle
// pale cyan.
void check_colours(const Game &g, const View &v) {
  auto at = [&](int x, int y) { return colour(g.fb[y * 640 + x]); };
  for (int r = 0; r < 6; r++)
    for (int c = 0; c < 8; c++) {
      int k = at(64 * (c + 1) + 32, 16 * (r + 4) + 8);
      CHECK(k == ROW_COLOURS[r], "brick %d in row %d is %#x, expected %#x", c, r, k,
            ROW_COLOURS[r]);
    }
  for (auto [x, y] : {std::pair{60, 300}, {580, 300}, {300, 28}})
    CHECK(at(x, y) == GREY, "the wall at (%d, %d) is %#x", x, y, at(x, y));
  CHECK(at(300, 300) == NAVY, "the field is %#x", at(300, 300));
  CHECK(at(v.paddle_x + v.paddle_w / 2, 452) == PADDLE, "the paddle is %#x",
        at(v.paddle_x + v.paddle_w / 2, 452));
}

// A new game, played by hand from the pins:
// - new game: the call (G4, D5, G5 for 8 frames each, then C6 for 24) with voice B an octave
//   below, the full wall, two spare balls and the ball resting on the paddle; then quiet while
//   it waits there
// - colours: of the bricks, walls, field and paddle
// - steering: the paddle moves 4 px every other frame (at the base speed) while LEFT or RIGHT
//   is held, from either the direct pins or the gamepad; both together cancel out. The resting
//   ball moves with it.
// - limits: the first level's paddle is 96 px wide and stops at the walls: its left end at
//   x 64, its right end at x 575 (left end at x 480)
// - launch: FIRE launches the ball upwards
// - select: after a reset, SELECT on the gamepad switches autoplay on: it launches the ball and
//   steers. Left, right or fire switches it off, after which the paddle only moves when told.
void controls() {
  Game g;
  power_up(g);
  part = "new game";
  Sound s;
  for (int i = 0; i < 10 && !(bass(s) && s.a.half == 40); i++) {  // the demo ends
    run(g, 1, false);
    s = listen(g);
  }
  const int call[][2] = {{40, 8}, {27, 8}, {20, 8}, {15, 24}};  // G4 D5 G5 C6: lines, frames
  for (const auto &note : call) {  // a note that sticks is cut off at 4 times its length
    int n = 0;
    for (; n < 4 * note[1] && s.a.half == note[0] && bass(s); n++) {
      run(g, 1, false);
      s = listen(g);
    }
    CHECK(n == note[1], "%d frames of the note at %d lines over its bass (expected %d)", n,
          note[0], note[1]);
  }
  View v = look(g);
  CHECK(v.bricks == 48, "bricks %d", v.bricks);
  CHECK(v.lives == 2, "life markers %d", v.lives);
  CHECK(resting(v), "ball at (%d, %d), paddle at %d", v.ball_x, v.ball_y, v.paddle_x);
  for (int i = 0; i < 30; i++) {  // the ball waits on the paddle: quiet
    CHECK(s.a.vol == 0 && s.b.vol == 0, "%d frames after the call: volumes %d, %d (notes %d, %d)",
          i, s.a.vol, s.b.vol, s.a.half, s.b.half);
    run(g, 1, false);
    s = listen(g);
  }

  part = "colours";
  check_colours(g, look(g));

  for (int source = 0; source < 2; source++) {
    part = source ? "steering by gamepad" : "steering by direct pins";
    auto press = [&](bool l, bool r) {
      if (source) g.pad_bits = (l ? GP_LEFT : 0) | (r ? GP_RIGHT : 0);
      else g.buttons = (l ? LEFT : 0) | (r ? RIGHT : 0);
    };
    // Each press lasts 10 frames; a frame shows the paddle as the frame before left it, so its
    // last move shows in the frame after
    int x0 = run(g, 2).paddle_x;
    press(false, true);
    for (int i = 0; i < 10; i++) {  // the resting ball stays centred on the moving paddle
      v = run(g, 1);
      CHECK(resting(v), "moving right, frame %d: ball at x %d, paddle %d", i, v.ball_x, v.paddle_x);
    }
    press(false, false);
    int x1 = run(g, 1).paddle_x;
    CHECK(x1 >= x0 + 16 && x1 <= x0 + 24, "right moved the paddle %d -> %d", x0, x1);
    press(true, false);
    run(g, 10);
    press(false, false);
    int x2 = run(g, 1).paddle_x;
    CHECK(x2 <= x1 - 16 && x2 >= x1 - 24, "left moved the paddle %d -> %d", x1, x2);
    press(true, true);
    int x3 = run(g, 2).paddle_x;
    int x4 = run(g, 10).paddle_x;
    CHECK(x4 == x3, "left + right moved the paddle %d -> %d", x3, x4);
    press(false, false);
  }

  // From the middle, 2 px a frame takes 104 frames to the left wall and 208 across
  part = "limits";
  CHECK(v.paddle_w == 96, "the first level's paddle is %d px wide", v.paddle_w);
  g.buttons = LEFT;
  v = run(g, 120);
  CHECK(v.paddle_x == 64, "left limit %d", v.paddle_x);
  g.buttons = RIGHT;
  v = run(g, 225);
  CHECK(v.paddle_x == 480 && v.paddle_w == 96, "right limit %d (%d px wide)", v.paddle_x,
        v.paddle_w);

  part = "launch";
  g.buttons = FIRE;
  run(g, 1);
  g.buttons = 0;
  v = run(g, 20);
  CHECK(v.ball && v.ball_y < 440 - 10, "ball not launched upwards: y %d", v.ball_y);

  part = "select";
  power_up(g);
  start_game(g);
  g.pad_bits = GP_SELECT;
  run(g, 3);
  g.pad_bits = 0;
  v = run(g, 30);
  CHECK(v.ball && v.ball_y < 440, "autoplay did not launch the ball: y %d", v.ball_y);
  int steered = 0;  // frames in which the paddle moved, with no button pressed
  for (int i = 0; i < 120; i++) {
    int x = v.paddle_x;
    v = run(g, 1);
    steered += v.paddle_x != x;
  }
  CHECK(steered > 0, "autoplay did not steer: the paddle stayed at %d", v.paddle_x);
  g.pad_bits = GP_LEFT;
  run(g, 2);
  g.pad_bits = 0;
  int x0 = run(g, 1).paddle_x;
  v = run(g, 60);
  CHECK(v.paddle_x == x0, "paddle moved with autoplay off: %d -> %d", x0, v.paddle_x);
}

// A new game in which every ball falls: LEFT is held throughout, so the paddle goes to the left
// wall and stays there, and FIRE launches each ball as soon as it rests on the paddle.
// - losses: the spare-ball markers count down one at a time, and every new ball starts at the
//   base speed, a 2-px move every other frame, however fast the last one was. A ball that has
//   fallen below the paddle (top at y >= 456) is lost: the border (the status line and the
//   strips beside the walls) turns red, brighter in each 8-px band it falls through (maroon,
//   dark red, red), and black again once the ball has left the screen; black at every other
//   time. Each lost ball sighs (E-flat, 25 lines), the last one plays the sad trombone (G4, 40).
// - game over: no ball and no markers, and the score is 10 per brick cleared. A black curtain
//   comes down from the top, 16 px a frame, until only the score is left, unchanged; FIRE
//   held while it comes down starts nothing, no ball comes without FIRE, and once the trombone
//   has ended, all is quiet.
// - restart: fire (A on the gamepad here) starts a new game. From its first frame nothing of the
//   old one shows: the border is black (it once flashed the level-clear rainbow, as the
//   curtain's count carried over), and the picture is back with a full wall, two spare balls,
//   score 0 and the ball resting on the paddle.
void losing_every_ball() {
  Game g;
  power_up(g);
  part = "losses";
  View v = start_game(g), before = v;
  int expected_lives = 2, since_launch = 1000, prev_y = -1, prev_dy = 0, missing = 0, lit = 0;
  int this_ball = 0;  // frames since the last ball was lost (or the game began)
  bool shades[4] = {};
  // Voice A's notes, frame by frame with repeats merged, leaving out the new game's call (known
  // by its bass on voice B). A lost ball's sigh (E-flat, D, C: 25, 27, 30 lines) and the
  // game-over trombone (G4, F#4, F4: 40, 42, 45) are found in it by their notes, whatever their
  // volumes: bricks and the paddle don't cut them short, and no other sound plays those runs.
  std::vector<int> notes;
  auto losses = [&] {
    std::vector<std::string> found;
    for (size_t i = 0; i + 2 < notes.size(); i++) {
      std::vector<int> run3(notes.begin() + i, notes.begin() + i + 3);
      if (run3 == std::vector<int>({25, 27, 30})) found.push_back("sigh");
      if (run3 == std::vector<int>({40, 42, 45})) found.push_back("trombone");
    }
    return found;
  };
  Sound s;
  auto listen_for_losses = [&] {
    s = listen(g);
    if (s.a.vol && !bass(s) && (notes.empty() || notes.back() != s.a.half))
      notes.push_back(s.a.half);
  };
  // Until the curtain shows (more than the 24-line status line is black), or the ball has
  // been gone for 10 frames: game over, with no curtain. Or until a ball has been in play for
  // 3600 frames: at 1x one goes up to the bricks and back past the paddle in about 600, or 1200
  // if the paddle sends it up again, so it would never be lost.
  while (this_ball < 3600 && black_from_top(g) <= 24 && missing < 10) {
    this_ball++;
    bool launch = resting(v);
    g.buttons = LEFT | (launch ? FIRE : 0);
    since_launch = launch ? 0 : since_launch + 1;
    before = v;
    v = run(g, 1);
    listen_for_losses();
    // Red channel = the ball's 8-px band below the paddle; black while it is higher, and once
    // it has left the screen (then it is not visible). This restates the RTL's own rule
    // (lost_rgb from ball_y[4:3]): it catches a broken implementation, not a wrong rule.
    int expected = v.ball && v.ball_y >= 456 ? ((v.ball_y >> 3) & 3) << 4 : BLACK;
    CHECK(border_colour(g) == expected, "ball at y %d, border %#x, expected %#x",
          v.ball ? v.ball_y : -1, border_colour(g), expected);
    if (expected != BLACK) {
      lit++;
      shades[expected >> 4] = true;
    }
    int dy = std::abs(v.ball_y - prev_y);
    if (since_launch >= 3 && since_launch < 12)
      CHECK(v.ball && (dy == 0 || dy == 2) && dy + prev_dy == 2, "new ball moved %d then %d px",
            prev_dy, dy);
    prev_y = v.ball_y;
    prev_dy = dy;
    if (v.lives != expected_lives) {
      CHECK(v.lives == expected_lives - 1, "life markers %d -> %d", expected_lives, v.lives);
      printf("frame %5d: %d spare balls left\n", frame_no, v.lives);
      expected_lives = v.lives;
      this_ball = 0;
    }
    missing = v.ball ? 0 : missing + 1;
  }
  CHECK(lit > 0 && shades[1] && shades[2] && shades[3],
        "the border never showed all three shades (%d lit frames)", lit);

  part = "game over";
  CHECK(black_from_top(g) > 24, "no curtain (ball gone for %d frames, %d since the last loss)",
        missing, this_ball);
  if (black_from_top(g) <= 24) return;
  // The frame before the curtain shows is after game over (see below)
  CHECK(!before.ball && before.lives == 0, "ball %s, %d markers left",
        before.ball ? "showing" : "gone", before.lives);
  CHECK(before.score == 10 * (48 - before.bricks), "score %d with %d bricks cleared", before.score,
        48 - before.bricks);
  printf("frame %5d: game over with %d bricks standing, score %d\n", frame_no, before.bricks,
         before.score);

  // The first frame that shows it has it 32 lines down (game over, then 16, then 32: the first
  // 16 are the black status line anyway), then 16 more each frame until it reaches the bottom.
  // FIRE held for the first 20 of those frames doesn't start a new game: only once it is down.
  part = "curtain";
  for (int line = 32; line <= 480 + 32; line += 16) {
    g.buttons = line < 32 + 16 * 20 ? FIRE : 0;
    int expected = line < 480 ? line : 480;
    CHECK(black_from_top(g) == expected, "curtain at %d lines, expected %d", black_from_top(g),
          expected);
    CHECK(border_colour(g) == BLACK, "border %#x", border_colour(g));
    CHECK(!v.ball, "a ball at (%d, %d) before the curtain is down", v.ball_x, v.ball_y);
    v = run(g, 1);
    listen_for_losses();
  }
  int others = 0;
  for (int y = 0; y < 480; y++)
    for (int x = 0; x < 640; x++)
      if (!(x >= 512 && x < 576 && y >= 3 && y < 19) && colour(g.fb[y * 640 + x]) != BLACK)
        others++;  // the score's cells: x 512..575, y 3..18
  CHECK(others == 0, "after the curtain: %d pixels besides the score are not black", others);
  CHECK(v.score == before.score, "after the curtain: score %d, was %d", v.score, before.score);

  // Wait for the trombone to end (about 25 frames after the curtain is down), then 30 frames of
  // quiet, still with no ball
  part = "game over";
  for (int i = 0; i < 100 && !(losses().size() >= 3 && s.a.vol == 0); i++) {
    v = run(g, 1);
    listen_for_losses();
    CHECK(!v.ball && border_colour(g) == BLACK, "ball %s, border %#x without FIRE",
          v.ball ? "showing" : "gone", border_colour(g));
  }
  std::string heard;
  for (const auto &n : losses()) heard += " " + n;
  CHECK(losses() == std::vector<std::string>({"sigh", "sigh", "trombone"}), "sounds:%s",
        heard.c_str());
  for (int i = 0; i < 30; i++) {
    v = run(g, 1);
    s = listen(g);
    CHECK(s.a.vol == 0 && s.b.vol == 0, "%d frames after the trombone: volumes %d, %d", i, s.a.vol,
          s.b.vol);
    CHECK(!v.ball && border_colour(g) == BLACK, "ball %s, border %#x without FIRE",
          v.ball ? "showing" : "gone", border_colour(g));
  }

  part = "restart";
  g.pad_bits = GP_A;
  run(g, 1);
  g.pad_bits = 0;
  for (int i = 0; i < 3; i++) {
    v = run(g, 1);
    CHECK(border_colour(g) == BLACK, "frame %d of the new game: border %#x", i, border_colour(g));
  }
  v = settle(g, v);
  CHECK(black_from_top(g) == 24, "%d black lines from the top", black_from_top(g));
  CHECK(v.lives == 2, "life markers %d", v.lives);
  CHECK(v.score == 0, "score %d", v.score);
  CHECK(v.bricks == 48, "bricks %d", v.bricks);
  CHECK(resting(v), "ball at (%d, %d)", v.ball_x, v.ball_y);
}


// Balls lost faster than the base speed with FIRE held, as autoplay and the demo always hold it:
// each costs one ball, and the next ball goes onto the paddle before it is launched. A lost ball
// is put on the paddle at the next move, and at 1x odd frames have none: with FIRE held the game
// once launched it from below the screen, losing it again and again, down to game over (from
// 1.5x up, where the ball can be lost on either parity). Autoplay speeds each ball up to 1.5x (4
// bricks), then the paddle is held at the left wall with FIRE until the ball is lost. A ball put
// on the paddle a frame later shows a loss on the parity that failed; both must be seen. The last
// ball's loss ends the game and is not checked, so that ball is lost at 1x, without autoplay.
void lost_at_speed() {
  Game g;
  power_up(g);
  part = "lost at speed";
  View v = start_game(g);
  std::vector<int> delays;  // per loss, frames until the next ball rests on the paddle
  // A round takes over a minute to simulate: the rounds end at the first failure, as the rest
  // would most likely fail the same way
  for (int round = 0; round < 8 && !failures; round++) {
    int sped = 0;
    if (v.lives > 0) {
      g.autoplay = true;  // speed this ball up: 4 bricks cleared since it was launched
      g.buttons = 0;
      int base = v.bricks;
      // At 1x a trip from the paddle to the bricks and back takes about 600 frames: autoplay
      // clears 4 bricks in 1500 to 3000, or more now and then as the wall thins (8000 to be safe)
      for (; sped < 8000 && base - v.bricks < 4; sped++) {
        v = run(g, 1);
        if (resting(v)) base = v.bricks;
      }
      CHECK(base - v.bricks >= 4, "round %d: the ball cleared %d bricks, not 4", round,
            base - v.bricks);
      if (failures) break;
    }
    g.autoplay = false;  // lose it, with FIRE held
    g.buttons = LEFT | FIRE;
    int lives = v.lives;
    // At 1.5x it falls past the paddle and off the screen in about 250 frames, or 650 if the
    // paddle sends it up again; the last ball, launched at 1x, in about 600, or 1200 if sent up
    // again, then the curtain comes down and FIRE starts a new game: 3600 is plenty
    int lost = 0;
    for (; lost < 3600 && v.lives == lives; lost++) v = run(g, 1);
    if (lives == 0) {  // the last ball: game over, and FIRE starts a new game
      // That loss ends on the new game's first frame, which shows its markers but not yet its
      // wall (frame 3, see start_game). The next round counts the bricks cleared from the wall
      // it starts with, so wait for it.
      for (int i = 0; i < 6 && v.bricks < 48; i++) v = run(g, 1);
      CHECK(v.bricks == 48 && v.lives == 2, "round %d: a new game with %d bricks, %d spare balls",
            round, v.bricks, v.lives);
      printf("frame %5d: round %d: the last ball lost at 1x, and a new game, in %d frames\n",
             frame_no, round, lost);
      continue;
    }
    CHECK(v.lives == lives - 1, "round %d: %d spare balls after losing one of %d", round, v.lives,
          lives);
    int d = 0;
    for (; d < 4 && !resting(v); d++) v = run(g, 1);
    CHECK(resting(v), "round %d: no ball on the paddle %d frames after the loss", round, d);
    CHECK(v.lives == lives - 1, "round %d: %d spare balls once the next ball rests (was %d)", round,
          v.lives, lives);
    printf("frame %5d: round %d: 4 bricks in %d frames, the ball lost in %d, the next resting %d "
           "later\n", frame_no, round, sped, lost, d);
    delays.push_back(d);
    if (std::count(delays.begin(), delays.end(), delays.front()) < int(delays.size())) break;
  }
  std::string seen;
  for (int d : delays) seen += " " + std::to_string(d);
  printf("frames from each loss to the next ball resting:%s\n", seen.c_str());
  if (!failures)  // stopped early, the rounds played may have been too few to see both
    CHECK(delays.size() >= 2 &&
              std::count(delays.begin(), delays.end(), delays.front()) < int(delays.size()),
          "losses seen on only one frame parity (delays:%s)", seen.c_str());

  // Reset in the middle of the game (score, fewer bricks, balls lost): a new game as at power-up,
  // which, with the controller in, starts with the call
  part = "reset mid-game";
  CHECK(v.score > 0 && v.bricks < 48, "before the reset: score %d, %d bricks", v.score, v.bricks);
  g.autoplay = false;
  g.buttons = 0;
  power_up(g);
  v = run(g, 4);
  Sound s = listen(g);
  CHECK(v.bricks == 48 && v.score == 0 && v.lives == 2, "after reset: %d bricks, score %d, %d "
        "spare balls", v.bricks, v.score, v.lives);
  CHECK(v.paddle_w == 96 && v.paddle_x == 272 && resting(v), "after reset: paddle at %d, %d px "
        "wide, ball at (%d, %d)", v.paddle_x, v.paddle_w, v.ball_x, v.ball_y);
  CHECK(bass(s) && s.a.half == 40, "after reset: not the call's G4 over its bass (voice A %d "
        "lines at volume %d, voice B %d at %d)", s.a.half, s.a.vol, s.b.half, s.b.vol);
}
// ---- Following play frame by frame -------------------------------------------------------

// A brick turns the ball back through the edge it came in by: hit on a side, the ball
// reverses horizontally; on the top or bottom, vertically. Of the two edges its direction
// allows, it came in by the one its 8x8 box is less far past (ties: top or bottom). Checked
// for every brick that goes alone, AHEAD frames later, once the ball has moved on.
struct BrickBounces {
  static constexpr int KEEP = 32, AHEAD = 12;  // frames kept, and frames looked ahead
  View v[KEEP];
  long t = 0;           // frames seen
  int checked[2] = {};  // side, top/bottom
  const View &at(long i) const { return v[i % KEEP]; }
  void feed(const View &w) {
    v[t++ % KEEP] = w;
    if (t - 1 - AHEAD >= 2) check(t - 1 - AHEAD);
  }
  void check(long s) {
    uint64_t gone = at(s - 1).standing & ~at(s).standing;
    if (gone == 0 || (gone & (gone - 1)) != 0 || at(s).bricks == 48) return;  // one brick
    // and no other in the frames either side: two bricks hit in one frame (both bounces count)
    // can vanish from the picture a frame apart, one drawn before the ball reached it
    if (s >= 2 && (at(s - 2).standing & ~at(s - 1).standing)) return;
    if (at(s).standing & ~at(s + 1).standing & ~gone) return;
    int b = __builtin_ctzll(gone), bx = 64 * (b % 8 + 1) + 2, by = 16 * (b / 8 + 4) + 2;
    // The brick (at bx..bx+61, by..by+13) vanished while frame s or s - 1 was drawn: the
    // first of them in which the ball's box overlaps it.
    auto overlaps = [&](const View &w) {
      return w.ball && w.ball_x < bx + 62 && w.ball_x + 8 > bx && w.ball_y < by + 14 &&
             w.ball_y + 8 > by;
    };
    long c = overlaps(at(s - 1)) ? s - 1 : s;
    // Some frames have no move: compare with the nearest frames where the ball moved
    auto moved = [&](long i) {
      return at(i).ball_x != at(c).ball_x || at(i).ball_y != at(c).ball_y;
    };
    long pi = c - 1, ni = c + 1, first = std::max(0L, t - KEEP), last = t - 1;
    while (pi > first && !moved(pi)) pi--;
    while (ni < last && !moved(ni)) ni++;
    const View &p = at(pi), &h = at(c), &n = at(ni);
    if (!p.ball || !h.ball || !n.ball || !overlaps(h) || !moved(pi) || !moved(ni)) return;
    if (h.ball_x < 80 || h.ball_x > 560 || h.ball_y < 48) return;  // walls could interfere
    bool left = h.ball_x < p.ball_x, up = h.ball_y < p.ball_y;
    // The edge it came through, by the RTL's own rule (side_hit: whichever of the two edges its
    // direction allows the box is less far past), so this catches a broken implementation of
    // the rule, not a wrong rule; the ball's actual turn is what's observed
    int past_side = left ? bx + 62 - h.ball_x : h.ball_x + 8 - bx;
    int past_flat = up ? by + 14 - h.ball_y : h.ball_y + 8 - by;
    bool side = past_side < past_flat;
    bool turned_x = (n.ball_x < h.ball_x) != left, turned_y = (n.ball_y < h.ball_y) != up;
    CHECK(turned_x == side && turned_y == !side,
          "brick %d hit from (%d, %d) moving %s-%s at frame %ld: expected a %s bounce, got "
          "x %s, y %s", b, h.ball_x, h.ball_y, left ? "left" : "right", up ? "up" : "down",
          frame_no - (last - c), side ? "side" : "top/bottom", turned_x ? "turned" : "kept",
          turned_y ? "turned" : "kept");
    checked[side ? 0 : 1]++;
  }
};

// The ball speeds up a half step every 4 bricks it clears: vertically it moves 4 px per 4
// frames at first (1x), then 6 (1.5x), 8 (2x), 10 (2.5x), and 12 px (3x) once it has cleared
// 16. Every ball starts at 1x, so the count starts again with each ball (and each wall).
struct SpeedSteps {
  int prev_y = -1, prev_bricks = -1, prev_lives = -1;
  int base = 48;  // the bricks when this ball started
  bool prev_known = false;  // whether prev_y is where the ball was
  int run_step = -1, run_len = 0, window[4] = {};  // vertical moves of the last 4 frames
  int checked[5] = {};  // windows checked at 1x, 1.5x, 2x, 2.5x, 3x
  int cleared(const View &v) const { return base - v.bricks; }
  void feed(const View &v) {
    // A new ball (a spare one used: a marker fewer), or a new wall (and a new game), restarts
    // the count. Not a ball seen resting: one bouncing off the paddle's middle can look so.
    if (v.lives < prev_lives || v.bricks > prev_bricks) base = v.bricks;
    prev_lives = v.lives;
    // A ball in the top wall (y 28 or 30, at most two moves in) is read as at y 32, where the
    // search for it starts: its move is known only if it is seen below that in both frames
    bool known = v.ball && v.ball_y > 32, moved_known = known && prev_known;
    int dy = std::abs(v.ball_y - prev_y);
    bool steady = v.bricks == prev_bricks;  // the picture's count lags a brick cleared mid-frame
    prev_y = v.ball_y;
    prev_known = known;
    prev_bricks = v.bricks;
    if (!moved_known || !steady || resting(v)) {
      run_len = 0;  // no window across a gap
      return;
    }
    int step = std::min(cleared(v) / 4, 4);  // 0..4: 1x, 1.5x, 2x, 2.5x, 3x
    if (step != run_step) run_len = 0;
    run_step = step;
    window[run_len++ % 4] = dy;
    if (run_len >= 4) {
      int sum = window[0] + window[1] + window[2] + window[3];
      CHECK(sum == 4 + 2 * step, "%d bricks cleared by this ball, moved %d px in 4 frames "
            "(expected %d)", cleared(v), sum, 4 + 2 * step);
      checked[step]++;
    }
  }
};

// Where the ball lands on the paddle sets its bounce: left from the left half, right from the
// right half, at the flatter angle (2 px across per 2 px up) from the last 16 px at each end,
// else the steeper one (1 px across). The zone is the one under the last ball pixel to touch
// the paddle, the right end of the ball's bottom row (ball x + 5), in the last frame it
// touches. Autoplay picks the zone to aim for at random (from the LFSR) after each paddle hit.
struct PaddleZones {
  View touch, from;
  int tracking = -1;    // frames since the ball left the paddle
  int checked[4] = {};  // bounces checked by zone, from the left
  bool all_seen() const { return checked[0] && checked[1] && checked[2] && checked[3]; }
  int total() const { return checked[0] + checked[1] + checked[2] + checked[3]; }
  static bool on_paddle_row(const View &w) {
    return w.ball && w.ball_y + 7 >= 448 && w.ball_y <= 455;
  }
  void feed(const View &prev, const View &v) {
    bool left_paddle = on_paddle_row(prev) && !on_paddle_row(v) && v.ball && v.ball_y < prev.ball_y;
    if (tracking < 0 && left_paddle) {
      touch = prev;  // the last frame the ball touched the paddle: it decided the bounce
      from = v;
      tracking = 0;  // follow the ball up for 8 frames
    } else if (tracking >= 0 && ++tracking == 8) {
      tracking = -1;
      int dx = v.ball_x - from.ball_x, dy = from.ball_y - v.ball_y;
      // Only bounces with the ball's bottom row wholly over the paddle, clear of the walls
      bool clean = v.ball && dy > 0 && touch.paddle_x <= touch.ball_x + 2 &&
                   touch.ball_x + 5 < touch.paddle_x + touch.paddle_w && from.ball_x >= 80 &&
                   from.ball_x <= 552 && v.ball_x >= 80 && v.ball_x <= 552;
      if (!clean) return;
      int half = touch.paddle_w / 2, d = touch.ball_x + 5 - (touch.paddle_x + half);
      bool right = d >= 0, outer = d < 16 - half || d >= half - 16;
      int zone = right ? (outer ? 3 : 2) : (outer ? 0 : 1);
      CHECK((dx > 0) == right && std::abs(dx) * (outer ? 1 : 2) == dy,
            "zone %d (pixel %+d px from the centre of a %d-px paddle): then %+d px across for %d "
            "up", zone, d, touch.paddle_w, dx, dy);
      checked[zone]++;
    }
  }
};

// Each brick that goes alone plays its row's note an octave down (red highest), two scale steps
// higher once the ball is fast (2x, from 8 bricks cleared by this ball), at volume 5. The brick
// leaves the picture as its note starts, give or take a frame. Also keeps every frame's sound.
struct BrickNotes {
  struct Hit {
    int row, frame, cleared;  // cleared: by this ball, as the picture shows it
  };
  std::vector<Sound> heard;
  std::vector<Hit> pending;
  int checked[2] = {};  // slow, fast
  std::vector<int> removals;  // frames in which bricks vanished from the picture
  void feed(const View &before, const View &v, const Sound &s, int cleared) {
    heard.push_back(s);
    uint64_t gone = before.standing & ~v.standing;
    if (gone) removals.push_back(int(heard.size()) - 1);
    if (gone && v.bricks == before.bricks - 1)
      pending.push_back({__builtin_ctzll(gone) / 8, int(heard.size()) - 1, cleared});
    while (!pending.empty() && pending.front().frame + 1 < int(heard.size())) {
      // Not when another brick vanished a frame before or after: two bricks hit in one frame
      // can show a frame apart, and the note is the second's
      int f = pending.front().frame;
      if (std::count(removals.begin(), removals.end(), f - 1) == 0 &&
          std::count(removals.begin(), removals.end(), f + 1) == 0)
        check(pending.front());
      pending.erase(pending.begin());
    }
  }
  void check(const Hit &h) {
    static const int scale[8] = {60, 54, 48, 40, 36, 30, 27, 24};  // C4 D4 E4 G4 A4 C5 D5 E5
    // The picture can lag the game by a brick cleared after the beam passed it: with 7 shown
    // cleared, this may be the 8th, and either note is right
    if (h.cleared == 7) return;
    bool fast = h.cleared >= 8;
    int n = scale[std::min(7, 5 - h.row + (fast ? 2 : 0))];
    bool ok = false;
    for (int f = h.frame - 1; f <= h.frame + 1; f++)
      ok |= f >= 0 && f < int(heard.size()) && heard[f].a.half == n && heard[f].a.vol == 5 &&
            !bass(heard[f]);
    CHECK(ok, "brick in row %d, %d cleared by this ball: no note of %d lines", h.row, h.cleared,
          n);
    checked[fast]++;
  }
};

// Plays a game frame by frame, with the checks above following it
struct Follow {
  Game &g;
  View v;
  BrickBounces bounces;
  SpeedSteps speeds;
  PaddleZones zones;
  BrickNotes notes;
  int paddle_bounces = 0, dir = 0;  // in the picture: the ball turning up near the paddle
  View step() {
    View before = v;
    v = run(g, 1);
    bounces.feed(v);
    speeds.feed(v);
    zones.feed(before, v);
    notes.feed(before, v, listen(g), speeds.cleared(v));
    if (v.ball && before.ball && v.ball_y != before.ball_y) {
      int d = v.ball_y > before.ball_y ? 1 : -1;
      paddle_bounces += dir == 1 && d == -1 && before.ball_y >= 400;
      dir = d;
    }
    return v;
  }
};

// At each paddle bounce, the thock (a low C dropping over 3 frames: 60, 66, 72 lines, getting
// quieter) over the thump, once per bounce; at the walls a rumble that fades and does not start
// over. Each is known by what it is, not by its volumes: the thock by its falling notes (a brick's
// C4 holds its note), the thump and the rumble as noise (runs of differing lengths) stepped every
// line or every 8 lines. `heard` holds the frames up to the current one.
void check_paddle_and_wall_sounds(const std::vector<Sound> &heard, int bounces) {
  int thocks = 0, rumbles = 0;
  auto frame_of = [&](size_t f) { return frame_no - int(heard.size() - 1 - f); };
  auto thump = [](const Voice &b) { return b.noise && !b.coarse; };
  auto rumble = [](const Voice &b) { return b.noise && b.coarse; };
  for (size_t f = 1; f + 3 < heard.size(); f++) {
    const Sound &h = heard[f], &prev = heard[f - 1];
    if (h.a.half == 60 && heard[f + 1].a.half == 66) {  // a thock
      thocks++;
      const Voice &a1 = heard[f + 1].a, &a2 = heard[f + 2].a;
      CHECK(a2.half == 72 && h.a.vol > a1.vol && a1.vol > a2.vol,
            "thock at frame %d: 60 (volume %d), 66 (volume %d), then %d (volume %d)",
            frame_of(f), h.a.vol, a1.vol, a2.half, a2.vol);
      CHECK(thump(h.b), "thock at frame %d without the thump under it", frame_of(f));
    }
    if (rumble(h.b) && !rumble(prev.b)) rumbles++;  // once per bounce
    if (rumble(h.b) && rumble(prev.b))
      CHECK(h.b.vol < prev.b.vol, "the rumble at frame %d restarts (volume %d after %d)",
            frame_of(f), h.b.vol, prev.b.vol);
    if (rumble(h.b))
      CHECK(h.b.vol <= 3, "the rumble at frame %d at volume %d", frame_of(f), h.b.vol);
  }
  printf("%zu frames: %d paddle bounces, %d thocks, %d rumbles\n", heard.size(), bounces, thocks,
         rumbles);
  CHECK(thocks >= 2 && rumbles >= 1, "%d thocks and %d rumbles", thocks, rumbles);
  // One thock per bounce (one in the last 3 frames isn't counted as a thock)
  CHECK(thocks == bounces || thocks == bounces - 1, "%d thocks for %d paddle bounces", thocks,
        bounces);
}

// Waits for the launch, then returns whether the ball rises at 1x for `frames` frames:
// moves of 2 px, 4 px in every 4 frames.
bool rises_at_1x(Follow &f, int frames) {
  for (int i = 0; i < 2000 && resting(f.v); i++) f.step();  // wait for the launch
  int prev_y = f.v.ball_y, dys[64] = {};
  for (int i = 0; i < frames && i < 64; i++) {
    f.step();
    dys[i] = prev_y - f.v.ball_y;
    prev_y = f.v.ball_y;
    if ((dys[i] != 0 && dys[i] != 2) ||
        (i >= 3 && dys[i] + dys[i - 1] + dys[i - 2] + dys[i - 3] != 4)) {
      printf("  launch frame %d: moved %d px up\n", i, dys[i]);
      return false;
    }
  }
  return true;
}

// The opening of a game that autoplay plays from a new game: the start of the long game
// (below), up to where every check has seen what it needs, all as the game is played:
// - bounces: each brick hit alone turns the ball by the edge it came in by; at least 1 side
//   and 5 top/bottom bounces seen (side bounces are rare this early: about 3 in 4000 frames)
// - speeds: the ball moves at 1x, then 1.5x after 4 bricks
// - zones: each of the paddle's four zones sets the bounce it should; each zone seen
// - sound: each brick's note (at least 4 at 1x), the thock over the thump at each paddle
//   bounce and the rumble at the walls
// It stops once all of them have (about frame 2400), or at frame 4000.
void opening() {
  Game g;
  power_up(g);
  g.autoplay = true;
  part = "opening";
  Follow f{g};
  f.v = start_game(g);
  constexpr int SIDE = 1, FLAT = 5, CAP = 4000;
  auto enough = [&] {
    return f.zones.all_seen() && f.speeds.checked[1] > 0 && f.notes.checked[0] >= 4 &&
           f.bounces.checked[0] >= SIDE && f.bounces.checked[1] >= FLAT;
  };
  while (frame_no < CAP && !enough()) f.step();
  printf("frame %5d: bounces %d side, %d top/bottom; zones %d %d %d %d; 1x/1.5x windows %d/%d; "
         "%d brick notes\n", frame_no, f.bounces.checked[0], f.bounces.checked[1],
         f.zones.checked[0], f.zones.checked[1], f.zones.checked[2], f.zones.checked[3],
         f.speeds.checked[0], f.speeds.checked[1], f.notes.checked[0]);
  CHECK(f.bounces.checked[0] >= SIDE && f.bounces.checked[1] >= FLAT,
        "bounces checked: %d side, %d top/bottom (wanted %d and %d)", f.bounces.checked[0],
        f.bounces.checked[1], SIDE, FLAT);
  CHECK(f.zones.all_seen(), "bounces by zone: %d %d %d %d", f.zones.checked[0],
        f.zones.checked[1], f.zones.checked[2], f.zones.checked[3]);
  CHECK(f.speeds.checked[0] > 0 && f.speeds.checked[1] > 0, "windows checked at 1x/1.5x: %d/%d",
        f.speeds.checked[0], f.speeds.checked[1]);
  CHECK(f.notes.checked[0] >= 4, "only %d bricks' notes checked", f.notes.checked[0]);
  check_paddle_and_wall_sounds(f.notes.heard, f.paddle_bounces);
}

// The pause after a cleared wall, from its first frame with no bricks: the empty wall stays for
// about a second, with rainbow bands over the field and the border, and the fanfare (C, E, G,
// then a held high C, over its bass), which has ended by the time the next wall comes in.
// Autoplay leaves the paddle where it is while the ball waits on it: to see that wherever the
// paddle is (autoplay often has it at a wall by now), it is steered away from the nearer wall by
// hand for the first frames of the pause, which it does at 1x (the speed counter is the pause's
// timer there), then handed back to autoplay. Returns the first frame of the next wall.
View pause_after_clear(Follow &f) {
  Game &g = f.g;
  // The rainbow: the field and the border show the same band colour on a line
  auto rainbow = [&] {
    int field = colour(g.fb[300 * 640 + 300]), border = colour(g.fb[300 * 640 + 20]);
    for (int k : {0x30, 0x38, 0x3c, 0x0c, 0x0b, 0x23, 0x33, 0x31})  // red .. violet, magenta, rose
      if (field == k && border == k) return true;
    return false;
  };
  int pause = 0, celebrated = 0, held_x = -1;
  std::vector<int> fanfare;  // voice A's notes in the pause, in order
  int unaccompanied = 0;     // frames of the fanfare without its bass
  // Steered away from the nearer wall for the first frames: at 1x, a 4-px step every other frame
  uint8_t away = f.v.paddle_x + f.v.paddle_w / 2 < 320 ? RIGHT : LEFT;
  int too_fast = 0, steered = 0;
  bool moved = false;
  View v = f.v;
  for (; pause < 100 && v.bricks == 0; pause++) {
    g.autoplay = pause >= 8;
    g.buttons = pause < 8 ? away : 0;
    if (pause == 10) held_x = v.paddle_x;
    // Only while the rainbow shows: the frame the next wall fills in has no bricks either, but
    // play has resumed (autoplay launches the ball and steers)
    if (pause > 10 && rainbow())
      CHECK(v.paddle_x == held_x, "pause frame %d: with autoplay, the paddle moved from %d to %d",
            pause, held_x, v.paddle_x);
    int x = v.paddle_x;
    v = f.step();
    if (pause >= 1 && pause < 8) {  // steered by hand: at 1x, never in two frames running
      int dx = std::abs(v.paddle_x - x);
      too_fast += dx > 4 || (dx > 0 && moved);
      moved = dx > 0;
      steered += dx;
    }
    celebrated += rainbow();
    Sound s = listen(g);
    if (s.a.vol && (fanfare.empty() || fanfare.back() != s.a.half)) fanfare.push_back(s.a.half);
    // The first frame can still play the last brick's note (it can vanish from the picture a
    // frame before its sound): from the second on, the fanfare
    unaccompanied += pause >= 1 && s.a.vol && !bass(s);
  }
  printf("frame %5d: empty wall for %d frames, rainbow in %d\n", frame_no, pause, celebrated);
  CHECK(pause >= 60 && pause <= 68, "empty wall for %d frames (expected about 64)", pause);
  CHECK(celebrated >= pause - 8, "rainbow in only %d of the pause's %d frames", celebrated, pause);
  CHECK(!rainbow(), "the rainbow stays after the pause");
  CHECK(fanfare == std::vector<int>({30, 24, 20, 15}), "fanfare of %zu notes, the last %d",
        fanfare.size(), fanfare.empty() ? 0 : fanfare.back());
  CHECK(unaccompanied == 0, "%d frames of the fanfare without its bass", unaccompanied);
  CHECK(too_fast == 0 && steered >= 8, "in the pause the paddle moved %d px by hand, %d times "
        "faster than 1x", steered, too_fast);
  Voice after = hear(g, 1);
  CHECK(after.vol == 0, "the new wall comes in with a note of %d lines at volume %d", after.half,
        after.vol);
  return v;
}

// Plays until the wall is cleared, at most `frames` frames; returns whether it was
void clear_the_wall(Follow &f, int frames) {
  for (int end = frame_no + frames; frame_no < end && f.v.bricks > 0;) f.step();
  CHECK(f.v.bricks == 0, "wall not cleared (%d bricks left)", f.v.bricks);
}

// Holds `buttons` (and FIRE whenever the ball rests on the paddle, if `fire`) until a ball is
// lost, at most `frames` frames
void lose_a_ball(Follow &f, uint8_t buttons, bool fire, int frames) {
  int lives = f.v.lives;
  for (int i = 0; i < frames && f.v.lives == lives; i++) {
    f.g.buttons = buttons | (fire && resting(f.v) ? FIRE : 0);
    f.step();
  }
  f.g.buttons = 0;
  CHECK(f.v.lives == lives - 1, "no ball lost in %d frames (%d spare balls)", frames, f.v.lives);
}

// A long game, from a new game to the third wall and back to a new game:
// - level 1: autoplay plays the opening (above) on, and clears the wall without losing a ball;
//   the score (10 per brick) is right at every brick, the ball takes all five speed steps, and
//   each zone of the paddle is seen, 16 bounces in all. Bounces, speeds, zones and brick notes
//   (two steps higher once the ball is fast) are checked on every frame to the end of the game.
// - the pause after the wall (see pause_after_clear)
// - level 2: one of the pattern walls, with an 80-px paddle; no third spare ball, as autoplay
//   lost none; the ball starts at 1x after the 3x it had. A ball lost with the paddle held at
//   the left wall: the next one starts at 1x again, and the paddle stops at both walls. Then
//   autoplay clears this wall too.
// - the pause, and level 3: another pattern wall, a spare ball back for the one lost, and a
//   64-px paddle that stops at both walls
// - game over and a new game from it: a full wall, score 0, two spare balls, and the paddle 96 px
//   again, centred, the ball resting on it
void long_game() {
  Game g;
  power_up(g);
  g.autoplay = true;
  Follow f{g};
  part = "level 1";
  View v = f.v = start_game(g);
  int prev_bricks = 48, lives = 2;
  while (frame_no < 60000 && v.bricks > 0) {
    v = f.step();
    CHECK(v.lives == lives, "autoplay lost a ball: %d spare balls left", v.lives);
    lives = v.lives;
    // The score is drawn above the wall: compare once the count is steady
    if (v.bricks == prev_bricks && v.bricks > 0)
      CHECK(v.score == 10 * (48 - v.bricks), "score %d with %d bricks cleared", v.score,
            48 - v.bricks);
    prev_bricks = v.bricks;
    if (frame_no % 2000 == 0) printf("frame %5d: %2d bricks\n", frame_no, v.bricks);
  }
  printf("frame %5d: level 1 cleared\n", frame_no);
  CHECK(v.bricks == 0, "level not cleared (%d bricks left)", v.bricks);
  CHECK(f.zones.all_seen() && f.zones.total() >= 16, "bounces by zone: %d %d %d %d",
        f.zones.checked[0], f.zones.checked[1], f.zones.checked[2], f.zones.checked[3]);
  const int *sc = f.speeds.checked;
  printf("frames checked at 1x/1.5x/2x/2.5x/3x: %d/%d/%d/%d/%d\n", sc[0], sc[1], sc[2], sc[3],
         sc[4]);
  for (int i = 0; i < 5; i++) CHECK(sc[i] > 0, "speed step %d was never reached", i);

  part = "pause after level 1";
  v = pause_after_clear(f);
  part = "level 2";
  CHECK(v.bricks < 48 && is_pattern_wall(v.standing),
        "the wall (%d bricks, %016llx) is not a pattern wall",
        v.bricks, (unsigned long long)v.standing);
  CHECK(v.lives == 2, "%d spare balls (expected no more than 2)", v.lives);
  CHECK(v.paddle_w == 80, "paddle %d px wide (expected 80)", v.paddle_w);
  CHECK(v.score == 480, "score %d after clearing level 1", v.score);
  CHECK(rises_at_1x(f, 16), "the ball did not start at 1x");
  g.autoplay = false;
  lose_a_ball(f, LEFT, false, 10000);
  CHECK(f.v.paddle_x == 64 && f.v.paddle_w == 80, "left stop at x %d (%d px wide)", f.v.paddle_x,
        f.v.paddle_w);
  for (int i = 0; i < 100 && !resting(f.v); i++) f.step();
  g.buttons = FIRE;
  f.step();
  g.buttons = 0;
  CHECK(rises_at_1x(f, 16), "the ball after a loss did not start at 1x");
  g.buttons = RIGHT;  // from x 64, 2 px a frame takes 216 frames to x 496; the ball is high
  for (int i = 0; i < 240; i++) f.step();
  g.buttons = 0;
  CHECK(f.v.paddle_x == 496 && f.v.paddle_w == 80, "right stop at x %d (%d px wide)",
        f.v.paddle_x, f.v.paddle_w);
  g.autoplay = true;
  clear_the_wall(f, 60000);
  printf("frame %5d: level 2 cleared\n", frame_no);
  int lives_at_clear = f.v.lives;

  part = "pause after level 2";
  v = pause_after_clear(f);
  part = "level 3";
  CHECK(v.bricks < 48 && is_pattern_wall(v.standing),
        "the wall (%d bricks, %016llx) is not a pattern wall",
        v.bricks, (unsigned long long)v.standing);
  CHECK(v.lives == lives_at_clear + 1, "%d spare balls after the level (expected one back)",
        v.lives);
  CHECK(v.paddle_w == 64, "paddle %d px wide (expected 64)", v.paddle_w);
  CHECK(rises_at_1x(f, 16), "the ball did not start at 1x");
  g.autoplay = false;
  lose_a_ball(f, LEFT, false, 10000);
  CHECK(f.v.paddle_x == 64 && f.v.paddle_w == 64, "left stop at x %d (%d px wide)", f.v.paddle_x,
        f.v.paddle_w);
  for (int i = 0; i < 100 && !resting(f.v); i++) f.step();
  g.buttons = FIRE;
  f.step();
  g.buttons = RIGHT;  // from x 64, 2 px a frame takes 224 frames to x 512
  for (int i = 0; i < 250; i++) f.step();
  g.buttons = 0;
  CHECK(f.v.paddle_x == 512 && f.v.paddle_w == 64, "right stop at x %d (%d px wide)",
        f.v.paddle_x, f.v.paddle_w);

  // Lose the remaining balls, then restart: the new game's paddle is 96 px again, centred
  part = "game over";
  // Game over is known by its curtain coming down: more than the status line black at the top
  for (int i = 0; i < 20000 && black_from_top(g) <= 24; i++) {
    g.buttons = LEFT | (resting(f.v) ? FIRE : 0);
    f.step();
  }
  CHECK(black_from_top(g) > 24 && f.v.lives == 0, "no game over (%d spare balls)", f.v.lives);
  g.buttons = 0;
  for (int i = 0; i < 40; i++) f.step();  // the curtain
  part = "restart";
  g.buttons = FIRE;
  f.step();
  g.buttons = 0;
  f.step();
  f.step();
  v = settle(g, f.v);
  CHECK(v.paddle_w == 96 && v.paddle_x == 272 && resting(v),
        "paddle %d px at x %d, ball at (%d, %d)", v.paddle_w, v.paddle_x, v.ball_x, v.ball_y);
  // From the third wall, part cleared: the new game's first wall is full, as at power-up (the
  // only way into a new game with a pattern wall's bricks still standing)
  CHECK(v.bricks == 48 && v.score == 0 && v.lives == 2 && border_colour(g) == BLACK,
        "new game: %d bricks, score %d, %d spare balls, border %#x", v.bricks, v.score, v.lives,
        border_colour(g));

  part = "whole game";
  printf("bounces checked: %d side, %d top/bottom; brick notes: %d slow, %d fast; bounces by "
         "zone: %d %d %d %d\n", f.bounces.checked[0], f.bounces.checked[1], f.notes.checked[0],
         f.notes.checked[1], f.zones.checked[0], f.zones.checked[1], f.zones.checked[2],
         f.zones.checked[3]);
  CHECK(f.bounces.checked[0] > 0 && f.bounces.checked[1] > 0, "did not see both kinds of bounce");
  CHECK(f.notes.checked[0] > 0 && f.notes.checked[1] > 0, "brick notes checked: %d slow, %d fast",
        f.notes.checked[0], f.notes.checked[1]);
}

// Two tiers: the cheap one runs all the time, the milestone one (the long game) only at
// milestones. test_scenarios.py reads each scenario's tier from this table.
constexpr bool CHEAP = false, MILESTONE = true;

struct Scenario {
  const char *name;
  void (*run)();
  bool milestone = CHEAP;
};

const Scenario scenarios[] = {
    {"controls", controls},
    {"demo", demo},
    {"losing_every_ball", losing_every_ball},
    {"lost_at_speed", lost_at_speed},
    {"opening", opening},
    {"long_game", long_game, MILESTONE},
};

}  // namespace

int main(int argc, char **argv) {
  setvbuf(stdout, nullptr, _IOLBF, 0);  // line by line, to follow a long scenario in a log
  if (argc != 2) {
    fprintf(stderr, "usage: %s <scenario> | list\n", argv[0]);
    return 2;
  }
  for (const Scenario &s : scenarios) {
    if (!strcmp(argv[1], "list")) {
      printf("%s\n", s.name);
    } else if (!strcmp(argv[1], s.name)) {
      part = s.name;
      s.run();
      printf("%s: %s\n", s.name, failures ? "FAIL" : "PASS");
      return failures ? 1 : 0;
    }
  }
  if (!strcmp(argv[1], "list")) return 0;
  fprintf(stderr, "unknown scenario %s\n", argv[1]);
  return 2;
}
