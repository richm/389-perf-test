#!/bin/sh

. ./libperftest.sh

DIRSRVPKG=${DIRSRVPKG:-389-ds-base}

# see if specified extra yum repos
for file in *.repo ; do
    if [ ! -f "$file" ] ; then break ; fi
    $SUDOCMD cp $file /etc/yum.repos.d
done

$SUDOCMD sysctl -w fs.file-max=65536
echo "* soft nofile 65536" | $SUDOCMD tee -a /etc/security/limits.conf
echo "* hard nofile 65536" | $SUDOCMD tee -a /etc/security/limits.conf

$SUDOCMD yum -y install openldap-clients openldap-devel openldap-debuginfo nss nss-debuginfo nss-devel nss-tools nss-softokn nss-softokn-debuginfo nss-softokn-devel nss-softokn-freebl nss-softokn-freebl-devel nspr nspr-debuginfo nspr-devel

USE_LDCLT=${USE_LDCLT:-1}
if [ "$USE_LDCLT" = 1 -a ! -f ldclt-bin ] ; then
    if rpm -q $DIRSRVPKG ; then
        echo $DIRSRVPKG already installed
    else
        $SUDOCMD yum -y install ${DIRSRVPKG}
    fi
    cp ${PREFIX:-/usr}/bin/ldclt-bin .
    $SUDOCMD yum -y erase 389-ds-base-libs
fi

# this test opens and closes a lot of connections
# the os will keep tens of thousands of sockets in the TIME_WAIT state
# e.g. /proc/net/sockstat shows a large number of tw
# this causes the client to have connection errors if no local port
# is available
# we increase the socket/tcp limits here to provide for a larger
# range of sockets, and to allow us to reuse ports faster
echo 1 | $SUDOCMD tee /proc/sys/net/ipv4/tcp_tw_reuse
echo 1 | $SUDOCMD tee /proc/sys/net/ipv4/tcp_tw_recycle
echo "1024 65535" | $SUDOCMD tee /proc/sys/net/ipv4/ip_local_port_range

# DNS is quite expensive and introduces quite a bit of irregularity
# into the results - so disable it by putting the server IP into /etc/hosts

case "$SERVER" in
[1-9][1-9]*) echo using server IP address $SERVER ;;
*) grep $SERVER /etc/hosts > /dev/null 2>&1 || getent hosts $SERVER >> /etc/hosts ;;
esac
