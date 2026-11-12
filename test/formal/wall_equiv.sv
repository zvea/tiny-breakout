/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Formal proof that src/brick_wall.sv behaves exactly as the reference test/reference/ref_wall.sv:
 * on every clock after a reset, their outputs are equal. Run by test/formal/prove.sh.
 *
 * Both get the same beam (from src/vga_timing.sv) and the same inputs. The inputs are free,
 * within what the game guarantees (the assumptions below). The proof is by induction, so it
 * also asserts what makes the outputs equal: the brick each of the chip's ring flip-flops holds,
 * for every beam position. test/formal/wall_contract.sv proves the assumptions hold in the chip.
 */

// sources: src/vga_timing.sv src/wall_pattern.sv src/brick_wall.sv test/reference/ref_wall.sv

`default_nettype none

module wall_equiv (
    input logic       clk,
    input logic       rst_n,
    input logic       refill,
    input logic       full_wall,
    input logic [1:0] level,
    input logic [4:0] random,
    input logic       clear
);

  localparam int COLUMNS = 8;
  localparam int ROWS    = 6;
  localparam int TAIL    = 40;
  localparam int GROUPS  = 5;

  logic [9:0] x, y;
  logic       frame_tick;

  vga_timing beam (
      .clk         (clk),
      .rst_n       (rst_n),
      .h_pos       (x),
      .v_pos       (y),
      .visible     (),
      .h_sync_n    (),
      .v_sync_n    (),
      .vblank_start(frame_tick)
  );

  logic       chip_brick_px, chip_over_columns, chip_empty;
  logic       ref_brick_px, ref_over_columns, ref_empty;
  logic [2:0] chip_brick_row, ref_brick_row;

  brick_wall chip (
      .clk         (clk),
      .rst_n       (rst_n),
      .h_pos       (x),
      .v_pos       (y),
      .refill      (refill),
      .full_wall   (full_wall),
      .level       (level),
      .random      (random),
      .clear       (clear),
      .brick_px    (chip_brick_px),
      .brick_row   (chip_brick_row),
      .over_columns(chip_over_columns),
      .empty       (chip_empty)
  );

  ref_wall reference (
      .clk         (clk),
      .rst_n       (rst_n),
      .x           (x),
      .y           (y),
      .refill      (refill),
      .full_wall   (full_wall),
      .level       (level),
      .random      (random),
      .clear       (clear),
      .brick_px    (ref_brick_px),
      .brick_row   (ref_brick_row),
      .over_columns(ref_over_columns),
      .empty       (ref_empty)
  );

  // Internal state of both
  (* connect = "chip.head" *)                 logic [7:0]           chip_head;
  (* connect = "chip.tail" *)                 logic [39:0]          chip_tail;
  (* connect = "chip.phase" *)                logic [2:0]           chip_phase;
  (* connect = "chip.filling" *)              logic                 chip_filling;
  (* connect = "chip.seen" *)                 logic                 chip_seen;
  (* connect = "reference.bricks" *)          logic [ROWS-1:0][7:0] ref_bricks;
  (* connect = "reference.pattern" *)         logic [ROWS-1:0][7:0] ref_pattern;
  (* connect = "reference.new_wall_due" *)    logic                 ref_new_wall_due;
  (* connect = "reference.drawn_since_top" *) logic                 ref_drawn_since_top;

  // ---- What the game guarantees ----

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
    last_empty      <= chip_empty;
    last_inputs     <= inputs;
  end

  always_comb begin
    // A new wall is asked for only at the frame update
    assume (!refill || frame_tick);
    // The inputs change only just after the frame update (or a reset)
    assume (!rst_n || !last_rst_n || last_frame_tick || inputs == last_inputs);
    // The wall built after a reset is full
    assume (!rst_n || !wall_after_reset || full_wall);
    // A patterned wall is asked for only when the wall is empty: a full one at any time
    assume (!rst_n || !last_refill || full_wall || last_empty);
  end

  // ---- The brick each ring flip-flop holds ----

  // Small modular arithmetic, kept narrow so the proof stays small
  function automatic logic [2:0] mod6(input logic [3:0] n);  // n < 12
    mod6 = n >= 6 ? 3'(n - 6) : 3'(n);
  endfunction

  function automatic logic [2:0] minus_mod5(input logic [2:0] a, input logic [2:0] b);  // a, b < 5
    minus_mod5 = a >= b ? 3'(a - b) : 3'(a + 5 - b);
  endfunction

  function automatic logic [5:0] mod40(input logic [6:0] n);  // n < 80
    mod40 = n >= 40 ? 6'(n - 40) : 6'(n);
  endfunction

  localparam int LINE              = 800;  // clocks per line
  localparam int FRAME             = 525;  // lines per frame
  localparam int FRAME_UPDATE_LINE = 480;
  localparam int WALL_LEFT         = 64;
  localparam int WALL_TOP          = 64;
  localparam int GAP               = 2;
  localparam int WALL_BOTTOM       = WALL_TOP + 16 * ROWS;
  localparam int FIRST_COLUMN_TURN = 64;
  localparam int LAST_COLUMN_TURN  = 512;
  localparam int FIRST_STEP        = 64;   // a row turn's steps start here, 8 clocks per phase
  localparam int FIRST_GROUP_SLOT  = FIRST_STEP % TAIL;

  wire       in_rows      = y >= WALL_TOP && y < WALL_BOTTOM;
  wire [2:0] row_of_line  = 3'((y - 10'(WALL_TOP)) >> 4);
  wire       row_line     = in_rows && y[3:0] == 0;
  wire [9:0] steps_start  = 10'(FIRST_STEP + 8 * chip_phase);
  wire       before_steps = row_line && x < steps_start;
  wire       in_steps     = row_line && x >= steps_start && x < steps_start + 8;
  wire [2:0] steps_done   = 3'(x - steps_start);

  // Row turns finished so far in this frame (6 in all), and the row the head holds
  wire [2:0] turns_done = y < WALL_TOP ? 3'd0 :
                          !in_rows ? 3'd6 :
                          (before_steps || in_steps) ? row_of_line : 3'(row_of_line + 1);
  wire [2:0] head_row   = turns_done == 0 ? 3'd5 : 3'(turns_done - 1);

  // The tail group holding the row after the head's: the next row turn's phase
  wire       phase_due  = row_line && !before_steps && !in_steps && x <= LAST_COLUMN_TURN;
  wire [2:0] next_group = phase_due ? (chip_phase == 4 ? 3'd0 : 3'(chip_phase + 1)) : chip_phase;

  // Column turns finished on this line (none on a row line)
  wire [3:0] column_turns = row_line || x <= FIRST_COLUMN_TURN ? 4'd0 :
                            x > LAST_COLUMN_TURN ? 4'd8 : 4'((x - 10'd1) >> 6);

  wire [5:0] x_mod_tail = 6'(x % TAIL);

  // A wall being built loads its rows in the order 5, 0, 1, 2, 3, 4, one at each row turn
  wire       in_loading_frame = in_rows || y == WALL_BOTTOM;
  logic [ROWS-1:0] row_loaded;
  always_comb begin
    for (int r = 0; r < ROWS; r++)
      row_loaded[r] = in_loading_frame && turns_done > (r == ROWS - 1 ? 3'd0 : 3'(r + 1));
  end

  // The head: head[i] holds column i - 1 + (the column turns so far), all of the head row;
  // during a row turn's steps, the new row comes in at the top as the old one leaves at 0.
  //
  // The tail turns by one bit every clock, so name its places by slot instead: tail bit t
  // holds slot (t + x) mod 40, the same slot at the same x on every line. The slots form 5
  // groups of 8, one row each, starting at FIRST_GROUP_SLOT; place p of a group holds column
  // p - 1. A row turn at phase g swaps the head with group g, a bit a clock, so the group that
  // holds the row after the head's is the next turn's phase.
  logic [47:0][2:0] ring_row;
  logic [47:0][2:0] ring_column;
  always_comb begin
    for (int i = 0; i < COLUMNS; i++) begin
      ring_row[i]    = in_steps && i >= 8 - steps_done ? row_of_line : head_row;
      ring_column[i] = 3'(i - 1 + (in_steps ? 4'(steps_done) : column_turns));
    end
    for (int t = 0; t < TAIL; t++) begin
      logic [5:0] slot, group_slot;
      logic [2:0] group, place;
      slot       = mod40(7'(t) + 7'(x_mod_tail));
      group_slot = mod40(7'(slot) + 7'(TAIL - FIRST_GROUP_SLOT));
      group      = group_slot[5:3];
      place      = group_slot[2:0];
      ring_column[COLUMNS+t] = 3'(place - 1);
      if (in_steps && group == chip_phase && place < steps_done)
        ring_row[COLUMNS+t] = head_row;
      else
        ring_row[COLUMNS+t] = mod6(4'(head_row) + 4'd1 + 4'(minus_mod5(group, next_group)));
    end
  end

  // ---- What each flip-flop must hold: known, and its value ----

  logic [47:0] ring_known, ring_value;
  always_comb begin
    for (int p = 0; p < 48; p++) begin
      if (!ref_new_wall_due) begin
        ring_known[p] = 1;
        ring_value[p] = ref_bricks[ring_row[p]][ring_column[p]];
      end else if (row_loaded[ring_row[p]]) begin
        ring_known[p] = 1;
        ring_value[p] = full_wall || ref_pattern[ring_row[p]][ring_column[p]];
      end else begin
        ring_known[p] = !full_wall;
        ring_value[p] = ref_bricks[ring_row[p]][ring_column[p]];
      end
    end
  end

  wire [47:0] chip_ring = {chip_tail, chip_head};

  // ---- When the wall is empty ----

  // A standing brick is drawn at its first pixel, just inside the gaps: once the beam has
  // passed that pixel with nothing drawn since the top of the wall, the brick is down
  wire wall_is_empty = ref_bricks == 0;
  logic [ROWS-1:0][COLUMNS-1:0] passed;
  always_comb begin
    for (int r = 0; r < ROWS; r++)
      for (int c = 0; c < COLUMNS; c++)
        passed[r][c] = y > WALL_TOP + 16 * r + GAP ||
                       (y == WALL_TOP + 16 * r + GAP && x > WALL_LEFT + 64 * c + GAP);
  end
  wire nothing_drawn = !ref_new_wall_due && !ref_drawn_since_top && y >= WALL_TOP;

  // ---- The proof ----

  always_comb begin
    if (reset_seen && rst_n) begin
      // The outputs are equal
      assert (chip_brick_px == ref_brick_px);
      assert (chip_over_columns == ref_over_columns);
      assert (chip_empty == ref_empty);
      assert (!in_rows || chip_brick_row == ref_brick_row);
      // ... because the states agree
      assert (x < LINE && y < FRAME);
      assert (frame_tick == (x == 0 && y == FRAME_UPDATE_LINE));
      assert (chip_phase < GROUPS);
      assert (chip_filling == ref_new_wall_due);
      assert (chip_seen == ref_drawn_since_top);
      assert (!ref_new_wall_due || y < WALL_BOTTOM || (y == WALL_BOTTOM && x == 0) ||
              y > FRAME_UPDATE_LINE || (y == FRAME_UPDATE_LINE && x != 0));
      assert (((chip_ring ^ ring_value) & ring_known) == 0);
      assert (!nothing_drawn || (ref_bricks & passed) == 0);
      assert (!ref_new_wall_due || full_wall || wall_is_empty);
    end
  end

endmodule
