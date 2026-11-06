/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * The score: a 3-digit decimal counter, and whether the beam is on one of its digits.
 *
 * It is shown with a fixed 0 after it, as arcade games often do: a point reads as 10, and
 * the display runs 0000 .. 9990. The digits are seven-segment style, 8 x 14 px with 2-px
 * strokes, in 16 x 16-px cells at x 512..575, y 0..15 (the digit at y 2..15). Counting in
 * decimal (BCD) costs a little more than binary, but the digits can then be drawn
 * directly, without dividing by 10. After 999 the count starts again from 000.
 */

`default_nettype none

module score (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       clear,     // back to 000 (new game)
    input  logic       add,       // one point (one clock per point)
    input  logic [9:0] h_pos,     // beam position
    input  logic [9:0] v_pos,
    output logic       score_px   // a lit segment of a digit is under the beam
);

  localparam logic [5:0] FIRST_SLOT = 32;  // x 512: 16-px slots, hundreds first

  logic [2:0][3:0] digits;  // BCD: [2] hundreds, [1] tens, [0] ones

  always_ff @(posedge clk) begin
    if (!rst_n || clear) begin
      digits <= '0;
    end else if (add) begin
      // Ripple carry: a digit at 9 goes back to 0 and carries into the next one
      digits[0] <= (digits[0] == 9) ? 0 : digits[0] + 1;
      if (digits[0] == 9) begin
        digits[1] <= (digits[1] == 9) ? 0 : digits[1] + 1;
        if (digits[1] == 9) digits[2] <= (digits[2] == 9) ? 0 : digits[2] + 1;
      end
    end
  end

  // The digit under the beam: slots FIRST_SLOT .. FIRST_SLOT + 3 on the top 16 lines,
  // the last one the fixed 0
  wire [5:0] slot    = h_pos[9:4] - FIRST_SLOT;
  wire       in_slot = (v_pos[9:4] == 0) && (slot[5:2] == 0);
  logic [3:0] digit;
  always_comb begin
    case (slot[1:0])
      0:       digit = digits[2];
      1:       digit = digits[1];
      2:       digit = digits[0];
      default: digit = 0;
    endcase
  end

  // Segments lit for each digit: {a, b, c, d, e, f, g}, as on a seven-segment display
  // (a top, b top right, c bottom right, d bottom, e bottom left, f top left, g middle)
  logic [6:0] lit;
  always_comb begin
    case (digit)
      0:       lit = 7'b1111110;
      1:       lit = 7'b0110000;
      2:       lit = 7'b1101101;
      3:       lit = 7'b1111001;
      4:       lit = 7'b0110011;
      5:       lit = 7'b1011011;
      6:       lit = 7'b1011111;
      7:       lit = 7'b1110000;
      8:       lit = 7'b1111111;
      default: lit = 7'b1111011;  // 9
    endcase
  end

  // Where each segment is within the cell (x, y 0..15): the digit spans x 4..11, y 2..15
  wire [3:1] x = h_pos[3:1];
  wire [3:0] y = v_pos[3:0];
  wire left_col   = (x[3:1] == 3'b010);  // x 4..5
  wire right_col  = (x[3:1] == 3'b101);  // x 10..11
  wire across     = (x[3:2] == 2'b01) || (x[3:2] == 2'b10);  // x 4..11
  wire top_row    = (y[3:1] == 3'b001);  // y 2..3
  wire mid_row    = (y[3:1] == 3'b100);  // y 8..9
  wire bottom_row = (y[3:1] == 3'b111);  // y 14..15
  wire upper      = (y >= 2) && (y <= 9);  // y 2..9
  wire lower      = y[3];                  // y 8..15

  wire [6:0] at = {
    across && top_row,     // a
    right_col && upper,    // b
    right_col && lower,    // c
    across && bottom_row,  // d
    left_col && lower,     // e
    left_col && upper,     // f
    across && mid_row      // g
  };

  assign score_px = in_slot && |(lit & at);

  wire _unused = &{h_pos[0], 1'b0};  // strokes are 2 px wide: bit 0 is never needed

endmodule
