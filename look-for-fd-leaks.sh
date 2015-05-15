#!/bin/sh

INTERVAL=${INTERVAL:-2}
sockstat=/proc/net/sockstat
PIDFILE=${PIDFILE:-$HOME/389srv/var/run/dirsrv/slapd-localhost.pid}
procbase=/proc/`cat $PIDFILE`
procsockstat=$procbase/net/sockstat

show_sockstat() {
    awk '/^TCP|^sockets/' $1
}

get_tw_sockets() {
    awk '/^TCP/ {print $7}' $1
}

get_sockets() {
    ls -al $1/fd 2> /dev/null | grep socket | wc -l
}

epollfd=`ls -al $procbase/fd|awk '/anon_inode:\[eventpoll\]/ {print $9}'`
if [ -n "$epollfd" ] ; then
    epollinfo=$procbase/fdinfo/$epollfd
fi
while true ; do
    date
    echo "###########" system
    show_sockstat $sockstat
    echo "###########" proc
    show_sockstat $procsockstat
    echo "###########" sockets
    get_sockets $procbase
    if [ -n "$epollinfo" ] ; then
        echo "###########" epoll
        cat $procbase/fdinfo/$epollfd
    fi
    echo ""
    sleep $INTERVAL
done
