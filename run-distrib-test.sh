#!/bin/sh

# load the performance test library
PERFDIR=${PERFDIR:-`dirname $0`}
if [ -z "$PERFDIR" ] ; then
    PERFDIR=.
fi
. $PERFDIR/libperftest.sh

if [ -z "$SERVER" ] ; then
    echo Error: no SERVER machine defined - set SERVER in $PERFTESTCONF
    exit 1
fi

if [ -z "$CLIENTS" ] ; then
    echo Error: no CLIENT "machine(s)" defined - set CLIENTS in $PERFTESTCONF
    exit 1
fi

DSLOGDIR=${DSLOGDIR:-/var/log/dirsrv/slapd-$INST}
DSPIDFILE=${DSPIDFILE:-/var/run/dirsrv/slapd-$INST.pid}
HOST=${HOST:-$SERVER}
PORT=${PORT:-389}
SPORT=${SPORT:-636}
SUFFIX=${SUFFIX:-"dc=example,dc=com"}

LOGCONV=${LOGCONV:-logconv.pl}

SSHUSER=${SSHUSER:-"root"}
SSHSERVERUSER=${SSHSERVERUSER:-$SSHUSER}
SSHCLIENTUSER=${SSHCLIENTUSER:-$SSHUSER}

if [ -n "$USE_SSL" -a "$USE_SSL" = "1" ] ; then
    SSLFILES="cacert.asc cert8.db key3.db secmod.db"
    SETUPSSL=${SETUPSSL:-$PERFDIR/setupssl2.sh}
fi

clientsetupssl() {
    if [ -n "$USE_SSL" -a "$USE_SSL" = "1" ] ; then
        if [ ! -f cert8.db ] ; then
            certutil -d . -A -t CT,, -n "cacert" -a -i cacert.asc || { echo Error: could not add cacert.asc to certdb in ~: $? ; exit 1 ; }
        fi
    fi
}

setupsystems() {
    echo Copying files to $SERVER
    scp $EXTRAFILES $PERFDIR/libperftest.sh $SETUPSSL $PERFTESTCONF $PERFDIR/mon-tcp-backlog.pl $PERFDIR/.toprc $PERFDIR/serversetup.sh $PERFDIR/serversetup.ldif $PERFDIR/servercleanup.sh $SSHSERVERUSER@$SERVER: >> $LOCALLOGDIR/sshout.$SERVER 2>&1
    ssh $SSHSERVERUSER@$SERVER "rpm -q 389-ds-base" >> $LOCALLOGDIR/sshout.$SERVER 2>&1 || {
        if [ -n "$USE_RPMS" ] ; then
            scp 389-ds-base*.rpm $SSHSERVERUSER@$SERVER: >> $LOCALLOGDIR/sshout.$SERVER 2>&1
        fi
    }
    echo Starting server $SERVER
    ssh $SSHSERVERUSER@$SERVER "./serversetup.sh $USE_RPMS" >> $LOCALLOGDIR/sshout.$SERVER 2>&1
    if [ -n "$USE_SSL" -a "$USE_SSL" = "1" -a ! -f cacert.asc ] ; then
        scp $SSHSERVERUSER@$SERVER:cacert.asc . >> $LOCALLOGDIR/sshout.$SERVER 2>&1
    fi
    clientsetupssl
    for sys in $CLIENTS ; do
        echo Copying files to $sys
        scp $EXTRAFILES $PERFDIR/libperftest.sh $PERFDIR/clientsetup.sh $PERFTESTCONF $PERFDIR/srchtest.sh $SSLFILES $SSHCLIENTUSER@$sys: >> $LOCALLOGDIR/sshout.$sys 2>&1
        ssh $SSHCLIENTUSER@$sys "./clientsetup.sh" >> $LOCALLOGDIR/sshout.$sys 2>&1
    done
}

runsrchtest() {
    for sys in $CLIENTS ; do
        echo Starting tests on $sys
        ssh $SSHCLIENTUSER@$sys "./srchtest.sh $LOGDIR" >> $LOCALLOGDIR/sshout.$sys 2>&1 &
    done

    echo All tests started - waiting for completion
    wait
    echo Tests complete
}

getclientlogs() {
    for sys in $CLIENTS ; do
        echo Copying logs from $sys
        scp -r $SSHCLIENTUSER@$sys:$LOGDIR $LOCALLOGDIR >> $LOCALLOGDIR/sshout.$sys 2>&1
        mv $LOCALLOGDIR/$LOGDIR $LOCALLOGDIR/log.$sys
    done
    echo Files copied to $LOCALLOGDIR
}

cleanuplogs() {
    for sys in $CLIENTS ; do
        echo removing old logs from $sys
        ssh $SSHCLIENTUSER@$sys "rm -rf ${LOGPREF}*"
    done
}

fixlogfile() {
    # note - when the test DURATION is hit, the test script
    # will kill the search proc - this means it may have
    # written the date, but not the search time, so
    # the file will have a odd number of lines - if we
    # find a file with an odd number of lines, just
    # remove the last line
    lines=`wc -l "$file"|awk '{print $1}'`
    n=`expr $lines / 2`
    l2=`expr $n \* 2`
    if [ $lines -ne $l2 ] ; then
        echo fixing log file $1
        cp -p "$1" "$1".bak
        head -n -1 "$1" > "$1".tmp
        mv "$1".tmp "$1"
    fi
}

fixlogfiles() {
    # only if not using ldclt
    find $LOCALLOGDIR -name srchtest.\*.log | while read file ; do
        fixlogfile $file
    done
}

threshexceed() {
    awk '
    BEGIN {max=0.0; thresh=1.0; sum=0.0; nn=0; threshcnt=0}
    NR % 2 {ts=$0}
    (NR % 2) == 0 {
        if ($0 > max) {max = $0; maxts=ts; maxNR=NR}
        if ($0 > thresh) {
            print "value", $0, "exceeds threshold", thresh, " at ts", ts, "line", NR
            threshcnt++
        }
        sum+=$0 ; nn++
    }
    END {
        print "MAX=" max " at " maxts " line " maxNR " average=" (sum/nn)
        print threshcnt, "records exceeded the threshold", thresh
    }
    '
}

getwaittimes() {
    awk -v hroff=2 '
    BEGIN {secoff = hroff*3600}
    NR % 2 {ts=$0+secoff}
    (NR % 2) == 0 {
        table[ts] += $0
    }
    END {
        for (ts in table) {
            print ts, table[ts]
        }
    }
    ' | sort -n
}

getthreshcounts() {
    awk -v hroff=-4 '
    BEGIN {thresh=4.0; secoff=hroff*3600;mints=9999999999;maxts=0}
    NR % 2 {ts=$0+secoff;if (ts < mints) { mints=ts }; if (ts > maxts) {maxts=ts}}
    (NR % 2) == 0 && ($0 > thresh) {
        table[ts] += 1
    }
    END {
        # if no counts exceeded the threshold, the output will be quite
        # sparse - just fill in the missing values with 0
        for (ii = mints; ii <= maxts; ++ii) {
            if (ii in table) {
                print ii, table[ii]
            } else {
                print ii, 0
            }
        }
    }
    '
}

findthreshexceeds() {
    dt="$1"
    for sys in $CLIENTS ; do
        dir="$LOCALLOGDIR/${LOGPREF}$sys"
        for log in "$dir"/*.log ; do
            echo log file $log
            threshexceed < "$log"
        done
    done
}

cnvttcp2data() {
#2013-04-17 19:19:33 -0400 port389=0/0 port636=0/0 pid=5285/mem=623400/61678/cpu=42389/5546 
#1970-01-01 10:00:00 +1000 port389=connections/backlog port636=connections/backlog pid=#/mem=VSIZE(pages)/RSS(pages)/cpu=utime(ticks)/stime(ticks)
    awk -F'[ :/=-]+' -v hroff=0 -v start=$1 -v end=$2 '
    BEGIN { secoff=hroff*3600; found=0 }
    /tcp_max_syn_backlog/ {next}
    /somaxconn/ {next}
    /connections/ {next}
    {
        origts=$1 "-" $2 "-" $3 "#" $4 ":" $5 ":" $6
        ts=mktime($1 " " $2 " " $3 " " $4 " " $5 " " $6)+secoff
        if ((ts >= start) && (ts <= end)) {
            print ts, $9, $10, $12, $13, $17, $18, $20, $21, origts
            found=1
        }
    }
    END {if (!found) {print "Error: no records found between", start, "and", end; exit 1;}}
    '
}

getaccesslogs() {
    ssh $SSHSERVERUSER@$SERVER "killall ns-slapd" >> $LOCALLOGDIR/sshout.$SERVER 2>&1
    ssh $SSHSERVERUSER@$SERVER "cd $DSLOGDIR ; shopt -s nullglob; tar cfj access.tar.bz2 access.20* access" >> $LOCALLOGDIR/sshout.$SERVER 2>&1
    scp $SSHSERVERUSER@$SERVER:$DSLOGDIR/access.tar.bz2 $LOCALLOGDIR >> $LOCALLOGDIR/sshout.$SERVER 2>&1
    ssh $SSHSERVERUSER@$SERVER "rm -f $DSLOGDIR/access.tar.bz2" >> $LOCALLOGDIR/sshout.$SERVER 2>&1
}

getlogconvfiles() {
    scp $SSHSERVERUSER@$SERVER:access.out $LOCALLOGDIR >> $LOCALLOGDIR/sshout.$SERVER 2>&1
    scp $SSHSERVERUSER@$SERVER:access.stats $LOCALLOGDIR >> $LOCALLOGDIR/sshout.$SERVER 2>&1
}

getserverlogs() {
    scp $SSHSERVERUSER@$SERVER:top.out $LOCALLOGDIR >> $LOCALLOGDIR/sshout.$SERVER 2>&1
    scp $SSHSERVERUSER@$SERVER:backlog.log $LOCALLOGDIR >> $LOCALLOGDIR/sshout.$SERVER 2>&1
    scp $SSHSERVERUSER@$SERVER:epoll.out $LOCALLOGDIR >> $LOCALLOGDIR/sshout.$SERVER 2>&1
}

servercleanup() {
    ssh $SSHSERVERUSER@$SERVER "./servercleanup.sh" >> $LOCALLOGDIR/sshout.$SERVER 2>&1
}

plotdropsconnsaccess() {
    if [ ! -f thresh.dat ] ; then
        cat log.*/*.log | getthreshcounts > thresh.dat
    fi
    if [ -f thresh.dat ] ; then
        COUNT="thresh.dat 2 count"
        start=`head -1 thresh.dat|cut -f1 -d' '`
        end=`tail -1 thresh.dat|cut -f1 -d' '`
    fi
    if [ -f extra.dat ] ; then
        cp extra.dat extra.gp
    fi
    if [ -f backlog.log -a ! -f backlog.dat ] ; then
        if [ -n "$start" -a -n "$end" -a "$start" -gt 0 -a "$end" -gt 0 ] ; then
            cnvttcp2data $start $end < backlog.log > backlog.dat
        else
            cnvttcp2data 86400 99999999999999 < backlog.log > backlog.dat
            start=`head -1 backlog.dat|cut -f1 -d' '`
            end=`tail -1 backlog.dat|cut -f1 -d' '`
        fi
    fi
    if [ -f backlog.dat ] ; then
        BACKLOG="backlog.dat 4 conns backlog.dat 5 qsize"
    fi
    if [ -f access.out -a ! -f access.dat ] ; then
        cnvtlogconvcsv $start $end < access.out > access.dat
    fi
    if [ -f access.dat ] ; then
        ACCESS="access.dat 11 Conns access.dat 12 SSLConns"
    fi
    if [ -f access.stats ] ; then
        cnvtlogconvextra < access.stats >> extra.gp
    fi
    doplot drops-vs-conns.png extra.gp $COUNT $BACKLOG $ACCESS
}

plotconnperf() {
    if [ ! -f ldclt.dat ] ; then
        cat log.*/ldclt*.log | cnvtoldldcltoutput > ldclt.dat
    fi
    if [ -s ldclt.dat ] ; then
        start=`head -1 ldclt.dat|cut -f1 -d' '`
        end=`tail -1 ldclt.dat|cut -f1 -d' '`
    fi
    if [ -f extra.dat ] ; then
        cp extra.dat extra.gp
    else
        rm -f extra.gp
    fi
    if [ -n "$EXTRADAT" ] ; then
        echo "$EXTRADAT" >> extra.gp
    fi
    if [ -f backlog.log -a ! -f backlog.dat ] ; then
        if [ -n "$start" -a -n "$end" -a "$start" -gt 0 -a "$end" -gt 0 ] ; then
            cnvttcp2data $start $end < backlog.log > backlog.dat
        else
            cnvttcp2data 86400 99999999999999 < backlog.log > backlog.dat
            start=`head -1 backlog.dat|cut -f1 -d' '`
            end=`tail -1 backlog.dat|cut -f1 -d' '`
        fi
    fi
    if [ ! -f access.out -a -f access.tar.bz2 ] ; then
        if [ ! -d /dev/shm/logconv ] ; then mkdir -p /dev/shm/logconv ; fi
        if [ ! -f access ] ; then
            if [ -z "$LOGCONV_SUPPORTS_ARCHIVES" ] ; then
                tar xfj access.tar.bz2
                shopt -s nullglob
                $LOGCONV -D /dev/shm/logconv -m access.out access.20* access > access.stats
                rm -f access.20* access
                shopt -u nullglob
            else
                $LOGCONV -D /dev/shm/logconv -m access.out access.tar.bz2 > access.stats
            fi
        fi
    fi
    if [ -f access.out -a ! -f access.dat ] ; then
        cnvtlogconvcsv $start $end < access.out > access.dat
    fi
    if [ -f access.stats ] ; then
        cnvtlogconvextra < access.stats >> extra.gp
    fi
    if [ ! -f sockstats.dat ] ; then
        cat log.*/sockstats.log | cnvtsockstats > sockstats.dat
    fi
    if [ ! -f waits.dat ] ; then
        cat log.*/srchtest.*.log 2> /dev/null | getwaittimes > waits.dat
    fi
    TITLE="Connection Statistics" YLABEL="N" \
    doplot connperf.png extra.gp ldclt.dat 2 "Client ops/sec" \
        backlog.dat 2 "Server TCP LDAP connections" backlog.dat 3 "Server TCP LDAP backlog" \
        backlog.dat 4 "Server TCP LDAPS connections" backlog.dat 5 "Server TCP LDAPS backlog" \
        access.dat 11 "Server LDAP connections/sec" access.dat 12 "Server LDAPS connections/sec" \
        sockstats.dat 2 "Number of client sockets" sockstats.dat 3 "Number of client TIME_WAIT sockets" \
        waits.dat 2 "LDAPS client delay"
}

makeconnperfcsv() {
    connstats=`getstats 11,12 1 1 < access.dat`
    backstats=`getstats 2,3 1 1 < backlog.dat`
    if [ -s waits.dat ] ; then
        delaystats=`getstats 2 1 1 < waits.dat`
    else
        delaystats=0,0
    fi
    if [ -z "$delaystats" ] ; then
        delaystats=0,0
    fi
    ldconns=`awk '/Total Connections:/ {print $NF}' access.stats`
    ldsconns=`awk '/LDAPS Connections:/ {print $NF}' access.stats`
    peak=`awk '/^Peak/ {print $NF}' access.stats`
    highfd=`awk '/^Highest FD/ {print $NF}' access.stats`
    hdr="Conn/sec avg."
    for label in "Conn/sec max" "SSL Conn/sec avg" "SSL Conn/sec max" \
        "LDAP TCP conn avg" "LDAP TCP conn max" "LDAP TCP backlog avg" "LDAP TCP backlog max" \
        "LDAPS client delay avg" "LDAPS client delay max" "Total connections" \
        "LDAPS connections" "Peak connections" "Highest FD taken" ; do
        hdr="$hdr,$label"
    done
    echo $hdr
    echo $connstats,$backstats,$delaystats,$ldconns,$ldsconns,$peak,$highfd
}

if [ "$1" = clean ] ; then
    cleanuplogs || { echo error cleaning up logs ; exit 1 ; }
    echo Done
    exit 0
fi

if [ "$1" = stats ] ; then
    getstats "$2" || { echo error in stats ; exit 1 ; }
    echo Done
    exit 0
fi

if [ "$1" = analyze ] ; then
    analyzelog || { echo error in stats ; exit 1 ; }
    exit 0
fi

if [ "$1" = threshcount ] ; then
    getthreshcounts
    exit 0
fi

if [ "$1" = plotdropsconnsaccess ] ; then
    plotdropsconnsaccess
    exit 0
fi

if [ "$1" = plotconnperf ] ; then
    plotconnperf
    exit 0
fi

if [ "$1" = cnvttcp2data ] ; then
    shift
    cnvttcp2data "$@"
    exit 0
fi

if [ "$1" = cnvtlogconvcsv ] ; then
    shift
    cnvtlogconvcsv "$@"
    exit 0
fi

if [ "$1" = getclientlogs ] ; then
    shift
    getclientlogs "$@"
    exit 0
fi

if [ "$1" = makeconnperfcsv ] ; then
    shift
    makeconnperfcsv "$@"
    exit 0
fi

if [ "$1" = getstats ] ; then
    shift
    getstats "$@"
    exit 0
fi

if [ "$1" = servercleanup ] ; then
    shift
    servercleanup "$@"
    exit 0
fi

if [ "$1" != run ] ; then
    echo unrecognized command $1
    exit 1
fi

LOCALLOGDIR=${LOCALLOGDIR:-"$LOGDIR"}
if [ ! -d $LOCALLOGDIR ] ; then
    mkdir -p $LOCALLOGDIR
fi

setupsystems
runsrchtest
getclientlogs
echo Can clean client logs now
fixlogfiles
servercleanup
getserverlogs
if [ -n "$LOGCONV_ON_SERVER" ] ; then
    getlogconvfiles
else
    getaccesslogs
fi
if [ -n "$PROCESS" ] ; then
    echo Can start another test now
    cd $LOCALLOGDIR
    plotconnperf
    makeconnperfcsv > stats.csv
fi

echo Done
