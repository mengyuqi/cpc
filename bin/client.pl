#!/usr/bin/perl -w

use strict;
use warnings;

use Getopt::Long;
use IO::Socket;

my ($arg_peer_addr);
my ($opt_config, $opt_port, $opt_flag_verbose);

GetOptions ("c=s" => \$opt_config,
	    "p=i" => \$opt_port,
	    "v|verbose"  => \$opt_flag_verbose,
	   );

$opt_port = 1861 unless ($opt_port);
$opt_config = "CPC" unless ($opt_config);

$arg_peer_addr = shift @ARGV;

die "Usage: $0 (server_ip)" unless $arg_peer_addr;

my $sock = new IO::Socket::INET( PeerAddr => $arg_peer_addr,
				 PeerPort => $opt_port,
				 Proto => 'tcp',
			       );
die "Socket could be be created: $!" unless $sock;

print $sock "SET CONFIGURE $opt_config", "\n"; # CPC configure
print $sock "SET GZIP_INPUT 0", "\n";
print $sock "SET GZIP_OUTPUT 1", "\n";

print $sock "BEGIN DATA", "\n";
print $sock <STDIN>;
print $sock "\n";
print $sock "END DATA", "\n";

$sock->flush();

my ($l, $buf);

my $blast_output_size = 0;
my $blast_error_size = 0;
while ($l = <$sock>) {
  if ($l =~ /^BEGIN RESULT (\d+) (\d+)/) {
    $blast_output_size = $1;
    $blast_error_size = $2;
    last;
  }
}
if ($blast_output_size > 0) {
  $sock->read($buf, $blast_output_size);
  print $buf;
}

if ($blast_error_size > 0) {
  $sock->read($buf, $blast_error_size);
  print STDERR $buf;
}

while ($l = <$sock>) {}		# XXX: eat up all rest data.

close ($sock);
