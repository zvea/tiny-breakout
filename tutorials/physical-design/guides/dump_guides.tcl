# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
# Writes the route guides stored in a database (what detailed routing reads) in the
# .guide format: net, then "x0 y0 x1 y1 layer" lines in brackets.
# Usage: IN_ODB=step.odb OUT_GUIDE=out.guide openroad -exit -no_splash dump_guides.tcl
read_db $::env(IN_ODB)
set f [open $::env(OUT_GUIDE) w]
foreach net [[ord::get_db_block] getNets] {
  set gs [$net getGuides]
  if {[llength $gs] == 0} { continue }
  puts $f [$net getName]
  puts $f "("
  foreach g $gs {
    set b [$g getBox]
    puts $f "[$b xMin] [$b yMin] [$b xMax] [$b yMax] [[$g getLayer] getName]"
  }
  puts $f ")"
}
close $f
