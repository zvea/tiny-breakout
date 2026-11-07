/*
 * Copyright (c) 2026 Alexei Zverovitch
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Types for the Psychogenic SNES Gamepad PMOD (https://github.com/psychogenic/gamepad-pmod).
 *
 * Refer to these as gamepad_pkg::name: the flow's yosys (0.62) does not support `import`.
 */

package gamepad_pkg;

  // One controller's buttons, in the order the PMOD sends them (1 = pressed). B arrives
  // first, so after 12 shifts it ends up in the most significant bit.
  typedef struct packed {
    logic b, y, select, start, up, down, left, right, a, x, l, r;
  } gamepad_t;

endpackage
