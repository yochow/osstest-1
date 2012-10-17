# -*- Tcl -*-

package require sqlite3

namespace eval jobdb {

proc logputs {f m} { logf $f $m }

proc prepare {job} {
    global flight jobinfo
    ensure-db-open
    osstestdb eval {
	SELECT job, status, recipe FROM jobs
	    WHERE flight = $flight
	    AND    job = $job
    } jobinfo {
	return
    }
    error "job $flight.$job not found"
}

proc job-set-status {flight job st} {
    ensure-db-open
    osstestdb eval {
	UPDATE jobs
	   SET status = $st
	 WHERE flight = $flight
	   AND job = $job
    }
}

proc ensure-db-open {} {
    global c
    if {![catch { osstestdb version }]} { return }
    sqlite3 osstestdb $c(JobDBStandaloneFilename)
}

proc set-flight {} {
    global flight env
    if {![info exists env(OSSTEST_FLIGHT)]} {
	set env(OSSTEST_FLIGHT) standalone
    }
    set flight $env(OSSTEST_FLIGHT)
}

proc spawn-step-begin {flight job ts stepnovar} {
    variable stepcounter
    if {![info exists stepcounter]} { set stepcounter 0 }
    upvar 1 $stepnovar stepno
    set stepno [incr stepcounter]
}

proc spawn-step-commit {flight job stepno testid} {
    logputs stdout "$flight.$job ========== $stepno testid $testid =========="
}

proc step-set-status {flight job stepno st} {
    logputs stdout "$flight.$job $stepno status status $st"
}

proc become-task {argv} { }

proc step-log-filename {flight job} {
    return {}
}

}; # namespace eval jobdb
