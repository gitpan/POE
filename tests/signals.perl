#!perl -w -I..
# $Id: signals.perl,v 1.4 1998/08/18 15:51:08 troc Exp $

use strict;

use POE; # and you get Kernel and Session

select(STDOUT); $|=1;

my $kernel = new POE::Kernel();

new POE::Session
  (
   $kernel,
   '_start' => sub
   {
     my ($k, $me, $from) = @_;
     $k->sig('INT', 'signal handler');
     print "Signal watcher started.  Send SIGINT: ";
     $k->post($me, 'set an alarm');
   },
   '_stop' => sub
   {
     my ($k, $me, $from) = @_;
     print "Signal watcher stopped.\n";
   },
   '_default' => sub
   {
     my ($k, $me, $from, $state, @etc) = @_;
     print "Signal watcher _default gets state ($state) from ($from) ",
           "parameters(", join(', ', @etc), ")\n";
   },
   'set an alarm' => sub
   {
     my ($k, $me, $from) = @_;
     print ".";
     $k->alarm('set an alarm', time()+1);
   },
   'signal handler' => sub
   {
     my ($k, $me, $from, $signal_name) = @_;
     print "\nSignal watcher caught SIG$signal_name.\n";
   },
  );

$kernel->run();
