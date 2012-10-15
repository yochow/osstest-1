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
    sqlite3 jobdb::osstestdb $g(job-db-standalone-filename)
}
