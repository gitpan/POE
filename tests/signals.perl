#!perl -w -I..
# $Id: signals.perl,v 1.6 1998/11/16 18:03:58 troc Exp $

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
     print "Signal watcher started.  Send SIGINT or SIGTERM: ";
     $me->{'done'} = '';
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
     return 0;
   },
   'set an alarm' => sub
   {
     my ($k, $me, $from) = @_;
     print ".";
     $k->delay('set an alarm', 0.5);
   },
   'signal handler' => sub
   {
     my ($k, $me, $from, $signal_name) = @_;
     print "\nSignal watcher caught SIG$signal_name.\n";
                                        # remove the delay; stops session
     $k->delay('set an alarm');
   },
  );

$kernel->run();
