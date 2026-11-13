#!/bin/sh
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
# Stand-in for openroad when LibreLane re-runs a step: same environment and
# same script (the last argument), run through split_driver.tcl.
for a; do last="$a"; done
SPLIT_SCRIPT="$last" exec "$REAL_OPENROAD" -exit -no_splash "$(dirname "$0")/split_driver.tcl"
