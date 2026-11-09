/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Receiver for the Psychogenic SNES Gamepad PMOD: the first controller's buttons that the
 * game uses, counted in rather than shifted in.
 *
 * The PMOD repeatedly sends a report on pmod_data, one bit per rising edge of pmod_clk,
 * then pulses pmod_latch (see gamepad_pkg for the bit order). A counter, held at 0 by the
 * latch, gives each bit's index, and each button used is caught straight into its own
 * flip-flop at its index. After reset the counter waits at 31 until the first latch, so a
 * report already under way at reset is ignored.
 *
 * A controller that is not connected reports all ones: up and down together (a d-pad
 * can't) is the test. The button outputs are not masked: use them with connected, including
 * select_autoplay, which such a report sets at SELECT and clears again at LEFT.
 *
 * Unplugging the controller from the PMOD is handled (its next report has no controller), but
 * not unplugging the PMOD itself: no reports come then, and the last one stands, connected and
 * with whatever buttons it had, until reset. Hot-plugging the PMOD isn't supported, so there is
 * no report timeout (one would also need the PMOD's periodic report to be guaranteed, or it
 * could hand an idle player's game to the demo).
 */

`default_nettype none

module gamepad_rx (
    input  logic clk,
    input  logic rst_n,
    input  logic pmod_latch,       // PMOD pins, asynchronous to clk
    input  logic pmod_clk,
    input  logic pmod_data,
    output logic connected,        // a controller is connected (as of the last report)
    output logic left,             // pressed in the last report (meaningless if !connected)
    output logic right,
    output logic fire,             // A, X, L or R
    output logic select_autoplay   // SELECT was pressed, and no left, right or fire since
);

  // Inputs pass through 2-flop synchronisers ([1:0]); the clock keeps one more bit of
  // history ([2]) so its rising edges can be detected.
  logic [1:0] data_s, latch_s;
  logic [2:0] clk_s;
  logic [4:0] index;  // index of the next bit; 31: waiting for a latch
  logic       up;     // up, held until down arrives

  wire clk_rise = clk_s[1] & ~clk_s[2];
  wire d        = data_s[1];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      data_s  <= 0;
      latch_s <= 0;
      clk_s   <= 0;
      index   <= 31;
    end else begin
      data_s  <= {data_s[0], pmod_data};
      latch_s <= {latch_s[0], pmod_latch};
      clk_s   <= {clk_s[1:0], pmod_clk};
      if (latch_s[1]) index <= 0;
      else if (clk_rise && index != 31) index <= index + 1;
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      connected       <= 0;
      select_autoplay <= 0;
    end else if (clk_rise) begin
      if (index == gamepad_pkg::BIT_DOWN) connected <= ~(up & d);
      // A report with no controller (all ones) sets this at SELECT and clears it at LEFT
      if (d && index == gamepad_pkg::BIT_SELECT) select_autoplay <= 1;
      else if (d && index >= gamepad_pkg::BIT_LEFT && index <= gamepad_pkg::BIT_R)
        select_autoplay <= 0;
    end
  end

  // No reset needed: the game reads these only together with connected, which reset clears.
  // connected is set at the DOWN bit, though, and the buttons follow 1 to 6 bits later, so for
  // those few microseconds after a controller connects they still hold the report before
  // (all ones when there was no controller): LEFT and RIGHT together cancel, and the new game
  // the connection starts takes priority over FIRE
  always_ff @(posedge clk) begin
    if (clk_rise) begin
      case (index)
        gamepad_pkg::BIT_UP:    up    <= d;
        gamepad_pkg::BIT_LEFT:  left  <= d;
        gamepad_pkg::BIT_RIGHT: right <= d;
        gamepad_pkg::BIT_A:     fire  <= d;
        gamepad_pkg::BIT_X, gamepad_pkg::BIT_L, gamepad_pkg::BIT_R: fire <= fire | d;
        default: ;
      endcase
    end
  end

  // The buttons the game doesn't use, named here so lint doesn't flag their constants
  wire _unused = &{gamepad_pkg::BIT_B, gamepad_pkg::BIT_Y, gamepad_pkg::BIT_START, 1'b0};

endmodule
