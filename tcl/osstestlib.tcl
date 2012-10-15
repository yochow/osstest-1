# -*- Tcl -*-

package require Tclx

proc readconfig {} {
    global g
    set pl {
        use Osstest;
        readglobalconfig();
        foreach my $k (sort keys %g) {
            my $v= $g{$k};
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
    source ./tcl/$m-$g($m).tcl
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

proc reap-ts {reap {dbopen 0}} {
    if {![string length $reap]} { if {$dbopen} db-open; return 0 }

    upvar #0 reap_details($reap) details
    set detstr [lindex $details 3]
    set iffail [lindex $details 4]
    logputs stdout "awaiting $detstr"
    if {[catch { close $reap } emsg]} {
        set result $iffail
    } else {
        set result pass
    }
    if {$dbopen} db-open

    eval step-set-status [lrange $details 0 2] $result
    logputs stdout "finished $detstr $result $emsg"
    return [expr {![string compare $result pass]}]
}
