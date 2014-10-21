#!/usr/bin/perl -w
# $Id: 03_aliases.t,v 1.10 2002/09/01 16:05:33 rcaputo Exp $

# Tests basic session aliases.

use strict;
use lib qw(./lib ../lib);
use TestSetup;
&test_setup(21);

use POSIX qw (:errno_h);

# Turn on all asserts.
sub POE::Kernel::ASSERT_DEFAULT () { 1 }

use POE;

### Define a simple state machine.

sub machine_start {
  my ($kernel, $session, $heap) = @_[KERNEL, SESSION, HEAP];
  my $resolved_session;

  $heap->{idle_count} = $heap->{zombie_count} = 0;

  # Set an alias.
  print "not " if $kernel->alias_set( 'new name' );
  print "ok 2\n";

  # Set it again.
  print "not " if $kernel->alias_set( 'new name' );
  print "ok 3\n";

  # Resolve weak, stringified session reference.
  $resolved_session = $kernel->alias_resolve( "$session" );
  print "not " unless $resolved_session eq $session;
  print "ok 4\n";

  # Resolve against session ID.
  $resolved_session = $kernel->alias_resolve( $session->ID );
  print "not " unless $resolved_session eq $session;
  print "ok 5\n";

  # Resolve against alias.
  $resolved_session = $kernel->alias_resolve( 'new name' );
  print "not " unless $resolved_session eq $session;
  print "ok 6\n";

  # Resolve against blessed session reference.
  $resolved_session = $kernel->alias_resolve( $session );
  print "not " unless $resolved_session eq $session;
  print "ok 7\n";

  # Resolve against something that doesn't exist.
  $resolved_session = eval { $kernel->alias_resolve( 'nonexistent' ) };
  print "not " if defined $resolved_session;
  print "ok 8\n";

  # Resolve IDs to and from Sessions.
  my $id = $session->ID;
  print "not " unless $kernel->ID_id_to_session($id) == $session;
  print "ok 9\n";

  print "not " unless $kernel->ID_session_to_id($session) == $id;
  print "ok 10\n";

  print "not " unless $kernel->ID_id_to_session($kernel->ID) == $kernel;
  print "ok 11\n";

  print "not " unless $kernel->ID_session_to_id($kernel) eq $kernel->ID;
  print "ok 12\n";

  # Check alias list for session.
  my @aliases = $kernel->alias_list();
  print "not " unless @aliases == 1 and $aliases[0] eq 'new name';
  print "ok 13\n";

  # Set and test a second alias.
  $kernel->alias_set( 'second name' );
  @aliases = $kernel->alias_list( $session );
  print "not "
    unless ( @aliases == 2 and
             grep( /^new name$/, @aliases ) == 1 and
             grep( /^second name$/, @aliases ) == 1
           );
  print "ok 14\n";

  print "not " if $kernel->alias_list($session) eq 2;
  print "ok 15\n";
}

# Catch SIGIDLE and SIGZOMBIE.

sub machine_signal {
  my ($kernel, $heap, $signal) = @_[KERNEL, HEAP, ARG0];

  # Count and handle SIGIDLE and SIGZOMBIE.  The latter is
  # nonmaskable, however, so the program continues to run.

  if ($signal eq 'IDLE') {
    $heap->{idle_count}++;
    return $kernel->sig_handled();
  }
  elsif ($signal eq 'ZOMBIE') {
    $heap->{zombie_count}++;
    return $kernel->sig_handled();
  }

  # We must still return 0 until significant return values are fully
  # removed.
  return 0;
}

# Make sure we got one SIGIDLE and one SIGZOMBIE.

sub machine_stop {
  my $heap = $_[HEAP];

  print "not " unless $heap->{idle_count} == 1;
  print "ok 19\n";

  print "not " unless $heap->{zombie_count} == 1;
  print "ok 20\n";
}

### Main loop.

print "ok 1\n";

# Spawn a state machine for testing.

POE::Session->create
  ( inline_states =>
    { _start  => \&machine_start,
      _signal => \&machine_signal,
      _stop   => \&machine_stop
    },
  );

# Spawn a second machine to test for alias removal.

print "ok 16\n";

my $sigidle_test = 1;
my $sigzombie_test = 1;

POE::Session->create
  ( inline_states =>
    { _start =>
      sub {
        $_[KERNEL]->alias_set( 'a_sample_alias' );
        print "not " if $_[KERNEL]->alias_remove( 'a_sample_alias' );
        print "ok 17\n";
      },
      _signal =>
      sub {
        $sigidle_test   = 0 if $_[0] eq 'IDLE';
        $sigzombie_test = 0 if $_[0] eq 'ZOMBIE';
      },
      _stop => sub { },
    }
  );

print "ok 18\n";

# Now run the kernel until there's nothing left to do.

my $poe_kernel = POE::Kernel->new();
$poe_kernel->run();

print "ok 21\n";

exit;
