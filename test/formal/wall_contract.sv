/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Formal proof that the chip gives src/brick_wall.sv what test/formal/wall_equiv.sv assumes it
 * does: the assumptions there, asserted here on the whole chip, for any inputs on its pins.
 * Run by test/formal/prove.sh.
 */

// sources: chip

`default_nettype none

module wall_contract (
    input logic       clk,
    input logic       rst_n,
    input logic       ena,
    input logic [7:0] ui_in,
    input logic [7:0] uio_in
);

  tt_um_tiny_breakout chip (
      .clk    (clk),
      .rst_n  (rst_n),
      .ena    (ena),
      .ui_in  (ui_in),
      .uio_in (uio_in),
      .uo_out (),
      .uio_out(),
      .uio_oe ()
  );

  // The wall's ports inside the chip
  (* connect = "chip.refill_bricks" *) logic       refill;
  (* connect = "chip.frame_tick" *)    logic       frame_tick;
  (* connect = "chip.bricks_empty" *)  logic       empty;
  (* connect = "chip.level" *)         logic [1:0] level;
  (* connect = "chip.random" *)        logic [4:0] random;
  wire        full_wall = level == 0;

  logic       reset_seen = 0;
  logic       wall_after_reset;
  logic       last_frame_tick, last_rst_n, last_refill, last_empty;
  logic [7:0] last_inputs;
  wire  [7:0] inputs = {full_wall, level, random};

  always_ff @(posedge clk) begin
    if (!rst_n) reset_seen <= 1;
    if (!rst_n) wall_after_reset <= 1;
    else if (refill) wall_after_reset <= 0;
    last_frame_tick <= frame_tick;
    last_rst_n      <= rst_n;
    last_refill     <= refill;
    last_empty      <= empty;
    last_inputs     <= inputs;
  end

  always_comb begin
    if (reset_seen && rst_n) begin
      // A new wall is asked for only at the frame update
      assert (!refill || frame_tick);
      // The inputs change only just after the frame update (or a reset)
      assert (!last_rst_n || last_frame_tick || inputs == last_inputs);
      // The wall built after a reset is full
      assert (!wall_after_reset || full_wall);
      // A patterned wall is asked for only when the wall is empty: a full one at any time
      assert (!last_refill || full_wall || last_empty);
    end
  end

endmodule
