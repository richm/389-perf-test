#!/bin/sh

LOGDIR=$1

LDCLT=${LDCLT:-./ldclt-bin}
. ./libperftest.sh

LDAPTLS_CACERT=${LDAPTLS_CACERT:-~/cacert.asc} ; export LDAPTLS_CACERT

# run 2 threads or 2 processes per core to maximize cpu utilization
NPROC=${NPROC:-`grep processor /proc/cpuinfo | wc -l`}
ITERS=${NITERS:-1}
BASEOPT=${BASEOPT:-"-b"}
BASE=${BASE:-"$SUFFIX"}
SCOPEOPT=${SCOPEOPT:-"-s"}
SCOPE=${SCOPE:-"sub"}
BINDDNOPT=${BINDDNOPT:-"-D"}
BINDDN=${BINDDN:-"uid=scarter,ou=people,$SUFFIX"}
BINDPWOPT=${BINDPWOPT:-"-w"}
BINDPW=${BINDPW:-"sprain"}
if [ "$USE_LDCLT" = "1" ] ; then
    # ldclt-only options
    #BINDONLY=${BINDONLY:-"-e bindonly"}
    #BINDEACH=${BINDEACH:-"-e bindeach"}
    # this causes a lot of errors
    #DOCLOSE=${DOCLOSE:-"-e close"}
    :
fi
if [ -z "$BINDONLY" ] ; then
    FILT=${FILT:-"uid=mwhite"}
    FILTOPT=${FILTOPT:-"-f"}
    ESEARCH=${ESEARCH:-"-e esearch"}
fi
ATTRS=${ATTRS:-""} # i.e. all
DURATION=${DURATION:-600} # seconds
LOGBASEDIR=${LOGBASEDIR:-.}
DEBUGLDAP=${DEBUGLDAP:-""} # use -d 1 for heavy trace output
TIMEIT=${TIMEIT-"/usr/bin/time -f %e"}
DATEIT=${DATEIT-"date +%s"} # set to ":" to disable dating
USE_SSL=${USE_SSL:-0}
USE_START_TLS=${USE_START_TLS:-0}
# there is a bug in openldap - not thread safe for multiple simultaneous SSL connections
USE_SSL_THREADS=${USE_SSL_THREADS:-0}
SSLOPTS=${SSLOPTS:-"-Z ./cert8.db"}
if [ -n "$HALF_SSL" ] ; then
    NSSL=${NSSL:-$NPROC}
    NNOSSL=${NNOSSL:-$NPROC}
elif [ "$USE_SSL" = 1 ] ; then
    NSSL=${NSSL:-`expr $NPROC + $NPROC`}
    NNOSSL=0
    PROT=${PROT:-ldaps}
    LDPORT=${LDPORT:-$SPORT}
    URL=${URL:-${PROT}://${HOST}:${LDPORT}}
elif [ "$USE_START_TLS" = 1 ] ; then
    NNOSSL=${NNOSSL:-`expr $NPROC + $NPROC`}
    NSSL=0
    PROT=${PROT:-ldap}
    LDPORT=${LDPORT:-$PORT}
    URL=${URL:-${PROT}://${HOST}:${LDPORT}}
    TLSOPTS=${TLSOPTS:-"-ZZ"}
else
    NNOSSL=${NNOSSL:-`expr $NPROC + $NPROC`}
    NSSL=0
    PROT=${PROT:-ldap}
    LDPORT=${LDPORT:-$PORT}
    URL=${URL:-${PROT}://${HOST}:${LDPORT}}
fi

if [ ! -d $LOGDIR ] ; then
    mkdir -p $LOGDIR
fi

ldclt() {
    # use threads instead of procs with ldclt
    $LDCLT -h $HOST -p $LDCLTPORT $BINDDNOPT "$BINDDN" $BINDPWOPT "$BINDPW" \
        $BASEOPT "$BASE" $FILTOPT "$FILT" $LDCLTSSLOPTS \
        $ASYNC $BINDONLY $BINDEACH $DOCLOSE $ESEARCH \
        $EXTRALDCLTOPTS \
	    -n$NTHREAD \
	    -v -q || { echo Error: $LDCLT returned $? ; exit 1 ; }
}

ldsrch() {
    $TIMEIT ldapsearch $DEBUGLDAP -xLLL -H $URL $TLSOPTS $BINDDNOPT "$BINDDN" $BINDPWOPT \
        "$BINDPW" $SCOPEOPT $SCOPE $BASEOPT "$BASE" "$FILT" $ATTRS > /dev/null || {
        echo Error: ldapsearch returned $? ; exit 1 ; }
}

dosrch() {
    while [ 1 ] ; do
        ${DATEIT}
        ldsrch || { echo Error: ldsrch returned $? ; exit 1 ; }
    done
}

doldclt() {
    ldclt || { echo Error: ldclt returned $? ; exit 1 ; }
}

srchtest() {
    jj=${SNSSL:-0}
    pids=""
    while [ $jj -gt 0 ] ; do
        URL=ldaps://${HOST}:${SPORT} dosrch > $LOGDIR/srchtest.$jj.log 2>&1 || { echo Error: dosrch returned $? ; exit 1 ; } & pids="$pids $! "
        jj=`expr $jj - 1`
    done
    jj=${SNNOSSL:-0}
    while [ $jj -gt 0 ] ; do
        URL=ldap://${HOST}:${PORT} dosrch > $LOGDIR/srchtest.$jj.log 2>&1 || { echo Error: dosrch returned $? ; exit 1 ; } & pids="$pids $! "
        jj=`expr $jj - 1`
    done
    sleep $DURATION
    kill $pids
    wait
}

ldclttest() {
    top -b > $LOGDIR/top.log 2>&1 & toppid=$!
    pids=""
    if [ "$NNOSSL" -gt 0 ] ; then
        LDCLTPORT=$PORT NTHREAD=$NNOSSL doldclt > $LOGDIR/ldclt.log 2>&1 || { echo Error: doldclt returned $? ; exit 1 ; } & pids="$pids $! "
    fi
    if [ "$NSSL" -gt 0 ] ; then
        if [ $USE_SSL_THREADS -ne 0 ] ; then
            LDCLTPORT=$SPORT LDCLTSSLOPTS="$SSLOPTS" NTHREAD=$NSSL doldclt > $LOGDIR/ldclt.ssl.log 2>&1 || { echo Error: ldclt returned $? ; exit 1 ; } & pids="$pids $! "
        else
            jj=$NSSL
            while [ $jj -gt 0 ] ; do
                LDCLTPORT=$SPORT LDCLTSSLOPTS="$SSLOPTS" NTHREAD=1 doldclt > $LOGDIR/ldclt.$jj.log 2>&1 || { echo Error: ldclt returned $? ; exit 1 ; } & pids="$pids $! "
                jj=`expr $jj - 1`
            done
        fi
    fi
    sleep $DURATION
    killall -2 ldclt-bin
    kill $pids
    kill $toppid
    wait
}

getsockstats() {
    ts=`date +%s`
    endts=`expr $ts + $DURATION`
    while [ $ts -le $endts ] ; do
        echo $ts
        cat /proc/net/sockstat
        echo ""
        sleep 10 # default ldclt interval
        ts=`date +%s`
    done
}

getpingstats() {
    date +%s > $LOGDIR/pingstats.log
    ping $HOST >> $LOGDIR/pingstats.log & pingpid=$!
    sleep $DURATION
    kill $pingpid
}

# need a high ulimit in order to open lots of sockets - see also clientsetup.sh
ulimit -n ${FDMAX:-32768}
getsockstats > $LOGDIR/sockstats.log &
getpingstats &
ldclttest &
#SNSSL=1 srchtest
#SNSSL=${SNSSL:-$NSSL} SNNOSSL=${SNNOSSL:-$NNOSSL} srchtest
echo logdir is $LOGDIR
