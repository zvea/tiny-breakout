# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
# Runs LibreLane's global placement script with one change: extra arguments for
# global_placement (GPL_EXTRA: an earlier stop), then the placement is written to
# $REPRO_OUT/$FRAME.def and the script ends, so nothing is written into the run.
set f [open $::env(SPLIT_SCRIPT)]; set txt [read $f]; close $f
set call {log_cmd global_placement {*}$arg_list}
if { [string first $call $txt] < 0 } { puts "no global_placement call"; exit 1 }
set txt [string map [list $call "$call {*}\$::env(GPL_EXTRA)\nwrite_def \$::env(REPRO_OUT)/\$::env(FRAME).def\nexit"] $txt]
uplevel #0 $txt
