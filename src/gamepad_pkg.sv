/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * The report format of the Psychogenic SNES Gamepad PMOD
 * (https://github.com/psychogenic/gamepad-pmod).
 *
 * Refer to these as gamepad_pkg::name: the flow's yosys (0.62) does not support `import`.
 */

package gamepad_pkg;

  // A report is 24 bits, one per rising edge of pmod_clk: the second controller's 12
  // buttons, then the first's, in this order (1 = pressed). These are the first
  // controller's bit indices.
  localparam logic [4:0] BIT_B      = 12;
  localparam logic [4:0] BIT_Y      = 13;
  localparam logic [4:0] BIT_SELECT = 14;
  localparam logic [4:0] BIT_START  = 15;
  localparam logic [4:0] BIT_UP     = 16;
  localparam logic [4:0] BIT_DOWN   = 17;
  localparam logic [4:0] BIT_LEFT   = 18;
  localparam logic [4:0] BIT_RIGHT  = 19;
  localparam logic [4:0] BIT_A      = 20;
  localparam logic [4:0] BIT_X      = 21;
  localparam logic [4:0] BIT_L      = 22;
  localparam logic [4:0] BIT_R      = 23;

endpackage
