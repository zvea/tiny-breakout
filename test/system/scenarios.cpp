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
constexpr uint16_t GP_SELECT = 1 << 9, GP_LEFT = 1 << 5, GP_RIGHT = 1 << 4;

// ---- Reading the picture -----------------------------------------------------------------

// Colour of one pixel as 6 bits {r, g, b}, decoded from the TinyVGA PMOD byte
// {hsync, B0, G0, R0, vsync, B1, G1, R1}.
int colour(uint8_t o) {
  int r = ((o >> 0) & 1) << 1 | ((o >> 4) & 1);
  int g = ((o >> 1) & 1) << 1 | ((o >> 5) & 1);
  int b = ((o >> 2) & 1) << 1 | ((o >> 6) & 1);
  return r << 4 | g << 2 | b;
}

constexpr int BLACK = 0x00, WHITE = 0x3f, PADDLE = 0x2f;

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
  // Paddle: first paddle-coloured pixel on its row
  for (int x = 0; x < 640 && v.paddle_x < 0; x++)
    if (at(x, 450) == PADDLE) v.paddle_x = x;
  while (v.paddle_x >= 0 && v.paddle_x + v.paddle_w < 640 &&
         at(v.paddle_x + v.paddle_w, 450) == PADDLE)
    v.paddle_w++;
  // Score: 4 seven-segment digits in 16-px slots from x 512, read from the middle of each
  // segment (a..g)
  static const int seg_x[7] = {7, 10, 10, 7, 4, 4, 7}, seg_y[7] = {5, 8, 15, 17, 15, 8, 11};
  static const int digit_segments[10] = {0x7e, 0x30, 0x6d, 0x79, 0x33, 0x5b, 0x5f, 0x70, 0x7f, 0x7b};
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

// With no controller connected the game plays itself (demo). The emulated controller is
// recognised from its second report, which ends the demo and starts a new game; returns
// the view once that game's wall is in.
View start_game(Game &g) { return run(g, 4); }

// A new ball goes onto the paddle at the next move, and at 1x every other frame has none:
// runs up to 2 more frames for it to come to rest.
View settle(Game &g, View v) {
  for (int i = 0; i < 2 && !resting(v); i++) v = run(g, 1);
  return v;
}

// ---- Scenarios ---------------------------------------------------------------------------

// A new game shows the full wall, two spare balls and the ball resting on the paddle; it
// stays there until FIRE launches it upwards.
void launch() {
  Game g;
  g.reset();
  View v = start_game(g);
  CHECK(v.bricks == 48, "bricks %d", v.bricks);
  CHECK(v.lives == 2, "life markers %d", v.lives);
  CHECK(resting(v), "ball at (%d, %d), paddle at %d", v.ball_x, v.ball_y, v.paddle_x);
  v = run(g, 60);
  CHECK(resting(v), "ball left the paddle without FIRE: (%d, %d)", v.ball_x, v.ball_y);
  g.buttons = FIRE;
  run(g, 1);
  g.buttons = 0;
  v = run(g, 20);
  CHECK(v.ball && v.ball_y < 440 - 10, "ball not launched upwards: y %d", v.ball_y);
}

// The paddle moves 4 px every other frame (at the base speed) while LEFT or RIGHT is held,
// from either the direct pins or the gamepad; both together cancel out. The resting ball
// moves with it.
void steering() {
  for (int source = 0; source < 2; source++) {
    const char *name = source ? "gamepad" : "direct pins";
    auto press = [&](Game &g, bool l, bool r) {
      if (source) g.pad_bits = (l ? GP_LEFT : 0) | (r ? GP_RIGHT : 0);
      else g.buttons = (l ? LEFT : 0) | (r ? RIGHT : 0);
    };
    Game g;
    g.reset();
    start_game(g);
    int x0 = run(g, 2).paddle_x;
    press(g, false, true);
    View v;
    for (int i = 0; i < 10; i++) {  // the resting ball stays centred on the moving paddle
      v = run(g, 1);
      CHECK(resting(v), "%s: moving right, frame %d: ball at x %d, paddle %d", name, i, v.ball_x,
            v.paddle_x);
    }
    int x1 = v.paddle_x;
    CHECK(x1 >= x0 + 16 && x1 <= x0 + 24, "%s: right moved the paddle %d -> %d", name, x0, x1);
    press(g, true, false);
    int x2 = run(g, 10).paddle_x;
    CHECK(x2 <= x1 - 16 && x2 >= x1 - 24, "%s: left moved the paddle %d -> %d", name, x1, x2);
    press(g, true, true);
    int x3 = run(g, 2).paddle_x;
    int x4 = run(g, 10).paddle_x;
    CHECK(x4 == x3, "%s: left + right moved the paddle %d -> %d", name, x3, x4);
    press(g, false, false);
    CHECK(resting(run(g, 2)), "%s: the resting ball did not follow the paddle", name);
  }
}

// A new game's paddle is 96 px wide and stops at the walls: its left end at x 64, its
// right end at x 575 (left end at x 480).
void paddle_limits() {
  Game g;
  g.reset();
  View v = start_game(g);
  CHECK(v.paddle_w == 96, "the first level's paddle is %d px wide", v.paddle_w);
  g.buttons = LEFT;
  v = run(g, 200);
  CHECK(v.paddle_x == 64, "left limit %d", v.paddle_x);
  g.buttons = RIGHT;
  v = run(g, 300);
  CHECK(v.paddle_x == 480 && v.paddle_w == 96, "right limit %d (%d px wide)", v.paddle_x,
        v.paddle_w);
}

// Letting the ball fall uses up the spare balls one by one, then the game is over: no
// ball and no markers. FIRE starts a new game with a full wall and two spare balls.
// The black border (the status line and the strips beside the walls) as one colour, from
// three spots; -1 if they differ.
int border_colour(const Game &g) {
  auto at = [&](int x, int y) { return colour(g.fb[y * 640 + x]); };
  int top = at(300, 8), left = at(20, 300), right = at(620, 470);
  return top == left && left == right ? top : -1;
}

// A ball that has fallen below the paddle (top at y >= 456) is lost: the border turns red,
// brighter in each 8-px band it falls through (maroon, dark red, red), and black again once
// the ball has left the screen. Black at every other time, game over included.
void falling_ball_lights_the_border() {
  Game g;
  g.reset();
  View v = start_game(g);
  int frame = 0, lit = 0, missing = 0;
  bool shades[4] = {};
  for (; frame < 20000; frame++) {
    g.buttons = LEFT | (resting(v) ? FIRE : 0);  // paddle against the left wall
    v = run(g, 1);
    // Red channel = the ball's 8-px band below the paddle; black while it is higher, and once
    // it has left the screen (then it is not visible)
    int expected = v.ball && v.ball_y >= 456 ? ((v.ball_y >> 3) & 3) << 4 : BLACK;
    CHECK(border_colour(g) == expected, "frame %d: ball at y %d, border %#x, expected %#x", frame,
          v.ball ? v.ball_y : -1, border_colour(g), expected);
    if (expected != BLACK) {
      lit++;
      shades[expected >> 4] = true;
    }
    missing = v.ball ? 0 : missing + 1;
    if (missing == 3) {  // game over: in play the ball is never hidden for more than a frame
      run(g, 30);
      CHECK(border_colour(g) == BLACK, "after game over: border %#x", border_colour(g));
      break;
    }
  }
  CHECK(missing == 3, "no game over within %d frames", frame);
  CHECK(lit > 0 && shades[1] && shades[2] && shades[3],
        "the border never showed all three shades (%d lit frames)", lit);
  printf("frame %5d: game over; border lit for %d frames as the balls fell\n", frame, lit);
}

// Lines from the top that are black at x 300, a column the status line, top wall, bricks,
// field and paddle all cross (none of them black) and the score does not.
int black_from_top(const Game &g) {
  int y = 0;
  while (y < 480 && colour(g.fb[y * 640 + 300]) == BLACK) y++;
  return y;
}

// Game over brings a black curtain down from the top, 16 px a frame, until only the score is
// left; the next game brings the picture back.
void game_over_curtain() {
  Game g;
  g.reset();
  View v = start_game(g);
  int frame = 0, score = -1, missing = 0;
  // Until the curtain shows (more than the 24-line status line is black), or the ball has
  // been gone for 10 frames: game over, with no curtain
  for (; frame < 20000 && black_from_top(g) <= 24 && missing < 10; frame++) {
    score = v.score;
    g.buttons = LEFT | (resting(v) ? FIRE : 0);  // paddle against the left wall
    v = run(g, 1);
    missing = v.ball ? 0 : missing + 1;
  }
  CHECK(black_from_top(g) > 24, "no curtain by frame %d (ball gone for %d frames)", frame, missing);
  if (black_from_top(g) <= 24) return;
  printf("frame %5d: the curtain starts, score %d\n", frame, score);
  // The first frame that shows it has it 32 lines down (game over, then 16, then 32: the first
  // 16 are the black status line anyway), then 16 more each frame until it reaches the bottom
  g.buttons = 0;
  for (int line = 32; line <= 480 + 32; line += 16) {
    int expected = line < 480 ? line : 480;
    CHECK(black_from_top(g) == expected, "curtain at %d lines, expected %d", black_from_top(g),
          expected);
    v = run(g, 1);
  }
  int others = 0;
  for (int y = 0; y < 480; y++)
    for (int x = 0; x < 640; x++)
      if (!(x >= 512 && x < 576 && y >= 3 && y < 19) && colour(g.fb[y * 640 + x]) != BLACK)
        others++;  // the score's cells: x 512..575, y 3..18
  CHECK(others == 0, "after the curtain: %d pixels besides the score are not black", others);
  CHECK(v.score == score, "after the curtain: score %d, was %d", v.score, score);
  // A new game brings the picture back
  g.buttons = FIRE;
  run(g, 1);
  g.buttons = 0;
  v = settle(g, run(g, 2));
  CHECK(black_from_top(g) == 24, "after restart: %d black lines from the top", black_from_top(g));
  CHECK(v.bricks == 48 && v.lives == 2 && v.score == 0 && resting(v),
        "after restart: %d bricks, %d markers, score %d, ball at (%d, %d)", v.bricks, v.lives,
        v.score, v.ball_x, v.ball_y);
}

void game_over_and_restart() {
  Game g;
  g.reset();
  int expected_lives = 2, frame = 0, missing = 0, since_launch = 1000, prev_y = -1, prev_dy = 0;
  View v = start_game(g);
  for (; frame < 20000; frame++) {
    // Keep the paddle against the left wall, and launch whenever the ball is resting.
    bool launch = resting(v);
    g.buttons = LEFT | (launch ? FIRE : 0);
    since_launch = launch ? 0 : since_launch + 1;
    v = run(g, 1);
    // Every new ball starts at the base speed, a 2-px move every other frame, however fast
    // the last one was.
    int dy = std::abs(v.ball_y - prev_y);
    if (since_launch >= 3 && since_launch < 12)
      CHECK(v.ball && (dy == 0 || dy == 2) && dy + prev_dy == 2,
            "frame %d: new ball moved %d then %d px", frame, prev_dy, dy);
    prev_y = v.ball_y;
    prev_dy = dy;
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
  CHECK(v.score == 10 * (48 - v.bricks), "game over: score %d with %d bricks cleared", v.score,
        48 - v.bricks);
  printf("frame %5d: game over with %d bricks standing, score %d\n", frame, v.bricks, v.score);

  g.buttons = 0;
  v = run(g, 30);
  CHECK(!v.ball, "ball reappeared without FIRE");
  g.buttons = FIRE;
  run(g, 1);
  g.buttons = 0;
  // From the first frame of the new game nothing of the old one shows: the border is black
  // (it once flashed the level-clear rainbow, as the curtain's count carried over)
  for (int i = 0; i < 3; i++) {
    v = run(g, 1);
    CHECK(border_colour(g) == BLACK, "frame %d after restart: border %#x", i,
          border_colour(g));
  }
  v = settle(g, v);
  CHECK(v.lives == 2, "after restart: life markers %d", v.lives);
  CHECK(v.score == 0, "after restart: score %d", v.score);
  CHECK(v.bricks == 48, "after restart: bricks %d", v.bricks);
  CHECK(resting(v), "after restart: ball at (%d, %d)", v.ball_x, v.ball_y);
}

// Autoplay keeps the ball in play and clears a whole level (the wall comes back) without
// settling into a loop that never reaches the last bricks.
void autoplay_clears_a_level() {
  Game g;
  g.reset();
  g.autoplay = true;
  int fewest = 48, frame = 0, lives_lost = 0, lives = 2, prev_bricks = 48;
  bool cleared = false;
  View v = start_game(g);
  for (; frame < 80000 && !cleared; frame++) {
    v = run(g, 1, false);
    if (v.lives < lives) lives_lost += lives - v.lives;
    lives = v.lives;
    if (v.bricks < fewest) fewest = v.bricks;
    cleared = fewest == 0 && v.bricks > 0;  // the next wall has come in
    // The score (10 per brick) is drawn above the wall: compare once the count is steady
    if (v.bricks == prev_bricks && v.bricks > 0 && fewest > 0)
      CHECK(v.score == 10 * (48 - v.bricks), "frame %d: score %d with %d bricks cleared", frame,
            v.score, 48 - v.bricks);
    prev_bricks = v.bricks;
    if (frame % 2000 == 0) printf("frame %5d: %2d bricks, %d lost\n", frame, v.bricks, lives_lost);
  }
  printf("frame %5d: %s, %d spare balls lost\n", frame, cleared ? "level cleared" : "stuck",
         lives_lost);
  CHECK(cleared, "level not cleared in %d frames (fewest bricks %d)", frame, fewest);
  CHECK(v.score == 480, "score %d after clearing the level", v.score);
}

// The ball speeds up a half step every 4 bricks it clears: vertically it moves 4 px per 4
// frames at first (1x), then 6 (1.5x), 8 (2x), 10 (2.5x), and 12 px (3x) once it has
// cleared 16.
void ball_speeds_up() {
  Game g;
  g.reset();
  g.autoplay = true;
  View v = start_game(g);
  int prev_y = v.ball_y, prev_bricks = v.bricks, frame = 0, checked[5] = {};
  int run_step = -1, run_len = 0, window[4] = {};  // vertical moves of the last 4 frames
  for (; frame < 20000 && v.lives == 2 && v.bricks > 28; frame++) {
    v = run(g, 1);
    int dy = std::abs(v.ball_y - prev_y), cleared = 48 - v.bricks;
    bool steady = v.bricks == prev_bricks;  // the picture's count lags a brick cleared mid-frame
    prev_y = v.ball_y;
    prev_bricks = v.bricks;
    if (!v.ball || !steady || resting(v)) {
      run_len = 0;  // no window across a gap
      continue;
    }
    int step = cleared / 4 < 4 ? cleared / 4 : 4;  // 0..4: 1x, 1.5x, 2x, 2.5x, 3x
    if (step != run_step) run_len = 0;
    run_step = step;
    window[run_len++ % 4] = dy;
    if (run_len >= 4) {
      int sum = window[0] + window[1] + window[2] + window[3];
      CHECK(sum == 4 + 2 * step, "frame %d: %d bricks cleared, moved %d px in 4 frames (expected %d)",
            frame, cleared, sum, 4 + 2 * step);
      checked[step]++;
    }
  }
  printf("frame %5d: frames checked at 1x/1.5x/2x/2.5x/3x: %d/%d/%d/%d/%d\n", frame, checked[0],
         checked[1], checked[2], checked[3], checked[4]);
  for (int i = 0; i < 5; i++) CHECK(checked[i] > 0, "speed step %d was never reached", i);
}

// A brick turns the ball back through the edge it came in by: hit on a side, the ball
// reverses horizontally; on the top or bottom, vertically. Of the two edges its direction
// allows, it came in by the one its 8x8 box is less far past (ties: top or bottom).
void brick_bounces() {
  Game g;
  g.reset();
  g.autoplay = true;
  constexpr int N = 15000;
  static View v[N];
  start_game(g);
  for (int t = 0; t < N; t++) v[t] = run(g, 1);
  int checked[2] = {};  // side, top/bottom
  for (int s = 2; s + 2 < N; s++) {
    uint64_t gone = v[s - 1].standing & ~v[s].standing;
    if (gone == 0 || (gone & (gone - 1)) != 0 || v[s].bricks == 48) continue;  // one brick
    int b = __builtin_ctzll(gone), bx = 64 * (b % 8 + 1) + 2, by = 16 * (b / 8 + 4) + 2;
    // The brick (at bx..bx+61, by..by+13) vanished while frame s or s - 1 was drawn: the
    // first of them in which the ball's box overlaps it.
    auto overlaps = [&](const View &w) {
      return w.ball && w.ball_x < bx + 62 && w.ball_x + 8 > bx && w.ball_y < by + 14 &&
             w.ball_y + 8 > by;
    };
    int c = overlaps(v[s - 1]) ? s - 1 : s;
    // Some frames have no move: compare with the nearest frames where the ball moved
    auto moved = [&](int i) { return v[i].ball_x != v[c].ball_x || v[i].ball_y != v[c].ball_y; };
    int pi = c - 1, ni = c + 1;
    while (pi > 0 && !moved(pi)) pi--;
    while (ni + 1 < N && !moved(ni)) ni++;
    const View &p = v[pi], &h = v[c], &n = v[ni];
    if (!p.ball || !h.ball || !n.ball || !overlaps(h) || !moved(pi) || !moved(ni)) continue;
    if (h.ball_x < 80 || h.ball_x > 560 || h.ball_y < 48) continue;  // walls could interfere
    bool left = h.ball_x < p.ball_x, up = h.ball_y < p.ball_y;
    int past_side = left ? bx + 62 - h.ball_x : h.ball_x + 8 - bx;
    int past_flat = up ? by + 14 - h.ball_y : h.ball_y + 8 - by;
    bool side = past_side < past_flat;
    bool turned_x = (n.ball_x < h.ball_x) != left, turned_y = (n.ball_y < h.ball_y) != up;
    CHECK(turned_x == side && turned_y == !side,
          "frame %d: brick %d hit from (%d, %d) moving %s-%s: expected a %s bounce, got x %s, y %s",
          c, b, h.ball_x, h.ball_y, left ? "left" : "right", up ? "up" : "down",
          side ? "side" : "top/bottom", turned_x ? "turned" : "kept", turned_y ? "turned" : "kept");
    checked[side ? 0 : 1]++;
  }
  printf("bounces checked: %d side, %d top/bottom\n", checked[0], checked[1]);
  CHECK(checked[0] > 0 && checked[1] > 0, "did not see both kinds of bounce");
}

// Waits for the launch, then returns whether the ball rises at 1x for `frames` frames:
// moves of 2 px, 4 px in every 4 frames.
bool launch_at_1x(Game &g, View &v, int frames) {
  for (int i = 0; i < 2000 && resting(v); i++) v = run(g, 1);  // wait for the launch
  int prev_y = v.ball_y, dys[64] = {};
  bool ok = true;
  for (int i = 0; i < frames && i < 64; i++) {
    v = run(g, 1);
    dys[i] = prev_y - v.ball_y;
    prev_y = v.ball_y;
    if (dys[i] != 0 && dys[i] != 2) ok = false;
    if (i >= 3 && dys[i] + dys[i - 1] + dys[i - 2] + dys[i - 3] != 4) ok = false;
    if (!ok) {
      printf("  launch frame %d: moved %d px up\n", i, dys[i]);
      return false;
    }
  }
  return ok;
}

// The walls after the first are grown from a seed row chosen by the LFSR (brick_wall.sv): the
// bottom row is the seed, 4 bits mirrored into 8 columns, and each row from the top down is
// grown from the one before it by rule 150, or rule 182 when bit 4 is set. As `standing`.
uint64_t pattern_wall(int value) {
  int rule_182 = value >> 4 & 1;
  int half = (value & 0b1110) | (value & 1) | rule_182;  // bit c: column c, for c = 0..3
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

// Where the ball lands on the paddle sets its bounce: left from the left half, right from the
// right half, at the flatter angle (2 px across per 2 px up) from the last 16 px at each end,
// else the steeper one (1 px across). The zone is the one under the last ball pixel to touch
// the paddle, the right end of the ball's bottom row (ball x + 5), in the last frame it
// touches. Autoplay aims at all four zones in turn; the first level's paddle is 96 px.
void paddle_zones_set_the_angle() {
  Game g;
  g.reset();
  g.autoplay = true;
  View v = start_game(g), prev, touch, from;
  int checked[4] = {}, tracking = -1;  // tracking: frames since the ball left the paddle
  auto done = [&] {
    return checked[0] && checked[1] && checked[2] && checked[3] &&
           checked[0] + checked[1] + checked[2] + checked[3] >= 16;
  };
  auto on_paddle_row = [](const View &w) {
    return w.ball && w.ball_y + 7 >= 448 && w.ball_y <= 455;
  };
  for (int frame = 0; frame < 12000 && !done(); frame++) {
    prev = v;
    v = run(g, 1);
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
      if (!clean) continue;
      int half = touch.paddle_w / 2, d = touch.ball_x + 5 - (touch.paddle_x + half);
      bool right = d >= 0, outer = d < 16 - half || d >= half - 16;
      int zone = right ? (outer ? 3 : 2) : (outer ? 0 : 1);
      CHECK((dx > 0) == right && std::abs(dx) * (outer ? 1 : 2) == dy,
            "frame %d: zone %d (pixel %+d px from the centre of a %d-px paddle): then %+d px "
            "across for %d up", frame, zone, d, touch.paddle_w, dx, dy);
      checked[zone]++;
    }
  }
  printf("bounces checked by zone: %d %d %d %d\n", checked[0], checked[1], checked[2], checked[3]);
  CHECK(done(), "too few bounces seen in some zone");
}

// Clearing a level: the empty wall stays for about a second, with rainbow bands over the
// field and the border, a spare ball comes back (one is lost first, as there are at most 2),
// the next wall comes in as one of the patterns with a narrower paddle (96 px, then 80), and
// the next level's balls start at 1x, as every ball does, also after a ball is lost.
void level_cleared() {
  Game g;
  g.reset();
  View v = start_game(g);
  CHECK(v.paddle_w == 96, "level 1 paddle is %d px wide", v.paddle_w);
  int frame = 0;
  for (; frame < 5000 && v.lives == 2; frame++) {  // lose a ball: paddle against the left wall
    g.buttons = LEFT | (resting(v) ? FIRE : 0);
    v = run(g, 1);
  }
  CHECK(v.lives == 1, "frame %d: still %d spare balls", frame, v.lives);
  g.buttons = 0;
  g.autoplay = true;
  for (; frame < 60000 && v.bricks > 0; frame++) v = run(g, 1, false);
  CHECK(v.bricks == 0, "frame %d: level not cleared (%d bricks)", frame, v.bricks);
  // The rainbow: the field and the border show the same band colour on a line
  auto rainbow = [&] {
    int field = colour(g.fb[300 * 640 + 300]), border = colour(g.fb[300 * 640 + 20]);
    for (int k : {0x30, 0x38, 0x3c, 0x0c, 0x0b, 0x23, 0x33, 0x31})  // red .. violet, magenta, rose
      if (field == k && border == k) return true;
    return false;
  };
  int pause = 0, celebrated = 0;
  for (; pause < 100 && v.bricks == 0; pause++) {
    v = run(g, 1, false);
    celebrated += rainbow();
  }
  printf("frame %5d: level cleared, empty wall for %d frames, rainbow in %d\n", frame, pause,
         celebrated);
  CHECK(pause >= 60 && pause <= 68, "empty wall for %d frames (expected about 64)", pause);
  CHECK(celebrated >= pause - 8, "rainbow in only %d of the pause's %d frames", celebrated, pause);
  CHECK(!rainbow(), "the rainbow stays after the pause");
  v = run(g, 1);  // past the filling frame
  CHECK(is_pattern_wall(v.standing), "level 2 wall (%d bricks, %016llx) is not a pattern wall",
        v.bricks, (unsigned long long)v.standing);
  CHECK(v.lives == 2, "%d spare balls after the level (expected one back)", v.lives);
  CHECK(v.paddle_w == 80, "level 2 paddle is %d px wide (expected 80)", v.paddle_w);
  CHECK(launch_at_1x(g, v, 16), "level 2 ball did not start at 1x");
  // Lose a ball in level 2: the next one starts at 1x again
  g.autoplay = false;
  for (int i = 0; i < 10000 && v.lives == 2; i++) {
    g.buttons = LEFT;
    v = run(g, 1);
  }
  CHECK(v.lives == 1, "no ball lost in level 2");
  for (int i = 0; i < 100 && !resting(v); i++) v = run(g, 1);
  g.buttons = FIRE;
  v = run(g, 1);
  g.buttons = 0;
  CHECK(launch_at_1x(g, v, 16), "level 2 ball after a loss did not start at 1x");
  // Lose the remaining balls, then restart: the new game's paddle is 96 px again, centred
  int missing = 0;  // game over: no spare balls, and the ball gone for more than a frame
  for (int i = 0; i < 20000 && !(v.lives == 0 && missing == 3); i++) {
    g.buttons = LEFT | (resting(v) ? FIRE : 0);
    v = run(g, 1);
    missing = v.ball ? 0 : missing + 1;
  }
  CHECK(v.lives == 0 && missing == 3, "no game over in level 2 (%d spare balls)", v.lives);
  g.buttons = 0;
  run(g, 40);  // the curtain
  g.buttons = FIRE;
  run(g, 1);
  g.buttons = 0;
  v = settle(g, run(g, 2));
  CHECK(v.paddle_w == 96 && v.paddle_x == 272 && resting(v),
        "after a restart from level 2: paddle %d px at x %d, ball at (%d, %d)", v.paddle_w,
        v.paddle_x, v.ball_x, v.ball_y);
}

// With no controller connected the game plays itself (demo): with no Gamepad PMOD at all,
// or with the PMOD reporting no controller (all ones). The demo ends, starting a new game,
// when a direct button is pressed or a controller is connected; after that nothing moves
// without input.
void demo_until_a_controller_or_button() {
  const char *names[] = {"no PMOD, then a button", "PMOD without controller, then one connected",
                         "PMOD without controller, reports across the frame update, then a button"};
  for (int how = 0; how < 3; how++) {
    const char *name = names[how];
    Game g;
    g.reset();
    if (how) g.pad_bits = 0x0fff;  // the PMOD reports no controller
    else g.pmod_plugged = false;
    // A report with no controller is all ones, so the receiver sees SELECT (bit 14) pressed
    // until LEFT (bit 18) comes in. Here the frame update (clock 480 x 800) falls in between.
    if (how == 2) g.pmod_start = 480 * 800 - 16 * 40;
    View v = run(g, 4);
    int bricks0 = v.bricks;
    v = run(g, 900);
    CHECK(v.bricks < bricks0, "%s: demo cleared no bricks in 900 frames (%d left)", name, v.bricks);
    CHECK(!resting(v), "%s: in the demo the ball is resting on the paddle", name);
    if (how == 1) {
      g.pad_bits = 0;  // a controller is connected, nothing pressed
      v = settle(g, run(g, 3));
    } else {
      g.buttons = LEFT;
      run(g, 1);
      g.buttons = 0;
      v = settle(g, run(g, 3));  // the new game starts at the next frame update, then its wall fills
    }
    CHECK(v.bricks == 48 && v.lives == 2, "%s: then %d bricks, %d spare balls", name, v.bricks,
          v.lives);
    CHECK(resting(v), "%s: then the ball is at (%d, %d), paddle %d", name, v.ball_x, v.ball_y,
          v.paddle_x);
    int x0 = v.paddle_x;
    v = run(g, 60);
    CHECK(resting(v) && v.paddle_x == x0, "%s: without input, ball (%d, %d), paddle %d -> %d",
          name, v.ball_x, v.ball_y, x0, v.paddle_x);
  }
}

// SELECT on the gamepad switches autoplay on: it launches the ball and steers. Left, right
// or fire switches it off, after which the paddle only moves when told to.
void select_turns_autoplay_on() {
  Game g;
  g.reset();
  start_game(g);
  g.pad_bits = GP_SELECT;
  run(g, 3);
  g.pad_bits = 0;
  View v = run(g, 30);
  CHECK(v.ball && v.ball_y < 440, "autoplay did not launch the ball: y %d", v.ball_y);
  g.pad_bits = GP_LEFT;
  run(g, 2);
  g.pad_bits = 0;
  int x0 = run(g, 1).paddle_x;
  v = run(g, 60);
  CHECK(v.paddle_x == x0, "paddle moved with autoplay off: %d -> %d", x0, v.paddle_x);
}

struct Scenario {
  const char *name;
  void (*run)();
};

const Scenario scenarios[] = {
    {"launch", launch},
    {"steering", steering},
    {"paddle_limits", paddle_limits},
    {"falling_ball_lights_the_border", falling_ball_lights_the_border},
    {"game_over_and_restart", game_over_and_restart},
    {"game_over_curtain", game_over_curtain},
    {"demo_until_a_controller_or_button", demo_until_a_controller_or_button},
    {"select_turns_autoplay_on", select_turns_autoplay_on},
    {"ball_speeds_up", ball_speeds_up},
    {"brick_bounces", brick_bounces},
    {"paddle_zones_set_the_angle", paddle_zones_set_the_angle},
    {"level_cleared", level_cleared},
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
