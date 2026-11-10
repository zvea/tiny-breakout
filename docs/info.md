## How it works

Tiny Breakout is a brick-breaker game with 640x480 VGA output at 60 Hz. There is no frame
buffer: every pixel is worked out from the beam position as the picture is drawn.

- **Bricks:** 8x6, coloured by row from red at the top to violet at the bottom. The first
  brick wall of a game is full; each later one is a symmetric pattern of 20 to 32 bricks, one
  of 21, picked at random.
- **Ball:** bounces off the side and top walls, the paddle and the bricks. Where it lands on
  the paddle sets its direction: off the left half it goes left, off the right half right, and
  at a flatter angle off the outer 16 px at each end. A brick hit on its side sends the ball
  back sideways; a hit on its top or bottom sends it back vertically.
- **Speed:** every ball starts at 1x and goes up to 1.5x, 2x, 2.5x and 3x as it clears 4, 8,
  12 and 16 bricks. The speed goes back to 1x for each new ball and after a cleared brick wall.
  The paddle moves 4 px each time the ball moves, so it speeds up with the ball (in the
  pause after a cleared brick wall it moves at 1x).
- **Lives and score:** you have 2 spare balls, shown top left; the score, top right, counts
  10 per brick, up to 9990. Once a ball has fallen past the paddle, the black margin around the
  playfield turns red, brightening as the ball drops off the screen. Losing the last ball ends
  the game: a black curtain comes down over everything but the score, and once it is down
  (about half a second) fire starts a new game.
- **Levels:** when the last brick is cleared, the game pauses for about a second while
  rainbow bands rise up the screen, gives back a spare ball (up to 2) and builds a new brick
  wall. Each level's paddle is narrower: 96 px, 80, 64, then 48 from the 4th level.
- **Autoplay:** the paddle steers itself and launches the ball. After each paddle hit it
  picks one of the paddle's four angle zones at random (the two outer ends and the two halves
  of the middle) and steers so that the ball lands there, so the ball keeps reaching new
  bricks.
- **Demo:** from reset, while no controller is connected and no direct button (`ui[0]` to
  `ui[2]`) has been pressed, the game plays itself. Connecting a controller or pressing a
  direct button starts a new game. A direct button ends the demo for good, until the next
  reset; unplugging the controller instead resumes the demo, in the current game. With a
  controller connected at reset, the game waits with the ball on the paddle.
- **Sound:** effects through the Audio Pmod on `uio[7]`: a note for each brick (higher rows,
  higher notes), a thock for the paddle, a low rumble for the side and top walls, a sigh for a
  lost ball and a sad trombone at game over; a rising call for a new game and a fanfare for a
  cleared brick wall, each doubled an octave below.

## How to test

1. Set the clock to 25.175 MHz.
2. Connect a VGA monitor through the TinyVGA PMOD on the output pins, and an SNES controller
   through the Gamepad PMOD on the input pins. For sound, also connect the Audio Pmod to the
   bidirectional pins (`uio[7]`); it is optional.
3. Reset. With no controller connected the demo runs; connecting one starts a new game. Press
   fire to launch the ball.

| Control | Gamepad | Direct input |
|---|---|---|
| Move left / right | D-pad left / right | `ui[0]` / `ui[1]` |
| Fire: launch the ball, or start a new game after game over | A, X, L or R | `ui[2]` |
| Autoplay | SELECT switches it on; left, right or fire switches it off | `ui[3]` high |

The other gamepad buttons (B, Y, START, up and down) do nothing. There is no pause, and a
game you are playing can't be restarted before game over, except by a reset or by unplugging
the controller and plugging it back in. Only the first of the Gamepad PMOD's two controllers is
read (the one Psychogenic's `gamepad_pmod_single` reads: the last 12 bits of each report); with
only the second one connected, the game sees no controller.

The direct inputs are active high, for plain buttons or for simulators that can't produce
the gamepad's serial signal. Pressing left, right or fire (`ui[0]` to `ui[2]`) also ends the
demo. Hold unused direct inputs low with pull-downs: a high `ui[3]` keeps autoplay on, and a
high `ui[0]` to `ui[2]` holds that button down. On the demo board, switch off the DIP switches
for `ui[0]` to `ui[3]`, and those for `ui[4]` to `ui[6]` too when the Gamepad PMOD is fitted.

## External hardware

- [TinyVGA PMOD](https://github.com/mole99/tiny-vga) on `uo[7:0]`, with a VGA monitor.
- [Gamepad PMOD](https://github.com/psychogenic/gamepad-pmod) on `ui[6:4]`, with an
  SNES-compatible controller. Optional: without it, use the direct inputs.
- Optional: buttons or switches on `ui[3:0]`, active high, with pull-downs.
- Optional: the [Audio Pmod](https://github.com/MichaelBell/tt-audio-pmod) on `uio[7]`, with
  headphones or a speaker, for sound.
