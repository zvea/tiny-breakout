/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Pixel colours with 2 bits per channel (64 colours, as the TinyVGA PMOD shows them),
 * and names for the ones this project uses.
 *
 * Note: refer to these as colour_pkg::name. The yosys frontend used by the flow (0.62)
 * does not support `import`.
 */

package colour_pkg;

  typedef struct packed {
    logic [1:0] r, g, b;
  } rgb_t;

  localparam rgb_t BLACK     = 6'b00_00_00;
  localparam rgb_t WHITE     = 6'b11_11_11;
  localparam rgb_t PALE_CYAN = 6'b10_11_11;
  localparam rgb_t GREY      = 6'b01_01_01;
  localparam rgb_t NAVY      = 6'b00_00_01;
  localparam rgb_t RED       = 6'b11_00_00;
  localparam rgb_t ORANGE    = 6'b11_10_00;
  localparam rgb_t YELLOW    = 6'b11_11_00;
  localparam rgb_t GREEN     = 6'b00_11_00;
  localparam rgb_t AZURE     = 6'b00_10_11;
  localparam rgb_t VIOLET    = 6'b10_00_11;

endpackage
