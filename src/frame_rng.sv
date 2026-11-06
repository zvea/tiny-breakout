/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Pseudo-random bits for the game, new every frame.
 *
 * A 5-bit maximal-length LFSR (x^5 + x^3 + 1) advanced once per frame: it cycles through
 * all 31 non-zero values. All zeros would lock it up, so it never starts there. Its bits
 * are close to evenly distributed, which is all the game needs.
 */

`default_nettype none

module frame_rng (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       frame_tick,  // advance once per frame
    output logic [4:0] lfsr
);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      lfsr <= 1;  // any non-zero seed
    end else if (frame_tick) begin
      lfsr <= {lfsr[3:0], lfsr[4] ^ lfsr[2]};
    end
  end

endmodule
