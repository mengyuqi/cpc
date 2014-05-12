#!/usr/bin/perl -w

use warnings;
use strict;

my $arg_input_blast_report = shift @ARGV;

open FH_BLAST, "<$arg_input_blast_report" or die "Can't open BLAST input file ($arg_input_blast_report): $!";

my ($curr_query_id, $curr_record_start, $curr_record_end);

while (my $l = <FH_BLAST>) {

my $query_id = (split  " ",$l)[0]; 
 
unless ($curr_query_id) {$curr_query_id = $query_id;$curr_record_start=0;}

unless ($query_id eq $curr_query_id) {
    my $curr_pos = tell() - length($l);
    $curr_record_end = $curr_pos - 1;
    
    if ($curr_query_id) {
      print join("\t", $curr_query_id, $curr_record_start, $curr_record_end), "\n";
    }
    $curr_record_start = $curr_pos;
 $curr_query_id= $query_id;
}
 }

$curr_record_end = tell();
if ($curr_query_id) {print join("\t", $curr_query_id, $curr_record_start, $curr_record_end), "\n";}

close FH_BLAST;
