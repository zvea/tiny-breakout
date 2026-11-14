#!/bin/bash
# Tests tools/package.sh, on a scratch copy of the files it reads: the folder it makes holds
# exactly the bitstreams, logs, licences and README.txt, copied unchanged and named as they
# should be; README.txt names the commit and each file; and it refuses, leaving nothing
# behind, when an input is missing, the commit isn't one, or the output is already there.
# Usage: test/package_test.sh
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
FPGA=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

COMMIT=0123456789abcdef0123456789abcdef01234567
REPO=https://github.com/example/tiny-breakout
NAME=tiny-breakout-fpga-0123456
errors=0
fail() { echo "FAIL: $*"; errors=$((errors + 1)); }

# A scratch repo: the script, the licences, and each board's build output, all different
make_tree() {
  rm -rf "$T/repo"
  mkdir -p "$T/repo/fpga/tools" "$T/repo/fpga/tang_nano_20k/third_party/hdmi"
  cp "$FPGA/tools/package.sh" "$T/repo/fpga/tools/"
  echo "project licence" > "$T/repo/LICENSE"
  echo "hdl-util licence" > "$T/repo/fpga/tang_nano_20k/third_party/hdmi/LICENSE-MIT"
  local board file
  for board in fabricfox:fabricfox.bin icebreaker:icebreaker.bin tang_nano_20k:tn20k.fs; do
    file=${board#*:}
    board=${board%%:*}
    mkdir -p "$T/repo/fpga/$board/build"
    echo "$board bitstream" > "$T/repo/fpga/$board/build/$file"
    echo "$board synthesis" > "$T/repo/fpga/$board/build/synth.log"
    echo "$board place and route" > "$T/repo/fpga/$board/build/pnr.log"
  done
}

# 1. A good run: the folder's files, their contents, and README.txt
make_tree
"$T/repo/fpga/tools/package.sh" "$T/out" "$COMMIT" "$REPO" > /dev/null ||
  fail "package.sh failed on a complete tree"
P="$T/out/$NAME"
want="LICENSE
LICENSE-hdl-util-hdmi
README.txt
logs/fabricfox-pnr.log
logs/fabricfox-synth.log
logs/icebreaker-pnr.log
logs/icebreaker-synth.log
logs/tang-nano-20k-pnr.log
logs/tang-nano-20k-synth.log
tiny-breakout-fabricfox.bin
tiny-breakout-icebreaker.bin
tiny-breakout-tang-nano-20k.fs"
has=$(cd "$P" 2> /dev/null && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
[ "$has" = "$want" ] || fail "files in $NAME/:
$(diff <(echo "$want") <(echo "$has"))"
[ "$(ls -A "$T/out")" = "$NAME" ] || fail "the output holds more than $NAME/: $(ls -A "$T/out")"
case $(ls -ld "$P") in
  drwxr-xr-x*) ;;
  *) fail "$NAME/ isn't readable by all, as folders usually are: $(ls -ld "$P")" ;;
esac

same() { cmp -s "$1" "$2" || fail "$(basename "$2") isn't a copy of ${1#"$T"/repo/}"; }
R="$T/repo"
same "$R/LICENSE" "$P/LICENSE"
same "$R/fpga/tang_nano_20k/third_party/hdmi/LICENSE-MIT" "$P/LICENSE-hdl-util-hdmi"
same "$R/fpga/fabricfox/build/fabricfox.bin" "$P/tiny-breakout-fabricfox.bin"
same "$R/fpga/icebreaker/build/icebreaker.bin" "$P/tiny-breakout-icebreaker.bin"
same "$R/fpga/tang_nano_20k/build/tn20k.fs" "$P/tiny-breakout-tang-nano-20k.fs"
for board in fabricfox:fabricfox icebreaker:icebreaker tang_nano_20k:tang-nano-20k; do
  same "$R/fpga/${board%%:*}/build/synth.log" "$P/logs/${board#*:}-synth.log"
  same "$R/fpga/${board%%:*}/build/pnr.log" "$P/logs/${board#*:}-pnr.log"
done

readme="$P/README.txt"
for text in "$COMMIT" "$REPO/tree/$COMMIT" \
  tiny-breakout-fabricfox.bin tiny-breakout-icebreaker.bin tiny-breakout-tang-nano-20k.fs \
  "$REPO/blob/$COMMIT/fpga/fabricfox/README.md" "$REPO/blob/$COMMIT/fpga/icebreaker/README.md" \
  "$REPO/blob/$COMMIT/fpga/tang_nano_20k/README.md" \
  "iceprog tiny-breakout-icebreaker.bin" \
  "mpremote fs cp tiny-breakout-fabricfox.bin :/bitstreams/tt_um_tiny_breakout.bin" \
  "tt.shuttle.tt_um_tiny_breakout.enable()" "clock_frequency = 25.175e6" \
  "not yet been tried on a board" \
  "openFPGALoader -b tangnano20k -f tiny-breakout-tang-nano-20k.fs" \
  LICENSE-hdl-util-hdmi logs/; do
  grep -qF -- "$text" "$readme" 2> /dev/null || fail "README.txt doesn't mention $text"
done
if LC_ALL=C grep -q '[^ -~]' "$readme" 2> /dev/null; then fail "README.txt isn't plain ASCII"; fi

# 2. Refusals: each leaves no output
refuses() {  # WHY ARGS...: package.sh must fail and write nothing
  local why=$1
  shift
  rm -rf "$T/out"
  if "$T/repo/fpga/tools/package.sh" "$@" > /dev/null 2>&1; then fail "accepted $why"; fi
  [ ! -e "$T/out" ] || fail "left output behind after $why"
}
for missing in fpga/icebreaker/build/icebreaker.bin fpga/fabricfox/build/pnr.log \
  fpga/tang_nano_20k/third_party/hdmi/LICENSE-MIT; do
  make_tree
  rm "$T/repo/$missing"
  refuses "a tree without $missing" "$T/out" "$COMMIT" "$REPO"
done
make_tree
refuses "a commit that isn't one" "$T/out" "not-a-commit" "$REPO"
refuses "a short commit" "$T/out" "0123456" "$REPO"
refuses "no repository URL" "$T/out" "$COMMIT"
mkdir -p "$T/out/$NAME"
if "$T/repo/fpga/tools/package.sh" "$T/out" "$COMMIT" "$REPO" > /dev/null 2>&1; then
  fail "overwrote an existing $NAME/"
fi

if [ "$errors" = 0 ]; then echo PASS; else echo "FAIL: $errors errors"; exit 1; fi
