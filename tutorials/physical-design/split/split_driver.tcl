# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
# Runs a LibreLane OpenROAD step script with one change: the layout is
# written to DEF just before and just after its legalisation
# (common/dpl.tcl), and write_views is dropped, so nothing is written into
# the run. Everything else (commands, order, environment) is the step's own.
set script $::env(SPLIT_SCRIPT)
set out $::env(REPRO_OUT)
set f [open $script]; set txt [read $f]; close $f
set dpl {source $::env(SCRIPTS_DIR)/openroad/common/dpl.tcl}
set n [string first $dpl $txt]
if { $n < 0 } { puts "no legalisation in $script"; exit 1 }
set txt [string map [list $dpl "write_def $out/before_legalise.def\n$dpl\nwrite_def $out/after_legalise.def"] $txt]
regsub -all -line {^\s*write_views\s*$} $txt "" txt
uplevel #0 $txt
