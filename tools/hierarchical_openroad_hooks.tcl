# Runtime hooks. No command in this file runs on import or during dry run.
proc hr_json_string {value} {
  return "\"[string map [list \\ \\\\ \" \\\" \n \\n \r \\r \t \\t] $value]\""
}

proc hr_floorplan {} {
  global hr_kind hr_rows hr_cols hr_config_json hr_layout_request hr_layout_file hr_python hr_runner
  set db [ord::get_db]
  set block [ord::get_db_block]
  set dbu [$block getDbUnitsPerMicron]
  set macros {}
  set std_area 0.0
  foreach inst [$block getInsts] {
    set master [$inst getMaster]
    set w [expr {double([$master getWidth]) / $dbu}]
    set h [expr {double([$master getHeight]) / $dbu}]
    if {[$inst isBlock]} {
      lappend macros "{\"name\":[hr_json_string [$inst getName]],\"master\":[hr_json_string [$master getName]],\"width_um\":$w,\"height_um\":$h}"
    } else {
      set std_area [expr {$std_area + $w * $h}]
    }
  }
  set site NULL
  foreach lib [$db getLibs] {
    set site [$lib findSite $::env(PLACE_SITE)]
    if {$site != "NULL"} {break}
  }
  if {$site == "NULL"} {error "Cannot resolve placement site"}
  set sx [expr {double([$site getWidth]) / $dbu}]
  set sy [expr {double([$site getHeight]) / $dbu}]
  set f [open $hr_layout_request w]
  puts $f "{\"kind\":\"$hr_kind\",\"rows\":$hr_rows,\"cols\":$hr_cols,\"site_width_um\":$sx,\"site_height_um\":$sy,\"standard_cell_area_um2\":$std_area,\"config\":$hr_config_json,\"macros\":\[[join $macros ,]\]}"
  close $f
  exec $hr_python $hr_runner --layout-file $hr_layout_request $hr_layout_file
  source $hr_layout_file
  unset -nocomplain ::env(CORE_UTILIZATION)
  set ::env(CORE_AREA) $hr_core
  set ::env(DIE_AREA) $hr_die
}

proc hr_place {} {
  global hr_layout_file
  source $hr_layout_file
  foreach placement $hr_placements {
    lassign $placement name x y
    place_macro -macro_name $name -location [list $x $y] -orientation R0
  }
  # place_macro marks instances LOCKED; RTLMP retains fixed macros.
}

proc hr_check {final} {
  global hr_expected hr_check_file
  set block [ord::get_db_block]
  set dbu [$block getDbUnitsPerMicron]
  set core [$block getCoreArea]
  set counts [dict create]
  set boxes {}
  foreach inst [$block getInsts] {
    if {![$inst isBlock]} {continue}
    set master [[$inst getMaster] getName]
    if {![dict exists $hr_expected $master]} {error "Unexpected macro master: $master"}
    dict incr counts $master
    set rect [$inst getBBox]
    set box [list [$rect xMin] [$rect yMin] [$rect xMax] [$rect yMax]]
    lassign $box x1 y1 x2 y2
    if {$x1 < [$core xMin] || $y1 < [$core yMin] || $x2 > [$core xMax] || $y2 > [$core yMax]} {
      error "Macro outside core: [$inst getName]"
    }
    lappend boxes [list $x1 $y1 $x2 $y2 [$inst getName]]
    if {$final} {
      set supplies [dict create]
      foreach iterm [$inst getITerms] {
        set sig [[$iterm getMTerm] getSigType]
        if {$sig ni {POWER GROUND}} {continue}
        set net [$iterm getNet]
        set expected_net [expr {$sig == "POWER" ? "VDD" : "VSS"}]
        if {$net == "NULL" || [$net getName] != $expected_net} {
          error "Unconnected/incorrect macro supply: [$inst getName]"
        }
        dict set supplies $expected_net 1
      }
      if {![dict exists $supplies VDD] || ![dict exists $supplies VSS]} {error "Missing macro supply terminals"}
    }
  }
  dict for {master count} $hr_expected {
    if {![dict exists $counts $master] || [dict get $counts $master] != $count} {error "Macro instance count mismatch: $master"}
  }
  set active {}
  foreach box [lsort -real -index 0 $boxes] {
    lassign $box x1 y1 x2 y2 name
    set keep {}
    foreach other $active {
      lassign $other ox1 oy1 ox2 oy2 oname
      if {$ox2 <= $x1} {continue}
      if {$y1 < $oy2 && $oy1 < $y2} {error "Overlapping macros: $name, $oname"}
      lappend keep $other
    }
    set active $keep
    lappend active $box
  }
  if {$final} {
    if {![design_is_routed]} {error "Unrouted nets remain"}
    set pairs {}
    dict for {master count} $counts {lappend pairs "[hr_json_string $master]:$count"}
    set f [open $hr_check_file w]
    puts $f "{\"macro_counts\":{[join $pairs ,]},\"unrouted_nets\":0,\"power_connected\":true}"
    close $f
  }
}
