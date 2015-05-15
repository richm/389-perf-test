#!/bin/sh
cd $HOME
git clone https://git.fedorahosted.org/git/nunc-stans.git
mkdir nsbuilt
pushd nsbuilt
CFLAGS="-g -pipe -Wall -fexceptions -fstack-protector-strong --param=ssp-buffer-size=4 -grecord-gcc-switches  -m64 -mtune=generic" ../nunc-stans/configure --with-fhs --libdir=/usr/lib64 --enable-debug
make install
rm -f /usr/lib64/libnunc-stans.a /usr/lib64/libnunc-stans.la
popd
git clone https://git.fedorahosted.org/git/389/ds.git
mkdir dsbuilt
pushd dsbuilt
CFLAGS="-g -pipe -Wall -fexceptions -fstack-protector-strong --param=ssp-buffer-size=4 -grecord-gcc-switches  -m64 -mtune=generic" CXXFLAGS="$CFLAGS" ../ds/configure --with-openldap --enable-debug \
    --with-fhs --libdir=/usr/lib64 \
    --enable-nunc-stans --with-nunc-stans \
    --with-tmpfiles-d=/etc/tmpfiles.d \
    --enable-autobind --with-selinux \
    --with-systemdsystemunitdir=/usr/lib/systemd/system \
    --with-systemdsystemconfdir=/etc/systemd/system \
    --with-systemdgroupname=dirsrv.target
make -j && make install
