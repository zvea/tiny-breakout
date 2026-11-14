#!/bin/bash
# Gathers every board's bitstream, from each board's build/, into one folder for one download:
# OUT_DIR/tiny-breakout-fpga-<short commit>/, with the bitstreams, each board's synthesis and
# place-and-route logs in logs/, the licences that come with the bitstreams, and README.txt,
# which names the commit and says what each file is. CI uploads the folder; it works the same
# locally, after each board's tools/build.sh.
# Usage: tools/package.sh OUT_DIR COMMIT REPO_URL
#   COMMIT: the full commit hash the bitstreams were built from
#   REPO_URL: the repository on GitHub, for README.txt's links (https://github.com/OWNER/REPO)
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)

if [ $# -ne 3 ]; then
  echo "Usage: $0 OUT_DIR COMMIT REPO_URL" >&2
  exit 2
fi
out=$1 commit=$2 repo=${3%/}
[[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "Not a full commit hash: $commit" >&2; exit 1; }
name=tiny-breakout-fpga-${commit:0:7}
[ ! -e "$out/$name" ] || { echo "Already there: $out/$name" >&2; exit 1; }

# The boards: folder, bitstream in its build/, name in the package (dashes, as file names are)
BOARDS="fabricfox fabricfox.bin fabricfox
icebreaker icebreaker.bin icebreaker
tang_nano_20k tn20k.fs tang-nano-20k"

# Everything is checked before anything is written
missing=0
need() { [ -f "$ROOT/$1" ] || { echo "Missing: $1" >&2; missing=1; }; }
need LICENSE
need fpga/tang_nano_20k/third_party/hdmi/LICENSE-MIT
while read -r board bitstream _; do
  need "fpga/$board/build/$bitstream"
  need "fpga/$board/build/synth.log"
  need "fpga/$board/build/pnr.log"
done <<< "$BOARDS"
[ "$missing" = 0 ] || exit 1

# Made under a scratch name in OUT_DIR, and renamed once complete: a failure leaves nothing
# (and removes OUT_DIR if this made it)
made_out=0
[ -d "$out" ] || { mkdir -p "$out"; made_out=1; }
work=$(mktemp -d "$out/.package.XXXXXX")
trap 'rm -rf "$work"; [ "$made_out" = 0 ] || rmdir "$out" 2> /dev/null || true' EXIT
mkdir "$work/logs"

cp "$ROOT/LICENSE" "$work/LICENSE"
cp "$ROOT/fpga/tang_nano_20k/third_party/hdmi/LICENSE-MIT" "$work/LICENSE-hdl-util-hdmi"
while read -r board bitstream short; do
  cp "$ROOT/fpga/$board/build/$bitstream" "$work/tiny-breakout-$short.${bitstream##*.}"
  cp "$ROOT/fpga/$board/build/synth.log" "$work/logs/$short-synth.log"
  cp "$ROOT/fpga/$board/build/pnr.log" "$work/logs/$short-pnr.log"
done <<< "$BOARDS"

docs="$repo/blob/$commit/fpga"
cat > "$work/README.txt" << EOF
Tiny Breakout: FPGA bitstreams

Tiny Breakout is a brick-breaker game made for a Tiny Tapeout chip. These are bitstreams of
the same design for three FPGA boards, all built from one commit:

  Commit: $commit
  Source: $repo/tree/$commit

Each board's README says what to plug in, how to load the bitstream, and how it was built.

tiny-breakout-fabricfox.bin
  Tiny Tapeout's FPGA Development Kit: the FabricFox FPGASIC (iCE40UP5K) in place of the chip
  on the Tiny Tapeout demo board, with the chip's Pmods (VGA, gamepad, audio). It builds and
  meets timing, but has not yet been tried on a board.
  Load: copy it to the demo board's /bitstreams/ as tt_um_tiny_breakout.bin,
    mpremote fs cp tiny-breakout-fabricfox.bin :/bitstreams/tt_um_tiny_breakout.bin
  give it its 25.175 MHz clock in the demo board's config.ini,
    [tt_um_tiny_breakout]
    clock_frequency = 25.175e6
  and in the demo board's REPL: tt.shuttle.tt_um_tiny_breakout.enable()
  $docs/fabricfox/README.md

tiny-breakout-icebreaker.bin
  1BitSquared iCEBreaker (iCE40UP5K), with MuseLab's PMOD-VGA v1.1 on PMOD1A and PMOD1B, and
  the snap-off board's buttons. No sound.
  Load: iceprog tiny-breakout-icebreaker.bin
  $docs/icebreaker/README.md

tiny-breakout-tang-nano-20k.fs
  Sipeed Tang Nano 20K (Gowin GW2AR-18), with picture and sound over HDMI. The game plays its
  demo: there is no controller.
  Load: openFPGALoader -b tangnano20k -f tiny-breakout-tang-nano-20k.fs
  $docs/tang_nano_20k/README.md

logs/
  Each board's synthesis and place-and-route logs: the resources the design uses, and its
  timing.

LICENSE
  Tiny Breakout's licence (Apache-2.0).

LICENSE-hdl-util-hdmi
  The MIT licence of hdl-util/hdmi (which is dual MIT and Apache-2.0), whose HDMI transmitter
  is in the Tang Nano 20K bitstream.
EOF

chmod 755 "$work"  # mktemp's folders are the owner's only
mv "$work" "$out/$name"
trap - EXIT
echo "$out/$name"
