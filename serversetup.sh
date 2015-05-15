#!/bin/sh

# this script is to be run as root on the remote server machine, usually via ssh
# this assumes all of the necessary files such as distrib.conf, setupssl2.sh, etc. have already
# been copied to the machine

. ./libperftest.sh

DIRSRVPKG=${DIRSRVPKG:-389-ds-base}
DSLOGDIR=${DSLOGDIR:-$PREFIX/var/log/dirsrv/slapd-$INST}
DSPIDFILE=${DSPIDFILE:-$PREFIX/var/run/dirsrv/slapd-$INST.pid}
FDMAX=${FDMAX:-32768}

if [ -z "$SBINDIR" ] ; then
    if [ -n "$PREFIX" ] ; then
        SBINDIR=$PREFIX/sbin
    else
        SBINDIR=/usr/sbin
    fi
fi

# see if specified extra yum repos
for file in *.repo ; do
    if [ ! -f "$file" ] ; then break ; fi
    $SUDOCMD cp $file /etc/yum.repos.d
done

$SUDOCMD sysctl -w fs.file-max=65536
limituser=${SERVERUID:-nobody}
echo "$limituser soft nofile 65536" | $SUDOCMD tee -a /etc/security/limits.conf
echo "$limituser hard nofile 65536" | $SUDOCMD tee -a /etc/security/limits.conf

$SUDOCMD yum -y install openldap-clients openldap-devel openldap-debuginfo nss nss-debuginfo nss-devel nss-tools nss-softokn nss-softokn-debuginfo nss-softokn-devel nss-softokn-freebl nss-softokn-freebl-devel nspr nspr-debuginfo nspr-devel perl-DB_File perl-Archive-Tar

if [ -n "$USE_SOURCE" ] ; then
    echo assume already built from source
elif [ -n "$use_82" ] ; then
    $SUDOCMD rpm -q redhat-ds-base > /dev/null 2>&1 ||
    $SUDOCMD yum -y localinstall redhat-ds-base-8.2.10-3.2.el5dsrv.x86_64.rpm redhat-ds-base-debuginfo-8.2.10-3.2.el5dsrv.x86_64.rpm ||
    { echo Error: could not install redhat-ds-base ; exit 1 ; }
else
    if [ -n "$1" ] ; then
        $SUDOCMD yum -y localinstall 389-ds-base-*.rpm ||
        { echo Error: could not install 389-ds-base ; exit 1 ; }
    else
        $SUDOCMD yum -y install $DIRSRVPKG ||
        { echo Error: could not install $DIRSRVPKG ; exit 1 ; }
        $SUDOCMD debuginfo-install -y $DIRSRVPKG
    fi
fi

if [ -f /etc/sysconfig/dirsrv.systemd ] ; then
    $SUDOCMD sed -i -e 's/^.*LimitNOFILE=.*$/LimitNOFILE='$FDMAX'/' /etc/sysconfig/dirsrv.systemd
    grep LimitCORE=infinity /etc/sysconfig/dirsrv.systemd > /dev/null 2>&1 || echo "LimitCORE=infinity" | $SUDOCMD tee -a /etc/sysconfig/dirsrv.systemd
    $SUDOCMD systemctl daemon-reload
else
    sed -i -e 's/^.*ulimit -n.*$/ulimit -n '$FDMAX'/' $PREFIX/etc/sysconfig/dirsrv
    grep "ulimit -c unlimited" $PREFIX/etc/sysconfig/dirsrv > /dev/null 2>&1 || echo "ulimit -c unlimited" >> $PREFIX/etc/sysconfig/dirsrv
fi

if [ ! -d $PREFIX/etc/dirsrv/slapd-$INST ] ; then
    setupargs="-l /dev/null -s slapd.ServerPort=$PORT slapd.RootDNPwd=$ROOTPW slapd.Suffix=$SUFFIX General.FullMachineName=$HOST slapd.ServerIdentifier=$INST slapd.InstallLdifFile=${PREFIX:-/usr}/share/dirsrv/data/Example.ldif"
    if [ -n "$SERVERUID" ] ; then
        setupargs="$setupargs General.SuiteSpotUserID=$SERVERUID General.SuiteSpotGroup=$SERVERUID"
    fi
    if [ -f serversetup.ldif ] ; then
        setupargs="$setupargs slapd.ConfigFile=serversetup.ldif"
    fi
    $SBINDIR/setup-ds.pl -s $setupargs || { echo Error: could not setup slapd $INST ; exit 1 ; }
elif [ -f serversetup.ldif ] ; then
    # make sure server has correct configuration
    ldapmodify -x -h localhost -p $PORT -D "$ROOTDN" -w "$ROOTPW" -f serversetup.ldif
fi

if [ -n "$USE_SSL" -a "$USE_SSL" = "1" ] ; then
    if ! certutil -d $PREFIX/etc/dirsrv/slapd-$INST -L -n "Server-Cert" > /dev/null 2>&1 ; then
        DMPWD="$ROOTPW" ./setupssl2.sh $PREFIX/etc/dirsrv/slapd-$INST
        certutil -d $PREFIX/etc/dirsrv/slapd-$INST -L -n "CA certificate" -a > cacert.asc
    fi
fi

# get clean access logs for this run only
myservice dirsrv stop $INST 2> /dev/null
rm -f $DSLOGDIR/access*
myservice dirsrv start $INST || { echo error: could not start server $INST: $? ; exit 1 ; }
if [ -f serversetup.ldif ] ; then
    # make sure server has correct configuration
    ldapmodify -x -h localhost -p $PORT -D "$ROOTDN" -w "$ROOTPW" -f serversetup.ldif
    myservice dirsrv stop $INST || { echo error: could not stop server $INST: $? ; exit 1 ; }
    myservice dirsrv start $INST || { echo error: could not start server $INST: $? ; exit 1 ; }
fi

DSPID=`cat $DSPIDFILE`
top -d 1 -b -H -p $DSPID > top.out 2>&1 &
if [ -n "$PORT" -a "$PORT" != 389 ] ; then
    monport=$PORT
fi
if [ -n "$SPORT" -a "$SPORT" != 636 ] ; then
    monport="$monport,$SPORT"
fi
/usr/bin/perl mon-tcp-backlog.pl ${monport:+"-P" $monport} -o backlog.log -p $DSPID > /dev/null &

epollfd=`ls -al /proc/$DSPID/fd | awk '/eventpoll/ {print $9}'`
if [ -n "$epollfd" ] ; then
    while true ; do
        date +"%s"
        cat /proc/$DSPID/fdinfo/$epollfd
        sleep 1
    done > epoll.out 2>&1 & echo $! > epoll.pid
fi

# monitor and compress access logs
logmon() {
    rpm -q inotify-tools > /dev/null 2>&1 || yum -y install inotify-tools
    # the server does rename access -> access.20..... when rotating, then
    # creates a new file named "access"
    inotifywait -e move $DSLOGDIR --exclude '.bz2$' -m | while read dir act name ; do
        file=${dir}$name
        case "$file" in
        *access.20*) echo compressing $file ; bzip2 $file & ;;
        *) echo skipping file $file ;;
        esac
    done
}

logmon > logmon.out 2>&1 & echo $! > logmon.pid
