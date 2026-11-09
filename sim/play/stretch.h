// SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
// SPDX-License-Identifier: Apache-2.0
//
// Pitch-preserving time stretch for the player's audio. The model gives 800 samples (16.7 ms)
// per simulated frame, but a slow machine simulates fewer than 60 frames a second, and played
// as they come the samples would run out and stutter. Stretching each frame's audio to the
// time the frame really took keeps the sound continuous and in step with the slow-motion
// picture, at its true pitch: a beep lasts longer, but it is the same note.
//
// The method is WSOLA (waveform-similarity overlap-add): the output is built from 21-ms grains
// of the input, overlapped by half under a Hann window, which sum to 1. Each grain is taken
// near where the stretch says, but moved by up to 5 ms to where it best lines up with the
// waveform that followed the previous grain, so the overlaps add in phase. The game's sounds
// are steady tones and noise, which stretch this way with hardly a trace. At a ratio of 1
// (a fast machine) every grain lines up with no move and the output is the input.
#pragma once
#include <cmath>
#include <vector>

class Stretcher {
  static constexpr int W = 1024;     // grain length: 21 ms at 48 kHz
  static constexpr int HS = W / 2;   // output hop: grains overlap by half
  static constexpr int SEEK = 256;   // how far a grain may move to line up: 5 ms

 public:
  Stretcher() : window_(W) {
    for (int i = 0; i < W; i++) window_[i] = 0.5f - 0.5f * std::cos(6.2831853f * i / W);
    reset();
  }

  void reset() {
    in_.clear();
    acc_.assign(W, 0.0f);
    ready_.clear();
    pos_ = 0;
    prev_ = -1;
  }

  // Adds input samples (one frame's).
  void push(const float *x, int n) { in_.insert(in_.end(), x, x + n); }

  // Input samples waiting: from where the next grain should start to the end of the input.
  // A grain needs AHEAD of them.
  static constexpr int AHEAD = W + SEEK;
  int backlog() const { return (int)in_.size() - (int)pos_; }

  // Returns up to `count` output samples, stretching the input by `ratio` (output / input
  // length). Output comes in grains, a hop at a time, and needs input a grain ahead, so it can
  // fall short of `count`; the caller asks for the shortfall again next time (and keeps
  // ratio x what it pushes as its target), and the player's buffer evens it out.
  std::vector<float> pull(double ratio, int count) {
    while ((int)ready_.size() < count && hop(ratio)) {
    }
    int n = std::min(count, (int)ready_.size());
    std::vector<float> out(ready_.begin(), ready_.begin() + n);
    ready_.erase(ready_.begin(), ready_.begin() + n);
    return out;
  }

 private:
  std::vector<float> window_, in_, acc_, ready_;
  double pos_;  // where the next grain should start in in_, before lining up
  int prev_;    // where the last grain started (-1: none yet)

  // Adds one grain: HS more output samples. False if there isn't enough input yet.
  bool hop(double ratio) {
    int ideal = (int)pos_, lo = std::max(0, ideal - SEEK), hi = ideal + SEEK;
    if (hi + W > (int)in_.size()) return false;
    int best = ideal;
    if (prev_ >= 0) {  // line up with what followed the last grain: in_[prev_ + HS ...]
      const float *ref = &in_[prev_ + HS];
      double best_score = -1e30;
      for (int s = lo; s <= hi; s++) {
        double dot = 0, energy = 1e-9;
        for (int i = 0; i < HS; i++) {
          dot += ref[i] * in_[s + i];
          energy += in_[s + i] * in_[s + i];
        }
        double score = dot / std::sqrt(energy);
        if (score > best_score + 1e-9 || (std::abs(score - best_score) <= 1e-9 &&
                                          std::abs(s - ideal) < std::abs(best - ideal))) {
          best_score = score;
          best = s;
        }
      }
    }
    for (int i = 0; i < W; i++) acc_[i] += window_[i] * in_[best + i];
    ready_.insert(ready_.end(), acc_.begin(), acc_.begin() + HS);
    std::copy(acc_.begin() + HS, acc_.end(), acc_.begin());
    std::fill(acc_.begin() + HS, acc_.end(), 0.0f);
    prev_ = best;
    pos_ += HS / ratio;
    // Drop input no grain will use again
    int drop = std::min(prev_, (int)pos_ - SEEK);
    if (drop > 4 * W) {
      in_.erase(in_.begin(), in_.begin() + drop);
      prev_ -= drop;
      pos_ -= drop;
    }
    return true;
  }
};
