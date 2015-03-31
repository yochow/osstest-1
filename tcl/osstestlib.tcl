# -*- Tcl -*-

# This is part of "osstest", an automated testing framework for Xen.
# Copyright (C) 2009-2013 Citrix Inc.
# 
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
# 
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU Affero General Public License for more details.
# 
# You should have received a copy of the GNU Affero General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.


package require Tclx

proc readconfig {} {
    global c
    set pl {
        use Osstest;
        readglobalconfig();
        foreach my $k (sort keys %c) {
            my $v= $c{$k};
            printf "%s\n%d\n%s\n", $k, length($v), $v;
        }
    }
    set ch [open |[list perl -e $pl] r]
    while {[gets $ch k] >= 0} {
        gets $ch vl
        set v [read $ch $vl]
        if {[eof $ch]} { error "premature eof in $k" }
        set c($k) $v
        gets $ch blank
        if {[string length $blank]} { error "$blank ?" }
    }
    close $ch
}

proc source-method {m} {
    global c
    source ./tcl/$m-$c($m).tcl
}

proc logf {f m} {
    set now [clock seconds]
    set timestamp [clock format $now -format {%Y-%m-%d %H:%M:%S Z} -gmt 1]
    puts $f "$timestamp $m"
}

proc log {m} { logf stdout $m }

proc must-gets {chan regexp args} {
    if {[gets $chan l] <= 0} { error "[eof $chan] $regexp" }
    if {![uplevel 1 [list regexp $regexp $l dummy] $args]} {
        error "$regexp $l ?"
    }
}

proc lremove {listvar item} {
    upvar 1 $listvar list
    set ix [lsearch -exact $list $item]
    if {$ix<0} return
    set list [lreplace $list $ix $ix]
}

proc lshift {listvar} {
    upvar 1 $listvar list
    set head [lindex $list 0]
    set list [lrange $list 1 end]
    return $head
}

proc var-or-default {varname {default {}}} {
    upvar 1 $varname var
    if {[info exists var]} { return $var }
    return $default
}
