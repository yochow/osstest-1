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
proc preserve-task {argv} { }

proc step-log-filename {flight job stepno ts} {
    return {}
}

}; # namespace eval jobdb
