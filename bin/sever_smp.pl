#!/usr/bin/perl -w

use strict;
use warnings;

use Getopt::Long;
use IO::Socket;
use File::Temp;


use FindBin;			# XXX: the script location: $FindBin::Bin

my ($opt_port, $opt_path_database, $opt_path_gzip, $opt_flag_verbose);

GetOptions ("p=i" => \$opt_port,
	    "g=s" => \$opt_path_gzip,
	    "d=s" => \$opt_path_database,
	    "v|verbose"  => \$opt_flag_verbose,
	   );

$opt_port = 1861 unless ($opt_port);
chomp($opt_path_gzip = `which gzip 2>/dev/null`) unless $opt_path_gzip;
$opt_path_database = join("/", $FindBin::Bin, "../../data") unless $opt_path_database;

# BLAST configuration
my %blast_configure;

&init_blast_config(\%blast_configure, $opt_path_database);

# The following code came from perlipc manual page
use POSIX ":sys_wait_h";
sub REAPER {
  my $child;
  while ((my $waitedpid = waitpid(-1,WNOHANG)) > 0) {
    &logmsg ("reaped $waitedpid" . ($? ? " with exit $?" : ''));
  }
  $SIG{CHLD} = \&REAPER;	# loathe sysV
}

$SIG{CHLD} = \&REAPER;

my $main_sock = new IO::Socket::INET(LocalPort => $opt_port,	# 62751861
				     Listen => 5,
				     Proto => 'tcp',
				    );
die "Socket could not be created, Reason: $!" unless ($main_sock);

my $time_to_die=0;

sub signal_handler {
                  $time_to_die = 1;
                     local $SIG{HUP} = 'IGNORE';
                  kill(15, -$$);  
}
 

my $pid = fork();
  exit 0 if $pid;
  die "Can't fork: $!" unless defined($pid);
  POSIX::setsid( ) or die "Can't start a new session: $!\n";
for my $handle (*STDIN, *STDOUT, *STDERR) {
    open($handle, "+<", "/dev/null")
        || die "can't reopen $handle to /dev/null: $!";
}
$SIG{INT} = $SIG{TERM} = $SIG{HUP} =\&signal_handler; 
while($time_to_die==0){
next unless my $new_sock = $main_sock->accept();
  
  my $pid = fork();
   die "Can't fork: $!" unless defined($pid);
    if ($pid == 0) {		# in the sub-processing..
    &run_blast($new_sock);
    exit 1 ;
  }
}
close ($main_sock);

sub run_blast() {
  my $new_sock = shift @_;
  my $hersockaddr = $new_sock->peername;
  my ($port, $iaddr) = sockaddr_in($hersockaddr);
  my $herstraddr     = inet_ntoa($iaddr);

  &logmsg ("Getting connection from $herstraddr (port $port)");
  
  my %options;
  $SIG{PIPE}= \&signal_handler;
  while (defined (my $l = <$new_sock>)) {
    if (my ($key, $value) = ($l =~ /^SET (\S+) (\S+)/)) {
      $options{$key} = $value;
    } elsif ($l =~ /^BEGIN DATA/) {
      last;
    }
  }

  my $rh_current_blast_configure;
  if (exists $options{CONFIGURE}) {
    $rh_current_blast_configure = $blast_configure{$options{CONFIGURE}};
  }
  # Failsafe: use the CPC as default configure to match the oldversion client
  $rh_current_blast_configure = $blast_configure{CPC} unless $rh_current_blast_configure;
  
  # Fetch the input sequence (in gzip)
  my $blast_input = File::Temp::tmpnam();
  open FH, ">$blast_input" or warn "Can't write input file($blast_input): $!";
  my $length = 0;
  while (defined (my $l = <$new_sock>)) {
    last if ($l =~ /^END DATA/);
    print FH $l;
    $length += length($l);
  }
  truncate FH, $length - 1;	# XXX: remove the trailing \n
  close FH;
  &logmsg ("$length bytes data received");
  
  # Run blast
  my $blast_output = File::Temp::tmpnam(); # output blast, in gzip

  # Get options from configure
  my $blast_opts = $rh_current_blast_configure->{OPTIONS};
  my $blast_db = $rh_current_blast_configure->{DB};
  my $blast_program = $rh_current_blast_configure->{PROGRAM};
  
  if ($length > 6000) {
    $blast_opts = "$blast_opts -num_threads 6";  # some big sequences ==> 6 CPUs
  }
  else {
    $blast_opts = "$blast_opts -num_threads 4";  # a rather small sequences ==> 4 CPUs for fast startup
  }

  $blast_opts = "$blast_opts -db $blast_db"; # append database

  my $blast_cmd = join(" ", $blast_program, $blast_opts);
  my $input_cmd = "cat $blast_input";
  my $output_cmd = "cat";

  $input_cmd = "$opt_path_gzip -dc $blast_input" if ($options{GZIP_INPUT});
  $output_cmd = "$opt_path_gzip -c " if ($options{GZIP_OUTPUT});
  
  # XXX: a little trick: we just redirect the (original) STDOUT to the
  # result file, and redirect STDERR to STDOUT, which make gathering
  # the output easiler:)
  my $final_cmds = "($input_cmd | $blast_cmd | $output_cmd > $blast_output) 2>&1";
  logmsg ("Received Remote Cmd: $final_cmds");

#  $final_cmds = "(cat /etc/passwd | tee /dev/stdout | gzip -c > $blast_output )";
  
  my @blast_error = `$final_cmds`;
  my $blast_error = join("", @blast_error);

  my $blast_output_length = (-s $blast_output) || 0;
  my $blast_error_length = length($blast_error);
  
  # Send back...
  print $new_sock "BEGIN RESULT $blast_output_length $blast_error_length", "\n";
  if ($blast_output_length && open FH, "<$blast_output") {
    print $new_sock <FH>;
    close FH;
  }

  if ($blast_error && $blast_error_length > 0) {
    print $new_sock $blast_error;
  }
  
  print $new_sock "END RESULT", "\n";

  close ($new_sock);

  unlink ($blast_input);
  unlink ($blast_output);
}

sub logmsg { print "$0 $$: @_ at ", scalar localtime, "\n" }

sub init_blast_config($$) {
  my ($rh_blast_config, $path2db) = @_;

  ##################################################
  # 
  # Set1: CPC, for the main BLASTX search

  # BLASTX settings: Combining the BLAST and Frith2006(PLoS & RNA) protocols
  my $blast_CPC_opts="-strand plus";              # only the same strand
  $blast_CPC_opts = "$blast_CPC_opts -evalue 1e-10"; # as a quick setting 
  $blast_CPC_opts = "$blast_CPC_opts -ungapped"; # un-gapped blast (Frith2006, PLoS)
  $blast_CPC_opts = "$blast_CPC_opts -threshold 14 "; # Neighborhood word threshold score, default=12 
  $blast_CPC_opts = "$blast_CPC_opts -max_target_seqs 250";
  $blast_CPC_opts = "$blast_CPC_opts -comp_based_stats F";
  $blast_CPC_opts = "$blast_CPC_opts -outfmt 6";

  $rh_blast_config->{CPC} = {PROGRAM => "blastx",
			     DB => $path2db,
			     OPTIONS => $blast_CPC_opts,
			    };

  ##################################################
  # 
  # Set2: UTRef DB

  # BLASTN settings: just a baseline, may be further optimized
  my $blast_UTRef_opts = "-strand plus";	# only the same strand
  $blast_UTRef_opts = "$blast_UTRef_opts -evalue 1e-5"; # Pesole 2002
  $blast_UTRef_opts = join(" ", $blast_UTRef_opts,  "-dust yes", "-soft_masking true"); # softmask rep -- there're rep sequence in the UTR region
  
  $rh_blast_config->{UTRef} = {PROGRAM => "blastn",
			     DB => join("/", $path2db, "web", "UTRef_all"),
			     OPTIONS => "$blast_UTRef_opts",
			    };

  ##################################################
  # 
  # Set3: RNAdb

  # BLASTN settings: just a baseline, may be further optimized
  my $blast_RNAdb_opts = "-strand plus";	# only the same strand
  $blast_RNAdb_opts = "$blast_RNAdb_opts -evalue 1e-5"; # Furuno 2006 PLoS Genet
  $blast_RNAdb_opts = join(" ", $blast_RNAdb_opts,  "-dust yes", "-soft_masking true"); # softmask rep -- there're rep sequence in the UTR region
  
  $rh_blast_config->{RNAdb} = {PROGRAM => "blastn",
			     DB => join("/", $path2db, "web", "RNAdb_all"),
			     OPTIONS => "$blast_RNAdb_opts",
			    };

}
