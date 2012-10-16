# -*- Tcl -*-

package require Pgtcl 1.5

namespace eval jobdb {

proc logputs {f m} {
    global argv
    set time [clock format [clock seconds] -gmt true \
                  -format "%Y-%m-%d %H:%M:%S Z"]
    puts $f "$time \[$argv] $m"
}

proc prepare {job} {
    global jobinfo
    db-open
    set found 0
    pg_execute -array jobinfo dbh "
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
    pg_execute dbh "
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


proc db-open {} {
    global g
    variable dbusers 0

    if {$dbusers > 0} { incr dbusers; return }

    # PgDbName_* are odbc-style strings as accepted by Perl's DBD::Pg
    # but Tcl pg_connect unaccountably uses a different format which
    # is whitespace-separated.
    regsub -all {;} $c(ExecutiveDbname_osstestdb) { } conninfo
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
    set nrows [pg_execute dbh $stmt]
    if {$nrows != 1} { error "$nrows != 1 in < $stmt >" }
}

proc lock-tables {tables} {
    # must be inside transaction
    foreach tab $tables {
        pg_execute dbh "
		LOCK TABLE $tab IN ACCESS EXCLUSIVE MODE
        "
    }
}

proc spawn-step-begin {flight job ts stepnovar} {
    upvar 1 $stepnovar stepno

    db-open

    pg_execute dbh BEGIN
    pg_execute dbh "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
    if {[catch {
        lock-tables flights
	pg_execute -array stepinfo dbh "
            SELECT max(stepno) AS maxstep FROM steps
                WHERE flight=[pg_quote $flight] AND job=[pg_quote $job]
        "
        set stepno $stepinfo(maxstep)
	if {[string length $stepno]} {
	    incr stepno
	} else {
	    set stepno 1
	}
	pg_execute dbh "
            INSERT INTO steps
                VALUES ([pg_quote $flight], [pg_quote $job], $stepno,
                        [pg_quote $ts], 'running',
                        'TBD')
        "
	pg_execute dbh COMMIT
    } emsg]} {
	global errorInfo errorCode
	set ei $errorInfo
	set ec $errorCode
	catch { pg_execute dbh ROLLBACK }
        db-close
	error $emsg $ei $ec
    }
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

    db-close
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
        pg_execute -array stopinfo dbh "
            SELECT val FROM runvars
             WHERE flight=$flight AND job='$job'
               AND name='pause_on_$st'
        " {
            pg_execute -array stepinfo dbh "
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
        pg_execute dbh BEGIN
        pg_execute dbh "SET TRANSACTION ISOLATION LEVEL SERIALIZABLE"
        lock-tables $tables
	set rc [catch { uplevel 1 $script } result]
	if {!$rc} {
	    if {[catch {
		pg_execute dbh COMMIT
	    } emsg]} {
		puts "commit failed: $emsg; retrying ..."
		pg_execute dbh ROLLBACK
		after 500
		continue
	    }
	} else {
	    pg_execute dbh ROLLBACK
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
        set nrows [pg_execute dbh "
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

}; # namespace eval jobdb
