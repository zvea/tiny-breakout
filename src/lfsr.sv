/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * The game's source of chance: a 5-bit LFSR (x^5 + x^3 + 1) that steps once per frame,
 * whatever the game is doing, and cycles through all 31 non-zero values. Autoplay picks
 * where to aim from it, and the wall picks the shape of each new wall. Both read it when
 * something in play happens (a paddle hit, a cleared wall), so the value they get depends
 * on the exact frame of that event.
 */

`default_nettype none

module lfsr (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       frame_tick,  // once per frame: the LFSR steps
    output logic [4:0] value        // never 0; steady between frame_ticks
);

  always_ff @(posedge clk) begin
    if (!rst_n) value <= 1;  // any non-zero seed
    else if (frame_tick) value <= {value[3:0], value[4] ^ value[2]};
  end

endmodule
