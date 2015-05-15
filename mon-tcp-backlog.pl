#!/usr/bin/perl
# mpoole@redhat.com 2013-04-17
# mk3

use strict;
use Getopt::Std;
use IO::File;
use Data::Dumper;
use POSIX qw(strftime);

use Getopt::Std;

my ($found,$s,@b,$fh,$now,%o,@n,$ofh);

$o{'s'}=1;
getopts("46P:p:o:s:",\%o);
push @n, '/proc/net/tcp'
    if !$o{'4'};
push @n, '/proc/net/tcp6'
    if !$o{'6'};
$ofh = new IO::File $o{'o'}, "w+"
    if $o{'o'};
$ofh->autoflush(1)
    if $ofh;
$fh = new IO::File;
$s=setup_s($s,$o{'P'});

show_file( $fh, $ofh, '/proc/sys/net/ipv4/tcp_max_syn_backlog', '/proc/sys/net/core/somaxconn' );
$found = strftime('%Y-%m-%d %H:%M:%S %z ', localtime($now)).
	join( ' ', (map{ "port$_->{'p'}=connections/backlog"; } sort { $a->{'p'} <=> $b->{'p'} } values(%$s))).
		(($o{'p'}) ? ' pid=#/mem=VSIZE(pages)/RSS(pages)/cpu=utime(ticks)/stime(ticks)' : '').
		"\n";
	print $found;
	print $ofh $found
		if $ofh;
while(1)
{
    $now = time;
    $found=0;
    foreach my $v ( values %$s )
    {
	$v->{'c'}=$v->{'s'}=0;
    }
    foreach my $f( @n )
    {
	if ($fh->open($f))
	{
	    while(<$fh>)
	    {
		@b=split(/[:\s]+/,$_);
		if (exists $s->{$b[3]})
		{
		    $found++;
		    if ($b[6]=='0A') {
			$s->{$b[3]}->{'s'}=hex($b[8]);
		    }else {
			$s->{$b[3]}->{'c'}++;
		    }
		}
	    }
	    close $fh;
	}
    }
    if ($found)
    {
	$found = strftime('%Y-%m-%d %H:%M:%S %z ', localtime($now)).
		join( ' ', (map{ "port$_->{'p'}=$_->{'c'}/$_->{'s'}"; } sort { $a->{'p'} <=> $b->{'p'} } values(%$s))).
		procinfo( $fh, $o{'p'} ).
		"\n";
	print $found;
	print $ofh $found
		if $ofh;
    }else
    {
	# fail
	die "No ldap listener found\n";
    }
    sleep $o{'s'};
}

sub
setup_sp
{
    my $s = shift;
    my $p = shift;
    my $h = sprintf('%04X',$p);
    $s->{$h}={'p'=>$p,'c'=>0,'s'=>0,};
}

sub
setup_s
{
    my $s = shift;
    my $p = shift;
    $s={};
    if (length($p) && $p)
    {
	setup_sp( $s, split(',', $p ));
    }else
    {
	setup_sp( $s, 389 );
	setup_sp( $s, 636 );
    }
    return $s;
}

sub
contents
{
    my $ifh = shift;
    my $c;
    foreach my $f(@_)
    {
	if ($ifh->open($f,"r"))
	{
	    while(<$ifh>) { $c .= $_; }
	    $ifh->close;
	}
    }
    chomp($c);
    return $c;
}

sub
show_file
{
    my $ifh = shift;
    my $ofh = shift;
    my ($ts,$c,$f);
    $ts = strftime('%Y-%m-%d %H:%M:%S %z', localtime());
    foreach $f(@_)
    {
	$c=contents($ifh,$f);
	print "$ts $f = $c\n";
	print $ofh "$ts $f = $c\n" if $ofh;
    }
}

sub
procinfo
{
    my $ifh = shift;
    my $pid = shift;
    return '' if !$pid;
    my ($p,@c);
    foreach my $p( split( /,/, $pid ) )
    {
	my @b = split( /\s+/, contents( $ifh, '/proc/'. $p. '/stat' ));
	push @c,  'pid='. $p. '/mem='. int($b[22]/4096). '/'. $b[23]. '/cpu='. $b[13]. '/'. $b[14];
    }
    return ' '. join( ' ', @c ). ' ';
}


# vi: aw ai sw=4
# End of File
