# -*- Tcl -*-

package require sqlite3

namespace jobdb {

proc logputs {f m} { logf $f $m }

proc prepare {job} { }

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
    global g
    if {![catch { osstestdb version }]} { return }
    sqlite3 jobdb::osstestdb $g(JobDbStandaloneFilename)
}

proc set-flight {} {
    global flight env
    if {![info exists env(OSSTEST_FLIGHT)]} {
	set env(OSSTEST_FLIGHT) standalone
    }
    set flight $env(OSSTEST_FLIGHT)
}

proc spawn-step-begin {flight job ts stepnovar} {
    variable stepcounter 0
    upvar 1 $stepnovar stepno
    set stepno [incr stepcounter]
}

proc spawn-step-commit {flight job stepno testid} {
    logputs stdout "$flight.$job $stepno TESTID $testid..."
}

proc step-set-status {flight job stepno st} {
    logputs stdout "$flight.$job $stepno STATUS $st"
}

proc become-task {argv} { }
