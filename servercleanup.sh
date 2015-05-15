#!/bin/sh

# this script is to be run as root on the remote server machine, usually via ssh
# this assumes all of the necessary files such as distrib.conf, setupssl2.sh, etc. have already
# been copied to the machine

. ./libperftest.sh

DSLOGDIR=${DSLOGDIR:-$PREFIX/var/log/dirsrv/slapd-$INST}
LOGCONV=${LOGCONV:-logconv.pl}

# top
killall top
# mon-tcp-backlog
killall /usr/bin/perl
# epoll pid
if [ -f epoll.pid ]; then
    kill `cat epoll.pid`
fi
# logmon
if [ -f logmon.pid ]; then
    kill `cat logmon.pid`
fi
# list slapd sockets in use
ls -al /proc/`pidof ns-slapd`/fd|grep socket
# inotifywait
killall inotifywait

if [ -n "$LOGCONV_ON_SERVER" ] ; then
    killall ns-slapd
    mkdir -p /dev/shm/logconv
    $LOGCONV -D /dev/shm/logconv -m access.out $DSLOGDIR/access.20*.bz2 $DSLOGDIR/access > access.stats
    rm -rf /dev/shm/logconv
fi
