## How it works

Tiny Breakout is a brick-breaker game with 640x480 VGA output at 60 Hz. There is no frame
buffer: every pixel is worked out from the beam position as the picture is drawn.

- **Wall:** 8 x 6 bricks, coloured by row from red at the top to violet at the bottom.
- **Ball:** bounces off the walls, the paddle and the bricks. Where it lands on the paddle
  sets its angle (flatter towards the ends). A brick hit on its side sends the ball back
  sideways; a hit on its top or bottom sends it back vertically.
- **Speed:** rises by half a step for every 4 bricks the current ball clears, from 1x up to
  3x.
- **Lives and score:** you have 2 spare balls, shown top left; the score, top right, counts
  10 per brick. Losing the last ball ends the game.
- **Levels:** when the wall is cleared, the game pauses for half a second, gives back a spare
  ball (up to 2) and builds a new wall. Each level's balls start half a step faster, up to
  2.5x from the 4th level.
- **Autoplay:** the paddle steers itself. After each paddle hit it aims the ball at a
  pseudo-randomly chosen quarter of the paddle, so the ball keeps reaching new bricks.
- **Demo:** when no controller is connected, the game plays itself.

## How to test

1. Set the clock to 25.175 MHz.
2. Connect a VGA monitor through the TinyVGA PMOD on the output pins, and an SNES controller
   through the Gamepad PMOD on the input pins.
3. Reset. With no controller connected the demo runs; connecting one starts a new game.

| Control | Gamepad | Direct input |
|---|---|---|
| Move left / right | D-pad left / right | `ui[0]` / `ui[1]` |
| Launch the ball, or start a new game after game over | A, X, L or R | `ui[2]` |
| Autoplay | SELECT switches it on; left, right or fire switches it off | `ui[3]` high |

The direct inputs are active high, for plain buttons or for simulators that can't produce
the gamepad's serial signal. Pressing left, right or fire (`ui[0]` to `ui[2]`) also ends the
demo.

## External hardware

- [TinyVGA PMOD](https://github.com/mole99/tiny-vga) on `uo[7:0]`, with a VGA monitor.
- [Gamepad PMOD](https://github.com/psychogenic/gamepad-pmod) on `ui[6:4]`, with an
  SNES-compatible controller. Optional: without it, use the direct inputs.
- Optional: buttons or switches on `ui[3:0]`.
