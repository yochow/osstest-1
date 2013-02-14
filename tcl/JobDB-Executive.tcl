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

package require Pgtcl 1.5

namespace eval jobdb {

proc logputs {f m} {
    global argv
    set time [clock format [clock seconds] -gmt true \
                  -format "%Y-%m-%d %H:%M:%S Z"]
    puts $f "$time \[$argv] $m"
}

proc prepare {job} {
    global flight jobinfo
    db-open
    set found 0
    db-execute-array jobinfo "
        SELECT job, status, recipe FROM jobs
			WHERE	flight = [pg_quote $flight]
			AND	job = [pg_quote $job]
    " {
	switch -exact -- $jobinfo(status) {
	    queued - preparing - retriable - play { incr found }
	    default {
		error "job $flight.$job status $jobinfo(status)"
	    }
	}
    }
    if {!$found} {
	error "job $flight.$job not found"
    }

    setstatus preparing
    db-close
}

proc job-set-status-unlocked {flight job st} {
    db-open
    db-execute "
            UPDATE jobs SET status='$st'
                WHERE flight=$flight AND job='$job'
                  AND status<>'aborted' AND status<>'broken'
    "
    db-close
}

proc job-set-status {flight job st} {
    transaction flights {
        job-set-status-unlocked $flight $job $st
    }
}

proc set-flight {} {
    global flight argv env

    if {[string equal [lindex $argv 0] --start-delay]} {
        after [lindex $argv 1]
        set argv [lrange $argv 2 end]
    }

    set flight [lindex $argv 0]
    set argv [lrange $argv 1 end]
    set env(OSSTEST_FLIGHT) $flight
}

variable dbusers 0

proc db-open {} {
    global g
    variable dbusers

    if {$dbusers > 0} { incr dbusers; return }

    set pl {
	use Osstest;
	use Osstest::Executive;
	readglobalconfig();
	print db_pg_dsn("osstestdb") or die $!;
    }
    set db_pg_dsn [exec perl -e $pl]

    # PgDbName_* are odbc-style strings as accepted by Perl's DBD::Pg
    # but Tcl pg_connect unaccountably uses a different format which
    # is whitespace-separated.
    regsub -all {;} $db_pg_dsn { } conninfo
    pg_connect -conninfo $conninfo -connhandle dbh
    incr dbusers
}
proc db-close {} {
    variable dbusers
    incr dbusers -1
    if {$dbusers > 0} return
    if {$dbusers} { error "$dbusers ?!" }
    pg_disconnect dbh
}

proc db-update-1 {stmt} {
    # must be in transaction
    set nrows [db-execute $stmt]
    if {$nrows != 1} { error "$nrows != 1 in < $stmt >" }
}

proc db-execute-debug {stmt} {
    if {[info exists env(OSSTEST_TCL_JOBDB_DEBUG)]} {
	puts stderr "EXECUTING >$stmt<"
    }
}
proc db-execute {stmt} {
    db-execute-debug $stmt
    uplevel 1 pg_execute dbh $stmt
}
proc db-execute-array {stmt arrayvar} {
    db-execute-debug $stmt
    uplevel 1 pg_execute -array $arrayvar dbh $stmt
}

proc lock-tables {tables} {
    # must be inside transaction
    foreach tab $tables {
        db-execute "
		LOCK TABLE $tab IN ACCESS EXCLUSIVE MODE
        "
    }
}

proc spawn-step-begin {flight job ts stepnovar} {
    upvar 1 $stepnovar stepno

    db-open

    db-execute BEGIN
    db-execute "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
    if {[catch {
        lock-tables flights
	db-execute-array stepinfo "
            SELECT max(stepno) AS maxstep FROM steps
                WHERE flight=[pg_quote $flight] AND job=[pg_quote $job]
        "
        set stepno $stepinfo(maxstep)
	if {[string length $stepno]} {
	    incr stepno
	} else {
	    set stepno 1
	}
	db-execute "
            INSERT INTO steps
                VALUES ([pg_quote $flight], [pg_quote $job], $stepno,
                        [pg_quote $ts], 'running',
                        'STARTING')
        "
	db-execute COMMIT
    } emsg]} {
	global errorInfo errorCode
	set ei $errorInfo
	set ec $errorCode
	catch { db-execute ROLLBACK }
        db-close
	error $emsg $ei $ec
    }
    db-close
}

proc spawn-step-commit {flight job stepno testid} {
    transaction flights {
        db-update-1 "
            UPDATE steps
                  SET testid=[pg_quote $testid],
                      started=[clock seconds]
                WHERE flight=[pg_quote $flight]
                  AND job=[pg_quote $job]
                  AND stepno=$stepno
        "
    }
}

proc step-set-status {flight job stepno st} {
    transaction flights {
        db-update-1 "
            UPDATE steps
               SET status='$st',
                   finished=[clock seconds]
             WHERE flight=$flight AND job='$job' AND stepno=$stepno
        "
        set pause 0
        db-execute-array stopinfo "
            SELECT val FROM runvars
             WHERE flight=$flight AND job='$job'
               AND name='pause_on_$st'
        " {
            db-execute-array stepinfo "
                SELECT * FROM steps
                 WHERE flight=$flight AND job='$job' AND stepno=$stepno
            " {
                foreach col {step testid} {
                    if {![info exists stepinfo($col)]} continue
                    foreach pat [split $stopinfo(val) ,] {
                        if {[string match $pat $stepinfo($col)]} {
                            set pause 1
                        }
                    }
                }
            }
        }
    }
    if {$pause} {
        logputs stdout "PAUSING as requested"
        catch { exec sleep 86400 }
    }
}

proc transaction {tables script} {
    db-open
    while 1 {
        set ol {}
        db-execute BEGIN
        db-execute "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
        lock-tables $tables
	set rc [catch { uplevel 1 $script } result]
	if {!$rc} {
	    if {[catch {
		db-execute COMMIT
	    } emsg]} {
		puts "commit failed: $emsg; retrying ..."
		db-execute ROLLBACK
		after 500
		continue
	    }
	} else {
	    db-execute ROLLBACK
	}
        db-close
	return -code $rc $result
    }
}

proc become-task {comment} {
    global env c
    if {[info exists env(OSSTEST_TASK)]} return

    set ownerqueue [socket $c(ControlDaemonHost) $c(OwnerDaemonPort)]
    fconfigure $ownerqueue -buffering line -translation lf
    must-gets $ownerqueue {^OK ms-ownerdaemon\M}
    puts $ownerqueue create-task
    must-gets $ownerqueue {^OK created-task (\d+) (\w+ [\[\]:.0-9a-f]+)$} \
        taskid refinfo
    fcntl $ownerqueue CLOEXEC 0
    set env(OSSTEST_TASK) "$taskid $refinfo"

    set hostname [info hostname]
    regsub {\..*} $hostname {} hostname
    set username "[id user]@$hostname"

    transaction resources {
        set nrows [db-execute "
            UPDATE tasks
               SET username = [pg_quote $username],
                   comment = [pg_quote $comment]
             WHERE taskid = $taskid
               AND type = [pg_quote [lindex $refinfo 0]]
               AND refkey = [pg_quote [lindex $refinfo 1]]
        "]
    }
    if {$nrows != 1} {
        error "$nrows $taskid $refinfo ?"
    }
}

proc step-log-filename {flight job stepno ts} {
    global c
    set logdir $c(Logs)/$flight/$job
    file mkdir $c(Logs)/$flight
    file mkdir $logdir
    return $logdir/$stepno.$ts.log
}

}; # namespace eval jobdb
